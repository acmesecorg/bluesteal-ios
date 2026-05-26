//
//  TunnelTransport.swift
//  bluesteal-ios
//
//  caBLE tunnel side-channel transport with make-before-break handoff.
//  Swift port of Windows Services/Tunnel/TunnelTransport.cs.
//
//  Host-only on iOS: this device generates the OOB token and a macOS/Windows
//  peer joins. The peer-side join/offer-handling paths from the cross-platform
//  reference are omitted because iOS cannot re-broadcast adverts (mirrors the
//  host-only shaping of RelayClient).
//
//  Every 30 s the next hop is opened in parallel and promotion is negotiated
//  with the peer so the session survives the relay's ~60 s socket cap.
//  Promotion is *never* time-triggered — it requires an ack; the abort timer
//  only tears down a stuck pending hop.
//
//  Runs on the main actor; socket/Noise awaits suspend without blocking it.
//  Crypter state is touched only from this actor, so it stays single-threaded.
//

import Foundation
import Observation

@MainActor
@Observable
final class TunnelTransport {

    enum HopState { case steady, pendingAck }

    final class Hop {
        let session: TunnelNoiseSession
        let routingId: [UInt8]
        var readTask: Task<Void, Never>?
        init(session: TunnelNoiseSession, routingId: [UInt8]) {
            self.session = session
            self.routingId = routingId
        }
        func close() { readTask?.cancel(); session.close() }
    }

    // Timing (seconds)
    private static let handoffInterval: UInt64 = 30
    private static let hostAckTimeout: UInt64 = 50
    private static let oldHopLinger: UInt64 = 15

    // Observable surface (RelayView reads these directly)
    private(set) var state: RelayClient.State = .idle {
        didSet { if state != oldValue { tracer.log("tunnel", "state.change",
            ["transport": "cable-tunnel", "to": Self.label(state)]) } }
    }
    private(set) var token: String?
    private(set) var hopNumber = 0
    private(set) var messagesSent = 0
    private(set) var messagesReceived = 0
    private(set) var heartbeatCount = 0

    /// Decrypted advert/unknown frames (raw JSON bytes). iOS is host-only and
    /// does not consume inbound adverts, so this is normally left unset.
    var onFrame: (@MainActor ([UInt8]) -> Void)?

    private let tracer: RelayTracer

    private var code = ""
    private var keys: TunnelKeys?
    private var host = "cable.ua5v.com"
    private var userInitiated = false
    private var peerSaidBye = false
    private var disposed = false

    private var currentHop: Hop?
    private var pendingHop: Hop?
    private var hopState: HopState = .steady
    private var pendingRoutingId: String?

    private var heartbeatTask: Task<Void, Never>?
    private var handoffTask: Task<Void, Never>?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    init(tracer: RelayTracer) { self.tracer = tracer }

    // MARK: - Public API

    @discardableResult
    func host(code: String) async throws -> String {
        self.code = code
        let keys = TunnelKeyDerivation.derive(code: code)
        self.keys = keys
        host = TunnelServerDomain.get(keys.tunnelServerId) ?? "cable.ua5v.com"
        tracer.setContext(role: "Host", code: code)
        state = .hosting(code: code)

        let minute = TunnelKeyDerivation.currentUtcMinute()
        let tunnelId = TunnelKeyDerivation.deriveTunnelId(code: code, minute: minute)
        tracer.log("tunnel", "host.minute", ["minute": minute, "tunnelId": Data(tunnelId).hexUpper])

        do {
            let socket = try await TunnelHostSocket.connect(host: host, tunnelId: tunnelId, tracer: tracer)
            let tok = TunnelKeyDerivation.formatToken(code: code, routingId: socket.routingId)
            tracer.log("tunnel", "token.ready", ["token": tok])
            token = tok

            // Stay in .hosting (token on screen, copyable) while waiting for a
            // peer; the handshake only proceeds once the peer connects and sends
            // its initiator message, at which point we go straight to .open.
            let session = try await TunnelNoiseSession.handshakeAsHost(socket: socket, keys: keys, tracer: tracer)

            let hop = Hop(session: session, routingId: socket.routingId)
            currentHop = hop
            state = .open
            startReadLoop(hop)
            startHeartbeat()
            startHandoffTimer()
            return tok
        } catch {
            tracer.log("tunnel", "host.failed", ["error": "\(error)"])
            if !state.isClosed { state = .closed(reason: "host: \(error)") }
            throw error
        }
    }

    func send(_ data: [UInt8]) async {
        guard !disposed, let hop = currentHop else { return }
        do {
            try await hop.session.send(data)
            messagesSent += 1
        } catch {
            tracer.log("tunnel", "send_failed", ["error": "\(error)"])
        }
    }

    func disconnect() {
        guard !disposed else { return }
        userInitiated = true
        Task { [weak self] in
            guard let self else { return }
            if case .open = self.state, let hop = self.currentHop {
                try? await self.sendControl(hop, .bye(reason: "user_disconnect"))
                self.tracer.log("tunnel", "bye.sent", ["reason": "user_disconnect"])
            }
            self.dispose()
        }
    }

    // MARK: - Read loop

    private func startReadLoop(_ hop: Hop) {
        hop.readTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let frame = try await hop.session.receive()
                    if Task.isCancelled { break }
                    self.handleFrame(frame, hop: hop)
                }
            } catch {
                self.handleReadExit(hop, error: error)
            }
        }
    }

    private func handleReadExit(_ hop: Hop, error: Error) {
        guard !disposed else { return }
        tracer.log("tunnel", "read_loop_exit", ["error": "\(error)", "hopWasPending": hop === pendingHop])
        if hop === pendingHop {
            abortPending(reason: "pending_read_error")
        } else if hop === currentHop, hopState == .steady, !state.isClosed {
            state = .closed(reason: peerSaidBye ? "peer" : "tunnel closed")
        }
    }

    private func handleFrame(_ frame: [UInt8], hop: Hop) {
        guard let message = try? decoder.decode(RelayMessage.self, from: Data(frame)) else {
            onFrame?(frame)
            return
        }

        switch message {
        case .heartbeat:
            heartbeatCount += 1
        case .advert:
            messagesReceived += 1
            onFrame?(frame)
        case .bye(let reason):
            tracer.log("tunnel", "bye.received", ["reason": reason])
            if reason == "hop" { break }      // expected end of an old hop
            peerSaidBye = true
            state = .closed(reason: "peer: \(reason)")
        case .handoffAck(let ack):
            tracer.log("tunnel", "hop.ack_received",
                       ["nextRoutingId": ack.nextRoutingId, "connected": ack.connected])
            handleAckAsHost(ack)
        case .handoffOffer:
            // Host never receives offers; ignore.
            break
        }
    }

    // MARK: - Host-side handoff

    private func startHandoffTimer() {
        handoffTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.handoffInterval * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard case .open = self.state else { break }
                guard self.hopState == .steady else { continue }
                await self.initiateHandoff()
            }
        }
    }

    private func initiateHandoff() async {
        tracer.log("tunnel", "hop.begin", nil)
        guard let keys else { return }
        do {
            let minute = TunnelKeyDerivation.currentUtcMinute()
            let tunnelId = TunnelKeyDerivation.deriveTunnelId(code: code, minute: minute)
            let socket = try await TunnelHostSocket.connect(host: host, tunnelId: tunnelId, tracer: tracer)
            let nextRoutingHex = Data(socket.routingId).hexUpper
            pendingRoutingId = nextRoutingHex

            // Offer goes out over the current hop BEFORE the handshake — the peer
            // needs the routing_id to connect and send its initiator message.
            try await sendControl(currentHop!, .handoffOffer(.init(
                nextRoutingId: nextRoutingHex, nextMinute: minute, validFrom: Date())))
            tracer.log("tunnel", "hop.offer_sent", ["nextRoutingId": nextRoutingHex, "minute": minute])

            let session = try await TunnelNoiseSession.handshakeAsHost(socket: socket, keys: keys, tracer: tracer)
            pendingHop = Hop(session: session, routingId: socket.routingId)  // host reads it only after promotion
            hopState = .pendingAck

            startAckTimeout(nextRoutingHex)
        } catch {
            tracer.log("tunnel", "hop.begin_failed", ["error": "\(error)"])
            abortPending(reason: "begin_failed")
        }
    }

    private func startAckTimeout(_ correlationId: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: (Self.hostAckTimeout - Self.handoffInterval) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.hopState == .pendingAck, self.pendingRoutingId == correlationId {
                self.tracer.log("tunnel", "hop.abort", ["reason": "ack_timeout", "nextRoutingId": correlationId])
                self.abortPending(reason: "ack_timeout")
            }
        }
    }

    private func handleAckAsHost(_ ack: RelayMessage.HandoffAck) {
        guard hopState == .pendingAck, ack.nextRoutingId == pendingRoutingId else { return }
        if ack.connected {
            tracer.log("tunnel", "hop.promote", ["role": "host", "nextRoutingId": ack.nextRoutingId])
            promoteHop()
        } else {
            tracer.log("tunnel", "hop.abort", ["reason": "peer_nack", "nextRoutingId": ack.nextRoutingId])
            abortPending(reason: "peer_nack")
        }
    }

    // MARK: - Promotion / abort

    private func promoteHop() {
        let old = currentHop
        currentHop = pendingHop
        pendingHop = nil
        hopState = .steady
        pendingRoutingId = nil
        hopNumber += 1

        let rid = currentHop.map { Data($0.routingId).hexUpper } ?? "?"
        tracer.log("tunnel", "hop.promote", ["newRoutingId": rid, "hopCount": hopNumber])

        // The host's promoted hop had no read loop yet — start it now.
        if let cur = currentHop, cur.readTask == nil { startReadLoop(cur) }

        if let old { scheduleCloseOldHop(old) }
    }

    private func abortPending(reason: String) {
        pendingHop?.close()
        pendingHop = nil
        hopState = .steady
        pendingRoutingId = nil
        _ = reason
    }

    private func scheduleCloseOldHop(_ old: Hop) {
        old.readTask?.cancel()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.oldHopLinger * 1_000_000_000)
            guard let self else { old.close(); return }
            try? await self.sendControl(old, .bye(reason: "hop"))
            self.tracer.log("tunnel", "hop.old_closed", nil)
            old.close()
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard case .open = self.state, let hop = self.currentHop else { continue }
                do {
                    try await self.sendControl(hop, .heartbeat(.init(ts: Date(), knownIds: [])))
                    self.tracer.log("tunnel", "heartbeat.sent", nil)
                } catch {
                    self.tracer.log("tunnel", "heartbeat.send_failed", ["error": "\(error)"])
                    return
                }
            }
        }
    }

    // MARK: - Helpers

    private func sendControl(_ hop: Hop, _ message: RelayMessage) async throws {
        let data = try encoder.encode(message)
        try await hop.session.send([UInt8](data))
    }

    private func dispose() {
        guard !disposed else { return }
        disposed = true
        heartbeatTask?.cancel()
        handoffTask?.cancel()
        currentHop?.close()
        pendingHop?.close()
        currentHop = nil
        pendingHop = nil
        if !state.isClosed {
            state = .closed(reason: userInitiated ? "user" : (peerSaidBye ? "peer" : "closed"))
        }
    }

    private static func label(_ s: RelayClient.State) -> String {
        switch s {
        case .idle:           return "idle"
        case .hosting:        return "hosting"
        case .negotiating:    return "negotiating"
        case .open:           return "open"
        case .closed(let r):  return "closed(\(r))"
        }
    }
}

extension RelayClient.State {
    var isClosed: Bool { if case .closed = self { return true } else { return false } }
}
