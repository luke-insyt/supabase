-- The original handle_new_user trigger inserted only `id`, leaving
-- `auth_user_id` NULL. RLS on public.users gates SELECT on
-- `auth.uid() = auth_user_id`, so trigger-created rows were invisible to
-- their own owner. Set auth_user_id alongside id, and backfill rows the
-- broken trigger already created.

CREATE OR REPLACE FUNCTION public.handle_new_user() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
  INSERT INTO public.users (id, auth_user_id, email, username, display_name, profile_image_url)
  VALUES (
    NEW.id,
    NEW.id,
    NEW.email,
    NEW.raw_user_meta_data ->> 'username',
    NEW.raw_user_meta_data ->> 'display_name',
    NEW.raw_user_meta_data ->> 'profile_image_url'
  );
  RETURN NEW;
END;
$$;

UPDATE public.users
SET auth_user_id = id
WHERE auth_user_id IS NULL;
