-- Ploegchat: bijhouden tot waar elke speler gelezen heeft ("Gelezen door ...").
create table if not exists public.chat_reads (
  player_id uuid primary key default auth.uid() references public.profiles on delete cascade,
  last_read_at timestamptz not null default now()
);
alter table public.chat_reads enable row level security;
drop policy if exists "ploeg leest" on public.chat_reads;
drop policy if exists "eigen gelezen" on public.chat_reads;
create policy "ploeg leest" on public.chat_reads for select to authenticated using (true);
create policy "eigen gelezen" on public.chat_reads for all to authenticated using (player_id = auth.uid()) with check (player_id = auth.uid());
revoke all on public.chat_reads from anon;
grant select, insert, update on public.chat_reads to authenticated;
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chat_reads') then
    alter publication supabase_realtime add table public.chat_reads;
  end if;
end $$;
