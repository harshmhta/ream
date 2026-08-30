import SwiftUI
import UniformTypeIdentifiers
import ReamCore

/// The **Export → Images** sheet: render the current PDF's pages to PNG / JPEG /
/// TIFF (WebP when the OS can encode it) at a chosen DPI, either one file per
/// page or as contact sheets, saved as loose files in a folder or a single ZIP.
struct PDFToImagesSheet: View {
    @ObservedObject var coordinator: ConversionCoordinator

    enum Destination: String, CaseIterable, Identifiable {
        case folder = "Folder of Files"
        case zip = "Single ZIP"
        var id: String { rawValue }
    }

    @State private var format: ImageFormat = .png
    @State private var dpiChoice: DPIChoice = .dpi150
    @State private var customDPI: Double = 200
    @State private var quality: Double = 0.8
    @State private var useContactSheet = false
    @State private var columns = 2
    @State private var rows = 2
    @State private var destination: Destination = .folder
    @State private var errorMessage: String?

    enum DPIChoice: String, CaseIterable, Identifiable {
        case dpi72 = "72", dpi150 = "150", dpi300 = "300", custom = "Custom"
        var id: String { rawValue }
        var value: Double? {
            switch self {
            case .dpi72: return 72
            case .dpi150: return 150
            case .dpi300: return 300
            case .custom: return nil
            }
        }
    }

    /// Formats the current OS can actually encode. WebP is filtered out when
    /// unavailable (see `ImageFormat.isEncodable`), so we never offer a broken one.
    private let formats = ImageFormat.encodableCases

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if coordinator.isRunning {
                ConversionProgressView(progress: coordinator.progress) { coordinator.cancel() }
            } else {
                content
            }
        }
        .frame(width: 460)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Export Pages as Images").font(.headline)
                Text("\(coordinator.document?.pdfDocument.pageCount ?? 0) pages")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Format").font(.caption).foregroundStyle(.secondary)
                    Picker("Format", selection: $format) {
                        ForEach(formats) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resolution").font(.caption).foregroundStyle(.secondary)
                    Picker("DPI", selection: $dpiChoice) {
                        ForEach(DPIChoice.allCases) { Text($0 == .custom ? "Custom" : "\($0.rawValue) DPI").tag($0) }
                    }
                    .labelsHidden()
                }
            }

            if dpiChoice == .custom {
                HStack {
                    Text("Custom DPI")
                    TextField("", value: $customDPI, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder).frame(width: 70)
                    Stepper("", value: $customDPI, in: 36...600, step: 10).labelsHidden()
                    Spacer()
                }
            }

            if format.isLossy {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Quality")
                        Spacer()
                        Text("\(Int(quality * 100))%").foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $quality, in: 0.1...1.0, step: 0.05)
                }
            }

            Toggle("Contact sheet (grid of pages per image)", isOn: $useContactSheet)
                .font(.callout)
            if useContactSheet {
                HStack(spacing: 12) {
                    Stepper("Columns: \(columns)", value: $columns, in: 1...6)
                    Stepper("Rows: \(rows)", value: $rows, in: 1...8)
                }
                .font(.callout)
            }

            Picker("Save as", selection: $destination) {
                ForEach(Destination.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) { coordinator.dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Export…") { Task { await run() } }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Run

    private var resolvedDPI: CGFloat {
        CGFloat(dpiChoice.value ?? customDPI)
    }

    private func run() async {
        guard let pdfData = await coordinator.currentPDFData() else {
            errorMessage = "This document has no pages to export."
            return
        }
        errorMessage = nil

        let format = self.format
        let dpi = resolvedDPI
        let quality = CGFloat(self.quality)
        let layout: PDFToImagesExporter.Layout = useContactSheet
            ? .contactSheet(columns: columns, rows: rows)
            : .perPage
        let stem = coordinator.suggestedStem

        do {
            let outputs = try await coordinator.run { progress, token in
                try PDFToImagesExporter.export(pdfData: pdfData, format: format, dpi: dpi,
                                               quality: quality, layout: layout,
                                               fileNameStem: stem,
                                               progress: progress, cancellation: token)
            }
            guard !outputs.isEmpty else { return }
            try await save(outputs: outputs, stem: stem)
        } catch let error as ConversionError where error == .cancelled {
            // silent
        } catch {
            errorMessage = (error as? ConversionError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func save(outputs: [PDFToImagesExporter.OutputImage], stem: String) async throws {
        switch destination {
        case .folder:
            guard let folder = coordinator.chooseDirectory(message: "Choose a folder for the images") else { return }
            try coordinator.writeFiles(outputs.map { ($0.fileName, $0.data) }, into: folder)
            coordinator.dismiss()
        case .zip:
            guard let dest = coordinator.chooseSaveURL(suggestedName: "\(stem) images.zip",
                                                       contentType: .zip) else { return }
            let entries = outputs.map { ZipWriter.Entry(fileName: $0.fileName, data: $0.data) }
            try ZipWriter.write(entries: entries, to: dest, folderName: stem)
            coordinator.dismiss()
            coordinator.revealInFinder(dest)
        }
    }
}
