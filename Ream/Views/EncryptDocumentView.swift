import SwiftUI
import ReamCore

/// File → Encrypt… — set the open (user) and/or permissions (owner) password
/// and choose which actions remain allowed. Encryption is applied on the next
/// save (AES-128 via the native writer; see ``PDFSecurityService``).
struct EncryptDocumentView: View {
    @ObservedObject var document: PDFReferenceDocument
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager

    @State private var userPassword = ""
    @State private var userPasswordConfirm = ""
    @State private var ownerPassword = ""
    @State private var ownerPasswordConfirm = ""

    @State private var allowPrint = true
    @State private var allowCopy = true
    @State private var allowEdit = true
    @State private var allowAnnotate = true

    @State private var validationMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    passwordSection
                    Divider()
                    permissionsSection
                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    encryptionNote
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 560)
    }

    private var header: some View {
        HStack {
            Image(systemName: "lock.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Encrypt Document")
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
            Button("Encrypt") { apply() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!hasAnyPassword)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Passwords

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Passwords")
                .font(.subheadline.weight(.semibold))

            Text("Open password — required to view the document.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Open password", text: $userPassword)
                .textFieldStyle(.roundedBorder)
            SecureField("Confirm open password", text: $userPasswordConfirm)
                .textFieldStyle(.roundedBorder)

            Text("Permissions password — required to change permissions. Set this to enforce the restrictions below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            SecureField("Permissions password", text: $ownerPassword)
                .textFieldStyle(.roundedBorder)
            SecureField("Confirm permissions password", text: $ownerPasswordConfirm)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("When opened with the open password, allow:")
                .font(.subheadline.weight(.semibold))
            Toggle("Printing", isOn: $allowPrint)
            Toggle("Copying text and images", isOn: $allowCopy)
            Toggle("Editing content", isOn: $allowEdit)
            Toggle("Adding annotations and filling forms", isOn: $allowAnnotate)
        }
        .toggleStyle(.checkbox)
    }

    private var encryptionNote: some View {
        Text("Encryption uses AES-128, applied when you save. Passwords are held in memory only and never stored.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Logic

    private var hasAnyPassword: Bool {
        !userPassword.isEmpty || !ownerPassword.isEmpty
    }

    private var permissions: DocumentPermissions {
        var result: DocumentPermissions = []
        if allowPrint { result.insert(.print) }
        if allowCopy { result.insert(.copy) }
        if allowEdit { result.insert(.edit) }
        if allowAnnotate { result.insert(.annotate) }
        return result
    }

    private func apply() {
        guard userPassword == userPasswordConfirm else {
            validationMessage = "The open passwords do not match."
            return
        }
        guard ownerPassword == ownerPasswordConfirm else {
            validationMessage = "The permissions passwords do not match."
            return
        }
        // If the user restricts permissions but sets no owner password, warn:
        // the restrictions cannot be enforced without one.
        if permissions != .all && ownerPassword.isEmpty {
            validationMessage = "Set a permissions password to enforce the selected restrictions."
            return
        }

        let settings = EncryptionSettings(
            userPassword: userPassword.isEmpty ? nil : userPassword,
            ownerPassword: ownerPassword.isEmpty ? nil : ownerPassword,
            permissions: permissions
        )
        // The native PDF encryptor only accepts ASCII passwords; catch non-ASCII
        // here so the user sees a clear message instead of a failed save later.
        guard settings.passwordsAreASCII else {
            validationMessage = "Passwords must use only standard (ASCII) characters — no accents or emoji."
            return
        }
        document.setEncryption(settings, undoManager: undoManager)
        dismiss()
    }
}
