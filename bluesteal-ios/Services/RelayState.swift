//
//  RelayState.swift
//  bluesteal-ios
//
//  Session state for the relay transport. Extracted from the former
//  `RelayClient` (the WebRTC/MQTT path) when that transport was removed — the
//  caBLE tunnel is now the only transport, but it keeps the same lifecycle
//  vocabulary. Host-only on iOS (no `.joining`, no role), mirroring the shape
//  the host-only RelayClient used.
//

import Foundation

/// Lifecycle state of a relay/tunnel session (host-only on iOS).
enum RelayState: Equatable {
    case idle
    case hosting(code: String)
    case negotiating
    case open
    case closed(reason: String)

    var isClosed: Bool { if case .closed = self { return true } else { return false } }
}
