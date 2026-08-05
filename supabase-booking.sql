-- Meet Milan booking administration
-- Run once in Supabase Dashboard > SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.booking_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.booking_slots (
  id uuid primary key default gen_random_uuid(),
  starts_at timestamptz not null unique,
  ends_at timestamptz not null,
  status text not null default 'available'
    check (status in ('available','request_pending','booked','blocked')),
  constraint booking_slots_valid_window check (ends_at > starts_at),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.booking_requests (
  id uuid primary key default gen_random_uuid(),
  slot_id uuid not null references public.booking_slots(id) on delete restrict,
  requested_start timestamptz not null,
  requested_end timestamptz not null,
  name text not null check (char_length(name) between 1 and 120),
  contact text not null check (char_length(contact) between 3 and 200),
  duration text not null check (duration in ('1 hour','2 hours','Evening')),
  location text not null check (char_length(location) between 2 and 240),
  message text not null check (char_length(message) between 3 and 3000),
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
  ,constraint booking_requests_valid_period check (requested_end > requested_start)
);

create or replace function public.is_booking_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.booking_admins where user_id = auth.uid()
  );
$$;

create or replace function public.public_available_slots()
returns table(id uuid, starts_at timestamptz, ends_at timestamptz, unavailable jsonb)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.starts_at, s.ends_at,
    coalesce((select jsonb_agg(jsonb_build_object('start',r.requested_start,'end',r.requested_end))
      from public.booking_requests r where r.slot_id=s.id and r.status in ('pending','approved')),'[]'::jsonb)
  from public.booking_slots s
  where s.status = 'available' and s.starts_at > now()
  order by s.starts_at asc
  limit 60;
$$;

create or replace function public.request_booking(
  p_slot_id uuid,
  p_requested_start timestamptz,
  p_name text,
  p_contact text,
  p_duration text,
  p_location text,
  p_message text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request_id uuid;
  v_requested_end timestamptz;
  v_window_start timestamptz;
  v_window_end timestamptz;
begin
  if length(trim(p_name)) < 1 or length(trim(p_contact)) < 3 or
     length(trim(p_location)) < 2 or length(trim(p_message)) < 3 then
    raise exception 'Invalid booking details';
  end if;

  v_requested_end := p_requested_start + case p_duration
    when '1 hour' then interval '1 hour'
    when '2 hours' then interval '2 hours'
    when 'Evening' then interval '6 hours'
    else interval '0 hours' end;

  select starts_at, ends_at into v_window_start, v_window_end
  from public.booking_slots where id = p_slot_id and status = 'available' for update;
  if v_window_start is null or p_requested_start < v_window_start or
     v_requested_end > v_window_end or p_requested_start <= now() then
    raise exception 'This time is outside the available window';
  end if;

  if exists (select 1 from public.booking_requests r where r.slot_id = p_slot_id
    and r.status in ('pending','approved')
    and tstzrange(r.requested_start,r.requested_end,'[)') && tstzrange(p_requested_start,v_requested_end,'[)')) then
    raise exception 'This time is no longer available';
  end if;

  insert into public.booking_requests(slot_id,requested_start,requested_end,name,contact,duration,location,message)
  values (p_slot_id,p_requested_start,v_requested_end,trim(p_name),trim(p_contact),p_duration,trim(p_location),trim(p_message))
  returning id into v_request_id;

  return v_request_id;
end;
$$;

create or replace function public.admin_decide_booking(p_request_id uuid, p_decision text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_slot_id uuid;
begin
  if not public.is_booking_admin() then raise exception 'Not authorized'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'Invalid decision'; end if;

  select slot_id into v_slot_id
  from public.booking_requests
  where id = p_request_id and status = 'pending'
  for update;

  if v_slot_id is null then raise exception 'Request is no longer pending'; end if;

  update public.booking_requests
  set status = p_decision, updated_at = now()
  where id = p_request_id;

end;
$$;

alter table public.booking_admins enable row level security;
alter table public.booking_slots enable row level security;
alter table public.booking_requests enable row level security;

drop policy if exists "admins read slots" on public.booking_slots;
create policy "admins read slots" on public.booking_slots for select to authenticated
using (public.is_booking_admin());
drop policy if exists "admins create slots" on public.booking_slots;
create policy "admins create slots" on public.booking_slots for insert to authenticated
with check (public.is_booking_admin());
drop policy if exists "admins update slots" on public.booking_slots;
create policy "admins update slots" on public.booking_slots for update to authenticated
using (public.is_booking_admin()) with check (public.is_booking_admin());
drop policy if exists "admins delete slots" on public.booking_slots;
create policy "admins delete slots" on public.booking_slots for delete to authenticated
using (public.is_booking_admin());

drop policy if exists "admins read requests" on public.booking_requests;
create policy "admins read requests" on public.booking_requests for select to authenticated
using (public.is_booking_admin());

revoke all on public.booking_admins from anon, authenticated;
revoke all on public.booking_slots from anon;
revoke all on public.booking_requests from anon, authenticated;
grant select, insert, update, delete on public.booking_slots to authenticated;
grant select on public.booking_requests to authenticated;
grant execute on function public.public_available_slots() to anon, authenticated;
grant execute on function public.request_booking(uuid,timestamptz,text,text,text,text,text) to anon, authenticated;
grant execute on function public.admin_decide_booking(uuid,text) to authenticated;

-- After creating your admin account in Authentication > Users, activate it once:
-- insert into public.booking_admins(user_id) values ('YOUR-AUTH-USER-UUID');
