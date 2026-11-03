-- 2026-11-03 Capture Review: image identity + soft delete
-- Renames/moves update the existing row (same images.id), so client ratings (marks) stay attached.
-- Deletes hide the row instead of removing it, so a restore brings the ratings back.
-- Safe to run more than once. NOT RUN YET.

-- The catalog's permanent image id (survives renames/moves); filename/rel_path become "where it is now"
alter table public.images add column if not exists image_uid text;
-- Set when the frame is deleted in Capture One (Trash or gone); null = visible
alter table public.images add column if not exists deleted_at timestamptz;
create index if not exists images_gallery_uid on public.images (gallery_id, image_uid, variant_position);

-- The catalog's session id, for one-gallery-per-session later (keyed on this, not the session name)
alter table public.galleries add column if not exists session_uid text;

-- Clients never see deleted frames
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
    where i.gallery_id = gid and i.deleted_at is null and (p_ids is null or i.id = any(p_ids))
    order by i.rel_path, i.variant_position
    offset greatest(p_offset, 0) limit least(greatest(p_limit, 1), 1000);
end $function$;

-- Changes since a time: images updated (and visible), images removed, client marks
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
                        where i.gallery_id = gid and i.deleted_at is null and i.updated_at > p_since), '[]'::json),
    'removed', coalesce((select json_agg(i.id) from images i
                         where i.gallery_id = gid and i.deleted_at is not null and i.updated_at > p_since), '[]'::json),
    'marks',  coalesce((select json_agg(json_build_object('image_id', m.image_id,
                                                          'rating', m.rating, 'color_tag', m.color_tag))
                        from marks m join images i on i.id = m.image_id
                        where i.gallery_id = gid and i.deleted_at is null
                          and m.reviewer = 'client' and m.updated_at > p_since),
                       '[]'::json));
end $function$;

-- A client can't rate a deleted frame
create or replace function public.gallery_set_mark(p_slug text, p_code text, p_image uuid, p_rating integer, p_color text)
 returns void
 language plpgsql security definer
 set search_path to 'public'
as $function$
declare gid uuid := gallery_for(p_slug, p_code);
begin
  if gid is null then raise exception 'not allowed'; end if;
  if not exists (select 1 from images where id = p_image and gallery_id = gid and deleted_at is null) then
    raise exception 'not allowed';
  end if;
  if p_rating is null or p_rating < 0 or p_rating > 5 then raise exception 'bad rating'; end if;
  insert into marks (image_id, reviewer, rating, color_tag, source)
  values (p_image, 'client', p_rating, nullif(p_color, ''), 'client')
  on conflict (image_id, reviewer)
  do update set rating = excluded.rating, color_tag = excluded.color_tag, source = 'client';
end $function$;
