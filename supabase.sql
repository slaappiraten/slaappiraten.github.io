-- ============================================================
-- Slaappiraten: database voor Supabase (gratis plan)
-- Plak dit volledig in Supabase > SQL Editor > New query > Run.
-- PAS EERST DE TEAMCODE AAN op de regel met 'PIRATEN2026'.
-- ============================================================

-- Spelersprofielen (gekoppeld aan login)
create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  name text not null check (char_length(name) between 1 and 40),
  nickname text check (char_length(nickname) <= 30),
  number int check (number between 0 and 99),
  position text,
  avatar text default '🏴‍☠️',
  motto text check (char_length(motto) <= 60),
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

-- Aanwezigheden per wedstrijd (match_id = id uit data/tournify.json)
create table if not exists public.attendance (
  match_id text not null,
  player_id uuid not null references public.profiles on delete cascade,
  status text not null check (status in ('yes','maybe','no','fan')),
  updated_at timestamptz not null default now(),
  primary key (match_id, player_id)
);

-- Goals en assists die spelers zelf doorgeven
create table if not exists public.goals (
  match_id text not null,
  player_id uuid not null references public.profiles on delete cascade,
  goals int not null default 0 check (goals between 0 and 30),
  assists int not null default 0 check (assists between 0 and 30),
  primary key (match_id, player_id)
);

-- Stemmen voor de awards (1 stem per categorie per speler per match)
create table if not exists public.votes (
  match_id text not null,
  voter_id uuid not null references public.profiles on delete cascade,
  category text not null check (category in ('kapitein','muur','kanon','zeebonk','schipbreuk','slaapkop')),
  nominee_id uuid not null references public.profiles on delete cascade,
  primary key (match_id, voter_id, category),
  check (voter_id <> nominee_id)
);

-- Voorspellingen van de uitslag
create table if not exists public.predictions (
  match_id text not null,
  player_id uuid not null references public.profiles on delete cascade,
  us int not null check (us between 0 and 60),
  them int not null check (them between 0 and 60),
  primary key (match_id, player_id)
);

-- Update voor bestaande databases: supporters toestaan
alter table public.attendance drop constraint if exists attendance_status_check;
alter table public.attendance add constraint attendance_status_check check (status in ('yes','maybe','no','fan'));

-- Maximum 7 spelers per wedstrijd (5 op het veld + 2 wissels)
create or replace function public.max_seven() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'yes' and (tg_op = 'INSERT' or old.status is distinct from 'yes') then
    perform pg_advisory_xact_lock(hashtext(new.match_id));
    if (select count(*) from public.attendance where match_id = new.match_id and status = 'yes' and player_id <> new.player_id) >= 7 then
      raise exception 'Schip is vol';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists max_seven on public.attendance;
create trigger max_seven before insert or update on public.attendance
  for each row execute function public.max_seven();

-- Is de ingelogde speler kapitein (admin)?
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

-- Nieuw account: teamcode controleren en profiel aanmaken.
-- De eerste speler die zich registreert wordt automatisch kapitein.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.raw_user_meta_data->>'team_code', '') <> 'PIRATEN2026' then
    raise exception 'Verkeerde teamcode';
  end if;
  insert into public.profiles (id, name, is_admin)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1)), 40),
    not exists (select 1 from public.profiles)
  );
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Gewone spelers mogen zichzelf geen kapitein maken
create or replace function public.protect_admin_flag() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.is_admin is distinct from old.is_admin and not public.is_admin() then
    new.is_admin := old.is_admin;
  end if;
  return new;
end;
$$;
drop trigger if exists protect_admin on public.profiles;
create trigger protect_admin before update on public.profiles
  for each row execute function public.protect_admin_flag();

-- ============ Beveiliging (Row Level Security) ============
-- Lezen: iedereen met de link (zo zien vrienden ook de rankings).
-- Schrijven: alleen je eigen rijen; de kapitein mag aanwezigheden en goals van anderen bijwerken.
alter table public.profiles enable row level security;
alter table public.attendance enable row level security;
alter table public.goals enable row level security;
alter table public.votes enable row level security;
alter table public.predictions enable row level security;

drop policy if exists "lezen" on public.profiles;
drop policy if exists "eigen profiel" on public.profiles;
create policy "lezen" on public.profiles for select using (true);
create policy "eigen profiel" on public.profiles for update
  using (id = auth.uid() or public.is_admin()) with check (id = auth.uid() or public.is_admin());

do $$
declare t text;
begin
  foreach t in array array['attendance','goals'] loop
    execute format('drop policy if exists "lezen" on public.%I', t);
    execute format('drop policy if exists "schrijven" on public.%I', t);
    execute format('create policy "lezen" on public.%I for select using (true)', t);
    execute format('create policy "schrijven" on public.%I for all using (player_id = auth.uid() or public.is_admin()) with check (player_id = auth.uid() or public.is_admin())', t);
  end loop;
end $$;

drop policy if exists "lezen" on public.predictions;
drop policy if exists "schrijven" on public.predictions;
create policy "lezen" on public.predictions for select using (true);
create policy "schrijven" on public.predictions for all using (player_id = auth.uid()) with check (player_id = auth.uid());

drop policy if exists "lezen" on public.votes;
drop policy if exists "schrijven" on public.votes;
create policy "lezen" on public.votes for select using (true);
create policy "schrijven" on public.votes for all using (voter_id = auth.uid()) with check (voter_id = auth.uid());

grant select on all tables in schema public to anon, authenticated;
grant insert, update, delete on public.attendance, public.goals, public.votes, public.predictions to authenticated;
grant update on public.profiles to authenticated;

-- ============ Ploegchat ============
create table if not exists public.messages (
  id bigint generated always as identity primary key,
  player_id uuid not null default auth.uid() references public.profiles on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists messages_created_at_idx on public.messages (created_at desc);
alter table public.messages enable row level security;
drop policy if exists "ploeg leest" on public.messages;
drop policy if exists "eigen bericht sturen" on public.messages;
drop policy if exists "eigen bericht wissen" on public.messages;
create policy "ploeg leest" on public.messages for select to authenticated using (true);
create policy "eigen bericht sturen" on public.messages for insert to authenticated with check (player_id = auth.uid());
create policy "eigen bericht wissen" on public.messages for delete to authenticated using (player_id = auth.uid() or public.is_admin());
revoke all on public.messages from anon;
grant select, insert, delete on public.messages to authenticated;
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages') then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;

-- ============ Spelerslimiet ============
create table if not exists public.settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.settings enable row level security;
drop policy if exists "lezen" on public.settings;
drop policy if exists "kapitein" on public.settings;
create policy "lezen" on public.settings for select using (true);
create policy "kapitein" on public.settings for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select on public.settings to anon, authenticated;
grant insert, update, delete on public.settings to authenticated;
insert into public.settings (key, value) values ('max_players', '7') on conflict (key) do nothing;

create or replace function public.max_players() returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::int from public.settings where key = 'max_players'), 7);
$$;

create or replace function public.max_seven() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'yes' and (tg_op = 'INSERT' or old.status is distinct from 'yes') then
    perform pg_advisory_xact_lock(hashtext(new.match_id));
    if (select count(*) from public.attendance where match_id = new.match_id and status = 'yes' and player_id <> new.player_id) >= public.max_players() then
      raise exception 'Schip is vol';
    end if;
  end if;
  return new;
end;
$$;

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'settings') then
    alter publication supabase_realtime add table public.settings;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'attendance') then
    alter publication supabase_realtime add table public.attendance;
  end if;
end $$;

-- ============ Chat: gelezen ============
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
