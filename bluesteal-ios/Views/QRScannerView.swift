//
//  QRScannerView.swift
//  bluesteal-ios
//
//  Camera QR scanning via VisionKit's DataScannerViewController, gated on camera
//  permission and filtered to `FIDO:/` QR payloads. Device-only (no simulator
//  camera); iOS 16+.
//

import SwiftUI
import AVFoundation
import VisionKit
import Vision

/// Recognises the FIDO hybrid QR scheme. We share the raw URI string; we do not
/// decode the CBOR payload.
enum FidoQR {
    static func isFidoUri(_ s: String) -> Bool {
        s.uppercased().hasPrefix("FIDO:/")
    }
}

/// Full-screen scan experience: requests camera access, hosts the live scanner,
/// shows guidance, and surfaces a Cancel control.
struct ScannerScreen: View {
    /// Called with the validated `FIDO:/` URI once a matching QR is recognised.
    var onScanned: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var authorized: Bool?      // nil = still checking

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch authorized {
            case nil:
                ProgressView().tint(.white)
            case .some(true) where DataScannerViewController.isSupported && DataScannerViewController.isAvailable:
                DataScannerRepresentable { uri in onScanned(uri) }
                    .ignoresSafeArea()
                VStack {
                    Spacer()
                    Text("Point at a FIDO QR code")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 60)
                }
            case .some(true):
                message("Scanning isn’t available on this device.")
            default:
                message("Camera access is off. Enable it in Settings to scan QR codes.")
            }

            VStack {
                HStack {
                    Button("Cancel") { dismiss() }
                        .padding()
                        .foregroundStyle(.white)
                    Spacer()
                }
                Spacer()
            }
        }
        .task {
            authorized = await Self.requestCamera()
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(32)
    }

    private static func requestCamera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:    return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default:             return false
        }
    }
}

/// Thin wrapper over `DataScannerViewController` filtered to QR barcodes.
private struct DataScannerRepresentable: UIViewControllerRepresentable {
    var onScanned: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        try? vc.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScanned: onScanned) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScanned: (String) -> Void
        private var handled = false
        init(onScanned: @escaping (String) -> Void) { self.onScanned = onScanned }

        func dataScanner(_ scanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            handle(addedItems)
        }

        func dataScanner(_ scanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            handle([item])
        }

        private func handle(_ items: [RecognizedItem]) {
            guard !handled else { return }
            for case let .barcode(barcode) in items {
                guard let value = barcode.payloadStringValue, FidoQR.isFidoUri(value) else { continue }
                handled = true
                onScanned(value)
                return
            }
        }
    }
}
