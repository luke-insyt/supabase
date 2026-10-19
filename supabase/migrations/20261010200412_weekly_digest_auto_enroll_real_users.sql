-- Pulled into the repo 2026-10-18 from prod's migration history (applied to prod
-- directly, never committed). The recorded statements held only the function;
-- the trigger was applied live alongside it, so its definition is copied here
-- from prod's pg_trigger to make this file reproduce prod.
--
-- Auto-enroll every new real user into the weekly digest allowlist.
-- Decision: 2026-10-10, Lukas (owner), via chat.
-- Excludes @example.com synthetic QA/monitoring probe accounts.
-- See claude/weekly-digest-allowlist-policy-2026-10-10.md in the GetInsyts
-- project for the full decision record, including the still-open
-- no-unsubscribe compliance item the owner chose to proceed past.
-- NEW.id is safe as an auth.users id: public.users.id = auth_user_id for every row.

CREATE OR REPLACE FUNCTION public.enroll_user_in_weekly_digest()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.email NOT ILIKE '%@example.com' THEN
    INSERT INTO public.weekly_digest_state (user_id, is_active, last_sent_at, dormant_streak)
    VALUES (NEW.id, true, now(), 0)
    ON CONFLICT (user_id) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enroll_user_in_weekly_digest ON public.users;
CREATE TRIGGER trg_enroll_user_in_weekly_digest
  AFTER INSERT ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.enroll_user_in_weekly_digest();
