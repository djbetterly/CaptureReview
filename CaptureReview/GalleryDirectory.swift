// GalleryDirectory.swift – Capture Review
// One gallery per Capture One session, so different jobs never share a gallery.
// Galleries are keyed on the session catalog's permanent id (galleries.session_uid), never on the
// session name: names get reused job to job, and a renamed or moved session keeps its gallery.

import Foundation
import Supabase

nonisolated struct GalleryRef: Sendable {
    let id: UUID
    let name: String
    let created: Bool          // made just now (false = existing gallery loaded)
}

nonisolated enum GalleryDirectory {
    private struct Row: Decodable, Sendable { let id: UUID; let name: String }
    private struct NewGallery: Encodable, Sendable {
        let name: String
        let session_name: String
        let session_uid: String
    }

    /// The gallery for this session, created (named after the session folder) if there isn't one.
    static func resolve(supabaseURL: URL, serviceKey: String, sessionUID: String, sessionName: String) async throws -> GalleryRef {
        let client = SupabaseClient(supabaseURL: supabaseURL, supabaseKey: serviceKey,
                                    options: SupabaseClientOptions(auth: .init(emitLocalSessionAsInitialSession: true)))
        let found: [Row] = try await client.from("galleries")
            .select("id, name")
            .eq("session_uid", value: sessionUID)
            .order("created_at")
            .limit(1)
            .execute().value
        if let g = found.first { return GalleryRef(id: g.id, name: g.name, created: false) }

        let made: Row = try await client.from("galleries")
            .insert(NewGallery(name: sessionName, session_name: sessionName, session_uid: sessionUID))
            .select("id, name")
            .single()
            .execute().value
        return GalleryRef(id: made.id, name: made.name, created: true)
    }

    /// Whether the gallery still exists on the server (it can be deleted from the admin page).
    /// nil = couldn't tell (offline): keep using the remembered gallery.
    static func exists(id: UUID, supabaseURL: URL, serviceKey: String) async -> Bool? {
        let client = SupabaseClient(supabaseURL: supabaseURL, supabaseKey: serviceKey,
                                    options: SupabaseClientOptions(auth: .init(emitLocalSessionAsInitialSession: true)))
        do {
            let rows: [Row] = try await client.from("galleries").select("id, name")
                .eq("id", value: id.uuidString).limit(1).execute().value
            return !rows.isEmpty
        } catch { return nil }
    }
}
