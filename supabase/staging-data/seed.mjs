#!/usr/bin/env node
// Seed orchestrator for staging.
// Run with: node --env-file=.env seed.mjs
//
// Refuses to run against production. Idempotency contract: rows scoped by
// seed slug pattern (insyt_id LIKE 'seed-insyt-%', stripe_session_id LIKE
// 'seed-sess-%') get wiped + reinserted. Anchor accounts are upserted in
// place; their auth.users UUID and password are preserved. See SCENARIOS.md.

import fs from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

import { ANCHORS, TEST_USERS, allUsers } from './fixtures/accounts.mjs'
import { INSYTS } from './fixtures/insyts.mjs'
import { PURCHASES } from './fixtures/purchases.mjs'

// ----- Config -----

const SUPABASE_URL = required('SUPABASE_URL')
const SUPABASE_SERVICE_ROLE_KEY = required('SUPABASE_SERVICE_ROLE_KEY')
const WEBFLOW_API_TOKEN = required('WEBFLOW_API_TOKEN')
const WEBFLOW_CREATORS_COLLECTION_ID = required('WEBFLOW_CREATORS_COLLECTION_ID')
const WEBFLOW_INSYTS_COLLECTION_ID = required('WEBFLOW_INSYTS_COLLECTION_ID')
const SEED_USER_PASSWORD = required('SEED_USER_PASSWORD')
const STRIPE_SECRET_KEY = required('STRIPE_SECRET_KEY')
if (!STRIPE_SECRET_KEY.startsWith('sk_test_')) {
  console.error(
    `Refusing to run: STRIPE_SECRET_KEY must be a Test-mode standard secret ` +
    `key (starts with "sk_test_"). Got "${STRIPE_SECRET_KEY.slice(0, 8)}...". ` +
    `Restricted keys (rk_*) and live keys (sk_live_*) are not allowed — the ` +
    `seed creates products/prices/payment-links and must only ever touch the ` +
    `Stripe test environment.`
  )
  process.exit(1)
}

const PRODUCTION_REF = 'krapqgxrqprtajatxjzd'
const SEED_INSYT_PREFIX = 'seed-insyt-'
const SEED_SESS_PREFIX  = 'seed-sess-'
const AGREEMENT_VERSION = 'v1.0' // matches the row seeded by migration 20260503211914

const FIXTURES_DIR = path.join(__dirname, 'fixtures')

function required(name) {
  const v = process.env[name]
  if (!v) {
    console.error(`Missing required env var: ${name}`)
    process.exit(1)
  }
  return v
}

// ----- HTTP helpers -----

async function sb(pathStr, init = {}) {
  const url = `${SUPABASE_URL}${pathStr}`
  const headers = {
    apikey: SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    'Content-Type': 'application/json',
    ...(init.headers || {}),
  }
  const res = await fetch(url, { ...init, headers })
  const text = await res.text()
  let body = text
  try { body = JSON.parse(text) } catch {}
  if (!res.ok) {
    throw new Error(`Supabase ${init.method || 'GET'} ${pathStr} → ${res.status}: ${text}`)
  }
  return body
}

async function wf(pathStr, init = {}) {
  const url = `https://api.webflow.com/v2${pathStr}`
  const headers = {
    Authorization: `Bearer ${WEBFLOW_API_TOKEN}`,
    'Content-Type': 'application/json',
    accept: 'application/json',
    ...(init.headers || {}),
  }
  const res = await fetch(url, { ...init, headers })
  const text = await res.text()
  let body = text
  try { body = JSON.parse(text) } catch {}
  if (!res.ok) {
    throw new Error(`Webflow ${init.method || 'GET'} ${pathStr} → ${res.status}: ${text}`)
  }
  return body
}

// Stripe API helper. Pass form params as a flat object; nested keys must
// already be encoded with bracket notation by the caller (e.g.
// 'line_items[0][price]'). GET requests pass params via the query string;
// POSTs send them form-urlencoded.
async function stripe(pathStr, params = null, method = 'GET') {
  let url = `https://api.stripe.com/v1${pathStr}`
  const init = {
    method,
    headers: {
      Authorization: `Bearer ${STRIPE_SECRET_KEY}`,
    },
  }
  if (params) {
    const form = new URLSearchParams()
    for (const [k, v] of Object.entries(params)) {
      if (v === null || v === undefined) continue
      if (Array.isArray(v)) {
        for (const item of v) form.append(k, item)
      } else {
        form.set(k, String(v))
      }
    }
    if (method === 'GET') {
      url += (url.includes('?') ? '&' : '?') + form.toString()
    } else {
      init.headers['Content-Type'] = 'application/x-www-form-urlencoded'
      init.body = form.toString()
    }
  }
  const res = await fetch(url, init)
  const text = await res.text()
  let body = text
  try { body = JSON.parse(text) } catch {}
  if (!res.ok) {
    throw new Error(`Stripe ${method} ${pathStr} → ${res.status}: ${text}`)
  }
  return body
}

// ----- Phases -----

function refuseProduction() {
  if (SUPABASE_URL.includes(PRODUCTION_REF)) {
    console.error('Refusing to run against production project ref.')
    process.exit(1)
  }
  console.log(`✓ Pointed at staging: ${SUPABASE_URL}`)
}

async function probeWebflow() {
  // Light read to confirm the token still works. Any 401/403 here means we
  // would silently fail later; better to bail now.
  await wf(`/collections/${WEBFLOW_INSYTS_COLLECTION_ID}/items?limit=1`)
  console.log('✓ Webflow API token authorized for Insyts collection')
}

// Look up the anchor auth users (must already exist) and create or replace
// the non-anchor test users. Returns a map of email → auth_user_id.
async function ensureAuthUsers() {
  console.log('\n── Auth users ──')
  const idByEmail = new Map()

  // 1. List existing users (paginated; staging is small enough for one page).
  const existing = await sb('/auth/v1/admin/users?per_page=1000')
  const byEmail = new Map((existing.users || []).map(u => [u.email, u]))

  // 2. Anchors must already exist; just record their id.
  for (const anchor of ANCHORS) {
    const u = byEmail.get(anchor.email)
    if (!u) {
      console.error(`Anchor ${anchor.email} not found in auth.users — create it manually first.`)
      process.exit(1)
    }
    idByEmail.set(anchor.email, u.id)
    console.log(`  • anchor ${anchor.email} → ${u.id} (preserved)`)
  }

  // 3. Non-anchors: drop if present, then create fresh.
  for (const tu of TEST_USERS) {
    const existingUser = byEmail.get(tu.email)
    if (existingUser) {
      await sb(`/auth/v1/admin/users/${existingUser.id}`, { method: 'DELETE' })
      console.log(`  • dropped ${tu.email}`)
    }
    const created = await sb('/auth/v1/admin/users', {
      method: 'POST',
      body: JSON.stringify({
        email: tu.email,
        password: SEED_USER_PASSWORD,
        email_confirm: true,
        user_metadata: {
          display_name: tu.profile.display_name,
          username: tu.profile.username || null,
        },
      }),
    })
    idByEmail.set(tu.email, created.id)
    console.log(`  • created ${tu.email} → ${created.id}`)
  }

  return idByEmail
}

// Update public.users for every seeded user. The handle_new_user trigger
// already created the row at auth.users insert time; we PATCH the fields.
async function upsertPublicUsers(idByEmail) {
  console.log('\n── public.users ──')
  for (const u of allUsers()) {
    const authUserId = idByEmail.get(u.email)
    const p = u.profile
    const patch = {
      display_name: p.display_name ?? null,
      username: p.username ?? null,
      headline: p.headline ?? null,
      bio: p.bio ?? null,
      location: p.location ?? null,
      website: p.website ?? null,
      is_creator: !!p.is_creator,
      sports: Array.isArray(p.sports) ? p.sports : [],
      content_types: Array.isArray(p.content_types) ? p.content_types : [],
      creator_terms_accepted_at: (p.is_creator && !p.skip_terms) ? new Date().toISOString() : null,
      creator_activated_at: (p.is_creator && !p.skip_terms) ? new Date().toISOString() : null,
      profile_image_url: p.avatar ? `${authUserId}/avatar-seed.svg` : null,
      cover_image_url:   p.cover  ? `${authUserId}/cover-seed.svg`  : null,
      updated_at: new Date().toISOString(),
    }
    if (typeof p.stripe_connect_onboarded === 'boolean') {
      patch.stripe_connect_onboarded = p.stripe_connect_onboarded
    }
    await sb(`/rest/v1/users?auth_user_id=eq.${authUserId}`, {
      method: 'PATCH',
      headers: { Prefer: 'return=minimal' },
      body: JSON.stringify(patch),
    })
    console.log(`  • ${u.email} updated (is_creator=${patch.is_creator})`)
  }
}

async function replaceSocialLinks(idByEmail) {
  console.log('\n── user_social_links ──')
  // For non-anchors, the CASCADE on user delete already cleared them. For
  // anchors, do per-platform delete-then-insert (so unmanaged platforms — none
  // currently — would survive).
  for (const u of allUsers()) {
    const authUserId = idByEmail.get(u.email)
    // Wipe seeded platforms only.
    if (u.socials.length === 0) continue
    const platforms = u.socials.map(s => `"${s.platform}"`).join(',')
    await sb(`/rest/v1/user_social_links?user_id=eq.${authUserId}&platform=in.(${platforms})`, {
      method: 'DELETE',
      headers: { Prefer: 'return=minimal' },
    })
    const rows = u.socials.map(s => ({
      user_id: authUserId,
      platform: s.platform,
      handle: s.handle,
      updated_at: new Date().toISOString(),
    }))
    await sb('/rest/v1/user_social_links', {
      method: 'POST',
      headers: { Prefer: 'return=minimal' },
      body: JSON.stringify(rows),
    })
    console.log(`  • ${u.email}: ${u.socials.length} platform(s)`)
  }
}

async function replaceAgreements(idByEmail) {
  console.log('\n── agreement_acceptances ──')
  // Drop the seeded user's existing acceptances by user_id, then insert one.
  for (const u of allUsers()) {
    if (!u.profile.is_creator) continue
    if (u.profile.skip_terms) continue
    const authUserId = idByEmail.get(u.email)
    await sb(`/rest/v1/agreement_acceptances?auth_user_id=eq.${authUserId}`, {
      method: 'DELETE',
      headers: { Prefer: 'return=minimal' },
    })
    await sb('/rest/v1/agreement_acceptances', {
      method: 'POST',
      headers: { Prefer: 'return=minimal' },
      body: JSON.stringify({
        auth_user_id: authUserId,
        email: u.email,
        signature_name: u.profile.display_name || u.email,
        version: AGREEMENT_VERSION,
        ip: '127.0.0.1',
      }),
    })
    console.log(`  • ${u.email} accepted ${AGREEMENT_VERSION}`)
  }
}

// Provision real Stripe test-mode Product/Price/PaymentLink objects for
// every paid seed insyt. Idempotent across re-runs via a deterministic
// price `lookup_key` — if the lookup_key already exists, we reuse its
// price (and its parent product) instead of creating fresh ones. Mutates
// INSYTS in place; later phases read `_stripe*` off each item.
async function syncStripeProducts() {
  console.log('\n── Stripe products/prices (test mode) ──')
  const paid = INSYTS.filter(it => it.price_eur > 0)
  if (paid.length === 0) {
    console.log('  (no paid insyts)')
    return
  }

  // Bulk-resolve existing prices by lookup_key (max 10 per call).
  const keyToPrice = new Map()
  const keys = paid.map(it => priceLookupKey(it))
  for (let i = 0; i < keys.length; i += 10) {
    const chunk = keys.slice(i, i + 10)
    const resp = await stripe('/prices', {
      'lookup_keys[]': chunk,
      'expand[]': 'data.product',
      limit: 100,
      active: 'true',
    })
    for (const p of resp.data || []) {
      if (p.lookup_key) keyToPrice.set(p.lookup_key, p)
    }
  }

  for (const it of paid) {
    const lookupKey = priceLookupKey(it)
    const existing = keyToPrice.get(lookupKey)
    let productId
    let priceId
    if (existing) {
      priceId = existing.id
      productId = typeof existing.product === 'string' ? existing.product : existing.product?.id
      console.log(`  • reuse ${it.insyt_id} → ${priceId}`)
    } else {
      const product = await stripe('/products', {
        name: it.title,
        'metadata[seed]': 'true',
        'metadata[insyt_id]': it.insyt_id,
      }, 'POST')
      productId = product.id
      const price = await stripe('/prices', {
        product: productId,
        unit_amount: it.price_eur,
        currency: 'eur',
        lookup_key: lookupKey,
        'metadata[seed]': 'true',
        'metadata[insyt_id]': it.insyt_id,
      }, 'POST')
      priceId = price.id
      console.log(`  • create ${it.insyt_id} → ${priceId}`)
    }

    // Payment Link: Stripe has no lookup_key for these, so we recreate on
    // every run. Only used as a fallback in js/insyt-detail.js when the
    // publishable key is missing; in normal staging flow the create-
    // checkout-session edge function is what actually runs.
    const link = await stripe('/payment_links', {
      'line_items[0][price]': priceId,
      'line_items[0][quantity]': 1,
      'metadata[seed]': 'true',
      'metadata[insyt_id]': it.insyt_id,
    }, 'POST')

    it._stripeProductId = productId
    it._stripePriceId = priceId
    it._stripePaymentLinkUrl = link.url
  }
}

function priceLookupKey(it) {
  return `seed_${it.insyt_id}_${it.price_eur}`
}

// Wipe seeded insyts (slug pattern). Cascades to insyt_attachments and
// insyt_status. Webflow Insyts items are wiped before this in the teardown
// step so we don't lose the webflow_item_id reference here.
async function wipeSeedInsyts() {
  await sb(`/rest/v1/insyts?insyt_id=like.${SEED_INSYT_PREFIX}*`, {
    method: 'DELETE',
    headers: { Prefer: 'return=minimal' },
  })
}

async function insertInsyts(idByEmail) {
  console.log('\n── insyts ──')
  await wipeSeedInsyts()

  for (const it of INSYTS) {
    const ownerAuthUserId = idByEmail.get(it.creator_email)
    const row = {
      title: it.title,
      abstract: it.abstract,
      body_html: it.body_html,
      content_type: 'article',
      sport: it.sport,
      thumbnail_url: it.has_thumbnail
        ? `${SUPABASE_URL}/storage/v1/object/public/insyt-thumbnails/${it.insyt_id}.svg`
        : null,
      price_eur: it.price_eur,
      status: it.status,
      is_hidden: it.is_hidden,
      creator_email: it.creator_email,
      insyt_id: it.insyt_id,
      tags: it.tags || [],
      stripe_product_id: it._stripeProductId || null,
      stripe_price_id:   it._stripePriceId || null,
      stripe_payment_link_url: it._stripePaymentLinkUrl || null,
    }
    // read_time_min column may be missing if migration not applied; ignore.
    row.read_time_min = it.read_time_min
    const created = await sb('/rest/v1/insyts?select=id,insyt_id', {
      method: 'POST',
      headers: { Prefer: 'return=representation' },
      body: JSON.stringify(row),
    })
    const insytRow = Array.isArray(created) ? created[0] : created
    it._supabaseId = insytRow.id
    console.log(`  • ${it.insyt_id}  (${it.title.slice(0, 50)})`)
  }
}

async function insertAttachments() {
  console.log('\n── insyt_attachments ──')
  const rows = []
  for (const it of INSYTS) {
    for (const att of it.attachments || []) {
      const bucket =
        att.kind === 'pdf'   ? 'insyt-pdfs' :
        att.kind === 'image' ? 'insyt-images' :
        att.kind === 'video' ? 'insyt-videos' :
                               'insyt-images'
      const storagePath = `${it.insyt_id}/${att.filename}`
      rows.push({
        insyt_id: it._supabaseId,
        kind: att.kind,
        bucket,
        storage_path: storagePath,
        filename: att.filename,
        mime: att.kind === 'pdf' ? 'application/pdf' : 'image/svg+xml',
        position: att.position,
        width: att.width ?? null,
        height: att.height ?? null,
      })
    }
  }
  if (rows.length === 0) {
    console.log('  (none)')
    return
  }
  await sb('/rest/v1/insyt_attachments', {
    method: 'POST',
    headers: { Prefer: 'return=minimal' },
    body: JSON.stringify(rows),
  })
  console.log(`  • inserted ${rows.length} attachment rows`)
}

async function insertStatus() {
  console.log('\n── insyt_status ──')
  const errored = INSYTS.find(it => it.has_status_error)
  if (!errored) return
  // First wipe any existing status rows for this insyt.
  await sb(`/rest/v1/insyt_status?insyt_id=eq.${errored._supabaseId}`, {
    method: 'DELETE',
    headers: { Prefer: 'return=minimal' },
  })
  await sb('/rest/v1/insyt_status', {
    method: 'POST',
    headers: { Prefer: 'return=minimal' },
    body: JSON.stringify({
      insyt_id: errored._supabaseId,
      correlation_id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      creator_email: errored.creator_email,
      step: 'seed',
      status: 'error',
      message: 'Seed-generated error for status panel coverage',
    }),
  })
  console.log(`  • status error attached to ${errored.insyt_id}`)
}

async function insertPurchases() {
  console.log('\n── purchases ──')
  await sb(`/rest/v1/purchases?stripe_session_id=like.${SEED_SESS_PREFIX}*`, {
    method: 'DELETE',
    headers: { Prefer: 'return=minimal' },
  })
  const now = Date.now()
  const rows = PURCHASES.map(p => ({
    buyer_email: p.buyer_email,
    insyt_id: p.insyt_slug,
    creator_email: p.creator_email,
    amount_paid: p.amount_paid,
    stripe_session_id: p.stripe_session_id,
    payment_status: p.payment_status,
    purchased_at: new Date(now - p.purchased_days_ago * 86_400_000).toISOString(),
    insyt_link: `https://www.getinsyts.com/insyts/${p.insyt_slug}`,
  }))
  await sb('/rest/v1/purchases', {
    method: 'POST',
    headers: { Prefer: 'return=minimal' },
    body: JSON.stringify(rows),
  })
  console.log(`  • inserted ${rows.length} purchase rows`)
}

// ----- Storage -----

async function listStorageObjects(bucket, prefix) {
  // Storage list endpoint: POST /storage/v1/object/list/<bucket>
  const data = await sb(`/storage/v1/object/list/${bucket}`, {
    method: 'POST',
    body: JSON.stringify({ prefix, limit: 200, sortBy: { column: 'name', order: 'asc' } }),
  })
  return Array.isArray(data) ? data : []
}

async function deleteStorageObjects(bucket, paths) {
  if (!paths.length) return
  await sb(`/storage/v1/object/${bucket}`, {
    method: 'DELETE',
    body: JSON.stringify({ prefixes: paths }),
  })
}

async function uploadStorageObject(bucket, objectPath, localFile, contentType) {
  const buffer = await fs.readFile(localFile)
  const url = `${SUPABASE_URL}/storage/v1/object/${bucket}/${objectPath}`
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      'Content-Type': contentType,
      'x-upsert': 'true',
    },
    body: buffer,
  })
  if (!res.ok) {
    throw new Error(`storage upload ${bucket}/${objectPath} → ${res.status}: ${await res.text()}`)
  }
}

async function wipeAndUploadStorage(idByEmail) {
  console.log('\n── storage ──')
  // Avatars / covers under each seeded user's uuid.
  for (const u of allUsers()) {
    const authUserId = idByEmail.get(u.email)
    const objs = await listStorageObjects('creator-avatars', `${authUserId}/`)
    if (objs.length) {
      await deleteStorageObjects('creator-avatars', objs.map(o => `${authUserId}/${o.name}`))
    }
    const objs2 = await listStorageObjects('creator-covers', `${authUserId}/`)
    if (objs2.length) {
      await deleteStorageObjects('creator-covers', objs2.map(o => `${authUserId}/${o.name}`))
    }
    if (u.profile.avatar) {
      await uploadStorageObject(
        'creator-avatars',
        `${authUserId}/avatar-seed.svg`,
        path.join(FIXTURES_DIR, u.profile.avatar),
        'image/svg+xml',
      )
    }
    if (u.profile.cover) {
      await uploadStorageObject(
        'creator-covers',
        `${authUserId}/cover-seed.svg`,
        path.join(FIXTURES_DIR, u.profile.cover),
        'image/svg+xml',
      )
    }
  }
  console.log('  • avatars + covers refreshed')

  // Per-insyt thumbnails + attachments under <insyt-slug>/.
  for (const it of INSYTS) {
    // Thumbnail (one file at <slug>.svg, no subfolder)
    if (it.has_thumbnail) {
      await uploadStorageObject(
        'insyt-thumbnails',
        `${it.insyt_id}.svg`,
        path.join(FIXTURES_DIR, 'thumbnail.svg'),
        'image/svg+xml',
      )
    }
    // Wipe + reupload attachments under <slug>/...
    for (const bucket of ['insyt-images', 'insyt-pdfs']) {
      const objs = await listStorageObjects(bucket, `${it.insyt_id}/`)
      if (objs.length) {
        await deleteStorageObjects(bucket, objs.map(o => `${it.insyt_id}/${o.name}`))
      }
    }
    for (const att of it.attachments || []) {
      const bucket = att.kind === 'pdf' ? 'insyt-pdfs' : 'insyt-images'
      const localFile = path.join(FIXTURES_DIR, att.source)
      const contentType = att.kind === 'pdf' ? 'application/pdf' : 'image/svg+xml'
      await uploadStorageObject(bucket, `${it.insyt_id}/${att.filename}`, localFile, contentType)
    }
  }
  console.log('  • thumbnails + attachments refreshed')
}

// ----- Webflow CMS mirror -----

// Pull Webflow Creator items keyed by auth-user-id so we can locate the
// anchor's existing item and decide PATCH-vs-POST per non-anchor.
async function loadCreatorItems() {
  const out = []
  let offset = 0
  while (true) {
    const page = await wf(`/collections/${WEBFLOW_CREATORS_COLLECTION_ID}/items?limit=100&offset=${offset}`)
    out.push(...(page.items || []))
    if (!page.items || page.items.length < 100) break
    offset += 100
  }
  const byAuthId = new Map()
  for (const it of out) {
    const aid = it.fieldData?.['auth-user-id']
    if (aid) byAuthId.set(aid, it)
  }
  return byAuthId
}

async function syncCreatorsCms(idByEmail) {
  console.log('\n── Webflow Creators CMS ──')
  const byAuthId = await loadCreatorItems()

  for (const u of allUsers()) {
    if (!u.profile.is_creator) continue
    const authUserId = idByEmail.get(u.email)
    const fieldData = {
      name: u.profile.display_name || u.email,
      slug: authUserId,
      email: u.email,
      'auth-user-id': authUserId,
      bio: u.profile.bio || '',
      headline: u.profile.headline || '',
      username: u.profile.username || '',
      location: u.profile.location || '',
      website: u.profile.website || '',
      'joined-date': new Date().toISOString(),
      youtube:   u.socials.find(s => s.platform === 'youtube')?.handle   || '',
      instagram: u.socials.find(s => s.platform === 'instagram')?.handle || '',
      facebook:  u.socials.find(s => s.platform === 'facebook')?.handle  || '',
      tiktok:    u.socials.find(s => s.platform === 'tiktok')?.handle    || '',
    }
    if (u.profile.avatar) {
      fieldData['profile-image'] = { url: `${SUPABASE_URL}/storage/v1/object/public/creator-avatars/${authUserId}/avatar-seed.svg` }
    }
    if (u.profile.cover) {
      fieldData['cover-image']   = { url: `${SUPABASE_URL}/storage/v1/object/public/creator-covers/${authUserId}/cover-seed.svg` }
    }

    const existing = byAuthId.get(authUserId)
    if (existing) {
      // PATCH (anchors AND non-anchors keep the same item if it's already there).
      await wf(`/collections/${WEBFLOW_CREATORS_COLLECTION_ID}/items/${existing.id}/live`, {
        method: 'PATCH',
        body: JSON.stringify({ fieldData }),
      })
      console.log(`  • PATCH ${u.email} → ${existing.id}`)
      u._webflowCreatorId = existing.id
    } else {
      const created = await wf(`/collections/${WEBFLOW_CREATORS_COLLECTION_ID}/items/live`, {
        method: 'POST',
        body: JSON.stringify({ fieldData }),
      })
      console.log(`  • POST  ${u.email} → ${created.id}`)
      u._webflowCreatorId = created.id
    }

    // Write the id back to public.users so future syncs use it.
    await sb(`/rest/v1/users?auth_user_id=eq.${authUserId}`, {
      method: 'PATCH',
      headers: { Prefer: 'return=minimal' },
      body: JSON.stringify({ webflow_creator_id: u._webflowCreatorId }),
    })
  }
}

async function loadInsytItemsBySlug() {
  const out = []
  let offset = 0
  while (true) {
    const page = await wf(`/collections/${WEBFLOW_INSYTS_COLLECTION_ID}/items?limit=100&offset=${offset}`)
    out.push(...(page.items || []))
    if (!page.items || page.items.length < 100) break
    offset += 100
  }
  const bySlug = new Map()
  for (const it of out) {
    const slug = it.fieldData?.slug
    if (slug) bySlug.set(slug, it)
  }
  return bySlug
}

async function syncInsytsCms() {
  console.log('\n── Webflow Insyts CMS ──')
  const bySlug = await loadInsytItemsBySlug()

  // Resolve creator → webflow creator id for the `creator` reference field.
  const creatorByEmail = new Map()
  for (const u of allUsers()) {
    if (u.profile.is_creator && u._webflowCreatorId) creatorByEmail.set(u.email, u._webflowCreatorId)
  }

  for (const it of INSYTS) {
    if (it._bulkForPagination) continue
    const fieldData = {
      name: it.title,
      slug: it.insyt_id,
      abstract: it.abstract,
      price: (it.price_eur / 100).toFixed(2),
      tags: (it.tags || []).join(','),
      'creator-email': it.creator_email,
      sport: it.sport,
      hidden: !!it.is_hidden,
      env: 'staging',
      'read-time-min': it.read_time_min,
      'thumbnail-url-2': it.has_thumbnail
        ? `${SUPABASE_URL}/storage/v1/object/public/insyt-thumbnails/${it.insyt_id}.svg`
        : '',
      creator: creatorByEmail.get(it.creator_email) || null,
    }
    if (it._stripePaymentLinkUrl) {
      fieldData['stripe-payment-link'] = it._stripePaymentLinkUrl
    }

    const existing = bySlug.get(it.insyt_id)
    let cmsId
    if (existing) {
      await wf(`/collections/${WEBFLOW_INSYTS_COLLECTION_ID}/items/${existing.id}/live`, {
        method: 'PATCH',
        body: JSON.stringify({ fieldData }),
      })
      cmsId = existing.id
      console.log(`  • PATCH ${it.insyt_id}`)
    } else {
      const created = await wf(`/collections/${WEBFLOW_INSYTS_COLLECTION_ID}/items/live`, {
        method: 'POST',
        body: JSON.stringify({ fieldData }),
      })
      cmsId = created.id
      console.log(`  • POST  ${it.insyt_id}`)
    }

    await sb(`/rest/v1/insyts?insyt_id=eq.${it.insyt_id}`, {
      method: 'PATCH',
      headers: { Prefer: 'return=minimal' },
      body: JSON.stringify({ webflow_item_id: cmsId }),
    })
  }
}

async function orphanSweepInsyts() {
  console.log('\n── Webflow orphan sweep ──')
  const bySlug = await loadInsytItemsBySlug()
  const seededSlugs = new Set(INSYTS.map(i => i.insyt_id))
  let swept = 0
  for (const [slug, item] of bySlug.entries()) {
    if (slug.startsWith(SEED_INSYT_PREFIX) && !seededSlugs.has(slug)) {
      await wf(`/collections/${WEBFLOW_INSYTS_COLLECTION_ID}/items/${item.id}`, { method: 'DELETE' })
      console.log(`  • deleted orphan ${slug}`)
      swept++
    }
  }
  if (!swept) console.log('  (no orphans)')
}

// ----- Main -----

async function main() {
  console.log('=== GetInsyt staging seed ===')
  refuseProduction()
  await probeWebflow()

  const idByEmail = await ensureAuthUsers()
  await wipeAndUploadStorage(idByEmail)
  await upsertPublicUsers(idByEmail)
  await replaceSocialLinks(idByEmail)
  await replaceAgreements(idByEmail)
  await syncStripeProducts()
  await insertInsyts(idByEmail)
  await insertAttachments()
  await insertStatus()
  await insertPurchases()
  await syncCreatorsCms(idByEmail)
  await syncInsytsCms()
  await orphanSweepInsyts()

  console.log('\n✓ Seed complete.')
}

main().catch(err => {
  console.error('\n✗ Seed failed:', err.message)
  console.error(err.stack)
  process.exit(1)
})
