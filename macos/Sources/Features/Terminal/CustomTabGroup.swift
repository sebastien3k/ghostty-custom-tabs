import AppKit
import Combine
import SwiftUI

/// A lightweight tab group used by hidden-titlebar windows.
///
/// Each tab remains an independent `NSWindow` and therefore retains its own
/// `TerminalController`, split tree, and Ghostty surfaces. The group simply
/// keeps those windows on the same frame and orders all but the selected tab
/// out, allowing us to draw the tab strip inside the content view.
final class CustomTabGroup: ObservableObject {
    private struct Member {
        weak var controller: TerminalController?
    }

    @Published private(set) var revision: UInt = 0
    @Published private(set) var selectedID: UUID?
    @Published private(set) var enteringIDs: Set<UUID> = []
    @Published private(set) var closingIDs: Set<UUID> = []

    private var members: [Member] = []
    private var selectionTransitionGeneration: UInt = 0

    var switchAnimation: Ghostty.Config.MacOSCustomTabSwitchAnimation

    init(switchAnimation: Ghostty.Config.MacOSCustomTabSwitchAnimation = .spring) {
        self.switchAnimation = switchAnimation
    }

    var controllers: [TerminalController] {
        members.compactMap(\.controller)
    }

    var count: Int {
        controllers.count
    }

    func contains(_ controller: TerminalController) -> Bool {
        controllers.contains { $0 === controller }
    }

    func add(
        _ controller: TerminalController,
        after sibling: TerminalController? = nil,
        animated: Bool = false
    ) {
        compact()
        guard !contains(controller) else { return }

        let member = Member(controller: controller)
        if let sibling,
           let index = members.firstIndex(where: { $0.controller === sibling }) {
            members.insert(member, at: index + 1)
        } else {
            members.append(member)
        }

        if selectedID == nil {
            selectedID = controller.customTabID
        }
        revision &+= 1

        if animated {
            enteringIDs.insert(controller.customTabID)
            DispatchQueue.main.async { [weak self] in
                withAnimation(.easeOut(duration: 0.16)) {
                    _ = self?.enteringIDs.remove(controller.customTabID)
                }
            }
        }
    }

    /// Animate a user-initiated close before removing the controller and its
    /// window. Structural removals such as detaching or closing a whole window
    /// continue to use `remove` directly without waiting for animation.
    @discardableResult
    func close(_ controller: TerminalController, completion: @escaping () -> Void) -> Bool {
        compact()
        guard contains(controller), !closingIDs.contains(controller.customTabID) else { return false }

        withAnimation(.easeIn(duration: 0.11)) {
            _ = closingIDs.insert(controller.customTabID)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [self] in
            withAnimation(.easeOut(duration: 0.13)) {
                remove(controller)
                closingIDs.remove(controller.customTabID)
            }
            completion()
        }
        return true
    }

    func remove(_ controller: TerminalController, selectNeighbor: Bool = true) {
        compact()
        guard let index = members.firstIndex(where: { $0.controller === controller }) else { return }
        selectionTransitionGeneration &+= 1
        resetWindowPresentation()
        let wasSelected = selectedID == controller.customTabID
        members.remove(at: index)
        revision &+= 1

        guard wasSelected else { return }
        selectedID = nil
        guard selectNeighbor, !members.isEmpty else { return }

        let nextIndex = min(index, members.count - 1)
        if let next = members[nextIndex].controller {
            select(next, usingFrameFrom: controller.window)
        }
    }

    func select(_ controller: TerminalController, usingFrameFrom sourceWindow: NSWindow? = nil) {
        compact()
        guard contains(controller), let targetWindow = controller.window else { return }

        let sourceController = selectedController
        let source = sourceWindow ?? sourceController?.window
        let frame = source?.frame
        let sourceIndex = sourceController.flatMap { selected in
            controllers.firstIndex { $0 === selected }
        }
        let targetIndex = controllers.firstIndex { $0 === controller }

        selectionTransitionGeneration &+= 1
        let generation = selectionTransitionGeneration
        resetWindowPresentation()
        selectedID = controller.customTabID

        for candidate in controllers where candidate !== controller && candidate !== sourceController {
            candidate.window?.orderOut(nil)
        }

        if let frame, !targetWindow.styleMask.contains(.fullScreen) {
            targetWindow.setFrame(frame, display: false)
        }

        let transition = resolvedSwitchAnimation
        if transition != .none,
           let sourceController,
           sourceController !== controller,
           let source,
           !source.styleMask.contains(.fullScreen),
           !targetWindow.styleMask.contains(.fullScreen),
           let sourceIndex,
           let targetIndex,
           transitionLayer(for: source) != nil,
           transitionLayer(for: targetWindow) != nil {
            let direction: CGFloat = targetIndex > sourceIndex ? 1 : -1
            animateSelection(
                from: source,
                to: targetWindow,
                direction: direction,
                transition: transition,
                generation: generation)
        } else {
            for candidate in controllers where candidate !== controller {
                candidate.window?.orderOut(nil)
            }
            targetWindow.makeKeyAndOrderFront(nil)
        }

        focus(controller)
        revision &+= 1
    }

    private var resolvedSwitchAnimation: Ghostty.Config.MacOSCustomTabSwitchAnimation {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           switchAnimation == .spring {
            return .fade
        }
        return switchAnimation
    }

    private func animateSelection(
        from sourceWindow: NSWindow,
        to targetWindow: NSWindow,
        direction: CGFloat,
        transition: Ghostty.Config.MacOSCustomTabSwitchAnimation,
        generation: UInt
    ) {
        guard let sourceLayer = transitionLayer(for: sourceWindow),
              let targetLayer = transitionLayer(for: targetWindow) else { return }
        let incomingOffset: CGFloat = transition == .spring ? direction * 12 : 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sourceLayer.opacity = 1
        sourceLayer.transform = CATransform3DIdentity
        targetLayer.opacity = 0
        targetLayer.transform = CATransform3DMakeTranslation(incomingOffset, 0, 0)
        CATransaction.commit()

        targetWindow.makeKeyAndOrderFront(nil)

        // Ordering a previously hidden window commits its layer tree. Start the
        // transition on the next runloop so the initial state is presented first.
        DispatchQueue.main.async { [weak self, weak sourceWindow, weak targetWindow] in
            guard let self,
                  let sourceWindow,
                  let targetWindow,
                  generation == selectionTransitionGeneration,
                  selectedID == (targetWindow.windowController as? TerminalController)?.customTabID else { return }

            let opacityDuration = transition == .spring ? 0.14 : 0.12
            let opacityTiming = CAMediaTimingFunction(name: .easeInEaseOut)

            let incomingOpacity = CABasicAnimation(keyPath: "opacity")
            incomingOpacity.fromValue = 0
            incomingOpacity.toValue = 1
            incomingOpacity.duration = opacityDuration
            incomingOpacity.timingFunction = opacityTiming

            let outgoingOpacity = CABasicAnimation(keyPath: "opacity")
            outgoingOpacity.fromValue = 1
            outgoingOpacity.toValue = 0
            outgoingOpacity.duration = opacityDuration
            outgoingOpacity.timingFunction = opacityTiming

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { [weak self, weak sourceWindow, weak targetWindow] in
                guard let self,
                      let sourceWindow,
                      let targetWindow,
                      generation == selectionTransitionGeneration else { return }
                sourceWindow.orderOut(nil)
                resetWindowPresentation([sourceWindow, targetWindow])
            }

            targetLayer.opacity = 1
            targetLayer.transform = CATransform3DIdentity
            sourceLayer.opacity = 0
            targetLayer.add(incomingOpacity, forKey: "customTabIncomingOpacity")
            sourceLayer.add(outgoingOpacity, forKey: "customTabOutgoingOpacity")

            if transition == .spring {
                let incomingPosition = CASpringAnimation(keyPath: "transform.translation.x")
                incomingPosition.fromValue = incomingOffset
                incomingPosition.toValue = 0
                incomingPosition.mass = 1
                incomingPosition.stiffness = 1_600
                incomingPosition.damping = 68
                incomingPosition.initialVelocity = 0
                incomingPosition.duration = incomingPosition.settlingDuration
                targetLayer.add(incomingPosition, forKey: "customTabIncomingPosition")

                let outgoingPosition = CABasicAnimation(keyPath: "transform.translation.x")
                outgoingPosition.fromValue = 0
                outgoingPosition.toValue = -direction * 5
                outgoingPosition.duration = opacityDuration
                outgoingPosition.timingFunction = opacityTiming
                sourceLayer.add(outgoingPosition, forKey: "customTabOutgoingPosition")
            }

            CATransaction.commit()
        }
    }

    private func focus(_ controller: TerminalController) {
        if let surface = controller.focusedSurface {
            controller.focusSurface(surface)
        }
    }

    private func transitionLayer(for window: NSWindow) -> CALayer? {
        (window.contentView as? TerminalViewContainer)?.customTabTransitionLayer
    }

    private func resetWindowPresentation(_ windows: [NSWindow]? = nil) {
        let windows = windows ?? controllers.compactMap(\.window)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for window in windows {
            guard let layer = transitionLayer(for: window) else { continue }
            layer.removeAnimation(forKey: "customTabIncomingOpacity")
            layer.removeAnimation(forKey: "customTabOutgoingOpacity")
            layer.removeAnimation(forKey: "customTabIncomingPosition")
            layer.removeAnimation(forKey: "customTabOutgoingPosition")
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
        }
        CATransaction.commit()
    }

    func select(at index: Int) {
        let controllers = controllers
        guard controllers.indices.contains(index) else { return }
        select(controllers[index])
    }

    func select(relativeOffset offset: Int) {
        let controllers = controllers
        guard !controllers.isEmpty,
              let selectedController,
              let index = controllers.firstIndex(where: { $0 === selectedController }) else { return }

        let next = (index + offset % controllers.count + controllers.count) % controllers.count
        select(controllers[next])
    }

    func move(_ controller: TerminalController, by offset: Int) {
        compact()
        guard offset != 0,
              let source = members.firstIndex(where: { $0.controller === controller }) else { return }

        let destination = max(0, min(members.count - 1, source + offset))
        guard source != destination else { return }

        let member = members.remove(at: source)
        members.insert(member, at: destination)
        revision &+= 1
    }

    private var selectedController: TerminalController? {
        guard let selectedID else { return nil }
        return controllers.first { $0.customTabID == selectedID }
    }

    private func compact() {
        members.removeAll { $0.controller == nil }
    }
}
