ALTER TABLE public.agreement_versions
ADD CONSTRAINT agreement_versions_version_key UNIQUE (version);
