/**
 * Real ADR 004 `SyncTransport` over the Ops Hub full sync routes:
 *
 *   POST /api/v1/sync/commands  — submit an idempotent command/event batch
 *   GET  /api/v1/sync/changes   — pull authoritative changes after the stored frontier
 *   POST /api/v1/sync/uploads   — open (or dedupe) a tus upload session for a blob
 *
 * Wire contract: docs/integration/ops-triad-contract.md ("Full sync engine"). This adapter is
 * the V2 protocol and LAYERS BESIDE the V1 `OpsHubV1Client` — the V1 routes stay served and
 * the V1 client stays exported as compatibility.
 *
 * Mapping discipline (cross-cutting invariant #2):
 *  - Transport/protocol failures THROW typed errors (`HubNetworkError` / `HubAuthError` /
 *    `HubResponseError`); the engine maps a throw to "transient for the whole batch" — items go
 *    back to pending with backoff, never silently dropped.
 *  - Per-operation outcomes come back as DATA (`CommandResult[]`) — accepted / rejected /
 *    needs-review each carry their reason verbatim.
 *  - A malformed response NEVER becomes a guessed outcome: any results entry that does not
 *    parse fails the whole call loudly (`HubResponseError`), leaving every item retryable.
 *  - A stale `since` token surfaces as `sync.StaleChangeTokenError` (with Hub's suggested
 *    reset frontier when present) — never as an empty page that would freeze the frontier.
 */
import { sync } from '@fieldcapture/contracts';

import { HubAuthError, HubNetworkError, HubResponseError } from '../../domain';
import type { HubRuntimeConfig } from '../../config/hubConfig';
import { boundedAbortableFetch } from './boundedFetch';
import type { HubFetch, HubHttpResponse } from './OpsHubV1Client';

const ROUTES = {
  commands: '/api/v1/sync/commands',
  changes: '/api/v1/sync/changes',
  uploads: '/api/v1/sync/uploads',
} as const;

const DEFAULT_TIMEOUT_MS = 15_000;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function requireString(value: unknown, what: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new HubResponseError(`${what} is missing or not a string`);
  }
  return value;
}

function parseWireToken(value: unknown, what: string): sync.ChangeToken {
  if (
    !isRecord(value) ||
    !Number.isInteger(value.authority_epoch) ||
    !Number.isInteger(value.commit_seq)
  ) {
    throw new HubResponseError(`${what} is not a {authority_epoch, commit_seq} change token`);
  }
  return {
    authorityEpoch: value.authority_epoch as number,
    commitSeq: value.commit_seq as number,
  };
}

function envelopeToWire(env: sync.OperationEnvelope): Record<string, unknown> {
  return {
    op_id: env.opId,
    kind: env.kind,
    type: env.type,
    idempotency_key: env.idempotencyKey,
    local_seq: env.localSeq,
    depends_on: env.dependsOn,
    ...(env.precondition !== undefined
      ? { precondition: { base_version: env.precondition.baseVersion } }
      : {}),
    payload: env.payload,
  };
}

function parseWireResult(value: unknown, index: number): sync.CommandResult {
  if (!isRecord(value)) throw new HubResponseError(`results[${index}] is not an object`);
  const opId = requireString(value.op_id, `results[${index}].op_id`);
  switch (value.outcome) {
    case 'accepted':
      return {
        outcome: 'accepted',
        opId,
        token: parseWireToken(value.token, `results[${index}].token`),
      };
    case 'rejected':
      return {
        outcome: 'rejected',
        opId,
        rejectionCode: requireString(value.rejection_code, `results[${index}].rejection_code`),
        ...(typeof value.detail === 'string' && value.detail.length > 0
          ? { detail: value.detail }
          : {}),
        ...(value.latest !== undefined ? { latest: value.latest } : {}),
      };
    case 'needs-review':
      return {
        outcome: 'needs-review',
        opId,
        reviewReason: requireString(value.review_reason, `results[${index}].review_reason`),
      };
    default:
      // An unknown outcome must fail loud — guessing would either fake a success or silently
      // freeze an item; failing the call keeps the whole batch retryable.
      throw new HubResponseError(
        `results[${index}].outcome is unknown: ${JSON.stringify(value.outcome)}`,
      );
  }
}

export class OpsHubSyncTransport implements sync.SyncTransport {
  private readonly config: HubRuntimeConfig;
  private readonly fetchFn: HubFetch;
  private readonly timeoutMs: number;
  private readonly tokenProvider?: () => string | Promise<string>;

  constructor(
    config: HubRuntimeConfig,
    fetchFn?: HubFetch,
    options?: {
      timeoutMs?: number;
      /**
       * Resolve a FRESH bearer per request (reuse `AppController.getSession`'s single-flight
       * refresh). Without it the transport would send the token bound at construction and keep
       * sending it stale after a refresh. Falls back to `config.sessionToken` when absent.
       */
      tokenProvider?: () => string | Promise<string>;
    },
  ) {
    this.config = config;
    this.fetchFn = fetchFn ?? (globalThis.fetch as unknown as HubFetch);
    this.timeoutMs = options?.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.tokenProvider = options?.tokenProvider;
  }

  private async resolveToken(): Promise<string> {
    return this.tokenProvider !== undefined ? this.tokenProvider() : this.config.sessionToken;
  }

  private headers(token: string, extra?: Record<string, string>): Record<string, string> {
    return {
      Authorization: `Bearer ${token}`,
      Accept: 'application/json',
      ...extra,
    };
  }

  /** Shared request path: network → HubNetworkError; 401/403 → HubAuthError. Returns the raw
   *  response for route-specific status handling (e.g. 410 stale-token). */
  private async request(
    path: string,
    init: { method: 'GET' | 'POST'; body?: string; contentType?: string },
    signal?: AbortSignal,
  ): Promise<HubHttpResponse> {
    const token = await this.resolveToken();
    let response: HubHttpResponse;
    try {
      response = await boundedAbortableFetch(
        this.fetchFn,
        `${this.config.baseUrl}${path}`,
        {
          method: init.method,
          headers: this.headers(
            token,
            init.contentType !== undefined ? { 'Content-Type': init.contentType } : undefined,
          ),
          ...(init.body !== undefined ? { body: init.body } : {}),
        },
        this.timeoutMs,
        signal,
      );
    } catch (error) {
      throw new HubNetworkError(`Hub unreachable for ${init.method} ${path}: ${String(error)}`, {
        cause: error,
      });
    }
    if (response.status === 401 || response.status === 403) {
      throw new HubAuthError(
        `Hub auth failed (${response.status}) for ${init.method} ${path}`,
        response.status,
      );
    }
    return response;
  }

  private async jsonBody(response: HubHttpResponse, what: string): Promise<unknown> {
    try {
      return await response.json();
    } catch {
      throw new HubResponseError(`Hub returned a non-JSON body for ${what}`, response.status);
    }
  }

  async submitBatch(
    batch: readonly sync.OperationEnvelope[],
    options?: { signal?: AbortSignal },
  ): Promise<sync.CommandResult[]> {
    if (batch.length === 0) return [];
    const response = await this.request(
      ROUTES.commands,
      {
        method: 'POST',
        contentType: 'application/json',
        body: JSON.stringify({ operations: batch.map(envelopeToWire) }),
      },
      options?.signal,
    );
    if (!response.ok) {
      throw new HubResponseError(
        `Hub returned ${response.status} for POST ${ROUTES.commands}`,
        response.status,
      );
    }
    const body = await this.jsonBody(response, `POST ${ROUTES.commands}`);
    if (!isRecord(body) || !Array.isArray(body.results)) {
      throw new HubResponseError('commands response is missing a results list', response.status);
    }
    return body.results.map(parseWireResult);
  }

  async pullChanges(
    since: sync.ChangeToken,
    options?: { signal?: AbortSignal },
  ): Promise<sync.ChangePage> {
    const query = `?after_epoch=${since.authorityEpoch}&after_seq=${since.commitSeq}`;
    const response = await this.request(
      `${ROUTES.changes}${query}`,
      { method: 'GET' },
      options?.signal,
    );
    if (response.status === 410) {
      // Hub compacted its change log past our frontier: full/partial resync required. The
      // suggested reset frontier is optional; absent means restart from the zero token.
      const body = await response.json().then(
        (b) => b,
        () => undefined,
      );
      const resetTo =
        isRecord(body) && body.reset_to !== undefined
          ? parseWireToken(body.reset_to, 'stale-token reset_to')
          : undefined;
      throw new sync.StaleChangeTokenError(
        `change token <${since.authorityEpoch},${since.commitSeq}> is stale on Hub`,
        resetTo,
      );
    }
    if (!response.ok) {
      throw new HubResponseError(
        `Hub returned ${response.status} for GET ${ROUTES.changes}`,
        response.status,
      );
    }
    const body = await this.jsonBody(response, `GET ${ROUTES.changes}`);
    if (!isRecord(body) || !Array.isArray(body.changes)) {
      throw new HubResponseError('changes response is missing a changes list', response.status);
    }
    return { token: parseWireToken(body.token, 'changes token'), changes: body.changes };
  }

  async openUploadSession(
    request: sync.UploadSessionRequest,
    options?: { signal?: AbortSignal },
  ): Promise<sync.UploadSessionResponse> {
    const response = await this.request(
      ROUTES.uploads,
      {
        method: 'POST',
        contentType: 'application/json',
        body: JSON.stringify({
          blob_id: request.blobId,
          sha256: request.sha256,
          byte_length: request.byteLength,
          mime_type: request.mimeType,
          idempotency_key: request.idempotencyKey,
        }),
      },
      options?.signal,
    );
    if (!response.ok) {
      throw new HubResponseError(
        `Hub returned ${response.status} for POST ${ROUTES.uploads}`,
        response.status,
      );
    }
    const body = await this.jsonBody(response, `POST ${ROUTES.uploads}`);
    if (isRecord(body) && body.result === 'already-present') {
      return { result: 'already-present', blobId: requireString(body.blob_id, 'uploads blob_id') };
    }
    if (isRecord(body) && body.result === 'new-session') {
      return {
        result: 'new-session',
        uploadSessionId: requireString(body.upload_session_id, 'uploads upload_session_id'),
        uploadUrl: requireString(body.upload_url, 'uploads upload_url'),
      };
    }
    throw new HubResponseError('uploads response has an unknown result shape', response.status);
  }
}
