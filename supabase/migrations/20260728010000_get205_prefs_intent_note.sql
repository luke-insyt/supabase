-- GET-205: reader content-preferences gain "what am I here for" + a free-text note.
--
-- Additive and backwards-compatible on purpose: the frontend reads these columns
-- defensively, so this can land on staging/prod before or after the client that
-- uses them without a broken window. Follows the GET-191 migration's house style
-- (comments + check constraints alongside the columns).
--
-- ⚠️ `intent` defaults to '{}', so from the moment this applies EVERY existing
-- account counts as "incomplete" for the blocking modal's predicate (D7 —
-- accepted, no staged rollout). Prefill keeps it to one question for readers who
-- already answered GET-191's sports/content-type prompt.
--
-- Spec: webflow-app-documentation/features/signup-preferences-modal/{requirements,implementation}.md

alter table public.user_content_preferences
  add column if not exists intent        text[] not null default '{}',
  add column if not exists interest_note text;

comment on column public.user_content_preferences.intent is
  'What the reader says they are here for: subset of {creator,buyer}. INTENT ONLY — users.is_creator
   remains the systems authority on creator status (GET-205 D3).';

comment on column public.user_content_preferences.interest_note is
  'Free-text "anything specific youre after" answer. Trimmed, <=280 chars; stored raw and rendered
   via textContent, never innerHTML (GET-205 D5).';

-- Constraints are added separately so a re-run against a partially-applied database
-- fails loudly on the constraint rather than silently skipping the column add.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'ucp_intent_valid'
  ) then
    alter table public.user_content_preferences
      add constraint ucp_intent_valid check (intent <@ array['creator','buyer']::text[]);
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'ucp_interest_note_len'
  ) then
    alter table public.user_content_preferences
      add constraint ucp_interest_note_len
      check (interest_note is null or char_length(interest_note) <= 280);
  end if;
end $$;
