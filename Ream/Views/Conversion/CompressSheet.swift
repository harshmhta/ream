import SwiftUI
import UniformTypeIdentifiers
import ReamCore

/// The **Compress** sheet — home of the killer "make this ≤ N MB" feature.
///
/// Three modes: a quality preset, manual downsampling, and target-size (the
/// default, since it's the reason people reach for this). The target-size run
/// binary-searches resolution + quality in ``CompressionEngine`` to land at or
/// just under the requested size, and reports honestly when a size is
/// unreachable.
struct CompressSheet: View {
    @ObservedObject var coordinator: ConversionCoordinator

    enum Mode: String, CaseIterable, Identifiable {
        case targetSize = "Target Size"
        case preset = "Quality Preset"
        case downsample = "Manual"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .targetSize
    @State private var targetMegabytes: Double = 2.0
    @State private var preset: QualityPreset = .ebook
    @State private var manualDPI: Double = 150
    @State private var manualQuality: Double = 0.6

    @State private var result: CompressionResult?
    @State private var errorMessage: String?
    @State private var originalBytes: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if coordinator.isRunning {
                ConversionProgressView(progress: coordinator.progress) {
                    coordinator.cancel()
                }
            } else {
                content
            }
        }
        .frame(width: 460)
        .task {
            // Compute the original size off-main so opening the sheet is instant.
            originalBytes = await coordinator.currentPDFData()?.count ?? 0
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Compress PDF")
                    .font(.headline)
                if originalBytes > 0 {
                    Text("Original size: \(ByteFormat.string(fromBytes: originalBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch mode {
                case .targetSize: targetSizeControls
                case .preset: presetControls
                case .downsample: downsampleControls
                }
            }

            if let result {
                resultBanner(result)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            fidelityNote

            Divider()
            footer
        }
        .padding(20)
    }

    // MARK: Mode controls

    private var targetSizeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Make the file at most:")
                .font(.callout)
            HStack(spacing: 8) {
                TextField("", value: $targetMegabytes, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                Text("MB")
                    .foregroundStyle(.secondary)
                Stepper("", value: $targetMegabytes, in: 0.1...500, step: 0.5)
                    .labelsHidden()
                Spacer()
            }
            Text("Ream searches resolution and quality to get as close to this size as possible without going over.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var presetControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Quality", selection: $preset) {
                ForEach(QualityPreset.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            Text(preset.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var downsampleControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Resolution")
                    Spacer()
                    Text("\(Int(manualDPI)) DPI").foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $manualDPI, in: 36...300, step: 6)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("JPEG Quality")
                    Spacer()
                    Text("\(Int(manualQuality * 100))%").foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $manualQuality, in: 0.1...0.95, step: 0.05)
            }
        }
    }

    // MARK: Result / note / footer

    private func resultBanner(_ result: CompressionResult) -> some View {
        let savings = max(0, 1 - result.ratio)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: result.reachedTarget ? "checkmark.circle.fill" : "info.circle.fill")
                    .foregroundStyle(result.reachedTarget ? Color.green : Color.orange)
                Text(bannerHeadline(result))
                    .font(.callout.weight(.medium))
            }
            Text("\(ByteFormat.string(fromBytes: result.originalBytes)) → "
                 + "\(ByteFormat.string(fromBytes: result.compressedBytes)) "
                 + "(\(Int((savings * 100).rounded()))% smaller) · "
                 + "\(Int(result.usedDPI)) DPI\(result.grayscale ? ", grayscale" : "")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Click Save… to write the compressed file.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private func bannerHeadline(_ result: CompressionResult) -> String {
        if result.reachedTarget {
            return mode == .targetSize ? "Reached target size" : "Ready to save"
        }
        return "Smallest achievable size"
    }

    private var fidelityNote: some View {
        Label {
            Text("Compression rasterizes pages, so text becomes part of the page image and is no longer selectable. The original file is never modified — you choose where to save the result.")
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack {
            Button(result == nil ? "Cancel" : "Close", role: .cancel) { coordinator.dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if result != nil {
                Button("Compress Again") { Task { await runCompression() } }
            }
            Button(saveButtonTitle) {
                if result == nil {
                    Task { await runCompression() }
                } else {
                    saveResult()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(mode == .targetSize && !(targetMegabytes > 0))
        }
    }

    // MARK: Run

    private var saveButtonTitle: String {
        result == nil ? "Compress…" : "Save…"
    }

    /// Compress to memory and show the achieved size. The user reviews the result
    /// (did it hit the target?) *before* choosing where to save — so cancelling
    /// the save panel never silently discards a completed compression, and the
    /// success banner never claims a save that didn't happen.
    private func runCompression() async {
        guard let pdfData = await coordinator.currentPDFData() else {
            errorMessage = "This document has no data to compress."
            return
        }
        errorMessage = nil
        result = nil

        let mode = engineMode()
        do {
            let compression = try await coordinator.run { progress, token in
                try CompressionEngine.compress(pdfData: pdfData, mode: mode,
                                               progress: progress, cancellation: token)
            }
            result = compression
        } catch let error as ConversionError where error == .cancelled {
            errorMessage = nil // silent on user cancel
        } catch {
            errorMessage = (error as? ConversionError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func engineMode() -> CompressionMode {
        switch mode {
        case .targetSize:
            return .targetSize(targetBytes: ByteFormat.bytes(fromMegabytes: targetMegabytes),
                               tolerance: 0.05)
        case .preset:
            return .preset(preset)
        case .downsample:
            return .downsample(dpi: CGFloat(manualDPI), quality: CGFloat(manualQuality))
        }
    }

    private func saveResult() {
        guard let result else { return }
        let stem = coordinator.suggestedStem
        guard let url = coordinator.chooseSaveURL(suggestedName: "\(stem) (compressed).pdf",
                                                  contentType: .pdf) else { return }
        do {
            try result.data.write(to: url, options: .atomic)
            coordinator.revealInFinder(url)
            coordinator.dismiss()
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }
}
