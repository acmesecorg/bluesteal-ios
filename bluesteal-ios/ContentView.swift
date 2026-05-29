//
//  ContentView.swift
//  bluesteal-ios
//

import SwiftUI

struct ContentView: View {
    @Environment(CableScanner.self) private var scanner
    @Environment(AdvertStore.self) private var store

    var body: some View {
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
                    Label("Waiting for caBLE adverts", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Listening for service data under UUIDs 0xFFF9 (FIDO) and 0xFDE2 (Google).\nStart a hybrid sign-in flow on a nearby phone or laptop.")
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.adverts) { AdvertRowView(advert: $0) }
                }
                .listStyle(.insetGrouped)
            }
        }
        .onAppear {
            scanner.onEvent = { event in
                store.ingest(event)
            }
        }
    }
}

#Preview {
    let store = AdvertStore(logger: JSONLLogger())
    let advertRelay = AdvertRelay(store: store)
    return ContentView()
        .environment(CableScanner(previewMode: true))
        .environment(store)
        .environment(advertRelay)
        .environment(TunnelTransport(tracer: RelayTracer()))
}
