import AppKit
import SwiftUI

extension NativeTimelineCanvasView {
    /// Poll voters and reaction users share the system popover and dismissal path.
    func presentMessagePeoplePopover<Content: View>(
        relativeTo anchor: CGRect,
        @ViewBuilder content: (NSPopover) -> Content
    ) -> NSPopover? {
        guard window != nil, !anchor.isNull, !anchor.isEmpty else { return nil }
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = StablePopoverHostingController(
            rootView: content(popover), dismiss: { [weak popover] in popover?.close() }
        )
        popover.contentViewController = controller
        popover.contentSize = MessagePeoplePopoverLayout.size
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxX)
        controller.monitorEscapeKey(in: controller.view.window, presentingWindow: window)
        Task { @MainActor [weak self, weak popover, weak controller] in
            await Task.yield()
            guard popover?.isShown == true, let controller else { return }
            controller.monitorEscapeKey(in: controller.view.window, presentingWindow: self?.window)
        }
        return popover
    }
}
