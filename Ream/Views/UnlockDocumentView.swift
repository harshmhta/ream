import SwiftUI

/// Password prompt shown when a locked (encrypted) document is opened.
///
/// The document loads in a locked state; this sheet collects the open password
/// and asks the model to unlock. Nothing is stored — the password is used only
/// to unlock the in-memory document.
struct UnlockDocumentView: View {
    @ObservedObject var document: PDFReferenceDocument
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var showError = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("This document is password-protected. Enter the open password to view it.")
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(attemptUnlock)
                if showError {
                    Label("Incorrect password. Try again.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(width: 420, height: 260)
        .onAppear { fieldFocused = true }
    }

    private var header: some View {
        HStack {
            Image(systemName: "lock.doc")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Unlock Document")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Unlock") { attemptUnlock() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func attemptUnlock() {
        guard !password.isEmpty else { return }
        if document.unlock(withPassword: password) {
            dismiss()
        } else {
            showError = true
            password = ""
        }
    }
}
