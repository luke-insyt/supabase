// GET-470 — who is really asking: client IP + user agent for legal evidence (AC2.4, AC4.3).
// Design: webflow-app-documentation/features/legal-terms-acceptance/feature.md §3.1.
//
// The RN server calls accept-agreement and create-subscription-checkout-session under the
// user's JWT, so without help the edge fn would record Node's UA and the server's IP. The
// server therefore sends the user's `ip` / `user_agent` (and `consent_at`) in the body PLUS an
// `x-gi-server-secret` header (the shared secret GI_SERVER_SECRET, held in the function
// secrets and the server env). The body values are trusted ONLY when that header matches; on
// any other call (direct browser call, no or wrong header, secret unset) they are ignored and
// the function uses its own request headers. That closes the forgery hole where
// accept-agreement took `ip` straight from the body.
//
// Pure (no Deno.env, no I/O) so it's unit-tested in request-meta_test.ts.

export const SERVER_SECRET_HEADER = 'x-gi-server-secret'

const UA_MAX = 500

// Constant-time string compare: the time taken never depends on where the first differing
// byte is. A length mismatch still walks the full expected length. An empty or missing
// configured secret never matches (a forgotten secret must not mean "trust everyone").
export function secretMatches(provided: string | null | undefined, configured: string | null | undefined): boolean {
  if (!configured || !provided) return false
  const enc = new TextEncoder()
  const a = enc.encode(provided)
  const b = enc.encode(configured)
  let diff = a.length ^ b.length
  for (let i = 0; i < b.length; i++) {
    diff |= (a[i % (a.length || 1)] ?? 0) ^ b[i]
  }
  return diff === 0
}

// Loose IPv4 / IPv6 shape check — the DB casts leniently anyway; this only keeps junk
// (a whole header, a hostname) out of the evidence.
const IP_RE = /^(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9a-fA-F:]{2,39}(?:%[0-9A-Za-z]+)?|::ffff:\d{1,3}(?:\.\d{1,3}){3})$/

export function cleanIp(v: unknown): string | null {
  if (typeof v !== 'string') return null
  const s = v.trim()
  return s && IP_RE.test(s) ? s : null
}

export function cleanUa(v: unknown): string | null {
  if (typeof v !== 'string') return null
  const s = v.trim().slice(0, UA_MAX)
  return s || null
}

// The caller's IP as the edge platform saw it. cf-connecting-ip is set by Cloudflare in front
// of Supabase and can't be set by the client; otherwise the RIGHT-most X-Forwarded-For entry
// (the one appended by the nearest proxy). The left-most entry is client-controlled and never
// used. Hop count to be confirmed on staging (P4 checklist).
export function ipFromHeaders(headers: Headers): string | null {
  const cf = cleanIp(headers.get('cf-connecting-ip'))
  if (cf) return cf
  const xff = (headers.get('x-forwarded-for') || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
  return cleanIp(xff[xff.length - 1])
}

export type RequestMeta = {
  ip: string | null
  userAgent: string | null
  // true = body values came from the RN server (valid x-gi-server-secret)
  trusted: boolean
}

export function requestMeta(
  headers: Headers,
  body: { ip?: unknown; user_agent?: unknown } | null | undefined,
  configuredSecret: string | null | undefined,
): RequestMeta {
  const trusted = secretMatches(headers.get(SERVER_SECRET_HEADER), configuredSecret)
  if (trusted) {
    return { ip: cleanIp(body?.ip), userAgent: cleanUa(body?.user_agent), trusted }
  }
  return { ip: ipFromHeaders(headers), userAgent: cleanUa(headers.get('user-agent')), trusted }
}
