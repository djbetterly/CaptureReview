-- 2026-11-03 Capture Review: apply renames / moves / deletes / restores from the session catalog
-- in ONE transaction. Called by the Mac app (secret key) only; clients can't call it.
--
-- p_moves: [{ "uid": catalog image id, "rel_path": "Set_01/A.CR3", "folder_path": "Set_01",
--             "filename": "A.CR3", "stem": "A", "deleted": false }]
-- Every variant row of that image follows. Rows keep their id, so client ratings (marks) stay.
-- Two phases (park everything, then place) so swaps like A→B + B→A never hit the unique index.
-- Deleted rows are hidden (deleted_at) and parked under '.deleted/<row id>/…' to free their name.
-- A restore whose name is now taken by another image stays hidden instead of failing the batch.

create or replace function public.app_apply_moves(p_gallery uuid, p_moves jsonb)
 returns integer
 language plpgsql security definer
 set search_path to 'public'
as $function$
declare
  m jsonb;
  n integer := 0;
  c integer;
  hide boolean;
begin
  -- Safety: one row per image + variant. If an upload raced a delete and made a second row,
  -- keep the newest and hide the others (never fails the batch).
  update images d set rel_path = '.duplicate/' || d.id::text, deleted_at = coalesce(d.deleted_at, now())
    from images k
   where d.gallery_id = p_gallery and k.gallery_id = p_gallery
     and d.image_uid is not null and d.image_uid = k.image_uid
     and d.variant_position = k.variant_position and d.id <> k.id
     and (d.updated_at, d.id::text) < (k.updated_at, k.id::text)
     and d.rel_path not like '.duplicate/%' and k.rel_path not like '.duplicate/%'
     and d.image_uid in (select mv->>'uid' from jsonb_array_elements(p_moves) mv);

  -- Phase 1: park every affected row under a unique temporary path
  update images i set rel_path = '.moving/' || i.id::text
    from jsonb_array_elements(p_moves) mv
   where i.gallery_id = p_gallery and i.image_uid = mv->>'uid' and i.rel_path not like '.duplicate/%';

  -- Phase 2: final place (or hidden)
  for m in select * from jsonb_array_elements(p_moves) loop
    hide := coalesce((m->>'deleted')::boolean, false)
            or exists (select 1 from images o
                        where o.gallery_id = p_gallery and o.rel_path = m->>'rel_path'
                          and o.image_uid is distinct from m->>'uid');
    update images set
      rel_path     = case when hide then '.deleted/' || id::text || '/' || (m->>'rel_path') else m->>'rel_path' end,
      folder_path  = coalesce(m->>'folder_path', folder_path),
      filename     = coalesce(m->>'filename', filename),
      display_name = case when variant_position > 1 then (m->>'stem') || ' (v' || variant_position || ')'
                          else m->>'stem' end,
      deleted_at   = case when hide then coalesce(deleted_at, now()) else null end
    where gallery_id = p_gallery and image_uid = m->>'uid' and rel_path like '.moving/%';
    get diagnostics c = row_count;
    n := n + c;
  end loop;
  return n;
end $function$;

revoke all on function public.app_apply_moves(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.app_apply_moves(uuid, jsonb) to service_role;
