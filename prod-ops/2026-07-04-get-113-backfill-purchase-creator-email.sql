-- GET-113 · Backfill purchases.creator_email (prod data repair, run manually)
--
-- Every purchases row written by the n8n "Purchase Completed" pipeline before
-- 2026-07-04 has creator_email = '' — the insert node read
-- `$('Lookup insyt (creator + title)').first().json[0]` but n8n splits the
-- PostgREST array response into items, so `.json` IS the row and `[0]` was
-- always undefined. The creator's revenue views filter purchases by
-- creator_email, so those sales were invisible to their creators (while the
-- buyer still saw them via buyer_email). The pipeline was fixed on 2026-07-04;
-- this repairs the rows written before the fix (prod: ids 2 and 3, both
-- resolving to matthias.wallenwein@gmx.de via the insyt).
--
-- Idempotent: only touches rows whose creator_email is still empty/null.

update public.purchases p
set creator_email = i.creator_email
from public.insyts i
where p.insyt_id = i.insyt_id
  and coalesce(p.creator_email, '') = '';

-- Verify: expect 0 rows.
-- select id, insyt_id from public.purchases where coalesce(creator_email, '') = '';
