-- 2026-11-03 Capture Review: admin area (review.dbcapture.com/admin.html)
-- Admins sign in with Supabase Auth (email + password) and see everything, including hidden
-- folders. Clients are unaffected: they still only reach data through the gallery_* functions.

-- Who is an admin (auth user ids). Added by hand in SQL, never by the web page.
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;

create or replace function public.is_admin()
 returns boolean
 language sql stable security definer
 set search_path to 'public'
as $function$
  select exists (select 1 from admins where user_id = auth.uid())
$function$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated, service_role;

-- Shots per capture folder, reported by the Mac app (for "awaiting upload")
create table if not exists public.folder_stats (
  gallery_id  uuid not null references public.galleries(id) on delete cascade,
  folder_path text not null,
  shots       integer not null default 0,
  updated_at  timestamptz not null default now(),
  primary key (gallery_id, folder_path)
);
alter table public.folder_stats enable row level security;

-- Client visits
alter table public.galleries add column if not exists last_opened_at timestamptz;
alter table public.galleries add column if not exists open_count integer not null default 0;

create or replace function public.gallery_open(p_slug text, p_code text)
 returns json
 language plpgsql security definer
 set search_path to 'public'
as $function$
declare gid uuid := gallery_for(p_slug, p_code);
begin
  if gid is null then
    perform pg_sleep(0.5);                                  -- slows down guessing
    return null;
  end if;
  update galleries set last_opened_at = now(), open_count = open_count + 1 where id = gid;
  return (select json_build_object('name', name, 'now', now()) from galleries where id = gid);
end $function$;

-- Read access for admins only (clients have no direct table access; RLS stays on)
drop policy if exists admin_read on public.galleries;
create policy admin_read on public.galleries for select to authenticated using (public.is_admin());
drop policy if exists admin_update on public.galleries;
create policy admin_update on public.galleries for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists admin_read on public.images;
create policy admin_read on public.images for select to authenticated using (public.is_admin());
drop policy if exists admin_read on public.marks;
create policy admin_read on public.marks for select to authenticated using (public.is_admin());
drop policy if exists admin_read on public.folder_visibility;
create policy admin_read on public.folder_visibility for select to authenticated using (public.is_admin());
drop policy if exists admin_write on public.folder_visibility;
create policy admin_write on public.folder_visibility for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists admin_read on public.folder_stats;
create policy admin_read on public.folder_stats for select to authenticated using (public.is_admin());
drop policy if exists admin_self on public.admins;
create policy admin_self on public.admins for select to authenticated using (user_id = auth.uid());

-- Dashboard in one call: every gallery with counts
create or replace function public.admin_galleries()
 returns json
 language plpgsql stable security definer
 set search_path to 'public'
as $function$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return coalesce((
    select json_agg(row_to_json(g) order by g.created_at desc) from (
      select ga.id, ga.name, ga.session_name, ga.slug, ga.access_code, ga.active, ga.created_at,
             ga.last_opened_at, ga.open_count,
             (select count(*) from images i where i.gallery_id = ga.id and i.deleted_at is null) as images,
             (select count(distinct i.rel_path) from images i where i.gallery_id = ga.id and i.deleted_at is null) as frames,
             (select coalesce(sum(shots), 0) from folder_stats s where s.gallery_id = ga.id) as shots,
             (select count(*) from folder_visibility v where v.gallery_id = ga.id and v.hidden) as hidden_folders,
             (select count(*) from marks m join images i on i.id = m.image_id
               where i.gallery_id = ga.id and i.deleted_at is null and m.reviewer = 'client'
                 and (coalesce(m.rating, 0) > 0 or m.color_tag is not null)) as client_marks
      from galleries ga
    ) g), '[]'::json);
end $function$;
revoke all on function public.admin_galleries() from public, anon;
grant execute on function public.admin_galleries() to authenticated;

-- Everything in one gallery for the admin view, hidden folders included
create or replace function public.admin_gallery(p_gallery uuid)
 returns json
 language plpgsql stable security definer
 set search_path to 'public'
as $function$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return json_build_object(
    'gallery', (select row_to_json(g) from (select id, name, session_name, slug, access_code, active, created_at,
                                                   last_opened_at, open_count from galleries where id = p_gallery) g),
    'folders', coalesce((select json_agg(row_to_json(f) order by f.folder_path) from (
        select fp.folder_path,
               coalesce(v.hidden, false) as hidden,
               coalesce(s.shots, 0) as shots,
               (select count(distinct i.rel_path) from images i
                 where i.gallery_id = p_gallery and i.folder_path = fp.folder_path and i.deleted_at is null) as frames
        from (select folder_path from images where gallery_id = p_gallery and deleted_at is null
              union select folder_path from folder_stats where gallery_id = p_gallery
              union select folder_path from folder_visibility where gallery_id = p_gallery) fp
        left join folder_visibility v on v.gallery_id = p_gallery and v.folder_path = fp.folder_path
        left join folder_stats s on s.gallery_id = p_gallery and s.folder_path = fp.folder_path) f), '[]'::json),
    'images', coalesce((select json_agg(json_build_object(
        'id', i.id, 'rel_path', i.rel_path, 'folder_path', i.folder_path, 'filename', i.filename,
        'display_name', i.display_name, 'variant_position', i.variant_position,
        'thumb_path', i.thumb_path, 'storage_path', i.storage_path,
        'rating', m.rating, 'color_tag', m.color_tag) order by i.rel_path, i.variant_position)
      from images i left join marks m on m.image_id = i.id and m.reviewer = 'client'
      where i.gallery_id = p_gallery and i.deleted_at is null), '[]'::json));
end $function$;
revoke all on function public.admin_gallery(uuid) from public, anon;
grant execute on function public.admin_gallery(uuid) to authenticated;
