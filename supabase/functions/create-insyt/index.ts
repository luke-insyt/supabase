import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const MAX_COVER_BYTES   = 5  * 1024 * 1024
const MAX_VIDEO_BYTES   = 100 * 1024 * 1024
const MAX_IMAGE_BYTES   = 10 * 1024 * 1024
const MAX_IMAGES_COUNT  = 10
const MAX_VIDEOS_COUNT  = 3

const BUCKET_COVER_IMAGE = 'insyt-thumbnails'
const BUCKET_COVER_VIDEO = 'insyt-videos'
const BUCKET_IMAGES      = 'insyt-images'
const BUCKET_VIDEOS      = 'insyt-videos'

type CoverType = 'image' | 'video'

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

function safeName(name: string) {
  return name.replace(/[^a-zA-Z0-9._-]/g, '_').slice(0, 120)
}

function parsePriceCents(raw: string | null, isFree: boolean): number {
  if (isFree) return 0
  const n = Number(raw)
  if (!Number.isFinite(n) || n < 1 || n > 100) {
    throw new Error('Price must be between 1.00 and 100.00')
  }
  return Math.round(n * 100)
}

function parseTags(raw: string | null): string[] {
  if (!raw) return []
  try {
    const v = JSON.parse(raw)
    if (Array.isArray(v)) return v.map(String).filter(Boolean).slice(0, 20)
  } catch {
    // fallback: comma-separated
  }
  return String(raw).split(',').map(s => s.trim()).filter(Boolean).slice(0, 20)
}

async function uploadFile(
  svc: ReturnType<typeof createClient>,
  bucket: string,
  path: string,
  file: File,
) {
  const ab = await file.arrayBuffer()
  const { error } = await svc.storage.from(bucket).upload(path, ab, {
    contentType: file.type || 'application/octet-stream',
    upsert: false,
  })
  if (error) throw new Error(`Upload to ${bucket}/${path} failed: ${error.message}`)
  return path
}

async function writeStatus(
  svc: ReturnType<typeof createClient>,
  correlation_id: string,
  insyt_id: string | null,
  creator_email: string,
  step: string,
  status: 'processing' | 'success' | 'error',
  message: string | null = null,
  details: Record<string, unknown> | null = null,
) {
  const { error } = await svc.from('insyt_status').insert({
    correlation_id,
    insyt_id,
    creator_email,
    step,
    status,
    message,
    details,
  })
  if (error) console.error('[create-insyt] insyt_status insert failed', error)
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  if (req.method !== 'POST') {
    return json(405, { error: 'Method not allowed' })
  }

  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json(401, { error: 'Missing Authorization header' })

  const svc = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )
  const userClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } },
  )

  // Verify the caller is an authenticated active creator.
  const { data: authResult, error: authError } = await userClient.auth.getUser()
  if (authError || !authResult?.user) {
    return json(401, { error: 'Invalid session' })
  }
  const authUserId = authResult.user.id
  const creatorEmail = authResult.user.email
  if (!creatorEmail) return json(401, { error: 'Missing email in token' })

  const { data: userRow, error: userLookupError } = await svc
    .from('users')
    .select('id, is_creator, agreement_version')
    .eq('auth_user_id', authUserId)
    .maybeSingle()
  if (userLookupError) return json(500, { error: userLookupError.message })
  if (!userRow) return json(404, { error: 'User not found' })
  if (!userRow.is_creator) return json(403, { error: 'Not an active creator' })

  // Parse multipart form data.
  let form: FormData
  try {
    form = await req.formData()
  } catch (err) {
    return json(400, { error: 'Invalid multipart body: ' + (err as Error).message })
  }

  const sport       = String(form.get('sport') || '').trim()
  const contentType = String(form.get('content_type') || '').trim()
  const title       = String(form.get('title') || '').trim()
  const description = String(form.get('description') || '').trim()
  const fullText    = String(form.get('full_text') || '').trim()
  const coverType   = (String(form.get('cover_type') || 'image').trim() as CoverType)
  const isFree      = String(form.get('is_free') || 'false') === 'true'
  let priceCents: number
  try {
    priceCents = parsePriceCents(String(form.get('price') || ''), isFree)
  } catch (err) {
    return json(400, { error: (err as Error).message })
  }
  const tags = parseTags(String(form.get('tags') || ''))

  if (!title)            return json(400, { error: 'Title is required' })
  if (title.length > 150) return json(400, { error: 'Title exceeds 150 chars' })
  if (!sport)            return json(400, { error: 'Sport is required' })

  // Generate correlation_id up-front so caller can poll insyt_status even if a later step fails.
  const correlation_id = crypto.randomUUID()

  await writeStatus(svc, correlation_id, null, creatorEmail, 'received', 'processing')

  const coverFile = form.get('cover')
  const imagesFiles: File[] = []
  const videosFiles: File[] = []
  for (const [key, val] of form.entries()) {
    if (!(val instanceof File)) continue
    if (key === 'images') imagesFiles.push(val)
    else if (key === 'videos') videosFiles.push(val)
  }
  if (imagesFiles.length > MAX_IMAGES_COUNT) return json(400, { error: 'Too many images' })
  if (videosFiles.length > MAX_VIDEOS_COUNT) return json(400, { error: 'Too many videos' })

  // Folder for this insyt's files. Use correlation_id so paths are unique even if the insyts insert fails.
  const folder = `${authUserId}/${correlation_id}`

  // Upload cover (required to set thumbnail/video URL on the insyts row).
  let thumbnailUrl: string | null = null
  let videoUrl: string | null = null
  let coverBucket: string | null = null
  let coverPath: string | null = null
  let coverFilename: string | null = null
  let coverMime: string | null = null
  let coverKind: 'thumbnail' | 'video' | null = null

  if (coverFile instanceof File && coverFile.size > 0) {
    if (coverType === 'image') {
      if (coverFile.size > MAX_COVER_BYTES) {
        await writeStatus(svc, correlation_id, null, creatorEmail, 'upload_cover', 'error', 'Cover image too large (max 5MB)')
        return json(400, { error: 'Cover image too large (max 5MB)' })
      }
      coverBucket = BUCKET_COVER_IMAGE
      coverKind = 'thumbnail'
    } else {
      if (coverFile.size > MAX_VIDEO_BYTES) {
        await writeStatus(svc, correlation_id, null, creatorEmail, 'upload_cover', 'error', 'Cover video too large (max 100MB)')
        return json(400, { error: 'Cover video too large (max 100MB)' })
      }
      coverBucket = BUCKET_COVER_VIDEO
      coverKind = 'video'
    }
    coverFilename = safeName(coverFile.name || 'cover')
    coverMime = coverFile.type || null
    coverPath = `${folder}/cover-${Date.now()}-${coverFilename}`
    try {
      await uploadFile(svc, coverBucket, coverPath, coverFile)
    } catch (err) {
      await writeStatus(svc, correlation_id, null, creatorEmail, 'upload_cover', 'error', (err as Error).message)
      return json(500, { error: (err as Error).message })
    }
    if (coverBucket === BUCKET_COVER_IMAGE) {
      const { data: pub } = svc.storage.from(coverBucket).getPublicUrl(coverPath)
      thumbnailUrl = pub.publicUrl
    } else {
      // Private bucket: keep storage_path; the read side resolves a signed URL via get-insyt-content.
      videoUrl = coverPath
    }
  }

  await writeStatus(svc, correlation_id, null, creatorEmail, 'attachments_saved', 'processing')

  // Insert the insyts row.
  const { data: insytRow, error: insytError } = await svc
    .from('insyts')
    .insert({
      title,
      abstract: description || ' ',
      content_type: contentType || coverType,
      sport: sport || 'soccer',
      thumbnail_url: thumbnailUrl,
      video_url: videoUrl,
      storage_path: coverPath,
      price_eur: priceCents,
      status: 'review',
      creator_email: creatorEmail,
      body_text: fullText || null,
      tags,
      is_hidden: false,
    })
    .select('id')
    .single()

  if (insytError || !insytRow) {
    await writeStatus(svc, correlation_id, null, creatorEmail, 'insert_insyt', 'error', insytError?.message || 'Insert failed')
    return json(500, { error: insytError?.message || 'Failed to insert insyt' })
  }

  const insytId = insytRow.id as string

  // Cover attachment row.
  if (coverBucket && coverPath && coverKind) {
    await svc.from('insyt_attachments').insert({
      insyt_id: insytId,
      kind: coverKind,
      bucket: coverBucket,
      storage_path: coverPath,
      filename: coverFilename,
      mime: coverMime,
      size_bytes: coverFile instanceof File ? coverFile.size : null,
      position: 0,
    })
  }

  // Upload extra images.
  for (let i = 0; i < imagesFiles.length; i++) {
    const f = imagesFiles[i]
    if (f.size > MAX_IMAGE_BYTES) continue
    const name = safeName(f.name || `image-${i}`)
    const path = `${folder}/image-${i}-${Date.now()}-${name}`
    try {
      await uploadFile(svc, BUCKET_IMAGES, path, f)
      await svc.from('insyt_attachments').insert({
        insyt_id: insytId,
        kind: 'image',
        bucket: BUCKET_IMAGES,
        storage_path: path,
        filename: name,
        mime: f.type || null,
        size_bytes: f.size,
        position: i + 1,
      })
    } catch (err) {
      console.error('[create-insyt] image upload failed', err)
    }
  }

  // Upload extra videos.
  for (let i = 0; i < videosFiles.length; i++) {
    const f = videosFiles[i]
    if (f.size > MAX_VIDEO_BYTES) continue
    const name = safeName(f.name || `video-${i}`)
    const path = `${folder}/video-${i}-${Date.now()}-${name}`
    try {
      await uploadFile(svc, BUCKET_VIDEOS, path, f)
      await svc.from('insyt_attachments').insert({
        insyt_id: insytId,
        kind: 'video',
        bucket: BUCKET_VIDEOS,
        storage_path: path,
        filename: name,
        mime: f.type || null,
        size_bytes: f.size,
        position: i + 1,
      })
    } catch (err) {
      console.error('[create-insyt] video upload failed', err)
    }
  }

  // Final success status row. Stripe/CMS publishing happens downstream (n8n on insyts insert).
  await writeStatus(svc, correlation_id, insytId, creatorEmail, 'completed', 'success', 'Insyt submitted for review', { is_free: isFree, tags_count: tags.length })

  return json(200, {
    success: true,
    insyt_id: insytId,
    correlation_id,
  })
})
