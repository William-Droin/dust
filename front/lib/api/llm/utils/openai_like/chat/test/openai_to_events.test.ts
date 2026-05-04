import type { ChatCompletionChunk } from "openai/resources/chat/completions";
import { describe, expect, it } from "vitest";

import { createAsyncGenerator } from "@app/lib/api/llm/utils";
import * as openai_to_events from "@app/lib/api/llm/utils/openai_like/chat/openai_to_events";

const metadata = {
  clientId: "openrouter",
  modelId: "gpt-oss-120b",
} as const;

describe("chat streamLLMEvents", () => {
  it("emits a single tool_call when the provider repeats the same id across indexes", async () => {
    const chunks: ChatCompletionChunk[] = [
      {
        id: "chatcmpl-1",
        object: "chat.completion.chunk",
        created: 1,
        model: "gpt-oss-120b",
        choices: [
          {
            index: 0,
            finish_reason: null,
            logprobs: null,
            delta: {
              tool_calls: [
                {
                  index: 0,
                  id: "call_duplicate",
                  type: "function",
                  function: {
                    name: "search",
                    arguments: "{\"query\":\"dsn\"}",
                  },
                },
                {
                  index: 1,
                  id: "call_duplicate",
                  type: "function",
                  function: {
                    name: "search",
                    arguments: "{\"query\":\"dsn\"}",
                  },
                },
              ],
            },
          },
        ],
      },
      {
        id: "chatcmpl-1",
        object: "chat.completion.chunk",
        created: 1,
        model: "gpt-oss-120b",
        choices: [
          {
            index: 0,
            finish_reason: "tool_calls",
            logprobs: null,
            delta: {},
          },
        ],
      },
    ];

    const result = [];
    for await (const event of openai_to_events.streamLLMEvents(
      createAsyncGenerator(chunks),
      metadata
    )) {
      result.push(event);
    }

    const toolCalls = result.filter((event) => event.type === "tool_call");
    expect(toolCalls).toHaveLength(1);
    expect(toolCalls[0]).toMatchObject({
      type: "tool_call",
      content: {
        id: "call_duplicate",
        name: "search",
        arguments: {
          query: "dsn",
        },
      },
    });
  });

  it("emits a single tool_call when finish_reason=tool_calls is repeated", async () => {
    const chunks: ChatCompletionChunk[] = [
      {
        id: "chatcmpl-2",
        object: "chat.completion.chunk",
        created: 1,
        model: "gpt-oss-120b",
        choices: [
          {
            index: 0,
            finish_reason: null,
            logprobs: null,
            delta: {
              tool_calls: [
                {
                  index: 0,
                  id: "call_once",
                  type: "function",
                  function: {
                    name: "list",
                    arguments: "{\"limit\":20}",
                  },
                },
              ],
            },
          },
        ],
      },
      {
        id: "chatcmpl-2",
        object: "chat.completion.chunk",
        created: 1,
        model: "gpt-oss-120b",
        choices: [
          {
            index: 0,
            finish_reason: "tool_calls",
            logprobs: null,
            delta: {},
          },
        ],
      },
      {
        id: "chatcmpl-2",
        object: "chat.completion.chunk",
        created: 1,
        model: "gpt-oss-120b",
        choices: [
          {
            index: 0,
            finish_reason: "tool_calls",
            logprobs: null,
            delta: {},
          },
        ],
      },
    ];

    const result = [];
    for await (const event of openai_to_events.streamLLMEvents(
      createAsyncGenerator(chunks),
      metadata
    )) {
      result.push(event);
    }

    const toolCalls = result.filter((event) => event.type === "tool_call");
    expect(toolCalls).toHaveLength(1);
    expect(toolCalls[0]).toMatchObject({
      type: "tool_call",
      content: {
        id: "call_once",
        name: "list",
        arguments: {
          limit: 20,
        },
      },
    });
  });
});
