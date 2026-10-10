import AppKit
import CoreText
import OSLog
import SakuraCordModels
import SwiftUI

struct NativeMemberListView: NSViewRepresentable {
    @Environment(\.profileCosmeticPolicy) var cosmeticPolicy
    @Environment(\.serverTagCardModel) var serverTagCardModel
    var sections: [MemberSection]
    let customEmojiURLsByID: CustomEmojiImageURLs
    let profilePresentation: ProfilePresentationState?
    let isProfilePresented: Bool
    let selectMember: (Member) -> Void
    let dismissProfile: () -> Void
    let runsPerformanceAutoScroll: Bool
    let viewportIdentity: ChannelID?
    var presentation = NativeMemberListPresentation()
    var onViewportRange: (ClosedRange<Int>) -> Void = { _ in }

    var openProfile: ((ProfilePresentationState) -> Void)?
    var rowAccessory: ((Member) -> AnyView)?
    var rowMenu: ((Member) -> NSMenu?)?
    var rowAccessibilityActions: ((Member) -> [NSAccessibilityCustomAction])?
    var contentIdentity: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        var parent = self
        let ignored = serverTagCardModel?.ignoredUsers.ignoredUserIDs ?? []
        parent.presentation.ignoredUserIDs = ignored
        if !ignored.isEmpty {
            parent.sections = sections.map { section in
                let members = section.members.map { member in
                    guard ignored.contains(member.id), !presentation.presenceHiddenUserIDs.contains(member.id) else { return member }
                    var member = member
                    member.activityText = "Ignored"
                    member.customStatus = nil
                    member.isListeningToMusic = false
                    return member
                }
                return MemberSection(id: section.id, title: section.title, colorHex: section.colorHex,
                                     totalCount: section.totalCount, members: members,
                                     gatewayStartIndex: section.gatewayStartIndex, isLoadingSkeleton: section.isLoadingSkeleton)
            }
        }
        context.coordinator.update(parent: parent, scrollView: scrollView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        (scrollView as? NativeMemberListScrollView)?
            .inputPerformanceProbe.invalidate()
        coordinator.stop()
        scrollView.documentView = nil
    }

    typealias Coordinator = NativeMemberListCoordinator
}

@MainActor
final class NativeMemberListScrollView: NSScrollView {
    let inputPerformanceProbe = ScrollInputPerformanceProbe(
        surface: .memberList
    )
    var appearanceDidChange: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        super.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        synchronizeCanvasFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackgroundForEffectiveAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundForEffectiveAppearance()
        appearanceDidChange?()
    }

    private func updateBackgroundForEffectiveAppearance() {
        backgroundColor = .clear
        needsDisplay = true
        contentView.needsDisplay = true
        documentView?.needsDisplay = true
    }

    func synchronizeCanvasFrame() {
        guard let canvas = documentView as? NativeMemberListCanvasView else { return }
        let targetSize = NSSize(
            width: max(0, contentSize.width),
            height: max(1, canvas.contentHeight)
        )
        guard canvas.frame.size != targetSize else { return }
        canvas.frame.size = targetSize
        canvas.needsDisplay = true
        canvas.updateVisibleOverlaysAndPrewarming(force: true)
    }
}
