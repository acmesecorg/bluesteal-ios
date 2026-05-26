//
//  AdvertRelay.swift
//  bluesteal-ios
//
//  Bridges the local AdvertStore with a host-only RelayClient. iOS only
//  hosts: every scanned advert is forwarded to the paired peer, and the
//  4-second heartbeat keep-alive runs for the lifetime of `.open`.
//
//  Inbound `.advert` messages are not expected (the peer never sends them
//  in this direction), so the inbound side is limited to heartbeat
//  bookkeeping. Anything unexpected is logged + dropped in `RelayClient`.
//

import Foundation
import Observation

@MainActor
@Observable
final class AdvertRelay {
    /// Last heartbeat timestamp received from the paired peer. Surfaced for
    /// the inbound-silence watchdog when §10 Fix 3 lands; today it's
    /// observation-only.
    private(set) var lastPeerHeartbeat: Date?

    private let store: AdvertStore
    private let relay: RelayClient

    private var heartbeatTask: Task<Void, Never>?

    /// When set (tunnel mode), outbound adverts are serialised to JSON and sent
    /// through this closure instead of the WebRTC data channel. Mirrors Windows
    /// `AdvertRelay.TunnelSend`.
    var tunnelSend: ((Data) -> Void)?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()

    init(store: AdvertStore, relay: RelayClient) {
        self.store = store
        self.relay = relay
        wireUp()
    }

    private func wireUp() {
        // Outbound: anything our scanner sees, forward to the paired peer —
        // through the tunnel transport when active, otherwise the WebRTC channel.
        store.onIngest = { [weak self] advert in
            guard let self else { return }
            let msg = RelayMessage.advert(.init(from: advert))
            if let tunnelSend = self.tunnelSend {
                if let data = try? self.encoder.encode(msg) { tunnelSend(data) }
            } else {
                self.relay.send(msg)
            }
        }
        // Inbound: only heartbeats and bye are meaningful for a host-only
        // app. RelayClient already short-circuits `.bye`, and `.advert` from
        // the peer is logged + dropped at the RelayClient layer, so this
        // callback effectively only sees heartbeats.
        relay.onMessage = { [weak self] message in
            self?.handleInbound(message)
        }
        // Heartbeats keep the host's outbound NAT mapping fresh for the
        // duration of `.open`. See docs §10 Fix 1.
        relay.onStateChange = { [weak self] newState in
            guard let self else { return }
            if case .open = newState {
                self.startHeartbeats()
            } else {
                self.stopHeartbeats()
            }
        }
    }

    func startHeartbeats() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self else { return }
                if case .open = self.relay.state {
                    let ids = self.store.adverts.map(\.id)
                    self.relay.send(.heartbeat(.init(ts: Date(), knownIds: ids)))
                }
            }
        }
    }

    func stopHeartbeats() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func handleInbound(_ message: RelayMessage) {
        switch message {
        case .heartbeat(let h):
            lastPeerHeartbeat = h.ts
        case .advert, .bye:
            // .advert is handled (dropped) in RelayClient; .bye triggers
            // disconnect there. Nothing for AdvertRelay to do.
            break
        case .handoffOffer, .handoffAck:
            // Tunnel-transport control frames; handled inside TunnelTransport,
            // never surfaced on the WebRTC onMessage path.
            break
        }
    }
}
