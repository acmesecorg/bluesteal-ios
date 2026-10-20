//
//  RendezvousClient.swift
//  bluesteal-ios
//
//  Out-of-band pairing-token drop for the "two people in different rooms"
//  demo. The persistent host PUTs its current CODE-ROUTING token under a shared
//  room; the peer GETs it. See bluesteal/tools/rendezvous (the Cloudflare
//  Worker) and specs/PAIRING_TOKEN.md.
//
//  SECRET HYGIENE: the base URL, room, and optional bearer are supplied at
//  runtime (via the `bluesteal://config` URL), stored in UserDefaults, and
//  NEVER compiled into the app or committed. This client never logs the token
//  or the bearer — only the room and HTTP status.
//

import Foundation

struct RendezvousConfig {
    let baseURL: URL
    let room: String
    let bearer: String?

    /// Reads config written by the `bluesteal://config` handler. Returns nil
    /// (rendezvous disabled) when no base URL / room has been configured.
    static func fromDefaults(_ defaults: UserDefaults = .standard) -> RendezvousConfig? {
        guard let urlString = defaults.string(forKey: "rv.baseURL"),
              let url = URL(string: urlString),
              let room = defaults.string(forKey: "rv.room"),
              !room.isEmpty else { return nil }
        let key = defaults.string(forKey: "rv.key")
        return RendezvousConfig(baseURL: url, room: room,
                                bearer: (key?.isEmpty == false) ? key : nil)
    }
}

final class RendezvousClient: @unchecked Sendable {
    private let config: RendezvousConfig
    private let tracer: RelayTracer

    init(config: RendezvousConfig, tracer: RelayTracer) {
        self.config = config
        self.tracer = tracer
    }

    private var endpoint: URL {
        config.baseURL.appendingPathComponent("r").appendingPathComponent(config.room)
    }

    /// Best-effort publish of the current pairing token. Failures are logged
    /// and swallowed — the host keeps serving regardless.
    func publish(token: String) async {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "PUT"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer = config.bearer {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            // Deliberately logs room + status only — never the token or bearer.
            tracer.log("rendezvous", "publish", ["room": config.room, "status": status])
        } catch {
            tracer.log("rendezvous", "publish.failed",
                       ["room": config.room, "error": "\(error)"])
        }
    }
}
