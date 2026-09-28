/**
 * Shared wall-clock-bounded, abortable fetch wrapper used by every Hub-facing HTTP adapter
 * (OpsHubV1Client, OpsHubSyncTransport, TusUploadClient).
 *
 * A timeout (or the caller's `signal`) fires the request's AbortController, so a real fetch
 * tears the socket down instead of leaving it draining battery/data. The race against the abort
 * event is a backstop: even a fetch implementation that ignores its signal cannot hold the
 * caller past the bound. Cancellation never cancels the WORK — callers map the rejection to
 * their transient arm and local evidence stays queued (cross-cutting invariant #2).
 */

export interface AbortableInit {
  signal?: AbortSignal;
}

export async function boundedAbortableFetch<TInit extends AbortableInit, TResponse>(
  fetchFn: (url: string, init: TInit) => Promise<TResponse>,
  url: string,
  init: TInit,
  timeoutMs: number,
  externalSignal?: AbortSignal,
): Promise<TResponse> {
  if (externalSignal?.aborted) {
    // Refuse before any network dispatch — an aborted caller must not start new work.
    throw new Error('request canceled before dispatch');
  }
  const controller = new AbortController();
  const onExternalAbort = () => controller.abort();
  externalSignal?.addEventListener('abort', onExternalAbort);
  let timer: ReturnType<typeof setTimeout> | undefined;
  let timedOut = false;
  const aborted = new Promise<never>((_, reject) => {
    controller.signal.addEventListener('abort', () =>
      reject(new Error(timedOut ? `request timed out after ${timeoutMs}ms` : 'request canceled')),
    );
  });
  try {
    timer = setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, timeoutMs);
    return await Promise.race([fetchFn(url, { ...init, signal: controller.signal }), aborted]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
    externalSignal?.removeEventListener('abort', onExternalAbort);
  }
}
