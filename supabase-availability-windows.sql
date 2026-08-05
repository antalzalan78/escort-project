-- One-time migration: convert booking availability from a single time to a time window.
-- Run in Supabase Dashboard > SQL Editor for the existing Meet Milan project.

alter table public.booking_slots
  add column if not exists ends_at timestamptz;

update public.booking_slots
set ends_at = starts_at + interval '1 hour'
where ends_at is null;

alter table public.booking_slots
  alter column ends_at set not null;

alter table public.booking_slots
  drop constraint if exists booking_slots_valid_window;

alter table public.booking_slots
  add constraint booking_slots_valid_window check (ends_at > starts_at);

drop function if exists public.public_available_slots();

create function public.public_available_slots()
returns table(id uuid, starts_at timestamptz, ends_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.starts_at, s.ends_at
  from public.booking_slots s
  where s.status = 'available' and s.starts_at > now()
  order by s.starts_at asc
  limit 60;
$$;

grant execute on function public.public_available_slots() to anon, authenticated;
