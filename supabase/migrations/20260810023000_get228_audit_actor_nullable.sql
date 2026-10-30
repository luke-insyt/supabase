-- GET-228 follow-up: share_ref_audit.actor_id must allow NULL.
--
-- An 'erasure' is performed by the RECIPIENT, who has no account at all — they
-- are authorised purely by holding the ref (S7-AC4). The first cut stored the
-- ref's own id in actor_id to satisfy NOT NULL, which puts a value in an audit
-- column that is simply false. An audit table that lies is worse than one that
-- admits "no identified actor", so the column becomes nullable and erasure
-- writes NULL. Every staff/owner action still carries a real actor.
alter table public.share_ref_audit alter column actor_id drop not null;
