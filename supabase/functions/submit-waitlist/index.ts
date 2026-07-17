// submit-waitlist — GET-198 landing-page waiting list write path.
//
// Untrusted PUBLIC endpoint (--no-verify-jwt): a visitor on the soft-launch
// landing page (`home-2-copy`) joins the waiting list with no auth. Because the
// caller is untrusted, EVERY field is validated + whitelisted server-side; the
// frontend's client checks are UX only. See waitlist-landing-features.md §5.1.
//
// Flow: validateWaitlistPayload(raw) -> (a) upsert into public.waitlist (the
// source of truth, on conflict (email)) -> (b) upsertBrevoContact(...) behind a
// single seam, wrapped in try/catch AFTER the DB commit so a Brevo outage still
// returns 200 (AC5). The DB write is authoritative; a later n8n sweep reconciles
// any Brevo gaps from the table.
//
// Secrets (Deno.env):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — auto-injected; own service-role
//     client for the DB write (never a client-passed token — AC6).
//   BREVO_API_KEY — unset => Brevo call is a logged no-op (skip state).
//   BREVO_WAITLIST_LIST_ID — the waitlist list; absent => contact upserts but
//     list-add is skipped (defensive).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

// Roles whitelist — keep in sync with src/lib/waitlist-vocab.ts (WAITLIST_ROLES).
export const WAITLIST_ROLES = ['creator', 'buyer']

// Content-preference labels (emoji-free), §2.1 — THIS exact order.
// keep in sync with src/lib/waitlist-vocab.ts (a frontend unit test asserts parity).
export const WAITLIST_CONTENT_PREFS = [
  'Content from higher performance levels',
  'Detailed match or opponent analyses',
  'Exclusive insights from athletes',
  'Experience reports from the professional world',
  'High-quality analyses',
  'Insights from other performance levels',
  'Practical training concepts',
  'Practical training content',
  'Scouting & talent information',
  'Sport-specific expert knowledge',
  'Structured scouting information',
]

// Canonical sport vocab — keep in sync with src/lib/insyt-vocab.ts (SPORTS).
export const SPORTS = [
  'Soccer',
  'Volleyball',
  'Basketball',
  'American Football',
  'Athletics',
  'Badminton',
  'Baseball',
  'Beach Volleyball',
  'Bodybuilding',
  'Boxing',
  'Brazilian Jiu-Jitsu',
  'BMX',
  'Canoeing',
  'Cheerleading',
  'Chess',
  'Climbing',
  'Combat Sports',
  'Cricket',
  'CrossFit',
  'Cycling',
  'Dance',
  'Esports',
  'Field Hockey',
  'Fitness',
  'Flag Football',
  'Formula Racing',
  'Futsal',
  'General',
  'Golf',
  'Gymnastics',
  'Handball',
  'Ice Hockey',
  'Judo',
  'Karate',
  'Karting',
  'Martial Arts',
  'MMA',
  'MotoGP',
  'Mountain Biking',
  'Motorsport',
  'Padel',
  'Powerlifting',
  'Rowing',
  'Rugby',
  'Running',
  'Sailing',
  'Skateboarding',
  'Skiing',
  'Snowboarding',
  'Softball',
  'Squash',
  'Surfing',
  'Swimming',
  'Table Tennis',
  'Taekwondo',
  'Tennis',
  'Trail Running',
  'Triathlon',
  'Water Polo',
  'Weightlifting',
  'Wrestling',
  'Other',
]

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const INTEREST_MAX = 280

// Strip HTML tags so no client-supplied markup reaches the DB/Brevo attributes.
// Same intent as the project sanitize helpers — never store raw HTML.
function stripHtml(input: string): string {
  return input.replace(/<[^>]*>/g, '')
}

// Keep only whitelisted values, de-duplicated, order-preserving.
function whitelist(raw: unknown, allowed: string[]): string[] {
  if (!Array.isArray(raw)) return []
  const allow = new Set(allowed)
  const seen = new Set<string>()
  const out: string[] = []
  for (const v of raw) {
    if (typeof v !== 'string') continue
    if (allow.has(v) && !seen.has(v)) {
      seen.add(v)
      out.push(v)
    }
  }
  return out
}

export interface WaitlistRow {
  email: string
  roles: string[]
  sports: string[]
  content_prefs: string[]
  interest: string | null
  source: string
}

export type ValidateResult =
  | { ok: true; value: WaitlistRow }
  | { ok: false; error: string }

// Pure validation + normalization (§5.1). Order matters:
// email -> roles -> sports -> content_prefs -> interest. Unit-tested offline.
export function validateWaitlistPayload(raw: unknown): ValidateResult {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    return { ok: false, error: 'invalid_payload' }
  }
  const body = raw as Record<string, unknown>

  // 1. email — required; shape-checked; trimmed + lowercased.
  const emailRaw = typeof body.email === 'string' ? body.email.trim().toLowerCase() : ''
  if (!emailRaw || !EMAIL_RE.test(emailRaw)) {
    return { ok: false, error: 'invalid_email' }
  }

  // 2. roles — required, >=1 after whitelisting to {creator,buyer}.
  const roles = whitelist(body.roles, WAITLIST_ROLES)
  if (roles.length === 0) {
    return { ok: false, error: 'roles_required' }
  }

  // 3. sports — optional; unknowns dropped (not rejected).
  const sports = whitelist(body.sports, SPORTS)

  // 4. content_prefs — optional; unknowns dropped.
  const content_prefs = whitelist(body.content_prefs, WAITLIST_CONTENT_PREFS)

  // 5. interest — optional; trim -> truncate(280) -> strip HTML tags.
  let interest: string | null = null
  if (typeof body.interest === 'string') {
    const cleaned = stripHtml(body.interest.trim().slice(0, INTEREST_MAX)).trim()
    interest = cleaned.length > 0 ? cleaned : null
  }

  const source = typeof body.source === 'string' && body.source.trim() ? body.source.trim() : 'home-2-copy'

  return {
    ok: true,
    value: { email: emailRaw, roles, sports, content_prefs, interest, source },
  }
}

// (b) Brevo seam (§5.1/§5.3). No-op + log when BREVO_API_KEY unset. The caller
// wraps this in try/catch after the DB commit, so any throw here is swallowed
// (AC5) — the DB row is the source of truth.
async function upsertBrevoContact(row: WaitlistRow): Promise<void> {
  const apiKey = (Deno.env.get('BREVO_API_KEY') || '').trim()
  if (!apiKey) {
    console.log('brevo:skipped-no-key')
    return
  }
  const listIdRaw = (Deno.env.get('BREVO_WAITLIST_LIST_ID') || '').trim()
  const listId = Number(listIdRaw)

  const payload: Record<string, unknown> = {
    email: row.email,
    attributes: {
      ROLE_CREATOR: row.roles.includes('creator'),
      ROLE_BUYER: row.roles.includes('buyer'),
      SPORTS: row.sports.join(','),
      CONTENT_PREFS: row.content_prefs.join(','),
      INTEREST: row.interest ?? '',
    },
    updateEnabled: true,
  }
  // Only add the list when a valid id is present (defensive — still upserts the
  // contact + attributes if the id env is absent/invalid).
  if (listIdRaw && Number.isFinite(listId)) {
    payload.listIds = [listId]
  }

  const resp = await fetch('https://api.brevo.com/v3/contacts', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      accept: 'application/json',
      'api-key': apiKey,
    },
    body: JSON.stringify(payload),
  })
  // Brevo returns 201 (created) / 204 (updated); anything else is a failure the
  // caller logs as brevo:failed but does not surface (DB is authoritative).
  if (!resp.ok) {
    const text = await resp.text().catch(() => '')
    throw new Error(`brevo ${resp.status}: ${text.slice(0, 300)}`)
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' })

  let raw: unknown
  try {
    raw = await req.json()
  } catch {
    return json(400, { error: 'invalid_json' })
  }

  const result = validateWaitlistPayload(raw)
  if (!result.ok) {
    return json(400, { error: result.error })
  }
  const row = result.value

  // (a) DB write — the source of truth. A failure here 500s (nothing else runs).
  try {
    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )
    const { error } = await serviceClient.from('waitlist').upsert(
      {
        email: row.email,
        roles: row.roles,
        sports: row.sports,
        content_prefs: row.content_prefs,
        interest: row.interest,
        source: row.source,
        updated_at: new Date().toISOString(),
      },
      { onConflict: 'email' }
    )
    if (error) {
      console.error('waitlist:db-failed', error.message)
      return json(500, { error: 'db_write_failed' })
    }
  } catch (err) {
    console.error('waitlist:db-threw', (err as Error).message)
    return json(500, { error: 'db_write_failed' })
  }

  // (b) Brevo — after the DB commit; any throw is swallowed (AC5).
  try {
    await upsertBrevoContact(row)
  } catch (err) {
    console.error('brevo:failed', (err as Error).message)
  }

  return json(200, { ok: true })
})
