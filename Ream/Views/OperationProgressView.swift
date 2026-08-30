import SwiftUI

/// A modal progress panel shown while a background page operation runs, with a
/// cancel button. Presented for any op that could exceed ~1s (merge, split,
/// image import).
struct OperationProgressView: View {
    let progress: OperationProgress
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()

            VStack(spacing: 16) {
                Text(progress.title)
                    .font(.headline)

                if progress.isIndeterminate {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                    Text("\(Int(progress.fraction * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            .frame(width: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 24, y: 8)
        }
    }
}
