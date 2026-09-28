/**
 * Adapts React Native's global `fetch` to the `TusFetch` seam the `TusUploadClient` expects
 * (Section 4e item 2). Without this the client's `header(name)` calls have nothing to read and
 * every probe/PATCH throws. The mapping is deliberately tiny: RN `Response.headers.get(name)` →
 * `header(name)` (case-insensitive, null → undefined), `Uint8Array` body and `AbortSignal` threaded
 * straight through. The bearer/Tus-Resumable headers are added by the client, not here.
 *
 * Built + tested standalone so wiring it into `wireAppRuntime` (swapping the throwing tus stubs) is
 * a one-line change during the on-device go-live, not new untested code.
 */
import type { TusFetch, TusFetchInit, TusHttpResponse } from './TusUploadClient';

/** The minimal slice of the WHATWG `fetch` we depend on (keeps this unit test-friendly). */
export interface FetchLikeResponse {
  status: number;
  headers: { get(name: string): string | null };
}
export type FetchLike = (
  url: string,
  init: {
    method: string;
    headers: Record<string, string>;
    body?: Uint8Array;
    signal?: AbortSignal;
  },
) => Promise<FetchLikeResponse>;

/** Wrap a `fetch`-like function as a `TusFetch`. */
export function createTusFetch(fetchFn?: FetchLike): TusFetch {
  const doFetch = fetchFn ?? (globalThis.fetch as unknown as FetchLike);
  return async (url: string, init: TusFetchInit): Promise<TusHttpResponse> => {
    const response = await doFetch(url, {
      method: init.method,
      headers: init.headers,
      ...(init.body !== undefined ? { body: init.body } : {}),
      ...(init.signal !== undefined ? { signal: init.signal } : {}),
    });
    return {
      status: response.status,
      header: (name: string) => response.headers.get(name) ?? undefined,
    };
  };
}
