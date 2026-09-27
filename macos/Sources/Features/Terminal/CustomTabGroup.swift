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

    func add(_ controller: TerminalController, after sibling: TerminalController? = nil) {
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
    let selectedBackgroundOpacity: Double
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: select) {
                HStack(spacing: 7) {
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.customTabTitle)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

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
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
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
