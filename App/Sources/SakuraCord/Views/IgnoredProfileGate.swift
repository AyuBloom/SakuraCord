import SakuraCordModels
import SwiftUI

struct IgnoredProfileGate: View {
    let model: AppModel
    let presentation: ProfilePresentationState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.slash").font(.largeTitle).foregroundStyle(.secondary)
            Text("Show Profile?").font(.headline)
            Text("You ignored \(model.friendDisplayName(presentation.member.user)). They won’t be notified if you view their profile.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Show Profile") {
                model.ignoredUsers.revealedProfileRequests.insert(presentation.id)
            }
            .buttonStyle(.borderedProminent)
            Button("Unignore") {
                model.setUserIgnored(presentation.member.user, ignored: false, location: .profileNotice)
            }
            .disabled(model.friends.pendingUserIDs.contains(presentation.member.id))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 260)
    }
}
