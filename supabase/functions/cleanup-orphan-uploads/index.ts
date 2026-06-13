// Maintenance: delete abandoned create-insyt uploads (TECH-DEBT §5.4).
//
// Lists orphans via the list_orphan_upload_objects() RPC (storage objects in
// the insyt-* buckets older than min_age_days with no insyt_attachments row
// and no legacy insyts.thumbnail_url / video_url reference) and deletes them
// through the Storage API.
//
// Invoked by the weekly n8n schedule ("GetInsyt — Orphan Upload Sweep") with
// the service-role key. Defaults are deliberately safe: dry_run=true unless
// the caller explicitly disables it, age floor enforced in the RPC, and a
// per-run deletion cap.
//
// Body: { dry_run?: boolean (default true), min_age_days?: number (default 7),
//         max_delete?: number (default 500) }

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

// Accept either auth shape (both valid while the legacy keys stay enabled):
//  - the new non-JWT secret key (sb_secret_…) — exact match against SB_SERVICE_SECRET
//  - a legacy service_role JWT — decode + check the role claim
// Never exact-match SB_SERVICE_SECRET: the injected env value and the
// legacy JWT n8n holds can both be valid yet differ byte-for-byte.
function isServiceRole(authHeader: string | null): boolean {
  if (!authHeader) return false
  const token = authHeader.replace(/^Bearer\s+/i, '')
  const newSecret = Deno.env.get('SB_SERVICE_SECRET')
  if (newSecret && token === newSecret) return true
  const parts = token.split('.')
  if (parts.length !== 3) return false
  try {
    const payload = JSON.parse(atob(parts[1].replace(/-/g, '+').replace(/_/g, '/')))
    return payload?.role === 'service_role'
  } catch (_) {
    return false
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    if (!isServiceRole(req.headers.get('Authorization'))) {
      return json(403, { error: 'service role required' })
    }

    let body: any = {}
    try {
      body = await req.json()
    } catch (_) {
      // empty body → all defaults
    }
    const dryRun = body.dry_run !== false // anything but an explicit false stays a dry run
    const minAgeDays = Number.isFinite(Number(body.min_age_days)) ? Number(body.min_age_days) : 7
    const maxDelete = Number.isFinite(Number(body.max_delete)) ? Number(body.max_delete) : 500

    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SB_SERVICE_SECRET')!
    )

    const { data: orphans, error: rpcError } = await serviceClient.rpc(
      'list_orphan_upload_objects',
      { p_min_age_days: minAgeDays }
    )
    if (rpcError) {
      return json(500, { error: 'Failed to list orphans', details: rpcError.message })
    }

    const rows: { bucket: string; path: string; created_at: string; size_bytes: number }[] =
      orphans ?? []
    const perBucket: Record<string, number> = {}
    for (const r of rows) perBucket[r.bucket] = (perBucket[r.bucket] ?? 0) + 1
    const totalBytes = rows.reduce((s, r) => s + (r.size_bytes || 0), 0)

    let deleted = 0
    const deleteErrors: string[] = []
    if (!dryRun && rows.length) {
      const toDelete = rows.slice(0, maxDelete)
      const byBucket: Record<string, string[]> = {}
      for (const r of toDelete) (byBucket[r.bucket] ??= []).push(r.path)
      for (const [bucket, paths] of Object.entries(byBucket)) {
        for (let i = 0; i < paths.length; i += 100) {
          const chunk = paths.slice(i, i + 100)
          const { error } = await serviceClient.storage.from(bucket).remove(chunk)
          if (error) {
            deleteErrors.push(`${bucket}: ${error.message}`)
          } else {
            deleted += chunk.length
          }
        }
      }
    }

    const summary = {
      dry_run: dryRun,
      min_age_days: minAgeDays,
      orphans: rows.length,
      orphan_bytes: totalBytes,
      per_bucket: perBucket,
      deleted,
      remaining_after_cap: dryRun ? rows.length : Math.max(0, rows.length - deleted),
      delete_errors: deleteErrors,
      sample: rows.slice(0, 10).map((r) => `${r.bucket}/${r.path}`),
    }
    console.log('[cleanup-orphan-uploads]', JSON.stringify(summary))
    return json(200, summary)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.error('[cleanup-orphan-uploads] Unhandled error:', message)
    return json(500, { error: 'Internal server error', details: message })
  }
})
