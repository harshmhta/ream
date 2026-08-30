import SwiftUI
import ReamCore

/// A compact progress panel shown inside a conversion sheet while an engine runs.
///
/// Shows a determinate bar (engines report per-page fractions), the current
/// status message, and a Cancel button wired to the coordinator's cooperative
/// cancel token — satisfying the brief's "progress + cancel on long ops".
struct ConversionProgressView: View {
    let progress: ConversionProgress?
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: progress?.fraction ?? 0) {
                Text(progress?.message ?? "Working…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .progressViewStyle(.linear)

            HStack {
                Text(percentText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var percentText: String {
        let pct = Int(((progress?.fraction ?? 0) * 100).rounded())
        return "\(pct)%"
    }
}
