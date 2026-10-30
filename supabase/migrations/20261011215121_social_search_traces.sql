-- Social Search (prototype, admin-only): one row per search + the full agent
-- trace as a gzipped JSON file in a private bucket.
--
-- The row is the index the admin list reads (who, what, how long, how many
-- tokens, per-stage summary, the result shown). The trace file holds every
-- model call (prompt, output, tokens) and every tool call (queries, raw
-- results) — ~0.5–1 MB gzipped per search, too big for a row.
--
-- Access: ONLY the RN server's service role, behind requireAdmin. RLS is on
-- with no policies and all table grants are revoked from anon/authenticated,
-- so the Supabase REST API exposes nothing. Search queries reveal what a club
-- is scouting for — keep it that way when this leaves the prototype.
-- Idempotent (IF NOT EXISTS / ON CONFLICT) because staging got it via the
-- Management API before this file was pushed.

CREATE TABLE IF NOT EXISTS public.social_searches (
  id              uuid PRIMARY KEY,
  auth_user_id    uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  user_email      text,
  query           text NOT NULL,
  answers         jsonb NOT NULL DEFAULT '{}'::jsonb,
  status          text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'done', 'failed')),
  error           text,
  profile         jsonb,
  result          jsonb,
  stages          jsonb NOT NULL DEFAULT '[]'::jsonb,
  players_shown   integer,
  below_threshold integer,
  rounds          integer,
  duration_ms     integer,
  tokens_in       integer,
  tokens_out      integer,
  youtube_queries integer,
  brave_calls     integer,
  trace_path      text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  finished_at     timestamptz
);

CREATE INDEX IF NOT EXISTS social_searches_created_at_idx ON public.social_searches (created_at DESC);

ALTER TABLE public.social_searches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.social_searches FROM anon, authenticated;

-- 20 MB cap: a 3-round trace is ~0.75 MB gzipped.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('social-search-traces', 'social-search-traces', false, 20971520, ARRAY['application/gzip'])
ON CONFLICT (id) DO NOTHING;
