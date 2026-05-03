ALTER TABLE public.users
ALTER COLUMN id SET DEFAULT gen_random_uuid();
