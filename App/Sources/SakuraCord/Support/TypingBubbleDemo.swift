#if DEBUG
    import Foundation
    import SakuraCordModels

    /// TEMPORARY, not for commit: replays a scripted typing sequence in the
    /// offline "Design crew" group so the typing bubble can be recorded.
    /// Launch offline with `SAKURACORD_TYPING_DEMO=1`. Bubble mode is applied
    /// without being saved.
    @MainActor
    enum TypingBubbleDemo {
        private enum Step {
            case starts(Int)
            case stops(Int)
        }

        static var isRequested: Bool {
            ProcessInfo.processInfo.environment["SAKURACORD_TYPING_DEMO"] == "1"
        }

        static func run(model: AppModel) async {
            var appearance = model.appearanceSettings
            appearance.messageAppearance = .bubbles
            model.applyAppearanceSettings(appearance, persists: false)
            let channelID = ChannelID(rawValue: 401)
            model.navigate(to: channelID)
            guard let snapshot = model.snapshot else { return }
            let known = snapshot.knownUsers
                + snapshot.channels.flatMap(\.recipients)
                + snapshot.members.map(\.user)
            // Maya, Theo, Juniper, Rowan, and Kai, who has no picture.
            let users = (2 ... 6).compactMap { raw in known.first { $0.id == UserID(rawValue: UInt64(raw)) } }
            guard users.count == 5 else { return }
            let script: [(Step, Double)] = [
                (.starts(0), 1.6), (.starts(1), 1.4), (.starts(2), 1.3), (.starts(3), 1.3),
                (.starts(4), 1.9), (.stops(1), 1.7), (.stops(4), 1.7), (.stops(0), 1.5),
                (.stops(2), 1.5), (.stops(3), 2.6),
            ]
            try? await Task.sleep(for: .seconds(2.5))
            var typing: [Int] = []
            while !Task.isCancelled {
                for (step, pause) in script {
                    switch step {
                    case let .starts(index):
                        typing.append(index)
                    case let .stops(index):
                        typing.removeAll { $0 == index }
                        model.typingState.clear(userID: users[index].id, in: channelID)
                    }
                    // Refreshing keeps everyone's place and stops expiry.
                    for index in typing {
                        model.typingState.receive(
                            channelID: channelID, user: users[index], currentUserID: snapshot.currentUser.id
                        )
                    }
                    try? await Task.sleep(for: .seconds(pause))
                }
            }
        }
    }
#endif
