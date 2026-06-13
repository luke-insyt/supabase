// Shared structured logging + error forwarding for edge functions.
// Contract: webflow-app-documentation/features/support-observability.md
// ("_shared/log.ts — the contract").
//
//   createLogger(fn) — one JSON log line per call, all sharing a per-request
//     reqId (searchable in the Supabase dashboard logs); error() additionally
//     fire-and-forgets the event to the n8n observability webhook → Slack.
//   withLogging(fn, corsHeaders, handler) — wraps a Deno.serve handler; an
//     uncaught exception is logged + forwarded and returned as a CORS'd
//     500 { error: 'internal_error', reqId } — the same reqId as the log
//     line and the Slack message, so a user report can quote it.
//
// With N8N_OBSERVABILITY_WEBHOOK_URL / OBSERVABILITY_WEBHOOK_SECRET unset
// (e.g. local dev) forwarding is a silent no-op — console only.

export interface GiLogger {
  reqId: string
  info(msg: string, data?: Record<string, unknown>): void
  warn(msg: string, data?: Record<string, unknown>): void
  error(msg: string, data?: Record<string, unknown>): void
}

function forward(fn: string, reqId: string, msg: string, data?: Record<string, unknown>) {
  try {
    const url = (Deno.env.get('N8N_OBSERVABILITY_WEBHOOK_URL') || '').trim()
    const secret = (Deno.env.get('OBSERVABILITY_WEBHOOK_SECRET') || '').trim()
    if (!url || !secret) return
    // No await, errors swallowed: reporting must never slow down or fail the
    // user's request (S5-AC2).
    fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-gi-obs-secret': secret },
      body: JSON.stringify({
        source: 'edge-fn',
        severity: 'error',
        title: `${fn}: ${msg}`,
        message: msg,
        context: { fn, reqId, ...(data ?? {}) },
      }),
    }).catch(() => {})
  } catch (_e) {
    /* never throw from reporting */
  }
}

export function createLogger(fn: string): GiLogger {
  const reqId = crypto.randomUUID()
  const emit = (level: 'info' | 'warn' | 'error', msg: string, data?: Record<string, unknown>) => {
    const line = JSON.stringify({ fn, reqId, level, msg, ...(data ?? {}) })
    if (level === 'error') console.error(line)
    else if (level === 'warn') console.warn(line)
    else console.log(line)
    if (level === 'error') forward(fn, reqId, msg, data)
  }
  return {
    reqId,
    info: (msg, data) => emit('info', msg, data),
    warn: (msg, data) => emit('warn', msg, data),
    error: (msg, data) => emit('error', msg, data),
  }
}

export function withLogging(
  fn: string,
  corsHeaders: Record<string, string>,
  handler: (req: Request, log: GiLogger) => Promise<Response>,
): (req: Request) => Promise<Response> {
  return async (req) => {
    const log = createLogger(fn)
    try {
      return await handler(req, log)
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      log.error('unhandled', { err: message, stack: err instanceof Error ? err.stack : undefined })
      return new Response(JSON.stringify({ error: 'internal_error', reqId: log.reqId }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }
  }
}
