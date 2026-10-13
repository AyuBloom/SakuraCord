import SakuraCordModels
import SwiftUI

struct ProfileAvatarExpansion: ViewModifier {
    var openProfile: (() -> Void)?
    @State private var isHovered = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if let openProfile {
            Button(action: openProfile) {
                content.overlay {
                    Circle().fill(.black.opacity(isHovered ? 0.22 : 0))
                        .allowsHitTesting(false)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .pointerStyle(.link)
            .onModalHover { isHovered = $0 }
            .help("Open full profile")
            .accessibilityLabel("Open full profile")
        } else {
            content
        }
    }
}

struct ProfileQuickMessageView: View {
    let displayName: String
    let send: (String, String) async -> Bool
    var releaseNonce: (String) -> Void = { _ in }
    @State private var draft = ""
    @State private var nonce = ClientNonce.make()
    @State private var isSending = false
    @State private var result: LocalizedStringResource?

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
            HStack(spacing: InterfaceScale.metric(8)) {
                TextField("Message @\(displayName)", text: Binding(
                    get: { draft },
                    set: {
                        draft = $0
                        result = nil
                    }
                ))
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
                    .disabled(isSending)
                if isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: submit) {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send message")
                    .accessibilityLabel("Send message")
                }
            }
            .padding(InterfaceScale.metric(12))
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1) }
            if let result {
                Text(result).font(.interface(.caption)).foregroundStyle(.secondary)
            }
        }
        .onChange(of: draft) { _, _ in
            if !isSending {
                releaseNonce(nonce)
                nonce = ClientNonce.make()
            }
        }
        .onDisappear { releaseNonce(nonce) }
    }

    private func submit() {
        guard !isSending, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let content = draft
        let submissionNonce = nonce
        isSending = true
        result = nil
        Task { @MainActor in
            let sent = await send(content, submissionNonce)
            if sent {
                releaseNonce(submissionNonce)
                draft = ""
                nonce = ClientNonce.make()
            }
            result = sent ? "Message sent" : "Couldn't send message. Try again."
            isSending = false
        }
    }
}
