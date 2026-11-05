-- 2026-11-04 Capture Review: delete a gallery from the admin page
-- The page first removes the gallery's files from Storage (it lists them with
-- admin_gallery_files and deletes them through the Storage API, so the files really go),
-- then calls admin_delete_gallery, which removes the gallery row. Images, client ratings,
-- folder visibility and shot counts go with it (all ON DELETE CASCADE).

-- Every file the gallery has in the proofs bucket, including old versions and leftovers
create or replace function public.admin_gallery_files(p_gallery uuid)
 returns setof text
 language plpgsql stable security definer
 set search_path to 'public', 'storage'
as $function$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return query
    select o.name from storage.objects o
    where o.bucket_id = 'proofs' and o.name like p_gallery::text || '/%';
end $function$;
revoke all on function public.admin_gallery_files(uuid) from public, anon;
grant execute on function public.admin_gallery_files(uuid) to authenticated;

create or replace function public.admin_delete_gallery(p_gallery uuid)
 returns json
 language plpgsql security definer
 set search_path to 'public', 'storage'
as $function$
declare n_images int; n_files int; gname text;
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  select name into gname from galleries where id = p_gallery;
  if gname is null then raise exception 'gallery not found'; end if;
  select count(*) into n_images from images where gallery_id = p_gallery;
  select count(*) into n_files from storage.objects
    where bucket_id = 'proofs' and name like p_gallery::text || '/%';
  delete from galleries where id = p_gallery;              -- cascades to images, marks, folders
  return json_build_object('name', gname, 'images', n_images, 'files_left', n_files);
end $function$;
revoke all on function public.admin_delete_gallery(uuid) from public, anon;
grant execute on function public.admin_delete_gallery(uuid) to authenticated;

-- Admins may remove files from the proofs bucket (Storage checks these when the page deletes)
drop policy if exists capture_review_admin_select on storage.objects;
create policy capture_review_admin_select on storage.objects for select to authenticated
  using (bucket_id = 'proofs' and public.is_admin());
drop policy if exists capture_review_admin_delete on storage.objects;
create policy capture_review_admin_delete on storage.objects for delete to authenticated
  using (bucket_id = 'proofs' and public.is_admin());
