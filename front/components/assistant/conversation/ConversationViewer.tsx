import type { ListRange } from "react-virtuoso";
import { Virtuoso } from "react-virtuoso";
import debounce from "lodash/debounce";
import React, {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";

import { AgentInputBar } from "@app/components/assistant/conversation/AgentInputBar";
import { ConversationErrorDisplay } from "@app/components/assistant/conversation/ConversationError";
import {
  ConversationListProvider,
} from "@app/components/assistant/conversation/ConversationListContext";
import {
  createPlaceholderAgentMessage,
  createPlaceholderUserMessage,
  submitMessage,
} from "@app/components/assistant/conversation/lib";
import { MessageItem } from "@app/components/assistant/conversation/MessageItem";
import type {
  VirtuosoMessage,
  VirtuosoMessageListContext,
} from "@app/components/assistant/conversation/types";
import {
  areSameRank,
  getMessageRank,
  isMessageTemporayState,
  isUserMessage,
  makeInitialMessageStreamState,
} from "@app/components/assistant/conversation/types";
import { ConversationViewerEmptyState } from "@app/components/assistant/ConversationViewerEmptyState";
import { useEnableBrowserNotification } from "@app/hooks/useEnableBrowserNotification";
import { useEventSource } from "@app/hooks/useEventSource";
import { useSendNotification } from "@app/hooks/useNotification";
import { getLightAgentMessageFromAgentMessage } from "@app/lib/api/assistant/citations";
import type { AgentMessageFeedbackType } from "@app/lib/api/assistant/feedback";
import { getUpdatedParticipantsFromEvent } from "@app/lib/client/conversation/event_handlers";
import type { DustError } from "@app/lib/error";
import {
  useConversation,
  useConversationFeedbacks,
  useConversationMarkAsRead,
  useConversationMessages,
  useConversationParticipants,
  useConversations,
} from "@app/lib/swr/conversations";
import { classNames } from "@app/lib/utils";
import type {
  AgentGenerationCancelledEvent,
  AgentMention,
  AgentMessageDoneEvent,
  AgentMessageNewEvent,
  ContentFragmentsType,
  ContentFragmentType,
  ConversationTitleEvent,
  LightAgentMessageType,
  LightMessageType,
  Result,
  RichMention,
  UserMention,
  UserMessageNewEvent,
  UserType,
  WorkspaceType,
} from "@app/types";
import { assertNever, isRichAgentMention } from "@app/types";
import { Err, isContentFragmentType, isUserMessageType, Ok } from "@app/types";

const DEFAULT_PAGE_LIMIT = 50;
const PLACEHOLDER_REFRESH_DELAY_MS = 5000;
const isLightAgentMessageType = (
  message: LightMessageType
): message is LightAgentMessageType => message.type === "agent_message";

// A conversation must be unread and older than that to enable the suggestion of enabling notifications.
const DELAY_BEFORE_SUGGESTING_PUSH_NOTIFICATION_ACTIVATION = 60 * 60 * 1000; // 1 hour

interface ConversationViewerProps {
  conversationId: string;
  agentBuilderContext?: VirtuosoMessageListContext["agentBuilderContext"];
  setPlanLimitReached?: (planLimitReached: boolean) => void;
  owner: WorkspaceType;
  user: UserType;
}

/**
 *
 * @param isInModal is the conversation happening in a side modal, i.e. when testing an agent?
 * @returns
 */
export const ConversationViewer = ({
  owner,
  user,
  conversationId,
  agentBuilderContext,
  setPlanLimitReached,
}: ConversationViewerProps) => {
  const sendNotification = useSendNotification();

  const {
    conversation,
    conversationError,
    isConversationLoading,
    mutateConversation,
  } = useConversation({
    conversationId,
    workspaceId: owner.sId,
  });

  const { markAsRead } = useConversationMarkAsRead({
    conversation,
    workspaceId: owner.sId,
  });

  const { askForPermission } = useEnableBrowserNotification();

  const shouldShowPushNotificationActivation = useMemo(() => {
    if (!conversation?.sId || !conversation.unread) {
      return false;
    }

    const delay = new Date().getTime() - conversation.updated;

    return delay > DELAY_BEFORE_SUGGESTING_PUSH_NOTIFICATION_ACTIVATION;
  }, [conversation?.sId, conversation?.unread, conversation?.updated]);

  useEffect(() => {
    if (shouldShowPushNotificationActivation) {
      void askForPermission();
    }
  }, [shouldShowPushNotificationActivation, askForPermission]);

  const { mutateConversations } = useConversations({
    workspaceId: owner.sId,
    options: {
      disabled: true,
    },
  });

  const {
    isLoadingInitialData,
    isMessagesLoading,
    isValidating,
    messages,
    setSize,
    size,
    mutateMessages,
  } = useConversationMessages({
    conversationId,
    workspaceId: owner.sId,
    limit: DEFAULT_PAGE_LIMIT,
  });

  const { mutateConversationParticipants } = useConversationParticipants({
    conversationId,
    workspaceId: owner.sId,
    options: { disabled: true }, // We don't need the participants, only the mutator.
  });

  const [initialListData, setInitialListData] = useState<
    VirtuosoMessage[] | undefined
  >(undefined);
  const listStateRef = useRef<VirtuosoMessage[]>([]);
  const listRef = useRef<HTMLElement | Window | null>(null);
  const [isAtBottom, setIsAtBottom] = useState(true);
  const placeholderRefreshTimeouts = useRef<Map<number, number>>(new Map());

  // Keep our ref in sync so callbacks can always see the latest list state
  // (avoids stale closures during streaming + sending follow-up messages).
  useEffect(() => {
    listStateRef.current = initialListData ?? [];
  }, [initialListData]);

  useEffect(() => {
    return () => {
      placeholderRefreshTimeouts.current.forEach((timeoutId) => {
        clearTimeout(timeoutId);
      });
      placeholderRefreshTimeouts.current.clear();
    };
  }, [conversationId]);

  // Setup the initial list data when the conversation is loaded.
  useEffect(() => {
    // We also wait in case of revalidation because otherwise we might use stale data from the swr cache.
    // Consider this scenario:
    // Load a conversation A, send a message, answer is streaming (streaming events have a short TTL).
    // Switch to conversation B, wait till A is done streaming, then switch back to A.
    // Without waiting for revalidation, we would use whatever data was in the swr cache and see the last message as "streaming" (old data, no more streaming events).
    if (!initialListData && messages.length > 0 && !isValidating) {
      const messagesToRender = convertLightMessageTypeToVirtuosoMessages(
        messages.flatMap((m) => m.messages)
      );

      listStateRef.current = messagesToRender;
      setInitialListData(messagesToRender);
    }
  }, [initialListData, messages, setInitialListData, isValidating]);

  // This is to handle we just fetched more messages by scrolling up.
  useEffect(() => {
    if (!initialListData || initialListData.length === 0) {
      return;
    }

    const ranks = initialListData.map(getMessageRank);
    const minRank = Math.min(...ranks);
    const maxRank = Math.max(...ranks);
    const messagesFromBackend = messages.flatMap((m) => m.messages);

    const olderMessagesFromBackend = messagesFromBackend.filter(
      (m) => m.rank < minRank
    );
    const recentMessagesFromBackend = messagesFromBackend.filter(
      (m) => m.rank > maxRank
    );

    if (olderMessagesFromBackend.length > 0 || recentMessagesFromBackend.length > 0) {
      setInitialListData((current) => {
        if (!current) {
          return current;
        }
        const next = [
          ...convertLightMessageTypeToVirtuosoMessages(
            olderMessagesFromBackend
          ),
          ...current,
          ...convertLightMessageTypeToVirtuosoMessages(
            recentMessagesFromBackend
          ),
        ];
        listStateRef.current = next;
        return next;
      });
    }
  }, [messages, initialListData]);

  useEffect(() => {
    if (!initialListData || initialListData.length === 0) {
      return;
    }

    const agentMessagesByRank = new Map(
      messages
        .flatMap((m) => m.messages)
        .filter((message) =>
          !isContentFragmentType(message) && !isUserMessageType(message)
        )
        .filter(isLightAgentMessageType)
        .map((message) => [message.rank, message] as const)
    );

    setInitialListData((current) => {
      if (!current) {
        return current;
      }
      let didChange = false;
      const next = current.map((message) => {
        if (
          isMessageTemporayState(message) &&
          message.agentState === "placeholder"
        ) {
          const resolvedMessage = agentMessagesByRank.get(message.message.rank);
          if (resolvedMessage) {
            const nextMessage = makeInitialMessageStreamState(resolvedMessage);
            didChange = true;
            return nextMessage;
          }
        }
        return message;
      });
      if (didChange) {
        listStateRef.current = next;
      }
      return didChange ? next : current;
    });
  }, [initialListData, messages]);

  const { feedbacks } = useConversationFeedbacks({
    conversationId: conversationId ?? "",
    workspaceId: owner.sId,
  });

  // Hooks related to conversation events streaming.

  const buildEventSourceURL = useCallback(
    (lastEvent: string | null) => {
      const esURL = `/api/w/${owner.sId}/assistant/conversations/${conversationId}/events`;
      let lastEventId = "";
      if (lastEvent) {
        const eventPayload: {
          eventId: string;
        } = JSON.parse(lastEvent);
        lastEventId = eventPayload.eventId;
      }
      const url = esURL + "?lastEventId=" + lastEventId;

      return url;
    },
    [conversationId, owner.sId]
  );

  const debouncedMarkAsRead = useMemo(
    () => debounce(markAsRead, 2000),
    [markAsRead]
  );

  const eventIds = useRef<string[]>([]);

  // Only conversation related events are handled here.
  const onEventCallback = useCallback(
    (eventStr: string) => {
      const eventPayload: {
        eventId: string;
        data:
          | UserMessageNewEvent
          | AgentMessageNewEvent
          | AgentMessageDoneEvent
          | AgentGenerationCancelledEvent
          | ConversationTitleEvent;
      } = JSON.parse(eventStr);
      const event = eventPayload.data;

      if (!eventIds.current.includes(eventPayload.eventId)) {
        eventIds.current.push(eventPayload.eventId);
        switch (event.type) {
          case "user_message_new": {
            const userMessage: VirtuosoMessage = {
              ...event.message,
              contentFragments: [],
            };
            const predicate = (m: VirtuosoMessage) =>
              isUserMessage(m) && areSameRank(m, userMessage);

            setInitialListData((current) => {
              if (!current) {
                return current;
              }
              const exists = current.find(predicate);
              if (exists) {
                return current;
              }
              const next = [...current, { ...event.message, contentFragments: [] }];
              listStateRef.current = next;
              return next;
            });

            void mutateConversationParticipants(
              async (participants) =>
                getUpdatedParticipantsFromEvent(participants, event),
              { revalidate: false }
            );

            void mutateConversations(
              (currentData) => {
                if (!currentData?.conversations) {
                  return currentData;
                }
                return {
                  conversations: currentData.conversations.map((c) =>
                    c.sId === conversationId ? { ...c, hasError: false } : c
                  ),
                };
              },
              { revalidate: false }
            );
            break;
          }
          case "agent_message_new": {
            const messageStreamState = makeInitialMessageStreamState(
              getLightAgentMessageFromAgentMessage(event.message)
            );

            const predicate = (m: VirtuosoMessage) =>
              isMessageTemporayState(m) && areSameRank(m, messageStreamState);

            setInitialListData((current) => {
              if (!current) {
                return current;
              }
              const exists = current.find(predicate);
              if (exists) {
                const next = current.map((m) =>
                  predicate(m) ? messageStreamState : m
                );
                listStateRef.current = next;
                return next;
              }
              const next = [...current, messageStreamState];
              listStateRef.current = next;
              return next;
            });

            void mutateConversationParticipants(async (participants) =>
              getUpdatedParticipantsFromEvent(participants, event)
            );
            break;
          }

          case "agent_generation_cancelled":
            void mutateMessages();
            break;

          case "conversation_title":
            void mutateConversation(
              (current) => {
                if (current) {
                  return {
                    ...current,
                    conversation: {
                      ...current.conversation,
                      title: event.title,
                    },
                  };
                }
              },
              { revalidate: false }
            );

            // to refresh the list of convos in the sidebar (title)
            void mutateConversations(
              (currentData) => {
                if (currentData?.conversations) {
                  return {
                    ...currentData,
                    conversations: currentData.conversations.map((c) =>
                      c.sId === conversationId
                        ? { ...c, title: event.title }
                        : c
                    ),
                  };
                }
              },
              { revalidate: false }
            );

            break;
          case "agent_message_done":
            // Mark as read and do not mutate the list of convos in the sidebar to avoid useless network request.
            // Debounce the call as we might receive multiple events for the same conversation (as we replay the events).
            void debouncedMarkAsRead(event.conversationId, false);

            // Update the conversation hasError state in the local cache without making a network request.
            void mutateConversations(
              (currentData) => {
                if (!currentData?.conversations) {
                  return currentData;
                }
                return {
                  conversations: currentData.conversations.map((c) =>
                    c.sId === event.conversationId
                      ? { ...c, hasError: event.status === "error" }
                      : c
                  ),
                };
              },
              { revalidate: false }
            );
            break;
          default:
            ((t: never) => {
              console.error("Unknown event type", t);
            })(event);
        }
      }
    },
    [
      conversationId,
      debouncedMarkAsRead,
      mutateConversation,
      mutateConversationParticipants,
      mutateConversations,
      mutateMessages,
    ]
  );

  useEventSource(
    buildEventSourceURL,
    onEventCallback,
    `conversation-${conversationId}`,
    {
      // We only start consuming the stream when the conversation has been loaded and we have a first page of message.
      isReadyToConsumeStream:
        !isConversationLoading &&
        !isLoadingInitialData &&
        messages.length !== 0,
    }
  );

  const handleSubmit = useCallback(
    async (
      input: string,
      mentions: RichMention[],
      contentFragments: ContentFragmentsType
    ): Promise<Result<undefined, DustError>> => {
      // NOTE: do NOT depend on `initialListData` here. This callback must keep working
      // for follow-up messages; we rely on `listStateRef.current` for latest list state.
      const messageData = {
        input,
        mentions: mentions.map((mention) => {
          switch (mention.type) {
            case "agent": {
              return {
                configurationId: mention.id,
              } satisfies AgentMention;
            }
            case "user": {
              return {
                type: "user",
                userId: mention.id,
              } satisfies UserMention;
            }
            default:
              assertNever(mention.type);
          }
        }),
        contentFragments,
      };

      const currentList = listStateRef.current;
      const lastMessageRank = currentList.length
        ? Math.max(...currentList.map(getMessageRank))
        : 0;

      let rank =
        lastMessageRank +
        // Content fragments are prepended as "message" in the conversation, before the user message.
        // We need to account for their ranks as well.
        contentFragments.contentNodes.length +
        contentFragments.uploaded.length +
        // +1 for the user message
        1;
      const placeholderUserMsg: VirtuosoMessage = createPlaceholderUserMessage({
        input,
        mentions,
        user,
        rank,
        contentFragments,
      });

      const placeholderAgentMessages: VirtuosoMessage[] = [];
      for (const mention of mentions) {
        if (isRichAgentMention(mention)) {
          // +1 per agent message mentioned
          rank += 1;
          placeholderAgentMessages.push(
            createPlaceholderAgentMessage({ mention, rank })
          );
        }
      }

      setInitialListData((current) => {
        const next = (current ?? []).concat(
          placeholderUserMsg,
          ...placeholderAgentMessages
        );
        // Update the ref immediately so subsequent sends don't see stale state.
        listStateRef.current = next;
        return next;
      });

      for (const placeholder of placeholderAgentMessages) {
        const placeholderRank = getMessageRank(placeholder);
        if (placeholderRefreshTimeouts.current.has(placeholderRank)) {
          continue;
        }
        const timeoutId = window.setTimeout(() => {
          const current = listStateRef.current;
          const isStillPlaceholder = current.some(
            (message) =>
              isMessageTemporayState(message) &&
              message.agentState === "placeholder" &&
              getMessageRank(message) === placeholderRank
          );
          if (isStillPlaceholder) {
            void mutateMessages();
          }
          placeholderRefreshTimeouts.current.delete(placeholderRank);
        }, PLACEHOLDER_REFRESH_DELAY_MS);
        placeholderRefreshTimeouts.current.set(placeholderRank, timeoutId);
      }

      if (mentions.some(isRichAgentMention)) {
        setTimeout(() => {
          if (listRef.current instanceof HTMLElement) {
            listRef.current.scrollTo({ top: 0, behavior: "auto" });
          }
        }, 0);
      } else if (isAtBottom) {
        setTimeout(() => {
          if (listRef.current instanceof HTMLElement) {
            listRef.current.scrollTo({
              top: listRef.current.scrollHeight,
              behavior: "smooth",
            });
          }
        }, 0);
      }

      const result = await submitMessage({
        owner,
        user,
        conversationId,
        messageData,
      });

      if (result.isErr()) {
        console.error("[ConversationViewer] Failed to submit message", {
          conversationId,
          error: result.error,
        });
        if (result.error.type === "plan_limit_reached_error") {
          setPlanLimitReached?.(true);
        } else {
          sendNotification({
            title: result.error.title,
            description: result.error.message,
            type: "error",
          });
        }

        // If the API errors, the original data will be rolled back by SWR automatically.
        console.error("Failed to post message:", result.error);
        return new Err({
          code: "internal_error",
          name: "FailedToPostMessage",
          message: `Failed to post message ${result.error}`,
        });
      }

      const {
        message: messageFromBackend,
        contentFragments: contentFragmentsFromBackend,
      } = result.value;

      // map() is how we update the state of virtuoso messages.
      setInitialListData((current) => {
        const next = (current ?? []).map((m) =>
          areSameRank(m, placeholderUserMsg)
            ? {
                ...messageFromBackend,
                contentFragments: contentFragmentsFromBackend,
              }
            : m
        );
        listStateRef.current = next;
        return next;
      });

      void mutateConversations(
        (currentData) => {
          if (!currentData?.conversations) {
            return currentData;
          }
          return {
            conversations: currentData.conversations.map((c) =>
              c.sId === conversationId
                ? { ...c, updated: new Date().getTime() }
                : c
            ),
          };
        },
        { revalidate: false }
      );

      return new Ok(undefined);
    },
    [
      user,
      owner,
      conversationId,
      setPlanLimitReached,
      sendNotification,
      mutateMessages,
      mutateConversations,
    ]
  );

  const onRangeChanged = useCallback(
    (range: ListRange) => {
      const isLoadingData =
        isLoadingInitialData || isMessagesLoading || isValidating;

      if (
        range.startIndex === 0 &&
        messages.at(0)?.hasMore &&
        !isLoadingData
      ) {
        void setSize(size + 1);
      }
    },
    [
      isLoadingInitialData,
      isMessagesLoading,
      isValidating,
      messages,
      setSize,
      size,
    ]
  );

  const computeItemKey = useCallback(
    ({
      data,
      context,
    }: {
      data: VirtuosoMessage;
      context: VirtuosoMessageListContext;
    }) => {
      return `conversation-${context.conversationId}-message-rank-${isMessageTemporayState(data) ? data.message.rank : data.rank}`;
    },
    []
  );

  const feedbacksByMessageId = useMemo(() => {
    return feedbacks.reduce(
      (acc, feedback) => {
        acc[feedback.messageId] = feedback;
        return acc;
      },
      {} as Record<string, AgentMessageFeedbackType>
    );
  }, [feedbacks]);

  const context = useMemo(() => {
    return {
      user,
      owner,
      handleSubmit,
      conversationId,
      agentBuilderContext,
      feedbacksByMessageId,
    };
  }, [
    user,
    owner,
    handleSubmit,
    conversationId,
    agentBuilderContext,
    feedbacksByMessageId,
  ]);

  const inputBarContext = useMemo(
    () => ({
      user,
      owner,
      handleSubmit,
      conversationId,
      agentBuilderContext,
      feedbacksByMessageId,
    }),
    [
      user,
      owner,
      handleSubmit,
      conversationId,
      agentBuilderContext,
      feedbacksByMessageId,
    ]
  );

  const Footer = useMemo(
    () => () => <AgentInputBar context={inputBarContext} />,
    [inputBarContext]
  );

  const methods = useMemo(
    () => ({
      data: {
        get: () => initialListData ?? [],
        set: (items: VirtuosoMessage[]) => setInitialListData(items),
        append: (items: VirtuosoMessage[]) =>
          setInitialListData((current) =>
            current ? [...current, ...items] : current
          ),
        prepend: (items: VirtuosoMessage[]) =>
          setInitialListData((current) =>
            current ? [...items, ...current] : current
          ),
        map: (mapper: (item: VirtuosoMessage) => VirtuosoMessage) =>
          setInitialListData((current) =>
            current ? current.map(mapper) : current
          ),
        find: (predicate: (item: VirtuosoMessage) => boolean) =>
          (initialListData ?? []).find(predicate),
      },
      scrollToItem: ({ index, behavior, align }: {
        index: number | "LAST";
        behavior?: ScrollBehavior;
        align?: "start" | "end" | "center";
      }) => {
        if (!listRef.current || !(listRef.current instanceof HTMLElement)) {
          return;
        }
        const targetIndex =
          index === "LAST" ? (initialListData?.length ?? 1) - 1 : index;
        const children = listRef.current.querySelectorAll(
          "[data-virtuoso-item]"
        );
        const target = children[targetIndex] as HTMLElement | undefined;
        if (!target) {
          return;
        }
        const parent = listRef.current;
        const parentRect = parent.getBoundingClientRect();
        const targetRect = target.getBoundingClientRect();
        const offset =
          align === "start"
            ? targetRect.top - parentRect.top
            : align === "end"
              ? targetRect.bottom - parentRect.bottom
              : targetRect.top - parentRect.top - parentRect.height / 2;
        parent.scrollTo({ top: parent.scrollTop + offset, behavior });
      },
      isAtBottom,
      context,
    }),
    [context, initialListData, isAtBottom]
  );

  return (
    <>
      {conversationError && (
        <ConversationErrorDisplay error={conversationError} />
      )}
      <ConversationListProvider value={methods}>
        <Virtuoso
          data={initialListData ?? []}
          components={{
            Footer,
            EmptyPlaceholder: ConversationViewerEmptyState,
          }}
          itemContent={(index, data) => (
            <MessageItem
              data={data}
              context={context}
              index={index}
              prevData={index > 0 ? initialListData?.[index - 1] ?? null : null}
              nextData={
                index < (initialListData?.length ?? 0) - 1
                  ? initialListData?.[index + 1] ?? null
                  : null
              }
            />
          )}
          className={classNames(
            "dd-privacy-mask",
            "s-@container/conversation",
            "h-full w-full",
            agentBuilderContext ? "px-4" : "px-4 md:px-8"
          )}
          rangeChanged={onRangeChanged}
          initialTopMostItemIndex={(initialListData?.length ?? 1) - 1}
          followOutput={isAtBottom}
          increaseViewportBy={8192}
          scrollerRef={(el) => {
            listRef.current = el;
          }}
          atBottomStateChange={setIsAtBottom}
          computeItemKey={(index, item) => computeItemKey({ data: item, context })}
        />
      </ConversationListProvider>
    </>
  );
};

const convertLightMessageTypeToVirtuosoMessages = (
  messages: LightMessageType[]
) => {
  const output: VirtuosoMessage[] = [];
  let tempContentFragments: ContentFragmentType[] = [];

  messages.forEach((message) => {
    if (isContentFragmentType(message)) {
      tempContentFragments.push(message); // Collect content fragments.
    } else {
      let messageWithContentFragments: VirtuosoMessage;
      if (isUserMessageType(message)) {
        // Attach collected content fragments to the user message.
        messageWithContentFragments = {
          ...message,
          contentFragments: tempContentFragments,
        };
        tempContentFragments = []; // Reset the collected content fragments.

        // Start a new group for user messages.
        output.push(messageWithContentFragments);
      } else {
        messageWithContentFragments = makeInitialMessageStreamState(message);
        output.push(messageWithContentFragments);
      }
    }
  });
  return output;
};
