-- Private Meet Milan Search Console dashboard storage.
-- Run once in Supabase Dashboard > SQL Editor.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'seo-dashboard',
  'seo-dashboard',
  false,
  5000000,
  array['text/html', 'application/json']
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "booking admins read private SEO dashboard" on storage.objects;
create policy "booking admins read private SEO dashboard"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'seo-dashboard'
  and public.is_booking_admin()
);

-- Upload these three files from meetmilan-seo-dashboard/dist into the private bucket:
--   data-app-build.json
--   index.html
--   snapshot.<hash>.json
