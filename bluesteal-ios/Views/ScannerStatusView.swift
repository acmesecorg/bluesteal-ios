//
//  ScannerStatusView.swift
//  bluesteal
//

import SwiftUI
import CoreBluetooth

struct ScannerStatusView: View {
    let state: CBManagerState
    let isScanning: Bool
    let totalDetections: Int
    let uniqueCount: Int
    @Binding var mode: ScanMode
    var onClear: () -> Void

    var body: some View {
        // Matches the Android ScannerStatusView layout: a single row with the
        // status badge + compact "· N/M" counter on the leading edge, then the
        // mode picker (menu-style, not segmented — saves horizontal space on
        // phone widths) and a trash icon button trailing.
        HStack(spacing: 8) {
            statusBadge

            Text("· \(uniqueCount)/\(totalDetections)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            // Plain `Picker(.menu)` lets the trigger text wrap vertically when
            // the surrounding HStack squeezes it — "Promiscuous" rendered one
            // character per line on the iPhone 16 Pro. Using `Menu` with an
            // explicit, `.lineLimit(1).fixedSize()` label sidesteps the
            // intrinsic-width race entirely and matches the Android TextButton
            // + tune icon layout.
            Menu {
                ForEach(ScanMode.allCases) { m in
                    Button(m.label) { mode = m }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                    Text(mode.label)
                        .lineLimit(1)
                }
                .font(.caption)
                .fixedSize(horizontal: true, vertical: false)
            }
            .accessibilityLabel("Scan mode")

            Button(action: onClear) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Clear adverts")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var statusBadge: some View {
        let (label, color): (String, Color) = {
            switch state {
            case .poweredOn:    return (isScanning ? "Scanning" : "Idle", .green)
            case .poweredOff:   return ("Bluetooth Off", .orange)
            case .unauthorized: return ("Unauthorized", .red)
            case .unsupported:  return ("Unsupported", .red)
            case .resetting:    return ("Resetting", .orange)
            case .unknown:      return ("Unknown", .secondary)
            @unknown default:   return ("Unknown", .secondary)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).monospacedDigit()
        }
    }
}
