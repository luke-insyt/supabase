-- GET-116 (SF1a + SF1b) — close the paywall bypass.
--
-- The paid-content columns on public.insyts (body_html, video_url) were readable
-- by anon/authenticated straight through PostgREST with the publishable key
-- (e.g. GET /rest/v1/insyts?select=body_html&status=eq.live), sidestepping the
-- gated get-insyt-content edge function. Column-level REVOKE removes that direct
-- read; paid text/video are then reachable ONLY via get-insyt-content, which runs
-- as service_role and gates on purchase / active subscription / creator-owner.
--
-- Backwards-compat / DEPLOY ORDER (important): the create-insyt editor previously
-- direct-selected body_html to prefill its editor. That was re-routed through
-- get-insyt-content (owner path) in the frontend PR on agent/GET-116. Deploy the
-- FRONTEND to staging FIRST, then apply this migration — otherwise the editor
-- blanks the body when a creator edits a published insyt.
--
-- Idempotent + non-destructive: only tightens column grants; no data change.

revoke select (body_html, video_url) on public.insyts from anon, authenticated;
