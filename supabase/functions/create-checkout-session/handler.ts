// GET-470 (feature.md §3.4 (d), implementation.md P4) — this legacy one-off checkout is RETIRED.
//
// It was still deployed and callable with any user JWT, creating a Stripe session with no
// Terms consent and no withdrawal waiver — a bypass of AC4.2 / AC4.6. Its only caller was the
// retired Webflow front end; every client now goes through the RN server's
// POST /api/checkout/insyt, which runs the legal checkout gate. So every call is now
// 410 Gone. CORS + OPTIONS stay, so a browser caller gets a readable error instead of a CORS
// failure. The pre-GET-470 body is in git history (this file's predecessor, index.ts).
//
// Separate from index.ts (which calls Deno.serve on load) so index_test.ts can import it.

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
}

export const GONE_BODY = { error: 'use /api/checkout/insyt' } as const

export function handle(req: Request): Response {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  return new Response(JSON.stringify(GONE_BODY), {
    status: 410,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}
