//
//  QRRelay.swift
//  bluesteal-ios
//
//  Scan-and-share: relays a scanned `FIDO:/` QR string to the paired peer over
//  the caBLE tunnel (outbound), and surfaces a QR received from the peer for
//  display in a modal (inbound). Convenience feature — it carries the QR string
//  only; it does not parse or act on the FIDO payload.
//

import Foundation
import Observation

/// An identifiable wrapper around a `FIDO:/` URI, for driving `.sheet(item:)`.
struct QRItem: Identifiable, Equatable {
    let id = UUID()
    let uri: String
}

@MainActor
@Observable
final class QRRelay {
    /// A QR received from the peer to display (drives the receive modal).
    var received: QRItem?

    private let tunnel: TunnelTransport
    private let tracer: RelayTracer

    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    init(tunnel: TunnelTransport, tracer: RelayTracer) {
        self.tunnel = tunnel
        self.tracer = tracer
    }

    /// Encode a scanned `FIDO:/` URI as a `RelayMessage.qr` and send it to the
    /// peer over the tunnel.
    func send(_ uri: String) {
        let msg = RelayMessage.qr(.init(uri: uri))
        guard let data = try? encoder.encode(msg) else { return }
        tracer.log("qr", "qr.send", ["len": uri.count])
        Task { await tunnel.send([UInt8](data)) }
    }

    /// Inbound tunnel frame handler. Decodes the frame and, when it is a QR
    /// message, surfaces the URI for display. Other frame types (adverts, which
    /// iOS as a host doesn't consume) are ignored.
    func handleFrame(_ bytes: [UInt8]) {
        guard let msg = try? decoder.decode(RelayMessage.self, from: Data(bytes)) else { return }
        if case .qr(let q) = msg {
            tracer.log("qr", "qr.recv", ["len": q.uri.count])
            received = QRItem(uri: q.uri)
        }
    }
}
