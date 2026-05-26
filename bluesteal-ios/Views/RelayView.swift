//
//  RelayView.swift
//  bluesteal-ios
//
//  Host-only relay control bar. iOS cannot re-broadcast peer adverts so
//  joining an existing session makes no sense — only the Host flow remains.
//  The transport picker chooses between WebRTC and the caBLE tunnel; in tunnel
//  mode the copyable value is the OOB token (code-routing) the peer pastes.
//

import SwiftUI

struct RelayView: View {
    @Environment(RelayClient.self) private var relay
    @Environment(AdvertRelay.self) private var advertRelay
    @Environment(TunnelTransport.self) private var tunnel

    enum TransportKind: String, CaseIterable { case webRTC = "WebRTC", tunnel = "Tunnel" }

    @State private var showLogsSheet: Bool = false
    @State private var transport: TransportKind = .tunnel

    /// The tunnel transport "owns" the UI whenever it is past idle/closed;
    /// otherwise the WebRTC RelayClient drives it.
    private var tunnelActive: Bool {
        switch tunnel.state {
        case .idle, .closed: return false
        default:             return true
        }
    }

    private var effectiveState: RelayClient.State { tunnelActive ? tunnel.state : relay.state }

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
        switch effectiveState {
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
            Picker("", selection: $transport) {
                ForEach(TransportKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)

            Button("Host", action: startHost)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Spacer()
        }
    }

    private func hostingControls(code: String) -> some View {
        let isTunnel = tunnelActive
        let ready = !isTunnel || tunnel.token != nil
        let displayValue = isTunnel ? (tunnel.token ?? "waiting…") : code
        let label = isTunnel ? "Token" : "Code"
        return HStack(spacing: 10) {
            Text(label)
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
            .accessibilityLabel("Copy \(label.lowercased())")
            Spacer()
            Button("Cancel", role: .destructive) { cancelOrDisconnect() }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
    }

    private var openControls: some View {
        HStack(spacing: 12) {
            if tunnelActive {
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
            } else {
                Text("sent \(relay.messagesSent)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Text("hbt \(relay.heartbeatCount)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if relay.isUsingTURN {
                    Text("TURN").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.18))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
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
        switch effectiveState {
        case .idle, .closed:                   return .secondary
        case .hosting, .negotiating:           return .orange
        case .open:                            return .green
        }
    }

    private var stateLabel: String {
        let prefix = tunnelActive ? "tunnel " : ""
        switch effectiveState {
        case .idle:                            return "idle"
        case .hosting:                         return "\(prefix)hosting"
        case .negotiating:                     return "\(prefix)negotiating"
        case .open:                            return "\(prefix)open"
        case .closed(let r):                   return "closed (\(r))"
        }
    }

    // MARK: - Actions

    private func startHost() {
        switch transport {
        case .webRTC: _ = relay.host()
        case .tunnel: startTunnelHost()
        }
    }

    private func wireTunnelSend() {
        advertRelay.tunnelSend = { data in
            Task { await tunnel.send([UInt8](data)) }
        }
    }

    private func startTunnelHost() {
        let code = SignalingClient.makeCode()
        wireTunnelSend()
        Task { try? await tunnel.host(code: code) }
    }

    private func cancelOrDisconnect() {
        if tunnelActive {
            advertRelay.tunnelSend = nil
            tunnel.disconnect()
        } else {
            relay.disconnect(reason: "user")
        }
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
