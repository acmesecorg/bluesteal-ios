//
//  bluesteal_iosApp.swift
//  bluesteal-ios
//

import SwiftUI

@main
struct bluesteal_iosApp: App {
    @State private var scanner: CableScanner
    @State private var store: AdvertStore
    @State private var relay: RelayClient
    @State private var advertRelay: AdvertRelay
    @State private var tunnel: TunnelTransport

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
        let relay = RelayClient(tracer: tracer)
        let advertRelay = AdvertRelay(store: store, relay: relay)
        // caBLE tunnel transport (parallel to WebRTC). iOS hosts only; inbound
        // adverts are not consumed so onFrame is left unset.
        let tunnel = TunnelTransport(tracer: tracer)
        _scanner = State(initialValue: scanner)
        _store = State(initialValue: store)
        _relay = State(initialValue: relay)
        _advertRelay = State(initialValue: advertRelay)
        _tunnel = State(initialValue: tunnel)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(scanner)
                .environment(store)
                .environment(relay)
                .environment(advertRelay)
                .environment(tunnel)
        }
    }
}
