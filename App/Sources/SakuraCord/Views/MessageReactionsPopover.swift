import AppKit
import SakuraCordModels
import SwiftUI

/// Presents the identities already retained by the timeline. Opening or
/// switching reactions must never initiate a reactor or member request.
struct MessageReactionsPopover: View {
    static var size: CGSize {
        CGSize(width: InterfaceScale.metric(480), height: InterfaceScale.metric(380))
    }

    let model: AppModel
    let message: Message
    let dismiss: () -> Void
    @State private var selectedReactionID: String?

    private var reactions: [Reaction] {
        let current = model.retainedMessage(channelID: message.channelID, messageID: message.id) ?? message
        return MessageReactionPresentation.items(from: current.reactions)
    }

    private var selectedReaction: Reaction? {
        reactions.first { $0.id == selectedReactionID } ?? reactions.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Reactions").font(.interface(.headline))
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.interface(.callout).weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: InterfaceScale.metric(24), height: InterfaceScale.metric(24))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close reactions")
            }
            .padding(InterfaceScale.metric(16))
            Divider()
            HStack(spacing: 0) {
                reactionList.frame(width: InterfaceScale.metric(112))
                Divider()
                peopleList.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onChange(of: reactions.map(\.id)) { _, ids in
            if !ids.contains(selectedReactionID ?? "") { selectedReactionID = ids.first }
        }
        .onChange(of: model.snapshot?.currentUser.id) { _, _ in dismiss() }
        .onChange(of: model.retainedMessage(channelID: message.channelID, messageID: message.id)?.id) { _, id in
            if id == nil { dismiss() }
        }
    }

    private var reactionList: some View {
        let selection = selectedReaction?.id
        return ScrollView(.vertical) {
            VStack(spacing: InterfaceScale.metric(2)) {
                ForEach(reactions) { reaction in
                    Button { selectedReactionID = reaction.id } label: {
                        HStack(spacing: InterfaceScale.metric(10)) {
                            MessageReactionEmoji(
                                reaction: reaction,
                                url: MessageReactionPresentation.emojiURL(
                                    for: reaction, customEmojiURLsByID: model.customEmojiURLsByID
                                ),
                                size: InterfaceScale.metric(24)
                            )
                            Text(String(reaction.count))
                                .font(.interface(.callout).weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(InterfaceScale.metric(10))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PopoverRowButtonStyle(isSelected: selection == reaction.id))
                    .accessibilityLabel("\(MessageReactionPresentation.emojiName(for: reaction)), \(reaction.count) reactions")
                    .accessibilityAddTraits(selection == reaction.id ? .isSelected : [])
                }
            }
            .padding(InterfaceScale.metric(8))
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder private var peopleList: some View {
        if let reaction = selectedReaction {
            let members = members(for: reaction)
            VStack(spacing: 0) {
                NativeMemberListView(
                    sections: [MemberSection(
                        id: .online, title: "", colorHex: nil,
                        totalCount: members.count, members: members
                    )],
                    customEmojiURLsByID: model.customEmojiURLsByID,
                    profilePresentation: nil, isProfilePresented: false,
                    selectMember: { _ in }, dismissProfile: {},
                    runsPerformanceAutoScroll: false, viewportIdentity: nil,
                    presentation: NativeMemberListPresentation(
                        roleColorDisplay: .hidden, dimsOfflineMembers: false,
                        presenceHiddenUserIDs: Set(members.map(\.id)),
                        activityTextPrimaryOpacity: 0.6
                    ),
                    contentIdentity: reaction.id
                )
                .padding(.vertical, InterfaceScale.metric(8))
                .overlay {
                    if members.isEmpty {
                        ContentUnavailableView("No People to Show", systemImage: "person.2")
                    }
                }
                if members.count < reaction.count {
                    Text("Showing \(members.count) of \(reaction.count)")
                        .font(.interface(.caption))
                        .foregroundStyle(.secondary)
                        .padding(InterfaceScale.metric(12))
                }
            }
        } else {
            ContentUnavailableView("No Reactions", systemImage: "face.smiling")
        }
    }

    private func members(for reaction: Reaction) -> [Member] {
        model.retainedReactionReactors(for: reaction, on: message).map { reactor in
            let known = model.snapshot?.currentUser.id == reactor.id ? model.snapshot?.currentUser
                : model.membersByID[reactor.id]?.user
                    ?? model.snapshot?.knownUsers.first { $0.id == reactor.id }
            let user = User(
                id: reactor.id, username: known?.username ?? "",
                displayName: reactor.displayName, avatarURL: reactor.avatarURL
            )
            return Member(user: user, roleName: "", isOnline: false, activityText: known?.username)
        }
    }
}

extension NativeTimelineCanvasView {
    func showMessageReactions(_ message: Message) {
        guard let model, let index = items.firstIndex(where: { $0.messageID == message.id }) else { return }
        let anchor = rowFrame(at: index).intersection(enclosingScrollView?.documentVisibleRect ?? visibleRect)
        guard !anchor.isNull, !anchor.isEmpty else { return }
        reactionDetailsPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let dismiss: () -> Void = { [weak popover] in popover?.close() }
        let controller = StablePopoverHostingController(
            rootView: MessageReactionsPopover(model: model, message: message, dismiss: dismiss),
            dismiss: dismiss
        )
        popover.contentViewController = controller
        popover.contentSize = MessageReactionsPopover.size
        reactionDetailsPopover = popover
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxX)
        controller.monitorEscapeKey(in: controller.view.window, presentingWindow: window)
        Task { @MainActor [weak self, weak popover, weak controller] in
            await Task.yield()
            guard popover?.isShown == true, let controller else { return }
            controller.monitorEscapeKey(in: controller.view.window, presentingWindow: self?.window)
        }
    }
}
