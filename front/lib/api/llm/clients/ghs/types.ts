import flatMap from "lodash/flatMap";

import type { LLMParameters } from "@app/lib/api/llm/types/options";
import type { ModelIdType } from "@app/types";
import { GHS_OSS_120B_INSTRUCT_MODEL_ID } from "@app/types";

export const GHS_MODEL_FAMILIES = ["oss"] as const;
export type GhsModelFamily = (typeof GHS_MODEL_FAMILIES)[number];

export const GHS_MODEL_FAMILY_CONFIGS: Record<
  GhsModelFamily,
  {
    modelIds: ModelIdType[];
    overwrites: Partial<LLMParameters>;
  }
> = {
  oss: {
    modelIds: [GHS_OSS_120B_INSTRUCT_MODEL_ID],
    overwrites: { reasoningEffort: "none" },
  },
};

export type GhsWhitelistedModelId = {
  [K in GhsModelFamily]: (typeof GHS_MODEL_FAMILY_CONFIGS)[K]["modelIds"][number];
}[GhsModelFamily];
const GHS_WHITELISTED_MODEL_IDS = flatMap<GhsWhitelistedModelId>(
  Object.values(GHS_MODEL_FAMILY_CONFIGS).map((config) => config.modelIds)
);

export function isGhsWhitelistedModelId(
  modelId: ModelIdType
): modelId is GhsWhitelistedModelId {
  return new Set<string>(GHS_WHITELISTED_MODEL_IDS).has(modelId);
}

export function getGhsModelFamilyFromModelId(
  modelId: GhsWhitelistedModelId
): GhsModelFamily {
  const family = GHS_MODEL_FAMILIES.find((family) =>
    GHS_MODEL_FAMILY_CONFIGS[family].modelIds.includes(modelId)
  );
  if (!family) {
    throw new Error(
      `Model ID ${modelId} does not belong to any Ghs model family`
    );
  }
  return family;
}

export function overwriteLLMParameters(
  llmParameters: LLMParameters & { modelId: GhsWhitelistedModelId }
): LLMParameters & {
  modelId: GhsWhitelistedModelId;
  clientId: "ghs";
} {
  const config = Object.values(GHS_MODEL_FAMILY_CONFIGS).find((config) =>
    new Set<string>(config.modelIds).has(llmParameters.modelId)
  );

  return {
    ...llmParameters,
    ...config?.overwrites,
    clientId: "ghs" as const,
  };
}
