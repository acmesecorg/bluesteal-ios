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
        // caBLE tunnel transport — the only transport. iOS hosts only; inbound
        // adverts are not consumed so onFrame is left unset.
        let tunnel = TunnelTransport(tracer: tracer)
        _scanner = State(initialValue: scanner)
        _store = State(initialValue: store)
        _advertRelay = State(initialValue: advertRelay)
        _tunnel = State(initialValue: tunnel)
        _tracer = State(initialValue: tracer)

        // Test affordance: `-host` launch arg auto-hosts without the custom-URL
        // confirmation prompt (which blocks headless `simctl openurl`). The
        // bluesteal:// URL scheme below is the production auto-drive.
        if CommandLine.arguments.contains("-host") {
            tracer.log("app", "app.autohost", nil)
            Self.beginHost(tunnel: tunnel, advertRelay: advertRelay)
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
                .onOpenURL { handle(url: $0) }
        }
    }

    /// Auto-drives the Host flow from a `bluesteal://host` URL so the app can be
    /// launched pre-configured for testing (e.g. `xcrun simctl openurl`). The
    /// hosted token surfaces in the UI and is logged via the tracer
    /// (`token.ready`). iOS is host-only, so `join` is not supported.
    private func handle(url: URL) {
        guard url.scheme?.lowercased() == "bluesteal" else { return }
        switch url.host?.lowercased() {
        case "host":
            tracer.log("app", "app.openurl.host", ["url": url.absoluteString])
            Self.beginHost(tunnel: tunnel, advertRelay: advertRelay)
        default:
            tracer.log("app", "app.openurl.unsupported", ["url": url.absoluteString])
        }
    }
}
