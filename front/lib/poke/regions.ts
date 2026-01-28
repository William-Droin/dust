import type { RegionType } from "@app/lib/api/regions/config";
import { assertNever } from "@app/types";

export const getRegionDisplay = (region: RegionType): string => {
  switch (region) {
    case "europe-west4":
      return "🇪🇺 Europe";
    case "us-central1":
      return "🇺🇸 United States";
    default:
      assertNever(region);
  }
};
