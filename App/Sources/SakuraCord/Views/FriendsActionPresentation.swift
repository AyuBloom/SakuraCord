import SwiftUI

/// Relationship dialogs belong to the workspace, regardless of the initiating surface.
struct FriendsActionPresentation: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        let friends = model.friends
        content
        .modifier(HumanCaptchaPresentation(store: friends.captcha))
        .onDisappear { friends.captcha.cancel() }
        .alert(
            confirmationTitle(friends.confirmation),
            isPresented: Binding(get: { friends.confirmation != nil }, set: { if !$0 { friends.confirmation = nil } }),
            presenting: friends.confirmation
        ) { confirmation in
            Button(confirmationAction(confirmation), role: confirmationRole(confirmation)) {
                model.confirmFriendsAction(confirmation)
            }
            Button("Cancel", role: .cancel) { friends.confirmation = nil }
        } message: { confirmation in
            Text(confirmationMessage(confirmation))
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { friends.actionError != nil }, set: { if !$0 { friends.actionError = nil } })
        ) {
            Button("OK", role: .cancel) { friends.actionError = nil }
        } message: {
            Text(friends.actionError ?? "")
        }
    }

    // Official stable633029 copy for removal and blocking.
    private func confirmationTitle(_ confirmation: FriendsConfirmation?) -> String {
        switch confirmation {
        case .removeFriend(let user): "Remove ‘\(model.friendDisplayName(user))’"
        case .block(let user): "Block \(model.friendDisplayName(user))?"
        case .acceptStranger: "Accept Friend Request?"
        case nil: ""
        }
    }

    private func confirmationMessage(_ confirmation: FriendsConfirmation) -> String {
        switch confirmation {
        case .removeFriend(let user):
            "Are you sure you want to remove \(model.friendDisplayName(user)) from your friends?"
        case .block(let user):
            "Are you sure you want to block \(model.friendDisplayName(user))? Blocking this user will also remove them from your friends list."
        case .acceptStranger(let user):
            "Discord wants you to confirm that you know \(model.friendDisplayName(user)) before accepting their request."
        }
    }

    private func confirmationAction(_ confirmation: FriendsConfirmation) -> String {
        switch confirmation {
        case .removeFriend: "Remove Friend"
        case .block: "Block"
        case .acceptStranger: "Accept"
        }
    }

    private func confirmationRole(_ confirmation: FriendsConfirmation) -> ButtonRole? {
        switch confirmation {
        case .removeFriend, .block: .destructive
        case .acceptStranger: nil
        }
    }
}
