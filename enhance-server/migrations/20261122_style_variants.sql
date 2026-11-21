-- v11.66: style variants (several looks inside one style card).
-- Additive only: a new table; nothing existing is altered.
-- RLS on with NO policies, like the photo rows of public.styles: only the
-- server's service-role key can read/write (variant prompts never reach the app).
create table if not exists public.style_variants (
  id text primary key,
  style_id text not null references public.styles(id) on delete cascade,
  name text not null,
  prompt text not null,
  sample_url text,
  sort_order integer not null default 0,
  enabled boolean not null default true,
  updated_at double precision not null default extract(epoch from now())
);

create index if not exists style_variants_style_idx
  on public.style_variants (style_id, sort_order);

alter table public.style_variants enable row level security;

revoke all on table public.style_variants from anon, authenticated;
-- The server (service role) reads/writes it, same grants as public.styles.
grant select, insert, update, delete on table public.style_variants to service_role;
