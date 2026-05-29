//
//  AdvertRelay.swift
//  bluesteal-ios
//
//  Bridges the local AdvertStore with the paired peer over the caBLE tunnel.
//  iOS only hosts: every scanned advert is serialised and forwarded to the
//  peer through `tunnelSend`. There is no inbound path here — iOS is the advert
//  source, and the tunnel runs its own heartbeat keep-alive.
//

import Foundation
import Observation

@MainActor
@Observable
final class AdvertRelay {
    private let store: AdvertStore

    /// Outbound adverts are serialised to JSON and sent through this closure
    /// (the caBLE tunnel transport). Set by the view once the tunnel is
    /// connected; nil means not connected, so adverts are not forwarded.
    /// Mirrors Windows `AdvertRelay.TunnelSend`.
    var tunnelSend: ((Data) -> Void)?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()

    init(store: AdvertStore) {
        self.store = store
        wireUp()
    }

    private func wireUp() {
        // Outbound: anything our scanner sees, forward to the paired peer over
        // the tunnel. When the tunnel isn't connected, `tunnelSend` is nil and
        // adverts are simply not forwarded.
        store.onIngest = { [weak self] advert in
            guard let self, let tunnelSend = self.tunnelSend else { return }
            let msg = RelayMessage.advert(.init(from: advert))
            if let data = try? self.encoder.encode(msg) { tunnelSend(data) }
        }
    }
}
