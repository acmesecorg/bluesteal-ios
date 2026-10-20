//
//  bluesteal_iosApp.swift
//  bluesteal-ios
//

import SwiftUI

@main
struct bluesteal_iosApp: App {
    @State private var scanner: CableScanner
    @State private var store: AdvertStore
    @State private var advertRelay: AdvertRelay
    @State private var tunnel: TunnelTransport
    @State private var tracer: RelayTracer
    @State private var qrRelay: QRRelay

    init() {
        let tracer = RelayTracer()
        tracer.log("app", "app.start", [
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "bundleVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "logFile": tracer.logFileURL.path
        ])

        let scanner = CableScanner()
        let store = AdvertStore(logger: JSONLLogger())
        let advertRelay = AdvertRelay(store: store)
        // caBLE tunnel transport — the only transport. iOS hosts only.
        let tunnel = TunnelTransport(tracer: tracer)
        // Inbound frames carry the peer's shared QR codes (and, on dual-role
        // platforms, adverts — ignored here). Route them to the QR relay.
        let qrRelay = QRRelay(tunnel: tunnel, tracer: tracer)
        tunnel.onFrame = { [weak qrRelay] bytes in qrRelay?.handleFrame(bytes) }

        _scanner = State(initialValue: scanner)
        _store = State(initialValue: store)
        _advertRelay = State(initialValue: advertRelay)
        _tunnel = State(initialValue: tunnel)
        _tracer = State(initialValue: tracer)
        _qrRelay = State(initialValue: qrRelay)

        // Test affordance: `-host` launch arg auto-hosts without the custom-URL
        // confirmation prompt (which blocks headless `simctl openurl`). The
        // bluesteal:// URL scheme below is the production auto-drive.
        let args = CommandLine.arguments
        if args.contains("-host") {
            tracer.log("app", "app.autohost", nil)
            Self.beginHost(tunnel: tunnel, advertRelay: advertRelay)
        }
        // Test affordance: `-sendqr <uri>` hosts and, once a peer connects,
        // sends the URI as a QR — for headless verification of the share path.
        if let i = args.firstIndex(of: "-sendqr"), i + 1 < args.count {
            let uri = args[i + 1]
            tracer.log("app", "app.autosendqr", ["len": uri.count])
            Self.beginHost(tunnel: tunnel, advertRelay: advertRelay)
            Task { @MainActor [weak tunnel, weak qrRelay] in
                for _ in 0..<120 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let tunnel, case .open = tunnel.state else { continue }
                    qrRelay?.send(uri)
                    return
                }
            }
        }
    }

    /// Wires outbound adverts through the tunnel and starts hosting. Shared by
    /// the `bluesteal://host` URL handler and the `-host` launch arg.
    private static func beginHost(tunnel: TunnelTransport, advertRelay: AdvertRelay) {
        advertRelay.tunnelSend = { data in
            Task { await tunnel.send([UInt8](data)) }
        }
        let code = PairingCode.make()
        Task { try? await tunnel.host(code: code) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(scanner)
                .environment(store)
                .environment(advertRelay)
                .environment(tunnel)
                .environment(qrRelay)
                .onOpenURL { handle(url: $0) }
        }
    }

    /// Auto-drives flows from a `bluesteal://` URL. `host` starts hosting (the
    /// production auto-drive). `sendqr` / `showqr` are test-only affordances for
    /// driving the QR send/display path headlessly (e.g. `xcrun simctl openurl`).
    private func handle(url: URL) {
        guard url.scheme?.lowercased() == "bluesteal" else { return }
        switch url.host?.lowercased() {
        case "config":
            // Supplies the rendezvous drop at runtime so no URL/bearer is ever
            // compiled in or committed: bluesteal://config?rv=<baseURL>&room=<room>&k=<bearer>
            let d = UserDefaults.standard
            if let rv = Self.queryValue(url, "rv") { d.set(rv, forKey: "rv.baseURL") }
            if let room = Self.queryValue(url, "room") { d.set(room, forKey: "rv.room") }
            if let k = Self.queryValue(url, "k") { d.set(k, forKey: "rv.key") }
            // Log presence only — never the base URL or bearer value.
            tracer.log("app", "app.openurl.config", [
                "hasRv": Self.queryValue(url, "rv") != nil,
                "hasRoom": Self.queryValue(url, "room") != nil,
                "hasKey": Self.queryValue(url, "k") != nil
            ])
        case "host":
            tracer.log("app", "app.openurl.host", ["url": url.absoluteString])
            Self.beginHost(tunnel: tunnel, advertRelay: advertRelay)
        case "sendqr":
            if let uri = Self.queryValue(url, "uri") {
                tracer.log("app", "app.openurl.sendqr", ["len": uri.count])
                qrRelay.send(uri)
            }
        case "showqr":
            if let uri = Self.queryValue(url, "uri") {
                tracer.log("app", "app.openurl.showqr", ["len": uri.count])
                qrRelay.received = QRItem(uri: uri)
            }
        default:
            tracer.log("app", "app.openurl.unsupported", ["url": url.absoluteString])
        }
    }

    private static func queryValue(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }
}
