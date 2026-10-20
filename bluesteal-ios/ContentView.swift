//
//  ContentView.swift
//  bluesteal-ios
//

import SwiftUI
import UIKit

/// Human-visible build tag shown in the top-left (reads the real bundle version,
/// bumped via MARKETING_VERSION), so you can glance at two devices and confirm
/// they're on the same build.
enum BuildInfo {
    static let tag = "v" + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?")
}

/// Current IPv4 of the active interface (Wi-Fi en0 preferred), shown under the
/// version so you can see which network the device is on. No permission needed.
func localIPv4() -> String {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "—" }
    defer { freeifaddrs(ifaddr) }
    var fallback: String?
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ptr.pointee.ifa_flags)
        guard let sa = ptr.pointee.ifa_addr,
              (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
              sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        let ip = String(cString: host)
        if String(cString: ptr.pointee.ifa_name) == "en0" { return ip }  // Wi-Fi wins
        if fallback == nil { fallback = ip }
    }
    return fallback ?? "—"
}

struct ContentView: View {
    @Environment(CableScanner.self) private var scanner
    @Environment(AdvertStore.self) private var store
    @Environment(TunnelTransport.self) private var tunnel
    @Environment(QRRelay.self) private var qrRelay

    @State private var showScanner = false
    @State private var showLogsSheet = false
    @State private var pendingURI: String?   // carried across the cover→sheet handoff
    @State private var scanned: QRItem?
    @State private var ipAddr: String = localIPv4()

    /// Send is only meaningful with a connected peer.
    private var canSend: Bool {
        if case .open = tunnel.state { return true } else { return false }
    }

    var body: some View {
        @Bindable var qr = qrRelay
        NavigationStack {
            VStack(spacing: 0) {
                ScannerStatusView(
                    state: scanner.state,
                    isScanning: scanner.isScanning,
                    totalDetections: store.totalDetections,
                    uniqueCount: store.adverts.count,
                    mode: Binding(get: { scanner.mode }, set: { scanner.mode = $0 }),
                    onClear: { store.clear() }
                )

                Divider()

                RelayView()

                Divider()

                if store.adverts.isEmpty {
                    ContentUnavailableView {
                        Label("Waiting for adverts", systemImage: "antenna.radiowaves.left.and.right")
                    } description: {
                        Text("Listening for service data under UUIDs 0xFFF9 (FIDO) and 0xFDE2 (Google).\nStart a hybrid sign-in flow on a nearby phone or laptop.")
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // iOS is host-only: it never receives adverts (`AdvertRelay`
                    // is outbound-only). So there's only a "Local" section — no
                    // "From peer" like Android's two-section layout.
                    List {
                        ForEach(store.adverts) { AdvertRowView(advert: $0) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Blue Steal")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                while !Task.isCancelled {
                    ipAddr = localIPv4()
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showLogsSheet = true } label: {
                        Image(systemName: "doc.text")
                    }
                    .accessibilityLabel("Share log files")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showScanner = true } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .accessibilityLabel("Scan QR code")
                }
            }
            .sheet(isPresented: $showLogsSheet) {
                LogsShareSheet()
            }
            .onAppear {
                scanner.onEvent = { event in
                    store.ingest(event)
                }
            }
        }
        // Build tag + local IP pinned to the literal top-left of the screen,
        // overlaid on the nav bar's (empty) leading edge — plain text, no pill.
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 1) {
                Text(BuildInfo.tag)
                Text(ipAddr)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.leading, 16)
            .padding(.top, 8)   // drop it to roughly vertically centre on the inline title
            .allowsHitTesting(false)
        }
        // Camera scanner (full screen). On a successful scan we stash the URI and
        // dismiss; the result sheet is presented from onDismiss to avoid a
        // cover→sheet presentation race.
        .fullScreenCover(isPresented: $showScanner, onDismiss: {
            if let uri = pendingURI {
                pendingURI = nil
                scanned = QRItem(uri: uri)
            }
        }) {
            ScannerScreen { uri in
                pendingURI = uri
                showScanner = false
            }
        }
        // Result of a scan: render + Copy / Send.
        .sheet(item: $scanned) { item in
            ScannedResultView(
                uri: item.uri,
                canSend: canSend,
                onCopy: { UIPasteboard.general.string = item.uri },
                onSend: { qrRelay.send(item.uri) }
            )
        }
        // A QR pushed by the peer: slide-up display modal.
        .sheet(item: $qr.received) { item in
            ReceivedQRView(uri: item.uri)
        }
    }
}

// MARK: - Logs share sheet

/// Wraps `UIActivityViewController` so the user can AirDrop / Files-export the
/// JSONL trace files for cross-platform diffing per PORTING_GUIDE §7. Lives
/// here (next to its toolbar trigger) rather than in RelayView so the relay row
/// stays parity-clean with the Android layout.
private struct LogsShareSheet: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let dir = RelayTracer.standardLogDirectory
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let items: [Any] = urls.isEmpty ? [dir] : urls
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

#Preview {
    let tracer = RelayTracer()
    let store = AdvertStore(logger: JSONLLogger())
    let advertRelay = AdvertRelay(store: store)
    let tunnel = TunnelTransport(tracer: tracer)
    return ContentView()
        .environment(CableScanner(previewMode: true))
        .environment(store)
        .environment(advertRelay)
        .environment(tunnel)
        .environment(QRRelay(tunnel: tunnel, tracer: tracer))
}
