import SwiftUI
import PDFKit

/// Inline editor for a sticky note or free-text box. For notes it also shows the
/// author/timestamp, threaded replies, and a resolve toggle. Presented as a
/// popover anchored near the annotation.
struct NoteEditorView: View {
    @ObservedObject var controller: AnnotationController
    let annotation: PDFAnnotation

    @State private var body_: String = ""
    @State private var replyText: String = ""
    @FocusState private var focused: Bool

    private var isNote: Bool { annotation.type == "Text" }

    private var replies: [PDFAnnotation] {
        _ = controller.revision
        let id = annotation.storedReamID
        return controller.allAnnotations()
            .map(\.annotation)
            .filter { $0.reamInReplyTo == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            TextEditor(text: $body_)
                .font(.body)
                .frame(width: 260, height: 80)
                .focused($focused)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .onChange(of: body_) { _, newValue in
                    annotation.contents = newValue
                    annotation.modificationDate = Date()
                    controller.didChange()
                }

            if isNote {
                repliesSection
            }

            HStack {
                if isNote {
                    Button(annotation.reamResolved ? "Unresolve" : "Resolve") {
                        annotation.reamResolved.toggle()
                        controller.didChange()
                    }
                }
                Spacer()
                Button("Delete", role: .destructive) {
                    controller.remove(annotation)
                    controller.editingAnnotation = nil
                }
                Button("Done") { controller.editingAnnotation = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 288)
        .onAppear {
            body_ = annotation.contents ?? ""
            focused = true
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: isNote ? "note.text" : "textformat")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(annotation.userName ?? NSFullUserName()).font(.callout).bold()
                if let date = annotation.modificationDate {
                    Text(date, style: .date).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if annotation.reamResolved {
                Label("Resolved", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly).foregroundStyle(.green)
            }
        }
    }

    private var repliesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !replies.isEmpty {
                Divider()
                ForEach(replies, id: \.storedReamID) { reply in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(reply.userName ?? "Unknown").font(.caption).bold()
                        Text(reply.contents ?? "").font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            HStack(spacing: 6) {
                TextField("Reply…", text: $replyText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addReply)
                Button("Reply", action: addReply)
                    .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let page = annotation.page else { return }
        let reply = AnnotationFactory.reply(to: annotation, contents: text)
        controller.add(reply, to: page)
        replyText = ""
    }
}
