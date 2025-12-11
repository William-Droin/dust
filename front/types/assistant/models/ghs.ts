import type { ModelConfigurationType } from "@app/types";

export const GHS_OSS_120B_INSTRUCT_MODEL_ID =
  "openai/gpt-oss-120b" as const;

export const GHS_OSS_120B_INSTRUCT_MODEL_CONFIG: ModelConfigurationType =
  {
    providerId: "ghs",
    modelId: GHS_OSS_120B_INSTRUCT_MODEL_ID,
    displayName: "GHS oss 120b",
    contextSize: 128_000,
    recommendedTopK: 32,
    recommendedExhaustiveTopK: 64, // 32_768
    largeModel: true,
    description: "Special GPT model tuned for GHS",
    shortDescription: "GPT model tuned for GHS.",
    isLegacy: false,
    isLatest: false,
    generationTokensCount: 2048,
    supportsVision: false,
    minimumReasoningEffort: "none",
    maximumReasoningEffort: "none",
    defaultReasoningEffort: "none",
    tokenizer: { type: "tiktoken", base: "o200k_harmony" },
  };