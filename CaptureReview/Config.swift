// Config.swift – Capture Review
// No secrets in here any more: the Supabase SECRET key lives in the Mac's Keychain
// (the app asks for it once per Mac). Safe to keep in git.

import Foundation

enum Config {
    // Supabase: Project Settings > API
    static let supabaseURL = URL(string: "https://mjaqginkbjgzcgxgzfma.supabase.co")!

    // Galleries: one per Capture One session, created automatically and keyed on the session
    // catalog's id (see GalleryDirectory.swift). The old shared test gallery was
    // a25bf490-d166-4e1e-88a5-6bf64719d2b3; it is no longer published to.

    // The hosted client gallery. Links become <galleryPage>?g=<gallery link>
    static let galleryPage = "https://review.dbcapture.com/"
}
