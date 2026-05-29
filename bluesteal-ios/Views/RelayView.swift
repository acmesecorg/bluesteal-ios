//
//  RelayView.swift
//  bluesteal-ios
//
//  Host-only relay control bar. iOS cannot re-broadcast peer adverts so
//  joining an existing session makes no sense — only the Host flow remains.
//  The caBLE tunnel is the only transport; the copyable value is the OOB token
//  (code-routing) the peer pastes.
//

import SwiftUI

struct RelayView: View {
    @Environment(AdvertRelay.self) private var advertRelay
    @Environment(TunnelTransport.self) private var tunnel

    @State private var showLogsSheet: Bool = false

    private var state: RelayState { tunnel.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                statusBadge
                Spacer()
                logsButton
            }

            controls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .sheet(isPresented: $showLogsSheet) {
            LogsShareSheet()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var controls: some View {
        switch state {
        case .idle, .closed:
            idleControls
        case .hosting(let code):
            hostingControls(code: code)
        case .negotiating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(stateLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { cancelOrDisconnect() }
                    .buttonStyle(.borderless)
            }
        case .open:
            openControls
        }
    }

    private var idleControls: some View {
        HStack(spacing: 8) {
            Button("Host", action: startTunnelHost)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Spacer()
        }
    }

    private func hostingControls(code: String) -> some View {
        let displayValue = tunnel.token ?? "waiting…"
        let ready = tunnel.token != nil
        return HStack(spacing: 10) {
            Text("Token")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(displayValue)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Button {
                UIPasteboard.general.string = displayValue
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!ready)
            .accessibilityLabel("Copy token")
            Spacer()
            Button("Cancel", role: .destructive) { cancelOrDisconnect() }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
    }

    private var openControls: some View {
        HStack(spacing: 12) {
            Text("sent \(tunnel.messagesSent)")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Text("hbt \(tunnel.heartbeatCount)")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if tunnel.hopNumber > 0 {
                Text("hop \(tunnel.hopNumber)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.blue.opacity(0.18))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
            }
            Spacer()
            Button("Disconnect") { cancelOrDisconnect() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var logsButton: some View {
        Button {
            showLogsSheet = true
        } label: {
            Label("Logs", systemImage: "doc.text")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Share log files")
    }

    // MARK: - Status badge

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text("Relay · " + stateLabel).font(.caption).monospacedDigit()
        }
    }

    private var statusColor: Color {
        switch state {
        case .idle, .closed:                   return .secondary
        case .hosting, .negotiating:           return .orange
        case .open:                            return .green
        }
    }

    private var stateLabel: String {
        switch state {
        case .idle:                            return "idle"
        case .hosting:                         return "tunnel hosting"
        case .negotiating:                     return "tunnel negotiating"
        case .open:                            return "tunnel open"
        case .closed(let r):                   return "closed (\(r))"
        }
    }

    // MARK: - Actions

    private func wireTunnelSend() {
        advertRelay.tunnelSend = { data in
            Task { await tunnel.send([UInt8](data)) }
        }
    }

    private func startTunnelHost() {
        let code = PairingCode.make()
        wireTunnelSend()
        Task { try? await tunnel.host(code: code) }
    }

    private func cancelOrDisconnect() {
        advertRelay.tunnelSend = nil
        tunnel.disconnect()
    }
}

// MARK: - Logs share sheet

/// Wraps `UIActivityViewController` so the user can AirDrop / Files-export
/// the JSONL trace files for cross-platform diffing per PORTING_GUIDE §7.
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
