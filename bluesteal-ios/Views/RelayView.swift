//
//  RelayView.swift
//  bluesteal-ios
//
//  iOS adaptation of the macOS RelayView. Functionally equivalent — same
//  state-machine view onto RelayClient — but laid out to work in iPhone
//  width and using iOS-native sharing instead of NSWorkspace.
//

import SwiftUI

struct RelayView: View {
    @Environment(RelayClient.self) private var relay

    @State private var showJoinSheet: Bool = false
    @State private var showLogsSheet: Bool = false
    @State private var joinCode: String = ""

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
        .sheet(isPresented: $showJoinSheet) {
            JoinSheet(
                joinCode: $joinCode,
                onSubmit: submitJoin,
                onCancel: { showJoinSheet = false; joinCode = "" }
            )
            .presentationDetents([.height(220)])
        }
        .sheet(isPresented: $showLogsSheet) {
            LogsShareSheet()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var controls: some View {
        switch relay.state {
        case .idle, .closed:
            idleControls
        case .hosting(let code):
            hostingControls(code: code)
        case .joining, .negotiating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(stateLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { relay.disconnect(reason: "cancelled") }
                    .buttonStyle(.borderless)
            }
        case .open:
            openControls
        }
    }

    private var idleControls: some View {
        HStack(spacing: 8) {
            Button("Host") { _ = relay.host() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Join…") { showJoinSheet = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Spacer()
        }
    }

    private func hostingControls(code: String) -> some View {
        HStack(spacing: 10) {
            Text("Code")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(code)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        Label("Copy code", systemImage: "doc.on.doc")
                    }
                }
            Text("waiting for peer…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Cancel", role: .destructive) { relay.disconnect(reason: "cancelled") }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
    }

    private var openControls: some View {
        HStack(spacing: 12) {
            Text(relay.messagesSent > 0
                 ? "sent \(relay.messagesSent)"
                 : "recv \(relay.messagesReceived)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if relay.isUsingTURN {
                Text("TURN").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.18))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
            Spacer()
            Button("Disconnect") { relay.disconnect() }
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
        switch relay.state {
        case .idle, .closed:                           return .secondary
        case .hosting, .joining, .negotiating:         return .orange
        case .open:                                    return .green
        }
    }

    private var stateLabel: String {
        switch relay.state {
        case .idle:                                    return "idle"
        case .hosting:                                 return "hosting"
        case .joining(let c):                          return "joining \(c)"
        case .negotiating:                             return "negotiating"
        case .open:                                    return "open"
        case .closed(let r):                           return "closed (\(r))"
        }
    }

    /// Uppercased + filtered to the alphabet — strips spaces, ambiguous
    /// I/L/O, and any digits the user might paste from a stale code. The
    /// "Connect" button gates on this length, not the raw input length.
    private var normalisedJoinCode: String {
        let allowed = Set(SignalingClient.codeAlphabet)
        return joinCode.uppercased().filter { allowed.contains($0) }
    }

    private func submitJoin() {
        let code = normalisedJoinCode
        guard code.count == SignalingClient.codeLength else { return }
        relay.join(code: code)
        showJoinSheet = false
        joinCode = ""
    }
}

// MARK: - Join sheet

private struct JoinSheet: View {
    @Binding var joinCode: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @FocusState private var codeFieldFocused: Bool

    private var normalised: String {
        let allowed = Set(SignalingClient.codeAlphabet)
        return joinCode.uppercased().filter { allowed.contains($0) }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Enter the \(SignalingClient.codeLength)-letter code shown on the host device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Code", text: $joinCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title2, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($codeFieldFocused)
                    .onSubmit(onSubmit)
                Spacer()
            }
            .padding(16)
            .navigationTitle("Join session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: onSubmit)
                        .disabled(normalised.count != SignalingClient.codeLength)
                }
            }
            .onAppear { codeFieldFocused = true }
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
