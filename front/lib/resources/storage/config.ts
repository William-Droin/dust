import { EnvironmentConfig } from "@app/types";

export const dbConfig = {
  getRequiredFrontDatabaseURI: (): string => {
    return EnvironmentConfig.getEnvVariable("FRONT_DATABASE_URI");
  },
  getFrontReplicaDatabaseURI: (): string | undefined => {
    return EnvironmentConfig.getOptionalEnvVariable(
      "FRONT_DATABASE_READ_REPLICA_URI"
    );
  },
};
