-- One-time migration: bookings use appointment times inside availability windows.

alter table public.booking_requests add column if not exists requested_start timestamptz;
alter table public.booking_requests add column if not exists requested_end timestamptz;

update public.booking_requests r set
  requested_start = s.starts_at,
  requested_end = least(s.ends_at, s.starts_at + case r.duration
    when '1 hour' then interval '1 hour'
    when '2 hours' then interval '2 hours'
    else interval '6 hours' end)
from public.booking_slots s
where r.slot_id = s.id and r.requested_start is null;

alter table public.booking_requests alter column requested_start set not null;
alter table public.booking_requests alter column requested_end set not null;
alter table public.booking_requests drop constraint if exists booking_requests_valid_period;
alter table public.booking_requests add constraint booking_requests_valid_period check (requested_end > requested_start);

drop function if exists public.public_available_slots();
create function public.public_available_slots()
returns table(id uuid,starts_at timestamptz,ends_at timestamptz,unavailable jsonb)
language sql stable security definer set search_path=public as $$
  select s.id,s.starts_at,s.ends_at,
    coalesce((select jsonb_agg(jsonb_build_object('start',r.requested_start,'end',r.requested_end))
      from public.booking_requests r where r.slot_id=s.id and r.status in ('pending','approved')),'[]'::jsonb)
  from public.booking_slots s
  where s.status='available' and s.ends_at>now()
  order by s.starts_at asc limit 60;
$$;

drop function if exists public.request_booking(uuid,text,text,text,text,text);
drop function if exists public.request_booking(uuid,timestamptz,text,text,text,text,text);

create function public.request_booking(
  p_slot_id uuid, p_requested_start timestamptz, p_name text, p_contact text,
  p_duration text, p_location text, p_message text
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_request_id uuid; v_requested_end timestamptz;
  v_window_start timestamptz; v_window_end timestamptz;
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
  from public.booking_slots where id=p_slot_id and status='available' for update;
  if v_window_start is null or p_requested_start < v_window_start or
     v_requested_end > v_window_end or p_requested_start <= now() then
    raise exception 'This time is outside the available window';
  end if;
  if exists (select 1 from public.booking_requests r where r.slot_id=p_slot_id
    and r.status in ('pending','approved')
    and tstzrange(r.requested_start,r.requested_end,'[)') && tstzrange(p_requested_start,v_requested_end,'[)')) then
    raise exception 'This time is no longer available';
  end if;
  insert into public.booking_requests(slot_id,requested_start,requested_end,name,contact,duration,location,message)
  values(p_slot_id,p_requested_start,v_requested_end,trim(p_name),trim(p_contact),p_duration,trim(p_location),trim(p_message))
  returning id into v_request_id;
  return v_request_id;
end; $$;

create or replace function public.admin_decide_booking(p_request_id uuid,p_decision text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_booking_admin() then raise exception 'Not authorized'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'Invalid decision'; end if;
  update public.booking_requests set status=p_decision,updated_at=now()
  where id=p_request_id and status='pending';
  if not found then raise exception 'Request is no longer pending'; end if;
end; $$;

grant execute on function public.request_booking(uuid,timestamptz,text,text,text,text,text) to anon, authenticated;
grant execute on function public.public_available_slots() to anon, authenticated;
