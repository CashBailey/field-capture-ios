/**
 * Tus-style resumable upload HTTP client (ADR 004). Talks to the per-session `upload_url` Hub
 * returned from `POST /api/v1/sync/uploads`:
 *
 *   HEAD  <upload_url>             → current durable offset (`Upload-Offset`), and the
 *                                    server-computed `Upload-Sha256` once the upload completed
 *   PATCH <upload_url> + chunk     → 204 with the new `Upload-Offset`; the final PATCH also
 *                                    carries `Upload-Sha256`
 *
 * Protocol discipline:
 *  - The SERVER's offset is the truth on resume (`sync.reconcileOffset` at the engine).
 *  - A 404/410 on the session means it expired server-side — `TusSessionGoneError`; the engine
 *    restarts from the durable local copy (the bytes were never purged).
 *  - A 409 offset conflict is NOT an error outcome: the engine re-probes and resumes.
 *  - Hash verification is the ENGINE's job (`sync.verifyUploadHash`); this client only
 *    transports the server-computed hash verbatim.
 */
import { HubAuthError } from '../../domain';
import { boundedAbortableFetch } from './boundedFetch';

/** Minimal response surface for tus calls — headers matter here, bodies do not. */
export interface TusHttpResponse {
  status: number;
  /** Header lookup, case-insensitive on the name. */
  header(name: string): string | undefined;
}

export interface TusFetchInit {
  method: 'HEAD' | 'PATCH';
  headers: Record<string, string>;
  body?: Uint8Array;
  signal?: AbortSignal;
}

export type TusFetch = (url: string, init: TusFetchInit) => Promise<TusHttpResponse>;

/** The upload session no longer exists on Hub (expired/garbage-collected). Restart locally. */
export class TusSessionGoneError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'TusSessionGoneError';
  }
}

/** The server answered outside the tus contract (unexpected status / missing offset header). */
export class TusProtocolError extends Error {
  readonly httpStatus?: number;
  constructor(message: string, httpStatus?: number) {
    super(message);
    this.name = 'TusProtocolError';
    if (httpStatus !== undefined) this.httpStatus = httpStatus;
  }
}

/**
 * A PATCH landed at the wrong offset — the Hub's durable offset differs from where we wrote
 * (opshub `sync/protocol.py`: 409 with `Upload-Offset` and NO `Upload-Sha256`). RESUMABLE: the
 * engine re-probes (HEAD) and continues from the server's true offset. Carries that offset.
 */
export class TusOffsetConflictError extends Error {
  readonly serverOffset?: number;
  constructor(message: string, serverOffset?: number) {
    super(message);
    this.name = 'TusOffsetConflictError';
    if (serverOffset !== undefined) this.serverOffset = serverOffset;
  }
}

/**
 * The Hub received the whole file but its bytes hash to something DIFFERENT than the declared
 * sha256 (opshub `sync/protocol.py`: 409 WITH `Upload-Sha256`). FATAL: re-sending the same
 * bytes can never fix it — the engine must restart the blob from the durable local copy. Carries
 * the server-computed digest.
 */
export class TusHashMismatchError extends Error {
  readonly serverSha256?: string;
  constructor(message: string, serverSha256?: string) {
    super(message);
    this.name = 'TusHashMismatchError';
    if (serverSha256 !== undefined) this.serverSha256 = serverSha256;
  }
}

/** The server's durable view of a session: bytes held, and the whole-file hash once complete. */
export interface TusProbeResult {
  offset: number;
  sha256?: string;
}

export interface TusPatchResult {
  offset: number;
  /** Present on the final PATCH (server verified the whole file). */
  sha256?: string;
}

const DEFAULT_TIMEOUT_MS = 60_000; // chunk uploads legitimately take longer than JSON calls

function parseOffset(response: TusHttpResponse, what: string): number {
  const raw = response.header('Upload-Offset');
  const offset = raw === undefined ? Number.NaN : Number(raw);
  if (!Number.isInteger(offset) || offset < 0) {
    throw new TusProtocolError(
      `${what} returned no usable Upload-Offset (got ${raw})`,
      response.status,
    );
  }
  return offset;
}

export class TusUploadClient {
  private readonly fetchFn: TusFetch;
  private readonly sessionToken?: string;
  private readonly tokenProvider?: () => string | Promise<string>;
  private readonly timeoutMs: number;

  constructor(options: {
    sessionToken?: string;
    /**
     * Resolve a FRESH bearer per request (reuse `AppController.getSyncSessionToken`'s single-flight
     * refresh). A multi-chunk upload can outlive a token, so without this a PATCH would 401 on a
     * token that rotated mid-transfer. Falls back to the static `sessionToken` when absent.
     */
    tokenProvider?: () => string | Promise<string>;
    fetchFn?: TusFetch;
    timeoutMs?: number;
  }) {
    if (options.tokenProvider === undefined && !options.sessionToken) {
      // Fail fast on misconfiguration: a silent `Bearer ` would 401 obscurely server-side.
      throw new Error('TusUploadClient requires a tokenProvider or a non-empty sessionToken');
    }
    this.sessionToken = options.sessionToken;
    this.tokenProvider = options.tokenProvider;
    this.fetchFn = options.fetchFn ?? (globalThis.fetch as unknown as TusFetch);
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  }

  private async resolveToken(): Promise<string> {
    if (this.tokenProvider !== undefined) return this.tokenProvider();
    return this.sessionToken ?? '';
  }

  private headers(token: string, extra?: Record<string, string>): Record<string, string> {
    return {
      Authorization: `Bearer ${token}`,
      'Tus-Resumable': '1.0.0',
      ...extra,
    };
  }

  /** The server's current durable offset for this session (and hash, once complete). */
  async probe(uploadUrl: string, options?: { signal?: AbortSignal }): Promise<TusProbeResult> {
    const token = await this.resolveToken();
    const response = await boundedAbortableFetch(
      this.fetchFn,
      uploadUrl,
      { method: 'HEAD', headers: this.headers(token) },
      this.timeoutMs,
      options?.signal,
    );
    if (response.status === 404 || response.status === 410) {
      throw new TusSessionGoneError(`upload session is gone (${response.status}): ${uploadUrl}`);
    }
    if (response.status === 401 || response.status === 403) {
      // Auth, not a tus-protocol fault: surface HubAuthError so the engine flags authRequired and
      // the upload driver PAUSES (consistent with the /sync/commands + openUploadSession legs).
      throw new HubAuthError(
        `HEAD ${uploadUrl} auth rejected (${response.status})`,
        response.status,
      );
    }
    if (response.status !== 200 && response.status !== 204) {
      throw new TusProtocolError(`HEAD ${uploadUrl} returned ${response.status}`, response.status);
    }
    const sha256 = response.header('Upload-Sha256');
    return { offset: parseOffset(response, 'HEAD'), ...(sha256 !== undefined ? { sha256 } : {}) };
  }

  /**
   * Upload one chunk at `offset`. Returns the server's new offset (and the whole-file hash on the
   * final chunk). The Hub returns 409 for TWO distinct reasons, disambiguated by `Upload-Sha256`:
   *  - present  → hash mismatch: `TusHashMismatchError` (FATAL — the file is corrupt as declared),
   *  - absent   → offset conflict: `TusOffsetConflictError` (RESUMABLE — re-probe and continue).
   * Bytes are never counted as sent without the server's answer.
   */
  async uploadChunk(
    uploadUrl: string,
    offset: number,
    chunk: Uint8Array,
    options?: { signal?: AbortSignal },
  ): Promise<TusPatchResult> {
    const token = await this.resolveToken();
    const response = await boundedAbortableFetch(
      this.fetchFn,
      uploadUrl,
      {
        method: 'PATCH',
        headers: this.headers(token, {
          'Content-Type': 'application/offset+octet-stream',
          'Upload-Offset': String(offset),
        }),
        body: chunk,
      },
      this.timeoutMs,
      options?.signal,
    );
    if (response.status === 404 || response.status === 410) {
      throw new TusSessionGoneError(`upload session is gone (${response.status}): ${uploadUrl}`);
    }
    if (response.status === 401 || response.status === 403) {
      // Auth, not a tus-protocol fault: HubAuthError so the engine flags authRequired and pauses.
      throw new HubAuthError(
        `PATCH ${uploadUrl} auth rejected (${response.status})`,
        response.status,
      );
    }
    if (response.status === 409) {
      const serverSha256 = response.header('Upload-Sha256');
      if (serverSha256 !== undefined) {
        throw new TusHashMismatchError(
          `PATCH ${uploadUrl} reported a hash mismatch (server ${serverSha256})`,
          serverSha256,
        );
      }
      const raw = response.header('Upload-Offset');
      const serverOffset = raw === undefined ? Number.NaN : Number(raw);
      throw new TusOffsetConflictError(
        `PATCH ${uploadUrl} offset conflict; server offset is ${raw ?? 'unknown'}`,
        Number.isInteger(serverOffset) && serverOffset >= 0 ? serverOffset : undefined,
      );
    }
    if (response.status !== 204 && response.status !== 200) {
      throw new TusProtocolError(`PATCH ${uploadUrl} returned ${response.status}`, response.status);
    }
    const sha256 = response.header('Upload-Sha256');
    return {
      offset: parseOffset(response, 'PATCH'),
      ...(sha256 !== undefined ? { sha256 } : {}),
    };
  }
}
