import type { ChatCompletionChunk } from "openai/resources/chat/completions";

import type { LLMEvent } from "@app/lib/api/llm/types/events";
import { EventError } from "@app/lib/api/llm/types/events";
import type { LLMClientMetadata } from "@app/lib/api/llm/types/options";
import { parseToolArguments } from "@app/lib/api/llm/utils/tool_arguments";
import logger from "@app/logger/logger";
import { assertNever } from "@app/types";

export async function* streamLLMEvents(
  chatCompletionStream: AsyncIterable<ChatCompletionChunk>,
  metadata: LLMClientMetadata
): AsyncGenerator<LLMEvent> {
  let textDelta = "";
  const toolCalls: Map<
    number,
    { id: string; name: string; arguments: string }
  > = new Map();
  const yieldedToolCallIds = new Set<string>();
  let toolCallsFinishReasonCount = 0;

  for await (const chunk of chatCompletionStream) {
    const choice = chunk.choices[0];
    if (!choice) {
      continue;
    }
    const delta = choice.delta;

    // Handle text content.
    // Note: In Chat Completions API, reasoning tokens are part of the text delta
    if (delta.content) {
      textDelta += delta.content;
      yield {
        type: "text_delta",
        content: {
          delta: delta.content,
        },
        metadata,
      };
    }

    // Handle tool calls.
    if (delta.tool_calls) {
      for (const toolCallDelta of delta.tool_calls) {
        const index = toolCallDelta.index;
        const existing = toolCalls.get(index);

        if (toolCallDelta.id) {
          toolCalls.set(index, {
            id: toolCallDelta.id,
            name: toolCallDelta.function?.name ?? "",
            arguments: toolCallDelta.function?.arguments ?? "",
          });
        } else if (existing && toolCallDelta.function?.arguments) {
          existing.arguments += toolCallDelta.function.arguments;
        } else if (existing && toolCallDelta.function?.name) {
          existing.name += toolCallDelta.function.name;
        }
      }
    }

    // Handle finish reason.
    if (choice.finish_reason) {
      if (chunk.usage) {
        // Token usage is sent when we receive the finish reason
        yield {
          type: "token_usage",
          content: {
            inputTokens: chunk.usage.prompt_tokens,
            outputTokens: chunk.usage.completion_tokens,
            totalTokens: chunk.usage.total_tokens,
            cachedTokens: chunk.usage.prompt_tokens_details?.cached_tokens,
          },
          metadata,
        };
      }
      switch (choice.finish_reason) {
        case "stop":
          if (textDelta) {
            yield {
              type: "text_generated",
              content: {
                text: textDelta,
              },
              metadata,
            };
          }
          break;

        case "tool_calls":
          toolCallsFinishReasonCount += 1;
          if (toolCallsFinishReasonCount > 1) {
            logger.warn(
              {
                chunkId: chunk.id,
                clientId: metadata.clientId,
                finishReasonCount: toolCallsFinishReasonCount,
                modelId: metadata.modelId,
                toolCallsCount: toolCalls.size,
              },
              "Provider stream emitted finish_reason=tool_calls more than once."
            );
          }

          if (textDelta) {
            yield {
              type: "text_generated",
              content: {
                text: textDelta,
              },
              metadata,
            };
          }

          const indexesByToolCallId = new Map<string, number[]>();
          for (const [index, toolCall] of toolCalls.entries()) {
            if (!toolCall.id) {
              continue;
            }

            const indexes = indexesByToolCallId.get(toolCall.id) ?? [];
            indexes.push(index);
            indexesByToolCallId.set(toolCall.id, indexes);
          }

          for (const [toolCallId, indexes] of indexesByToolCallId.entries()) {
            if (indexes.length > 1) {
              logger.warn(
                {
                  chunkId: chunk.id,
                  clientId: metadata.clientId,
                  indexes,
                  modelId: metadata.modelId,
                  toolCallId,
                },
                "Provider stream produced duplicate tool_call ids across indexes."
              );
            }
          }

          // Yield all tool calls.
          for (const toolCall of toolCalls.values()) {
            if (toolCall.id && toolCall.name) {
              if (yieldedToolCallIds.has(toolCall.id)) {
                logger.warn(
                  {
                    chunkId: chunk.id,
                    clientId: metadata.clientId,
                    modelId: metadata.modelId,
                    toolCallId: toolCall.id,
                  },
                  "Skipping duplicate tool_call event from provider stream."
                );
                continue;
              }

              yieldedToolCallIds.add(toolCall.id);
              yield {
                type: "tool_call",
                content: {
                  id: toolCall.id,
                  name: toolCall.name,
                  arguments: parseToolArguments(
                    toolCall.arguments,
                    toolCall.name
                  ),
                },
                metadata,
              };
            }
          }
          break;

        case "length":
          yield new EventError(
            {
              type: "maximum_length",
              isRetryable: false,
              message: "Maximum length reached",
            },
            metadata
          );
          break;

        case "content_filter":
          yield new EventError(
            {
              type: "refusal_error",
              isRetryable: false,
              message: "Content filtered",
            },
            metadata
          );
          break;

        case "function_call":
          // Function calls are handled via tool_calls deltas
          break;

        default:
          // Handle other finish reasons as needed
          assertNever(choice.finish_reason);
      }
    }
  }
}
