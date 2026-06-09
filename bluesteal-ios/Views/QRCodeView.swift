//
//  QRCodeView.swift
//  bluesteal-ios
//
//  Renders a string as a QR code, and the two QR sheets (scanned-result actions
//  and the received-QR display modal).
//

import SwiftUI
import CoreImage.CIFilterBuiltins

/// Renders an arbitrary string as a scannable QR image (CoreImage).
struct QRCodeView: View {
    let uri: String

    var body: some View {
        if let img = Self.make(uri) {
            Image(uiImage: img)
                .interpolation(.none)   // keep the modules crisp
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "qrcode")
                .resizable().scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    static func make(_ string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?
                .transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Shown after a successful scan: the rendered QR plus Copy / Send actions.
struct ScannedResultView: View {
    let uri: String
    let canSend: Bool
    var onCopy: () -> Void
    var onSend: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 18) {
            QRCodeView(uri: uri)
                .frame(width: 220, height: 220)
            Text(uri)
                .font(.caption.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            HStack(spacing: 16) {
                Button {
                    onCopy(); copied = true
                } label: {
                    Text(copied ? "Copied" : "Copy")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onSend(); dismiss()
                } label: {
                    Text("Send")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
            }
            .padding(.horizontal)
        }
        .padding()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// The slide-up modal shown on the receiving device: the peer's QR rendered for
/// the user to scan.
struct ReceivedQRView: View {
    let uri: String

    var body: some View {
        VStack(spacing: 18) {
            Text("QR Code Received")
                .font(.headline)
            Text("Scan with another device")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            QRCodeView(uri: uri)
                .frame(width: 260, height: 260)
        }
        .padding()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
