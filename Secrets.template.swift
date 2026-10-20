//
//  Secrets.template.swift  —  committed template.
//
//  Copy this to `bluesteal-ios/Secrets.swift` (which is gitignored) and fill in
//  your values before building. Never put real values in THIS file — the repo
//  is public. Leaving the fields blank disables the baked-in rendezvous config
//  (the app then falls back to the `bluesteal://config` URL override).
//
//  (Lives at the repo root, outside the synchronized source folder, so it is
//  not itself compiled — only the copy you place in Secrets.swift is.)
//

enum Secrets {
    static let rendezvousBaseURL = ""   // e.g. "https://<your-worker>.workers.dev"
    static let rendezvousRoom = ""      // e.g. "DEMO1"
    static let rendezvousKey = ""       // the Worker's RENDEZVOUS_KEY bearer
}
