import AppKit
import QuartzCore
import SakuraCordModels
import SwiftUI

/// The Messages-style typing bubble: a capsule with a two-circle thought tail
/// whose three dots darken in a left-to-right wave while the bubble breathes.
///
/// Core Animation runs the loop in the render server, so a visible indicator
/// never redraws the footer or wakes the main thread.
@MainActor
final class TypingBubble {
    /// Proportions follow Messages' typing bubble, scaled so the body is
    /// exactly as tall as a one-line message bubble.
    private enum Metrics {
        private static var unit: CGFloat { NativeTimelineBubbleLayout.oneLineHeight / 36 }
        static var bodySize: CGSize { CGSize(width: 60 * unit, height: 36 * unit) }
        /// How far the tail's small circle reaches past the body's leading edge.
        static var leadingOverhang: CGFloat { 7.5 * unit }
        static var bottomOverhang: CGFloat { 4 * unit }
        static var dotDiameter: CGFloat { 9 * unit }
        static var dotSpacing: CGFloat { 13 * unit }
        static var cornerCircleDiameter: CGFloat { 11 * unit }
        static var cornerCircleInset: CGFloat { 3.5 * unit }
        static var tinyCircleDiameter: CGFloat { 6 * unit }
        static var tinyCircleOffset: CGPoint { CGPoint(x: -4.5 * unit, y: 0.7 * unit) }
    }

    static var size: CGSize {
        CGSize(
            width: Metrics.leadingOverhang + Metrics.bodySize.width,
            height: Metrics.bodySize.height + Metrics.bottomOverhang
        )
    }

    /// The body's leading edge, which lines up with incoming message bubbles.
    static var bodyLeadingInset: CGFloat { Metrics.leadingOverhang }
    static var bodyHeight: CGFloat { Metrics.bodySize.height }

    // Each dot darkens for just under half a cycle, trailing the previous one
    // by a quarter, so the wave crosses the bubble and briefly rests.
    private static let cycle: CFTimeInterval = 1.32
    private static let dotStagger: CFTimeInterval = 0.33
    private static let dimDotOpacity: Float = 0.5
    /// The loops are slow eases, so they need not redraw at ProMotion rates
    /// for as long as someone types.
    private static let loopFrameRate = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)

    private static let dotColor = NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
        case .darkAqua:
            NSColor(srgbRed: 0.68, green: 0.68, blue: 0.70, alpha: 1)
        default:
            NSColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1)
        }
    }

    /// The tail, body, and dots, laid out in a `size` frame from the origin.
    let layer = CALayer()
    private let body = CALayer()
    private let cornerCircle = CALayer()
    private let tinyCircle = CALayer()
    private let dots = (0 ..< 3).map { _ in CALayer() }

    init() {
        for sublayer in [tinyCircle, cornerCircle, body] {
            layer.addSublayer(sublayer)
        }
        dots.forEach(body.addSublayer)
        layOut()
    }

    func layOut() {
        let bodyFrame = CGRect(
            origin: CGPoint(x: Metrics.leadingOverhang, y: 0),
            size: Metrics.bodySize
        )
        layer.frame = CGRect(origin: .zero, size: Self.size)
        place(body, frame: bodyFrame)
        let corner = Metrics.cornerCircleDiameter
        place(cornerCircle, frame: CGRect(
            x: bodyFrame.minX + Metrics.cornerCircleInset - corner / 2,
            y: bodyFrame.maxY - corner,
            width: corner,
            height: corner
        ))
        let tiny = Metrics.tinyCircleDiameter
        place(tinyCircle, frame: CGRect(
            x: bodyFrame.minX + Metrics.tinyCircleOffset.x - tiny / 2,
            y: bodyFrame.maxY + Metrics.tinyCircleOffset.y - tiny / 2,
            width: tiny,
            height: tiny
        ))
        let dot = Metrics.dotDiameter
        for (index, layer) in dots.enumerated() {
            let centerX = bodyFrame.width / 2 + CGFloat(index - 1) * Metrics.dotSpacing
            place(layer, frame: CGRect(
                x: centerX - dot / 2,
                y: (bodyFrame.height - dot) / 2,
                width: dot,
                height: dot
            ))
        }
    }

    func stopAnimating() {
        ([body, cornerCircle, tinyCircle] + dots).forEach { $0.removeAllAnimations() }
    }

    private func place(_ layer: CALayer, frame: CGRect) {
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        layer.cornerRadius = min(frame.width, frame.height) / 2
    }

    func updateColors(for appearance: NSAppearance) {
        appearance.performAsCurrentDrawingAppearance {
            let fill = NativeTimelineBubbleDrawing.incomingFillColor.cgColor
            [body, cornerCircle, tinyCircle].forEach { $0.backgroundColor = fill }
            let dot = Self.dotColor.cgColor
            dots.forEach { $0.backgroundColor = dot }
        }
    }

    func startAnimating() {
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = Self.cycle * (reducesMotion ? 2 : 1)
        for (index, dot) in dots.enumerated() {
            let wave = CAKeyframeAnimation(keyPath: "opacity")
            wave.values = [Self.dimDotOpacity, 1, Self.dimDotOpacity, Self.dimDotOpacity]
            wave.keyTimes = [0, 0.22, 0.44, 1]
            wave.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
            wave.preferredFrameRateRange = Self.loopFrameRate
            let lag = Self.dotStagger / Self.cycle * duration * CFTimeInterval(index)
            wave.repeatOnMediaClock(cycle: duration, lead: -lag)
            dot.opacity = Self.dimDotOpacity
            dot.add(wave, forKey: "wave")
        }
        guard !reducesMotion else { return }
        body.add(breathing(to: 1.04, halfCycle: 1), forKey: "breathe")
        for circle in [cornerCircle, tinyCircle] {
            circle.add(breathing(to: 1.1, halfCycle: 0.5), forKey: "breathe")
        }
    }

    private func breathing(to scale: CGFloat, halfCycle: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = CATransform3DIdentity
        animation.toValue = TypingIndicator.scale(scale)
        animation.duration = halfCycle
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.preferredFrameRateRange = Self.loopFrameRate
        return animation
    }
}

/// Bubble mode's typing indicator. It sits where the next incoming bubble
/// would, and in group conversations a stack of the typists' avatars follows.
///
/// The footer only reserves the indicator's height. Its arrival, departure,
/// and avatar changes all run in Core Animation alongside the transcript
/// glide, so they stay smooth however busy the main thread is.
struct TypingBubbleIndicatorView: View {
    let model: AppModel
    let channel: Channel

    var body: some View {
        let showsAvatars = NativeTimelineBubbleLayout.showsAvatar(in: channel)
        let presentation = model.typingState.presentation(in: channel.id)
        // Typing events already carry each typist's guild profile.
        let typists = showsAvatars
            ? model.typingState.usersNewestFirst(in: channel.id).map {
                TypingIndicator.Typist(id: $0.id, name: $0.displayName, avatarURL: $0.avatarURL)
            }
            : []
        let leadingInset = NativeTimelineBubbleLayout.incomingBubbleMinX(
            showsAvatar: showsAvatars,
            settings: model.interfaceSettings
        )
        TypingIndicatorRepresentable(
            state: TypingIndicator.State(channelID: channel.id, typists: typists, presentation: presentation)
        )
        .frame(width: TypingIndicator.width, height: presentation == nil ? 0 : TypingIndicator.height)
        .padding(.leading, leadingInset - TypingBubble.bodyLeadingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
    }
}

private struct TypingIndicatorRepresentable: NSViewRepresentable {
    let state: TypingIndicator.State

    func makeNSView(context _: Context) -> TypingIndicator {
        TypingIndicator()
    }

    func updateNSView(_ view: TypingIndicator, context _: Context) {
        view.update(state)
    }
}

/// Draws the typing bubble and avatar stack bottom-aligned to its bounds.
/// When the footer collapses it to zero height, the content keeps drawing
/// above it while it shrinks away.
final class TypingIndicator: NSView {
    struct Typist: Equatable {
        let id: UserID
        let name: String
        let avatarURL: URL?
    }

    struct State: Equatable {
        let channelID: ChannelID
        /// Newest first: each new typist joins beside the bubble and pushes
        /// the others along, and anyone past the visible few folds into the
        /// count. Empty where avatars do not show.
        let typists: [Typist]
        /// Who is typing, or nil when nobody is.
        let presentation: String?

        var isTyping: Bool { presentation != nil }
    }

    private enum Metrics {
        static let maximumVisibleAvatars = 4
        static var bottomPadding: CGFloat { InterfaceScale.metric(6) }
        static var stackSpacing: CGFloat { InterfaceScale.metric(6) }
        static var avatarDiameter: CGFloat { InterfaceScale.metric(24) }
        static var avatarOverlap: CGFloat { InterfaceScale.metric(8) }
        static var ringWidth: CGFloat { InterfaceScale.metric(2) }
        static var countPadding: CGFloat { InterfaceScale.metric(4) }
        static var countFontSize: CGFloat { InterfaceScale.fontSize(10) }
        /// How long a new avatar waits for its picture before it shows its
        /// placeholder instead.
        static let pictureWait: Duration = .milliseconds(350)
    }

    static var height: CGFloat { TypingBubble.size.height + Metrics.bottomPadding }
    /// Room for the bubble, a full stack, and a two-digit count.
    static var width: CGFloat {
        stackX + CGFloat(Metrics.maximumVisibleAvatars) * avatarStep
            + Metrics.avatarOverlap + InterfaceScale.metric(40)
    }

    private static var stackX: CGFloat { TypingBubble.size.width + Metrics.stackSpacing }
    private static var avatarStep: CGFloat { Metrics.avatarDiameter - Metrics.avatarOverlap }

    private final class AvatarSlot {
        let layer = CALayer()
        var typist: Typist?
        var showsFallback = false
        /// A new avatar stays hidden while its picture loads.
        var isWaitingForPicture = false
        var load: Task<Void, Never>?
        var wait: Task<Void, Never>?

        func cancelLoading() {
            load?.cancel()
            wait?.cancel()
        }
    }

    private let content = CALayer()
    private let bubble = TypingBubble()
    private let count = CALayer()
    private let countText = CATextLayer()
    private var slots: [UserID: AvatarSlot] = [:]
    /// The slots on screen, newest first, including departing ones until
    /// their exit finishes.
    private var order: [UserID] = []
    private var appliedAvatarDiameter = Metrics.avatarDiameter
    private var state: State?
    private var isShown: Bool { state?.isTyping == true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        content.anchorPoint = CGPoint(x: 0, y: 1)
        content.isHidden = true
        layer?.addSublayer(content)
        content.addSublayer(bubble.layer)
        count.anchorPoint = CGPoint(x: 0, y: 0.5)
        count.opacity = 0
        count.addSublayer(countText)
        countText.alignmentMode = .center
        updateCountFont()
        content.addSublayer(count)
        setAccessibilityElement(false)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShown, let superview, let layer else { return nil }
        let local = content.convert(convert(point, from: superview), from: layer)
        let parts = [bubble.layer] + slots.values.map(\.layer) + (count.opacity > 0 ? [count] : [])
        return parts.contains { $0.frame.contains(local) } ? self : nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.bounds = CGRect(x: 0, y: 0, width: Self.width, height: TypingBubble.size.height)
        content.position = CGPoint(x: 0, y: bounds.maxY - Metrics.bottomPadding)
        bubble.layOut()
        if appliedAvatarDiameter != Metrics.avatarDiameter { resizeStack() }
        CATransaction.commit()
    }

    /// Interface Size changed: resize every avatar, ring, and the count,
    /// then lay the stack out again.
    private func resizeStack() {
        appliedAvatarDiameter = Metrics.avatarDiameter
        updateCountFont()
        count.bounds = .zero
        for slot in slots.values {
            size(slot.layer)
            slot.layer.mask = nil
            if slot.showsFallback { showPlaceholder(in: slot, arrives: false) }
        }
        updateStack(state?.typists ?? [], animated: false)
    }

    private func updateCountFont() {
        countText.font = NSFont.systemFont(ofSize: Metrics.countFontSize, weight: .semibold)
        countText.fontSize = Metrics.countFontSize
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        countText.contentsScale = scale
        slots.values.forEach { $0.layer.contentsScale = scale }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            bubble.stopAnimating()
        } else {
            viewDidChangeBackingProperties()
            updateColors()
            if isShown { bubble.startAnimating() }
        }
    }

    func update(_ newState: State) {
        guard newState != state else { return }
        let previous = state
        state = newState
        setAccessibilityElement(newState.presentation != nil)
        setAccessibilityLabel(newState.presentation)
        toolTip = newState.presentation
        // A different conversation replaces the indicator outright.
        let animates = previous?.channelID == newState.channelID && window != nil
        let wasTyping = previous?.isTyping == true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if newState.isTyping, !wasTyping {
            show(animated: animates)
            updateStack(newState.typists, animated: false)
        } else if !newState.isTyping, wasTyping {
            hide(animated: animates)
        } else if newState.isTyping {
            updateStack(newState.typists, animated: animates)
        }
        CATransaction.commit()
    }

    // MARK: Arrival and departure

    private func show(animated: Bool) {
        content.removeAnimation(forKey: "presence")
        content.isHidden = false
        content.opacity = 1
        content.transform = CATransform3DIdentity
        if window != nil { bubble.startAnimating() }
        guard animated else { return }
        // Grows out of its tail as the rows above glide up to make room, at
        // the speed and on the curve of a sent message.
        content.add(scaleFade(from: 0, to: 1), forKey: "presence")
    }

    private func hide(animated: Bool) {
        guard animated else {
            finishHiding()
            return
        }
        // Shrinks back into its tail as the rows glide down over it. The
        // layer holds its final state itself, so nothing reappears when the
        // animation ends.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !isShown else { return }
            finishHiding()
        }
        content.opacity = 0
        content.add(scaleFade(from: 1, to: 0), forKey: "presence")
        CATransaction.commit()
    }

    private func finishHiding() {
        // Hiding a layer implicitly cross-fades it, which would flash it back.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.removeAnimation(forKey: "presence")
        content.isHidden = true
        bubble.stopAnimating()
        updateStack([], animated: false)
        CATransaction.commit()
    }

    /// Fades between the opacities while scaling by the same amount, or
    /// toward `minimumScale` when that is larger; Reduce Motion only fades.
    private func scaleFade(
        from: CGFloat,
        to: CGFloat,
        minimumScale: CGFloat = 0.001,
        duration: CFTimeInterval = NativeTimelineSendTransitionTiming.duration,
        timing: CAMediaTimingFunction = NativeTimelineSendTransitionTiming.vertical
    ) -> CAAnimation {
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = from
        opacity.toValue = to
        var animations: [CAAnimation] = [opacity]
        if !reducesMotion {
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = Self.scale(max(from, minimumScale))
            scale.toValue = Self.scale(max(to, minimumScale))
            animations.append(scale)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.timingFunction = timing
        return group
    }

    // MARK: Avatar stack

    private func updateStack(_ typists: [Typist], animated: Bool) {
        let visible = Array(typists.prefix(Metrics.maximumVisibleAvatars))
        let visibleIDs = Set(visible.map(\.id))
        for id in order where !visibleIDs.contains(id) {
            guard let slot = slots.removeValue(forKey: id) else { continue }
            slot.cancelLoading()
            if animated {
                depart(slot.layer)
            } else {
                slot.layer.removeFromSuperlayer()
            }
        }
        order = visible.map(\.id)
        for (index, typist) in visible.enumerated() {
            let isNew = slots[typist.id] == nil
            let slot = slots[typist.id] ?? makeSlot(for: typist.id)
            load(typist, into: slot, arrives: isNew && animated)
            slot.layer.zPosition = CGFloat(visible.count - index)
            move(slot.layer, to: avatarPosition(at: index), animated: animated)
        }
        updateRings(animated: animated)
        updateCount(typists.count - visible.count, after: visible.count, animated: animated)
    }

    /// Cuts a ring in each avatar where the one in front of it overlaps,
    /// opening it as that avatar grows in.
    private func updateRings(animated: Bool) {
        for (index, id) in order.enumerated() {
            guard let slot = slots[id] else { continue }
            let isCovered = index > 0 && slots[order[index - 1]]?.isWaitingForPicture == false
            guard isCovered else {
                slot.layer.mask = nil
                continue
            }
            guard slot.layer.mask == nil else { continue }
            let mask = cutout(width: Metrics.avatarDiameter)
            slot.layer.mask = mask
            if animated, !reducesMotion {
                let open = spring("path")
                open.fromValue = cutoutPath(width: Metrics.avatarDiameter, ringScale: 0)
                open.toValue = mask.path
                mask.add(open, forKey: "open")
            }
        }
    }

    private func avatarPosition(at index: Int) -> CGPoint {
        CGPoint(x: Self.stackX + CGFloat(index) * Self.avatarStep, y: TypingBubble.bodyHeight / 2)
    }

    private func makeSlot(for id: UserID) -> AvatarSlot {
        let slot = AvatarSlot()
        size(slot.layer)
        slot.layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        slot.layer.position = avatarPosition(at: 0)
        slot.layer.masksToBounds = true
        slot.layer.contentsGravity = .resizeAspectFill
        slot.layer.contentsScale = window?.backingScaleFactor ?? 2
        content.addSublayer(slot.layer)
        slots[id] = slot
        return slot
    }

    private func size(_ avatar: CALayer) {
        let diameter = Metrics.avatarDiameter
        avatar.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        avatar.cornerRadius = diameter / 2
    }

    /// Shows the typist's picture. A new avatar whose picture still has to
    /// load waits for it, briefly, so it grows in with its picture rather
    /// than swapping a placeholder for it mid-animation.
    private func load(_ typist: Typist, into slot: AvatarSlot, arrives: Bool) {
        let previous = slot.typist
        slot.typist = typist
        guard previous == nil || previous?.avatarURL != typist.avatarURL else {
            if slot.showsFallback, previous?.name != typist.name {
                showPlaceholder(in: slot, arrives: false)
            }
            return
        }
        let isNew = previous == nil
        slot.cancelLoading()
        guard let url = typist.avatarURL else {
            showPlaceholder(in: slot, arrives: arrives)
            return
        }
        // Share the timeline's decoded avatars, so anyone with a visible
        // message shows their picture straight away.
        let dimension = NativeTimelineMediaKey.avatarPixelDimension
        if let cached = SharedDecodedImageLoader.shared.cachedImage(
            for: url, maximumPixelDimension: dimension, preparesForTimeline: true
        ) {
            show(cached, in: slot, arrives: arrives)
            return
        }
        if isNew {
            slot.isWaitingForPicture = true
            slot.layer.opacity = 0
            slot.wait = Task { @MainActor [weak self, weak slot] in
                try? await Task.sleep(for: Metrics.pictureWait)
                guard !Task.isCancelled, let self, let slot else { return }
                showPlaceholder(in: slot, arrives: true)
            }
        } else {
            showPlaceholder(in: slot, arrives: false)
        }
        slot.load = Task { @MainActor [weak self, weak slot] in
            let image = await SharedDecodedImageLoader.shared.image(
                for: url, maximumPixelDimension: dimension, priority: .visible, preparesForTimeline: true
            )
            guard !Task.isCancelled, let self, let slot, slot.typist?.avatarURL == url, let image else { return }
            show(image, in: slot, arrives: slot.isWaitingForPicture)
        }
    }

    private func showPlaceholder(in slot: AvatarSlot, arrives: Bool) {
        show(slot.typist.flatMap { fallbackImage(name: $0.name) }, in: slot, arrives: arrives, isPlaceholder: true)
    }

    private func show(_ image: CGImage?, in slot: AvatarSlot, arrives: Bool, isPlaceholder: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slot.layer.contents = image
        slot.showsFallback = isPlaceholder
        if slot.isWaitingForPicture {
            slot.isWaitingForPicture = false
            slot.wait?.cancel()
            slot.layer.opacity = 1
            updateRings(animated: arrives)
        }
        if arrives, isShown { arrive(slot.layer) }
        CATransaction.commit()
    }

    private static var fallbackImages: [String: CGImage] = [:]

    private func fallbackImage(name: String) -> CGImage? {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return Self.fallbackImage(name: name, colorScheme: isDark ? .dark : .light, scale: window?.backingScaleFactor ?? 2)
    }

    private static func fallbackImage(name: String, colorScheme: ColorScheme, scale: CGFloat) -> CGImage? {
        let key = "\(name.prefix(1).uppercased())@\(scale)-\(colorScheme)-\(Metrics.avatarDiameter)"
        if let image = fallbackImages[key] { return image }
        let renderer = ImageRenderer(
            content: AvatarView(name: name, url: nil, size: Metrics.avatarDiameter)
                .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = scale
        let image = renderer.cgImage
        fallbackImages[key] = image
        return image
    }

    private func updateCount(_ hidden: Int, after visibleCount: Int, animated: Bool) {
        let wasShowing = count.opacity > 0 && count.animation(forKey: "depart") == nil
        if hidden > 0 {
            countText.string = "+\(hidden)"
            let textSize = countText.preferredFrameSize()
            let diameter = Metrics.avatarDiameter
            // The last avatar covers the chip's leading edge, so the count
            // centers in the part that shows.
            let covered = Metrics.avatarOverlap
            let width = max(diameter, covered + ceil(textSize.width) + Metrics.countPadding * 2)
            if count.bounds.width != width {
                count.bounds = CGRect(x: 0, y: 0, width: width, height: diameter)
                count.cornerRadius = diameter / 2
                count.mask = cutout(width: width)
            }
            let textHeight = ceil(textSize.height)
            countText.frame = CGRect(
                x: covered, y: (diameter - textHeight) / 2, width: width - covered, height: textHeight
            )
            count.removeAnimation(forKey: "depart")
            count.opacity = 1
            if !wasShowing {
                count.position = avatarPosition(at: visibleCount)
                if animated { arrive(count) }
            } else {
                move(count, to: avatarPosition(at: visibleCount), animated: animated)
            }
        } else if wasShowing {
            count.opacity = 0
            if animated { count.add(departure(), forKey: "depart") }
        }
    }

    /// Removes a ring where the avatar before this one overlaps, so the
    /// stack separates cleanly over any timeline background.
    private func cutout(width: CGFloat) -> CAShapeLayer {
        let mask = CAShapeLayer()
        mask.frame = CGRect(x: 0, y: 0, width: width, height: Metrics.avatarDiameter)
        mask.path = cutoutPath(width: width, ringScale: 1)
        mask.fillRule = .evenOdd
        return mask
    }

    private func cutoutPath(width: CGFloat, ringScale: CGFloat) -> CGPath {
        let diameter = Metrics.avatarDiameter
        let ring = (diameter + Metrics.ringWidth * 2) * max(ringScale, 0.001)
        let previousCenter = CGPoint(x: Metrics.avatarOverlap - diameter / 2, y: diameter / 2)
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: width, height: diameter))
        path.addEllipse(in: CGRect(
            x: previousCenter.x - ring / 2, y: previousCenter.y - ring / 2, width: ring, height: ring
        ))
        return path
    }

    // MARK: Avatar motion

    private var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private static let springDuration: CFTimeInterval = 0.35
    private static let springBounce: CGFloat = 0.25

    private func spring(_ keyPath: String) -> CASpringAnimation {
        let spring = CASpringAnimation(perceptualDuration: Self.springDuration, bounce: Self.springBounce)
        spring.keyPath = keyPath
        spring.duration = spring.settlingDuration
        return spring
    }

    private func move(_ layer: CALayer, to position: CGPoint, animated: Bool) {
        let from = layer.presentation()?.position ?? layer.position
        layer.position = position
        guard animated, from != position, !reducesMotion else { return }
        let slide = spring("position")
        slide.fromValue = from
        slide.toValue = position
        layer.add(slide, forKey: "move")
    }

    /// A new typist grows in beside the bubble, or under Reduce Motion
    /// fades in.
    private func arrive(_ layer: CALayer) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.springDuration
        layer.add(fade, forKey: "arriveFade")
        guard !reducesMotion else { return }
        let scale = spring("transform")
        var start = CATransform3DMakeTranslation(-Metrics.avatarDiameter / 2, 0, 0)
        start = CATransform3DScale(start, 0.3, 0.3, 1)
        scale.fromValue = start
        scale.toValue = CATransform3DIdentity
        layer.add(scale, forKey: "arrive")
    }

    /// A flat scale, which stays affine so every renderer honours it.
    static func scale(_ factor: CGFloat) -> CATransform3D {
        CATransform3DMakeScale(factor, factor, 1)
    }

    private func departure() -> CAAnimation {
        scaleFade(from: 1, to: 0, minimumScale: 0.3, duration: 0.2, timing: CAMediaTimingFunction(name: .easeIn))
    }

    private func depart(_ layer: CALayer) {
        CATransaction.begin()
        layer.opacity = 0
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        layer.add(departure(), forKey: "depart")
        CATransaction.commit()
    }

    private func updateColors() {
        bubble.updateColors(for: effectiveAppearance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for slot in slots.values where slot.showsFallback {
            slot.layer.contents = slot.typist.flatMap { fallbackImage(name: $0.name) }
        }
        CATransaction.commit()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            count.backgroundColor = NativeTimelineBubbleDrawing.incomingFillColor.cgColor
            countText.foregroundColor = NSColor.secondaryLabelColor.cgColor
        }
    }
}
