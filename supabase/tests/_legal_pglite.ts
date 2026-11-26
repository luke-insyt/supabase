// Shared PGlite stand-in for the legal migrations' offline tests (GET-470, GET-486). Extracted
// from get470_legal_registry_test.ts so the GET-486 tests build on the exact same schema.
// The stand-in models the schema BEFORE GET-470; `migrated()` applies the GET-470 migrations and
// GET-486 A1 (the legacy-table drop), i.e. the current legal schema.
import { assertRejects } from 'jsr:@std/assert@1'
import { PGlite } from 'npm:@electric-sql/pglite@0.2.17'

export const read = (f: string) => Deno.readTextFile(new URL(`../migrations/${f}`, import.meta.url))

export const GET330 = await read('20261111120000_get330_agreement_v1_1.sql')
export const GET357 = await read('20261111130000_get357_agreement_rollout.sql')
export const GET332 = await read('20261017120000_get332_sales_anonymity.sql')
export const P0 = await read('20261125120000_get470_drop_agreement_v1_1.sql')
export const MIG_A = await read('20261125121000_get470_registry_columns.sql')
export const MIG_B = await read('20261125122000_get470_legal_registry.sql')
export const DROP_LEGACY = await read('20261126120000_get470_drop_legacy_acceptances.sql')

export const V10_SHA = '673fb82af840b1e6d2ab16097ad973d35159bb840f1bc44e5bf256a9213c13a0'
export const SHA_B = 'b'.repeat(64)
export const SHA_C = 'c'.repeat(64)

// GET-332 §1 only (the purchase stamp); §2+ need tables this stand-in doesn't model.
export const GET332_S1 = GET332.slice(0, GET332.indexOf('-- 2. The creator'))

// Shapes from 20260503161943_remote_schema.sql, 20260503212044, 20260503222540, 20260519082724,
// 20260601120000, 20261012152621 (only the columns the GET-470 migrations touch).
export const STAND_IN = `
create role anon; create role authenticated; create role service_role bypassrls;
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text, created_at timestamptz default now());
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
create schema storage;
create table storage.buckets (id text primary key, name text, public boolean);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
alter table storage.objects enable row level security;

alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;

create table public.users (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid, email varchar, is_creator boolean default false, agreement_version varchar);

create table public.agreement_versions (
  id uuid primary key default gen_random_uuid(),
  version varchar not null, title varchar not null, url varchar not null,
  effective_date date not null, is_current boolean default false, changelog text,
  created_at timestamptz default now(), bucket_path text, content_type text);
alter table public.agreement_versions add constraint agreement_versions_version_key unique (version);
alter table public.agreement_versions enable row level security;
create policy "Public read" on public.agreement_versions for select using (true);

create table public.agreement_acceptances (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null, email text not null, signature_name text not null,
  version varchar not null references public.agreement_versions(version),
  ip text, accepted_at timestamptz not null default now());
alter table public.agreement_acceptances enable row level security;

insert into public.agreement_versions (version, title, url, effective_date, is_current, bucket_path, content_type)
values ('v1.0', 'Terms of Service',
        'https://xeqjairmlwnjtmselyvo.supabase.co/storage/v1/object/public/creator-agreements/terms/creator-agreement-v1.0.html',
        '2026-05-03', true, 'terms/creator-agreement-v1.0.html', 'text/html');

create table public.inquiries (
  id uuid primary key default gen_random_uuid(),
  requester_auth_user_id uuid, is_anonymous boolean not null default false,
  status text not null default 'open', audience text not null default 'all_insyters',
  open_until timestamptz, insyts_wanted integer default 1);
create table public.inquiry_targets (inquiry_id uuid, creator_auth_user_id uuid);
create table public.inquiry_proposals (
  id uuid primary key default gen_random_uuid(),
  inquiry_id uuid references public.inquiries(id),
  insyter_auth_user_id uuid, status text not null default 'submitted',
  abstract text not null, outline_html text not null, read_time_min integer not null,
  price_cents integer not null, deliver_by date not null, terms_accepted_at timestamptz not null,
  attached_insyt_id uuid, created_at timestamptz not null default now());
create table public.insyts (
  insyt_id text primary key, creator_email text, visibility text default 'public', inquiry_proposal_id uuid);
create table public.purchases (
  id bigint generated by default as identity primary key,
  insyt_id text, buyer_email text, stripe_session_id text, stripe_blob json,
  creator_email varchar, amount_paid bigint, is_anonymous boolean not null default false);
create table public.creator_subscriptions (
  id uuid primary key default gen_random_uuid(), subscriber_id uuid, creator_id uuid);
`

export type Db = PGlite

export async function base(): Promise<Db> {
  const pg = new PGlite()
  await pg.exec(STAND_IN)
  await pg.exec(GET330)
  await pg.exec(GET357)
  await pg.exec(GET332_S1)
  return pg
}

// Up to migration B: the GET-470 dual-write era (legacy table still there).
export async function throughB(seed = ''): Promise<Db> {
  const pg = await base()
  if (seed) await pg.exec(seed)
  await pg.exec(P0)
  await pg.exec(MIG_A)
  await pg.exec(MIG_B)
  return pg
}

// The current schema: + GET-486 A1 (legacy table dropped). `beforeDrop` runs between B and A1.
export async function migrated(seed = '', beforeDrop?: (pg: Db) => Promise<void>): Promise<Db> {
  const pg = await throughB(seed)
  if (beforeDrop) await beforeDrop(pg)
  await pg.exec(DROP_LEGACY)
  return pg
}

export const tableExists = async (pg: Db, name: string) =>
  (await one<{ t: string | null }>(pg, `select to_regclass($1)::text t`, [name])).t !== null

export async function user(pg: Db, email: string): Promise<string> {
  const id = (await pg.query<{ id: string }>(`insert into auth.users (email) values ($1) returning id`, [email])).rows[0].id
  await pg.query(`insert into public.users (auth_user_id, email, is_creator) values ($1, $2, true)`, [id, email])
  return id
}

export async function publish(pg: Db, type: string, version: string, sha: string, current = false, display: string | null = null) {
  await pg.query(
    `insert into public.agreement_versions (document_type, version, title, url, effective_date, is_current, sha256, display_text)
     values ($1, $2, $3, $4, '2026-12-01', $5, $6, $7)`,
    [type, version, `${type} ${version}`, `https://x/legal-documents/${type}/${version}.html`, current, sha, display],
  )
}

export async function one<T>(pg: Db, sql: string, params: unknown[] = []): Promise<T> {
  return (await pg.query<T>(sql, params)).rows[0]
}

export async function code(p: Promise<unknown>): Promise<string | undefined> {
  const err = await assertRejects(() => p)
  return (err as { code?: string }).code
}

export async function msg(p: Promise<unknown>): Promise<string> {
  const err = await assertRejects(() => p)
  return String((err as Error).message)
}
