import { Context } from "@temporalio/activity";
import type { ConnectionOptions } from "@temporalio/client";
import { Client, Connection, WorkflowNotFoundError } from "@temporalio/client";
import { NativeConnection } from "@temporalio/worker";
import dns from "node:dns/promises";
import os from "node:os";
import fs from "fs-extra";

import logger from "@connectors/logger/logger";
import type { ModelId } from "@connectors/types";

// Assuming one cached workflows takes 2MB on average,
// we can cache 292 workflows in 4096MB, which is the max heap size
// we give to our temporal workers.
// Add some margin to it, so we don't hit the limit, and we get to 200.
export const TEMPORAL_MAXED_CACHED_WORKFLOWS = 200;

// This is a singleton connection to the Temporal server.
let TEMPORAL_CLIENT: Client | undefined;

const CONNECTOR_ID_CACHE: Record<string, ModelId> = {};

/**
 * Small helper to safely stringify errors.
 */
function serializeError(err: any) {
  return {
    name: err?.name,
    message: err?.message,
    stack: err?.stack,
    code: err?.code,
    errno: err?.errno,
    syscall: err?.syscall,
    address: err?.address,
    port: err?.port,
    cause: err?.cause,
    // Some errors hide useful bits in non-enumerable properties
    raw: err,
  };
}

/**
 * Debug helper to log the effective address and resolution details.
 * Keeps logs compact but high-signal.
 */
async function logTemporalConnectionDebug(address: string, where: string) {
  const host = address.split(":")[0] || "";

  try {
    const lookups = await dns.lookup(host, { all: true });
    logger.info(
      {
        where,
        address,
        host,
        lookups,
        node: process.version,
        platform: `${process.platform}/${process.arch}`,
      },
      "Temporal connection debug"
    );
  } catch (e) {
    logger.warn(
      { where, address, host, dnsError: serializeError(e) },
      "Temporal DNS lookup failed"
    );
  }

  // Proxy vars are frequent silent troublemakers in container environments
  logger.info(
    {
      where,
      HTTP_PROXY: process.env.HTTP_PROXY,
      HTTPS_PROXY: process.env.HTTPS_PROXY,
      ALL_PROXY: process.env.ALL_PROXY,
      NO_PROXY: process.env.NO_PROXY,
    },
    "Temporal proxy env"
  );

  // Network interfaces can be useful when diagnosing EADDRNOTAVAIL / bind issues
  try {
    logger.info(
      { where, ifaces: os.networkInterfaces() },
      "Temporal network interfaces"
    );
  } catch {
    // ignore
  }
}

export async function getTemporalClient(): Promise<Client> {
  if (TEMPORAL_CLIENT) {
    return TEMPORAL_CLIENT;
  }

  const connectionOptions = await getConnectionOptions();

  const address =
    (connectionOptions as any)?.address ?? process.env.TEMPORAL_ADDRESS ?? "";

  if (address) {
    await logTemporalConnectionDebug(address, "client");
  } else {
    logger.warn(
      {
        NODE_ENV: process.env.NODE_ENV,
        TEMPORAL_ADDRESS: process.env.TEMPORAL_ADDRESS,
      },
      "No Temporal address found in connection options or env"
    );
  }

  let connection;
  try {
    connection = await Connection.connect(connectionOptions);
  } catch (err) {
    logger.error(
      { err: serializeError(err), connectionOptions },
      "Failed to connect Temporal Client"
    );
    throw err;
  }

  const clientOptions: { connection: typeof connection; namespace?: string } = {
    connection,
  };
  if (process.env.TEMPORAL_CONNECTORS_NAMESPACE) {
    clientOptions.namespace = process.env.TEMPORAL_CONNECTORS_NAMESPACE;
  }
  const client = new Client(clientOptions);

  TEMPORAL_CLIENT = client;
  return client;
}

async function getConnectionOptions(): Promise<
  | {
      address: string;
      tls: ConnectionOptions["tls"];
    }
  | Record<string, never>
> {
  const { NODE_ENV = "development" } = process.env;
  const isDeployed = ["production", "staging"].includes(NODE_ENV);

  // In non-deployed environments we return {}, which makes the SDK default
  // to localhost:7233. This is intentionally preserved from your original file.
  if (!isDeployed) {
    return {};
  }

  const {
    TEMPORAL_CERT_PATH,
    TEMPORAL_CERT_KEY_PATH,
    TEMPORAL_CONNECTORS_NAMESPACE,
    TEMPORAL_ADDRESS,
  } = process.env;

  // If you provide TEMPORAL_ADDRESS in deployed envs, we can use it directly.
  // Otherwise we fall back to Temporal Cloud address based on namespace.
  const address =
    TEMPORAL_ADDRESS && TEMPORAL_ADDRESS.trim().length > 0
      ? TEMPORAL_ADDRESS.trim()
      : TEMPORAL_CONNECTORS_NAMESPACE
      ? `${TEMPORAL_CONNECTORS_NAMESPACE}.tmprl.cloud:7233`
      : undefined;

  // If no TLS is configured, we still allow connecting (useful for self-hosted).
  // But we keep the original strictness for Temporal Cloud, where TLS is required.
  const usingTemporalCloud =
    !!TEMPORAL_CONNECTORS_NAMESPACE &&
    !TEMPORAL_ADDRESS &&
    address?.endsWith(".tmprl.cloud:7233");

  if (!address) {
    throw new Error(
      `No Temporal address could be determined. Provide TEMPORAL_ADDRESS, or TEMPORAL_CONNECTORS_NAMESPACE. ` +
        `Current env: NODE_ENV=${NODE_ENV}, TEMPORAL_ADDRESS=${TEMPORAL_ADDRESS}, TEMPORAL_CONNECTORS_NAMESPACE=${TEMPORAL_CONNECTORS_NAMESPACE}`
    );
  }

  if (usingTemporalCloud) {
    if (
      !TEMPORAL_CERT_PATH ||
      !TEMPORAL_CERT_KEY_PATH ||
      !TEMPORAL_CONNECTORS_NAMESPACE
    ) {
      throw new Error(
        "TEMPORAL_CERT_PATH, TEMPORAL_CERT_KEY_PATH and TEMPORAL_CONNECTORS_NAMESPACE are required " +
          `when connecting to Temporal Cloud (NODE_ENV=${NODE_ENV}), but not found in the environment`
      );
    }

    const cert = await fs.readFile(TEMPORAL_CERT_PATH);
    const key = await fs.readFile(TEMPORAL_CERT_KEY_PATH);

    return {
      address,
      tls: {
        clientCertPair: {
          crt: new Uint8Array(cert),
          key: new Uint8Array(key),
        },
      },
    };
  }

  // Self-hosted / non-cloud deployed mode:
  // - if TLS vars exist, we use them
  // - otherwise connect plaintext
  if (TEMPORAL_CERT_PATH && TEMPORAL_CERT_KEY_PATH) {
    const cert = await fs.readFile(TEMPORAL_CERT_PATH);
    const key = await fs.readFile(TEMPORAL_CERT_KEY_PATH);
    return {
      address,
      tls: {
        clientCertPair: {
          crt: new Uint8Array(cert),
          key: new Uint8Array(key),
        },
      },
    };
  }

  return { address, tls: undefined };
}

export async function getTemporalWorkerConnection(): Promise<{
  connection: NativeConnection;
  namespace: string | undefined;
}> {
  const address = (process.env.TEMPORAL_ADDRESS || "").trim();

  if (address) {
    await logTemporalConnectionDebug(address, "worker");
  } else {
    logger.error(
      { NODE_ENV: process.env.NODE_ENV, TEMPORAL_ADDRESS: process.env.TEMPORAL_ADDRESS },
      "TEMPORAL_ADDRESS is required for worker connection but is missing/empty"
    );
    throw new Error("TEMPORAL_ADDRESS is required for Temporal worker connection");
  }

  try {
    // IMPORTANT: pass only { address } to avoid native option parsing edge cases
    const connection = await NativeConnection.connect({ address });
    return {
      connection,
      namespace: process.env.TEMPORAL_CONNECTORS_NAMESPACE,
    };
  } catch (err) {
    logger.error(
      { err: serializeError(err), address },
      "Failed to connect Temporal Worker"
    );
    throw err;
  }
}


export async function getConnectorId(
  workflowRunId: string
): Promise<ModelId | null> {
  if (!CONNECTOR_ID_CACHE[workflowRunId]) {
    const client = await getTemporalClient();
    const workflowHandle = client.workflow.getHandle(workflowRunId);
    const described = await workflowHandle.describe();
    if (described.memo && described.memo.connectorId) {
      if (typeof described.memo.connectorId === "number") {
        CONNECTOR_ID_CACHE[workflowRunId] = described.memo.connectorId;
      } else if (typeof described.memo.connectorId === "string") {
        CONNECTOR_ID_CACHE[workflowRunId] = parseInt(
          described.memo.connectorId,
          10
        );
      }
    }
  }
  return CONNECTOR_ID_CACHE[workflowRunId] || null;
}

export async function cancelWorkflow(workflowId: string) {
  const client = await getTemporalClient();
  try {
    const workflowHandle = client.workflow.getHandle(workflowId);
    await workflowHandle.cancel();
    return true;
  } catch (e) {
    if (!(e instanceof WorkflowNotFoundError)) {
      throw e;
    }
  }
  return false;
}

export async function terminateWorkflow(workflowId: string, reason?: string) {
  const client = await getTemporalClient();
  try {
    const workflowHandle = client.workflow.getHandle(workflowId);
    await workflowHandle.terminate(reason);
    return true;
  } catch (e) {
    if (!(e instanceof WorkflowNotFoundError)) {
      throw e;
    }
  }
  return false;
}

export async function terminateAllWorkflowsForConnectorId(connectorId: ModelId) {
  const client = await getTemporalClient();

  const workflowInfos = client.workflow.list({
    query: `ExecutionStatus = 'Running' AND connectorId = ${connectorId}`,
  });

  logger.info(
    {
      connectorId,
    },
    "About to terminate all workflows for connectorId"
  );

  for await (const handle of workflowInfos) {
    logger.info(
      { connectorId, workflowId: handle.workflowId },
      "Terminating Temporal workflow"
    );

    const workflowHandle = client.workflow.getHandle(handle.workflowId);
    try {
      await workflowHandle.terminate();
    } catch (err) {
      // Intentionally ignore errors that indicate the workflow no longer exists.
      if (err instanceof WorkflowNotFoundError) {
        continue;
      }
      throw err;
    }
  }

  return;
}

// This function allows to heartbeat back to the temporal workflow, but also
// awaits a temporal sleep(0), which allows to throw an exception if the activity should be cancelled.
export async function heartbeat() {
  try {
    Context.current();
  } catch (error) {
    // If we're not in a temporal context, Context.current() will throw
    // In this case, we just return without doing anything
    // This allows the function to be called safely outside of temporal activities
    return;
  }
  Context.current().heartbeat();
  await Context.current().sleep(0);
}
