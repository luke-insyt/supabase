// support-intake — signs browser support/feedback posts on their way to the
// n8n gi-intake webhook (security review #1: the webhook must be able to
// reject unsigned posts, and a browser can't hold a secret).
// Anonymous-callable (deploy --no-verify-jwt): support must work signed-out.
// The payload passes through 1:1 (same contract as webflow-code support.ts);
// n8n's own Spam guard stays the content filter.
//
// Secrets: GI_INTAKE_SECRET (shared with the n8n Verify-secret node and the
// RN API relay). Optional N8N_INTAKE_URL override for tests.

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
}

const INTAKE_URL =
  (Deno.env.get('N8N_INTAKE_URL') || '').trim() ||
  'https://getinsyt.app.n8n.cloud/webhook/gi-intake'
const SECRET = (Deno.env.get('GI_INTAKE_SECRET') || '').trim()

// generous ceiling: the web payload carries a console buffer + replay URL,
// but nobody needs to pump megabytes into the intake
const MAX_BODY_BYTES = 256 * 1024

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json(405, { error: 'POST only' })
  // Missing secret degrades to an UNSIGNED forward (loud in fn logs) so the
  // rollout has no broken window — n8n only starts rejecting unsigned posts
  // once every sender is signing (the flip is the last step).
  if (!SECRET) console.error('support-intake: GI_INTAKE_SECRET not set — forwarding unsigned')

  const raw = await req.text()
  if (raw.length > MAX_BODY_BYTES) return json(413, { error: 'Payload too large' })
  let body: unknown
  try {
    body = JSON.parse(raw)
  } catch {
    return json(400, { error: 'Invalid JSON' })
  }
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    return json(400, { error: 'Object body required' })
  }

  let resp: Response
  try {
    resp = await fetch(INTAKE_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(SECRET ? { 'x-gi-intake-secret': SECRET } : {}),
      },
      body: JSON.stringify(body),
    })
  } catch (err) {
    return json(502, { error: `Failed to reach intake: ${(err as Error).message}` })
  }
  const text = await resp.text()
  let parsed: unknown
  try {
    parsed = text ? JSON.parse(text) : {}
  } catch {
    parsed = { ok: resp.ok }
  }
  return json(resp.status, parsed)
})
