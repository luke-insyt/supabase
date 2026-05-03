CREATE TABLE IF NOT EXISTS public.agreement_acceptances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid NOT NULL REFERENCES auth.users(id),
  email text NOT NULL,
  signature_name text NOT NULL,
  version varchar NOT NULL REFERENCES public.agreement_versions(version),
  ip text,
  accepted_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.agreement_acceptances ENABLE ROW LEVEL SECURITY;

GRANT ALL ON TABLE public.agreement_acceptances TO service_role;
