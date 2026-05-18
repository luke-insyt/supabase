-- Add correlation_id to insyts so resumed drafts can rebuild the same
-- {user_id}/{correlation_id}/ prefix used by uploaded attachments.
ALTER TABLE "public"."insyts"
  ADD COLUMN IF NOT EXISTS "correlation_id" uuid;

CREATE INDEX IF NOT EXISTS "insyts_correlation_id_idx"
  ON "public"."insyts" ("correlation_id");

-- Backfill from existing attachments. Storage paths are written as
-- `{auth_user_id}/{correlation_id}/{role}-{ts}-{filename}` by get-upload-url,
-- so split_part(...,'/',2) recovers the correlation_id. We only touch rows
-- that don't already have one and where the split yields a valid uuid.
UPDATE "public"."insyts" AS i
SET "correlation_id" = sub.cid::uuid
FROM (
  SELECT DISTINCT ON (a.insyt_id)
    a.insyt_id,
    split_part(a.storage_path, '/', 2) AS cid
  FROM "public"."insyt_attachments" a
  WHERE a.storage_path IS NOT NULL
  ORDER BY a.insyt_id, a.position NULLS LAST, a.id
) AS sub
WHERE i.id = sub.insyt_id
  AND i.correlation_id IS NULL
  AND sub.cid ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
