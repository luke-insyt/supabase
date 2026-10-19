-- GET-340: 👍/👎 on the insyts Player search shows ("From GetInsyt"), stored like
-- player reviews (Admin → Search reviews). target_id = the insyt's insyt_id;
-- player_name holds the insyt's title (its free, public title — the review list's
-- subject line). Ratings -1 / 1 like players (social_search_reviews_rating_scale
-- already covers every non-search kind).
alter table public.social_search_reviews drop constraint if exists social_search_reviews_target_kind_check;
alter table public.social_search_reviews
  add constraint social_search_reviews_target_kind_check
  check (target_kind in ('search', 'player', 'fact', 'insyt'));
