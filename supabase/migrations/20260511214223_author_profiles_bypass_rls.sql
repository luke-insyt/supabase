-- author_profiles is a deliberately-public view over users (email,
-- display_name, bio) used by the feed and detail pages to render author
-- info. In Postgres 15+ views default to security_invoker = on, which
-- means the view inherits the caller's RLS on users -- and users only
-- allows reading your own row. That blanks out other authors in the
-- feed. Switch the view to security_invoker = off so it bypasses RLS
-- and returns all author profile rows.

ALTER VIEW public.author_profiles SET (security_invoker = off);
