# Supabase schema snapshot (project capture_review, read 2026-11-03)

Read-only dump of `public`: columns, constraints, indexes, RLS, triggers, functions, realtime.
RLS is ON for all three tables with NO policies: anon/clients get nothing directly; the web
gallery goes through the SECURITY DEFINER functions below (slug + access code), and the Mac app
uses the secret key (bypasses RLS).

## galleries
- id uuid PK default gen_random_uuid()
- name text not null
- session_name text null
- slug text not null UNIQUE default translate(encode(gen_random_bytes(9),'base64'),'+/','-_')
- created_at timestamptz not null default now()
- access_code text null default new_access_code()
- active boolean not null default true

## images
- id uuid PK default gen_random_uuid()
- gallery_id uuid not null -> galleries(id) ON DELETE CASCADE   (index images_gallery_id_idx)
- rel_path text not null
- folder_path text not null default ''
- filename text not null
- file_hash text null
- storage_path text null
- sort_index integer null
- created_at timestamptz not null default now()
- updated_at timestamptz not null default now()   (trigger images_touch BEFORE UPDATE -> touch_updated_at)
- source_stamp text null
- variant_id text null
- variant_position integer not null default 1
- display_name text null
- thumb_path text null
- quality text null
- proof_bytes integer null
- thumb_bytes integer null
- UNIQUE INDEX images_gallery_rel_position (gallery_id, rel_path, variant_position)  <- the app's upsert key

## marks
- id uuid PK default gen_random_uuid()
- image_id uuid not null -> images(id) ON DELETE CASCADE   (index marks_image_id_idx)
- reviewer text not null default 'client'
- rating smallint null  CHECK 0..5
- color_tag text null   CHECK in (red, orange, yellow, green, blue, pink, purple)
- updated_at timestamptz not null default now()   (trigger marks_touch)
- source text not null default 'client'  CHECK in (client, studio)
- UNIQUE (image_id, reviewer)

## Functions (all SECURITY DEFINER, search_path public)
- gallery_for(p_slug, p_code) -> uuid: active gallery whose access code matches (dashes/spaces/case ignored)
- gallery_open(p_slug, p_code) -> json {name, now}; sleeps 0.5 s on a wrong code
- gallery_images(p_slug, p_code, p_ids uuid[] = null, p_offset = 0, p_limit = 1000) -> setof json
  (image fields + client rating/color_tag), ordered by rel_path, variant_position
- gallery_changes(p_slug, p_code, p_since) -> json {now, images: [ids updated since], marks: [client marks updated since]}
- gallery_set_mark(p_slug, p_code, p_image, p_rating, p_color): upsert the client's mark
- new_access_code() -> 'K7QM-4TXP' style code
- touch_updated_at() trigger

## Realtime
- supabase_realtime publishes public.images and public.marks
