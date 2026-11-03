-- 2026-11-03 Capture Review: per-folder visibility ("Publish to Client" / "Unpublish")
-- Upload and publish are separate: a hidden folder keeps uploading and syncing, the client sees
-- none of it; publishing shows the whole folder at once. No row = published (the default).
-- Ratings are kept while hidden.

create table if not exists public.folder_visibility (
  gallery_id  uuid not null references public.galleries(id) on delete cascade,
  folder_path text not null,
  hidden      boolean not null default false,
  updated_at  timestamptz not null default now(),
  primary key (gallery_id, folder_path)
);
alter table public.folder_visibility enable row level security;   -- no policies: Mac app (secret key) only
drop trigger if exists folder_visibility_touch on public.folder_visibility;
create trigger folder_visibility_touch before update on public.folder_visibility
  for each row execute function public.touch_updated_at();

-- Client list: not deleted, not in a hidden folder
create or replace function public.gallery_images(p_slug text, p_code text, p_ids uuid[] default null,
                                                 p_offset integer default 0, p_limit integer default 1000)
 returns setof json
 language plpgsql stable security definer
 set search_path to 'public'
as $function$
declare gid uuid := gallery_for(p_slug, p_code);
begin
  if gid is null then return; end if;
  return query
    select json_build_object(
      'id', i.id, 'rel_path', i.rel_path, 'folder_path', i.folder_path, 'filename', i.filename,
      'display_name', i.display_name, 'variant_position', i.variant_position,
      'thumb_path', i.thumb_path, 'storage_path', i.storage_path, 'quality', i.quality,
      'proof_bytes', i.proof_bytes, 'thumb_bytes', i.thumb_bytes,
      'rating', m.rating, 'color_tag', m.color_tag)
    from images i
    left join marks m on m.image_id = i.id and m.reviewer = 'client'
    left join folder_visibility fv on fv.gallery_id = gid and fv.folder_path = i.folder_path
    where i.gallery_id = gid and i.deleted_at is null and not coalesce(fv.hidden, false)
      and (p_ids is null or i.id = any(p_ids))
    order by i.rel_path, i.variant_position
    offset greatest(p_offset, 0) limit least(greatest(p_limit, 1), 1000);
end $function$;

-- Changes since a time. Publishing a folder sends all its images; hiding one removes them.
create or replace function public.gallery_changes(p_slug text, p_code text, p_since timestamptz)
 returns json
 language plpgsql stable security definer
 set search_path to 'public'
as $function$
declare gid uuid := gallery_for(p_slug, p_code);
begin
  if gid is null then return null; end if;
  return json_build_object(
    'now', now(),
    'images', coalesce((select json_agg(i.id) from images i
                        left join folder_visibility fv on fv.gallery_id = gid and fv.folder_path = i.folder_path
                        where i.gallery_id = gid and i.deleted_at is null and not coalesce(fv.hidden, false)
                          and (i.updated_at > p_since or fv.updated_at > p_since)), '[]'::json),
    'removed', coalesce((select json_agg(i.id) from images i
                         left join folder_visibility fv on fv.gallery_id = gid and fv.folder_path = i.folder_path
                         where i.gallery_id = gid
                           and ((i.deleted_at is not null and i.updated_at > p_since)
                             or (coalesce(fv.hidden, false) and (fv.updated_at > p_since or i.updated_at > p_since)))),
                        '[]'::json),
    'marks',  coalesce((select json_agg(json_build_object('image_id', m.image_id,
                                                          'rating', m.rating, 'color_tag', m.color_tag))
                        from marks m join images i on i.id = m.image_id
                        left join folder_visibility fv on fv.gallery_id = gid and fv.folder_path = i.folder_path
                        where i.gallery_id = gid and i.deleted_at is null and not coalesce(fv.hidden, false)
                          and m.reviewer = 'client' and m.updated_at > p_since),
                       '[]'::json));
end $function$;

-- Clients can't rate what they can't see
create or replace function public.gallery_set_mark(p_slug text, p_code text, p_image uuid, p_rating integer, p_color text)
 returns void
 language plpgsql security definer
 set search_path to 'public'
as $function$
declare gid uuid := gallery_for(p_slug, p_code);
begin
  if gid is null then raise exception 'not allowed'; end if;
  if not exists (select 1 from images i
                 left join folder_visibility fv on fv.gallery_id = gid and fv.folder_path = i.folder_path
                 where i.id = p_image and i.gallery_id = gid and i.deleted_at is null
                   and not coalesce(fv.hidden, false)) then
    raise exception 'not allowed';
  end if;
  if p_rating is null or p_rating < 0 or p_rating > 5 then raise exception 'bad rating'; end if;
  insert into marks (image_id, reviewer, rating, color_tag, source)
  values (p_image, 'client', p_rating, nullif(p_color, ''), 'client')
  on conflict (image_id, reviewer)
  do update set rating = excluded.rating, color_tag = excluded.color_tag, source = 'client';
end $function$;
