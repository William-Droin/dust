import type { WebClient } from "@slack/web-api";
import type { ConversationsHistoryResponse } from "@slack/web-api/dist/types/response/ConversationsHistoryResponse";

import {
  reportSlackUsage,
  withSlackErrorHandling,
} from "@connectors/connectors/slack/lib/slack_client";
import type { ModelId } from "@connectors/types";
import { redisClient } from "@connectors/types/shared/redis_client";

const HOT_STORE_VERSION = "v1";
const HOT_STORE_TTL_MS = 6 * 60 * 60 * 1000;
const HOT_STORE_MAX_MESSAGES = 200;
const HOT_STORE_DEFAULT_LIMIT = 100;
const EVENT_DEDUPE_TTL_MS = 24 * 60 * 60 * 1000;

export type HotSlackMessage = {
  ts: string;
  channelId: string;
  threadTs: string | null;
  userId: string | null;
  botId: string | null;
  text: string;
  subtype: string | null;
  deleted: boolean;
  receivedAtMs: number;
};

function getTimelineKey(connectorId: ModelId, channelId: string) {
  return `slack:hot:${HOT_STORE_VERSION}:${connectorId}:${channelId}:timeline`;
}

function getMessageKey(
  connectorId: ModelId,
  channelId: string,
  messageTs: string
) {
  return `slack:hot:${HOT_STORE_VERSION}:${connectorId}:${channelId}:msg:${messageTs}`;
}

function getHydratedKey(connectorId: ModelId, channelId: string) {
  return `slack:hot:${HOT_STORE_VERSION}:${connectorId}:${channelId}:hydrated`;
}

function getEventDedupeKey(teamId: string, eventId: string) {
  return `slack:hot:${HOT_STORE_VERSION}:${teamId}:event:${eventId}`;
}

function tsToScore(ts: string) {
  return Number(ts.replace(".", ""));
}

function formatSlackTimestamp(ts: string) {
  const date = new Date(Number(ts) * 1000);

  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  const hours = String(date.getHours()).padStart(2, "0");
  const minutes = String(date.getMinutes()).padStart(2, "0");

  return `${year}${month}${day} ${hours}:${minutes}`;
}

async function trimTimeline(
  connectorId: ModelId,
  channelId: string
): Promise<void> {
  const redis = await redisClient({ origin: "slack_hot_store" });
  const timelineKey = getTimelineKey(connectorId, channelId);

  const messageCount = await redis.zCard(timelineKey);
  const overflow = messageCount - HOT_STORE_MAX_MESSAGES;
  if (overflow <= 0) {
    return;
  }

  const staleEntries = await redis.zRange(timelineKey, 0, overflow - 1);

  const multi = redis.multi();
  multi.zRemRangeByRank(timelineKey, 0, overflow - 1);
  for (const messageTs of staleEntries) {
    multi.del(getMessageKey(connectorId, channelId, messageTs));
  }
  await multi.exec();
}

async function upsertHotChannelMessages({
  connectorId,
  channelId,
  messages,
}: {
  connectorId: ModelId;
  channelId: string;
  messages: HotSlackMessage[];
}): Promise<void> {
  if (messages.length === 0) {
    return;
  }

  const redis = await redisClient({ origin: "slack_hot_store" });
  const timelineKey = getTimelineKey(connectorId, channelId);

  const multi = redis.multi();
  for (const message of messages) {
    multi.set(
      getMessageKey(connectorId, channelId, message.ts),
      JSON.stringify(message),
      {
        PX: HOT_STORE_TTL_MS,
      }
    );
    multi.zAdd(timelineKey, {
      score: tsToScore(message.ts),
      value: message.ts,
    });
  }
  multi.pExpire(timelineKey, HOT_STORE_TTL_MS);
  await multi.exec();

  await trimTimeline(connectorId, channelId);
}

export async function markHotStoreEventProcessed({
  teamId,
  eventId,
}: {
  teamId: string;
  eventId?: string;
}): Promise<boolean> {
  if (!eventId) {
    return true;
  }

  const redis = await redisClient({ origin: "slack_hot_store" });
  const result = await redis.set(getEventDedupeKey(teamId, eventId), "1", {
    NX: true,
    PX: EVENT_DEDUPE_TTL_MS,
  });

  return result === "OK";
}

export async function ingestHotChannelMessage({
  connectorId,
  channelId,
  event,
  receivedAtMs,
}: {
  connectorId: ModelId;
  channelId: string;
  event: {
    bot_id?: string;
    channel?: string;
    subtype?: string;
    text?: string;
    thread_ts?: string;
    ts?: string;
    user?: string;
  };
  receivedAtMs?: number;
}): Promise<void> {
  if (!event.ts || !channelId || !event.user || event.bot_id || event.subtype) {
    return;
  }

  await upsertHotChannelMessages({
    connectorId,
    channelId,
    messages: [
      {
        ts: event.ts,
        channelId,
        threadTs: event.thread_ts || null,
        userId: event.user,
        botId: event.bot_id || null,
        text: event.text ?? "",
        subtype: event.subtype || null,
        deleted: false,
        receivedAtMs: receivedAtMs ?? Date.now(),
      },
    ],
  });
}

export async function getRecentHotChannelMessages({
  connectorId,
  channelId,
  beforeTs,
  limit = HOT_STORE_DEFAULT_LIMIT,
}: {
  connectorId: ModelId;
  channelId: string;
  beforeTs: string;
  limit?: number;
}): Promise<HotSlackMessage[]> {
  const redis = await redisClient({ origin: "slack_hot_store" });
  const timelineKey = getTimelineKey(connectorId, channelId);
  const cutoffScore = tsToScore(beforeTs);

  const scores = await redis.zRangeWithScores(timelineKey, 0, -1);
  const messageTsList = scores
    .filter((entry) => entry.score < cutoffScore)
    .slice(-limit)
    .map((entry) => entry.value);

  if (messageTsList.length === 0) {
    return [];
  }

  const rawMessages = await redis.mGet(
    messageTsList.map((messageTs) =>
      getMessageKey(connectorId, channelId, messageTs)
    )
  );

  return rawMessages
    .map((rawMessage) =>
      rawMessage ? (JSON.parse(rawMessage) as HotSlackMessage) : null
    )
    .filter((message): message is HotSlackMessage => Boolean(message))
    .sort((a, b) => tsToScore(a.ts) - tsToScore(b.ts));
}

export async function hydrateHotChannelFromSlack({
  connectorId,
  slackClient,
  channelId,
  beforeTs,
  limit = HOT_STORE_DEFAULT_LIMIT,
}: {
  connectorId: ModelId;
  slackClient: WebClient;
  channelId: string;
  beforeTs: string;
  limit?: number;
}): Promise<HotSlackMessage[]> {
  reportSlackUsage({
    connectorId,
    method: "conversations.history",
    channelId,
    limit,
    useCase: "bot",
  });

  const response: ConversationsHistoryResponse = await withSlackErrorHandling(
    () =>
      slackClient.conversations.history({
        channel: channelId,
        latest: beforeTs,
        limit,
      })
  );

  if (!response.ok || !response.messages) {
    throw new Error(response.error || "Failed to hydrate Slack hot channel");
  }

  const messages: HotSlackMessage[] = response.messages
    .filter(
      (message) =>
        Boolean(message.ts) &&
        Boolean(message.user) &&
        !message.bot_id &&
        !message.subtype
    )
    .map((message) => ({
      ts: message.ts as string,
      channelId,
      threadTs: message.thread_ts || null,
      userId: message.user || null,
      botId: message.bot_id || null,
      text: message.text ?? "",
      subtype: message.subtype || null,
      deleted: false,
      receivedAtMs: Date.now(),
    }));

  await upsertHotChannelMessages({
    connectorId,
    channelId,
    messages,
  });

  const redis = await redisClient({ origin: "slack_hot_store" });
  await redis.set(getHydratedKey(connectorId, channelId), String(Date.now()), {
    PX: HOT_STORE_TTL_MS,
  });

  return getRecentHotChannelMessages({
    connectorId,
    channelId,
    beforeTs,
    limit,
  });
}

export async function isHotChannelHydrated({
  connectorId,
  channelId,
}: {
  connectorId: ModelId;
  channelId: string;
}): Promise<boolean> {
  const redis = await redisClient({ origin: "slack_hot_store" });
  return (await redis.exists(getHydratedKey(connectorId, channelId))) === 1;
}

export function formatHotChannelMessages({
  channelName,
  beforeTs,
  messages,
}: {
  channelName: string;
  beforeTs: string;
  messages: HotSlackMessage[];
}): string | null {
  if (messages.length === 0) {
    return null;
  }

  const header =
    `Recent channel messages in ${channelName} before the current message (${formatSlackTimestamp(
      beforeTs
    )}).` + " Use this for immediate channel context.";

  const lines = messages.map((message) => {
    const author = message.userId
      ? `<@${message.userId}>`
      : message.botId
        ? `[bot ${message.botId}]`
        : "[unknown]";
    const text = message.text.trim() || "[no text]";

    return `>> ${author} [${formatSlackTimestamp(message.ts)}]:\n${text}`;
  });

  return `${header}\n${lines.join("\n\n")}`;
}
