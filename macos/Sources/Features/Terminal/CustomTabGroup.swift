import AppKit
import Combine
import GhosttyKit
import SwiftUI

/// The terminal state owned by one in-content tab.
///
/// A custom tab is intentionally not an `NSWindow`. Every session keeps its
/// own split tree and presentation state while a single `TerminalController`
/// owns the persistent window used to display the selected session.
final class CustomTabSession: ObservableObject, Identifiable {
    let id = UUID()

    @Published private(set) var title: String = "👻"
    @Published var icon: String?
    @Published private(set) var bell: Bool = false

    var surfaceTree: SplitTree<Ghostty.SurfaceView> {
        didSet { rebuildObservers() }
    }

    weak var focusedSurface: Ghostty.SurfaceView? {
        didSet { rebuildObservers() }
    }

    var titleOverride: String? {
        didSet { updateTitle() }
    }

    private let ghostty: Ghostty.App
    private var cancellables: Set<AnyCancellable> = []

    init(
        ghostty: Ghostty.App,
        surfaceTree: SplitTree<Ghostty.SurfaceView>,
        focusedSurface: Ghostty.SurfaceView? = nil
    ) {
        self.ghostty = ghostty
        self.surfaceTree = surfaceTree
        self.focusedSurface = focusedSurface ?? surfaceTree.first
        rebuildObservers()
    }

    func updateComputedTitle(_ title: String) {
        guard titleOverride == nil else { return }
        self.title = title
    }

    private func rebuildObservers() {
        cancellables.removeAll()

        if let focusedSurface = focusedSurface ?? surfaceTree.first {
            focusedSurface.$title
                .combineLatest(focusedSurface.$bell)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _ in self?.updateTitle() }
                .store(in: &cancellables)
        }

        surfaceTree.valuesPublisher(
            valueKeyPath: \.bell,
            publisherKeyPath: \.$bell)
            .map { $0.values.contains(true) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.bell = $0 }
            .store(in: &cancellables)

        updateTitle()
    }

    private func updateTitle() {
        let surface = focusedSurface ?? surfaceTree.first
        let base = titleOverride ?? surface?.title ?? "👻"
        if surface?.bell == true, ghostty.config.bellFeatures.contains(.title) {
            title = "🔔 \(base)"
        } else {
            title = base
        }
    }
}

/// A window-owned group of independent terminal sessions.
///
/// The group has one persistent host window. Selecting a tab asks that host to
/// display the session's split tree; it never creates, orders, or replaces an
/// `NSWindow`.
final class CustomTabGroup: ObservableObject {
    @Published private(set) var revision: UInt = 0
    @Published private(set) var selectedID: UUID?
    @Published private(set) var enteringIDs: Set<UUID> = []
    @Published private(set) var closingIDs: Set<UUID> = []
    @Published private(set) var sessions: [CustomTabSession]

    weak var host: TerminalController?
    var switchAnimation: Ghostty.Config.MacOSCustomTabSwitchAnimation

    init(
        host: TerminalController,
        initialSession: CustomTabSession,
        switchAnimation: Ghostty.Config.MacOSCustomTabSwitchAnimation = .spring
    ) {
        self.host = host
        self.sessions = [initialSession]
        self.selectedID = initialSession.id
        self.switchAnimation = switchAnimation
    }

    var count: Int {
        sessions.count
    }

    var selectedSession: CustomTabSession? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    func session(containing surface: Ghostty.SurfaceView) -> CustomTabSession? {
        sessions.first { $0.surfaceTree.contains(surface) }
    }

    func contains(_ session: CustomTabSession) -> Bool {
        sessions.contains { $0 === session }
    }

    func restore(
        sessions restoredSessions: [CustomTabSession],
        selected: CustomTabSession
    ) {
        guard restoredSessions.contains(where: { $0 === selected }) else { return }
        sessions = restoredSessions
        selectedID = selected.id
        revision &+= 1
    }

    func add(
        _ session: CustomTabSession,
        after sibling: CustomTabSession? = nil,
        animated: Bool = false
    ) {
        guard !contains(session) else { return }

        if let sibling,
           let index = sessions.firstIndex(where: { $0 === sibling }) {
            sessions.insert(session, at: index + 1)
        } else {
            sessions.append(session)
        }

        revision &+= 1
        if animated {
            enteringIDs.insert(session.id)
            DispatchQueue.main.async { [weak self] in
                withAnimation(.easeOut(duration: 0.16)) {
                    _ = self?.enteringIDs.remove(session.id)
                }
            }
        }
    }

    func select(_ session: CustomTabSession) {
        guard contains(session) else { return }
        guard selectedID != session.id else {
            host?.focusSelectedCustomTab()
            return
        }

        let previous = selectedSession
        selectedID = session.id
        host?.activateCustomTab(session, replacing: previous)
        revision &+= 1
    }

    @discardableResult
    func close(_ session: CustomTabSession, completion: @escaping () -> Void = {}) -> Bool {
        guard contains(session), !closingIDs.contains(session.id) else { return false }

        // Remove immediately so repeated close clicks always operate on the tab
        // that moves under the pointer. SwiftUI still animates the remaining
        // tabs into place, but session lifetime is no longer delayed by it.
        withAnimation(.easeOut(duration: 0.13)) {
            remove(session)
        }
        completion()
        return true
    }

    func remove(_ session: CustomTabSession, selectNeighbor: Bool = true) {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        let wasSelected = selectedID == session.id
        sessions.remove(at: index)
        revision &+= 1

        guard wasSelected else {
            host?.customTabDidRemove(session)
            return
        }
        selectedID = nil
        guard selectNeighbor, !sessions.isEmpty else {
            host?.customTabDidRemove(session)
            return
        }

        let nextIndex = min(index, sessions.count - 1)
        let next = sessions[nextIndex]
        selectedID = next.id
        host?.activateCustomTab(next, replacing: session)
        host?.customTabDidRemove(session)
    }

    func select(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        select(sessions[index])
    }

    func select(relativeOffset offset: Int) {
        guard !sessions.isEmpty,
              let selectedSession,
              let index = sessions.firstIndex(where: { $0 === selectedSession }) else { return }

        let next = (index + offset % sessions.count + sessions.count) % sessions.count
        select(sessions[next])
    }

    func move(_ session: CustomTabSession, by offset: Int) {
        guard offset != 0,
              let source = sessions.firstIndex(where: { $0 === session }) else { return }

        let destination = max(0, min(sessions.count - 1, source + offset))
        guard source != destination else { return }

        let member = sessions.remove(at: source)
        sessions.insert(member, at: destination)
        revision &+= 1
    }
}
