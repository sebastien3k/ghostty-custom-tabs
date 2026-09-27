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

        let source = sourceWindow ?? selectedController?.window
        let frame = source?.frame
        selectedID = controller.customTabID

        for candidate in controllers where candidate !== controller {
            candidate.window?.orderOut(nil)
        }

        if let frame, !targetWindow.styleMask.contains(.fullScreen) {
            targetWindow.setFrame(frame, display: true)
        }

        targetWindow.makeKeyAndOrderFront(nil)
        if let surface = controller.focusedSurface {
            controller.focusSurface(surface)
        }
        revision &+= 1
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

struct CustomTabBarView: View {
    @ObservedObject var group: CustomTabGroup
    @ObservedObject var controller: TerminalController
    let backgroundColor: Color
    let backgroundOpacity: Double
    let selectedTabBackgroundOpacity: Double

    var body: some View {
        let controllers = group.controllers

        ZStack {
            CustomTabWindowDragRegion()

            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(controllers, id: \.customTabID) { candidate in
                            CustomTabButton(
                                controller: candidate,
                                isSelected: group.selectedID == candidate.customTabID,
                                isEntering: group.enteringIDs.contains(candidate.customTabID),
                                isClosing: group.closingIDs.contains(candidate.customTabID),
                                selectedBackgroundOpacity: selectedTabBackgroundOpacity,
                                select: { group.select(candidate) },
                                close: { candidate.closeTab(nil) })
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.vertical, 5)
                }

                Button(action: { controller.newTab(nil) }, label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                })
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Tab")
                .padding(.trailing, 8)
            }
        }
        .frame(height: 36)
        .background(backgroundColor.opacity(backgroundOpacity))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal tabs")
    }
}

private struct CustomTabButton: View {
    @ObservedObject var controller: TerminalController
    let isSelected: Bool
    let isEntering: Bool
    let isClosing: Bool
    let selectedBackgroundOpacity: Double
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    private var iconFont: Font {
        let candidates = [
            (controller.window as? TerminalWindow)?.titlebarFont?.fontName,
            "Symbols Nerd Font Mono",
            "CaskaydiaCove Nerd Font",
            "JetBrainsMono Nerd Font",
        ]

        if let name = candidates.compactMap({ $0 }).first(where: { NSFont(name: $0, size: 11) != nil }) {
            return .custom(name, size: 11)
        }
        return .system(size: 11)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 7) {
                if let icon = controller.customTabIcon {
                    Text(icon)
                        .font(iconFont)
                        .fixedSize()
                        .frame(minWidth: 14, minHeight: 14)
                        .padding(.horizontal, 2)
                        .accessibilityHidden(true)
                }

                Text(controller.customTabTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Always reserve space so hover does not resize the title
                // or move the selection hit area underneath the pointer.
                Color.clear
                    .frame(width: 16, height: 16)
            }
            .font(.system(size: 12, weight: isSelected ? .medium : .regular))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .frame(minWidth: 92, idealWidth: 150, maxWidth: 210, minHeight: 26)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(selectedBackgroundOpacity) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(isSelected ? 0.10 : 0), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                CustomTabSelectionButton(
                    action: select,
                    icon: controller.customTabIcon,
                    setIcon: { controller.customTabIcon = $0 },
                    accessibilityLabel: controller.customTabTitle,
                    isSelected: isSelected)
            }

            if isSelected || isHovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Tab")
                .padding(.trailing, 10)
                .zIndex(1)
            } else if controller.bell {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
                    .frame(width: 16, height: 16)
                    .padding(.trailing, 10)
                    .help("Terminal needs attention")
                    .accessibilityLabel("Terminal needs attention")
            }
        }
        .opacity(isEntering || isClosing ? 0 : 1)
        .scaleEffect(isClosing ? 0.96 : (isEntering ? 0.98 : 1))
        .animation(.easeOut(duration: 0.16), value: isEntering)
        .animation(.easeIn(duration: 0.11), value: isClosing)
        .allowsHitTesting(!isClosing)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.08), value: isHovering)
        .animation(.easeOut(duration: 0.08), value: isSelected)
        .accessibilityElement(children: .contain)
    }
}

/// An AppKit button is used for tab selection so a click activates the tab
/// even when the Ghostty window is not currently key. SwiftUI buttons consume
/// that first click to activate the window on some macOS versions.
private struct CustomTabSelectionButton: NSViewRepresentable {
    let action: () -> Void
    let icon: String?
    let setIcon: (String?) -> Void
    let accessibilityLabel: String
    let isSelected: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action, setIcon: setIcon)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = FirstMouseButton()
        button.title = ""
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectTab)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        context.coordinator.setIcon = setIcon
        button.menu = context.coordinator.makeMenu(selectedIcon: icon)
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilitySelected(isSelected)
    }

    final class Coordinator: NSObject {
        private struct IconChoice {
            let name: String
            let glyph: String
        }

        private static let choices = [
            IconChoice(name: "Terminal", glyph: "\u{f489}"),
            IconChoice(name: "Code", glyph: "\u{f121}"),
            IconChoice(name: "Server", glyph: "\u{f233}"),
            IconChoice(name: "Database", glyph: "\u{f1c0}"),
            IconChoice(name: "Container", glyph: "\u{f308}"),
            IconChoice(name: "Git Branch", glyph: "\u{e725}"),
        ]

        var action: () -> Void
        var setIcon: (String?) -> Void

        init(action: @escaping () -> Void, setIcon: @escaping (String?) -> Void) {
            self.action = action
            self.setIcon = setIcon
        }

        @objc func selectTab() {
            action()
        }

        func makeMenu(selectedIcon: String?) -> NSMenu {
            let menu = NSMenu(title: "Tab Icon")

            for choice in Self.choices {
                let item = NSMenuItem(
                    title: choice.name,
                    action: #selector(chooseIcon(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = choice.glyph
                item.state = selectedIcon == choice.glyph ? .on : .off
                menu.addItem(item)
            }

            menu.addItem(.separator())

            let custom = NSMenuItem(
                title: "Custom Glyph…",
                action: #selector(chooseCustomIcon),
                keyEquivalent: "")
            custom.target = self
            menu.addItem(custom)

            let clear = NSMenuItem(
                title: "Clear Icon",
                action: #selector(clearIcon),
                keyEquivalent: "")
            clear.target = self
            clear.isEnabled = selectedIcon != nil
            menu.addItem(clear)

            return menu
        }

        @objc private func chooseIcon(_ sender: NSMenuItem) {
            guard let glyph = sender.representedObject as? String else { return }
            setIcon(glyph)
        }

        @objc private func clearIcon() {
            setIcon(nil)
        }

        @objc private func chooseCustomIcon() {
            let alert = NSAlert()
            alert.messageText = "Custom Tab Glyph"
            alert.informativeText = "Paste one Nerd Font glyph. It applies only to this tab."
            alert.addButton(withTitle: "Set Glyph")
            alert.addButton(withTitle: "Cancel")

            let input = NSTextField(string: "")
            input.placeholderString = "Glyph"
            input.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
            alert.accessoryView = input
            alert.window.initialFirstResponder = input

            guard alert.runModal() == .alertFirstButtonReturn,
                  let glyph = input.stringValue.first else { return }
            setIcon(String(glyph))
        }
    }

    private final class FirstMouseButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }
    }
}

private struct CustomTabWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
