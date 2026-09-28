import AppKit

extension TerminalRestorableState {
    struct CustomTabState<ViewType: NSView & Codable & Identifiable>: Codable {
        let index: Int
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>
        let titleOverride: String?
        let icon: String?
    }

    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 5 (1.2.3)
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>

        // MARK: - Version 7 (1.3.0)
        let effectiveFullscreenMode: FullscreenMode?
        let tabColor: TerminalTabColor?
        let titleOverride: String?

        // MARK: - Version 8 (custom tab host)
        let customTabs: [CustomTabState<ViewType>]?
        let selectedCustomTabIndex: Int?
        let selectedCustomTabIcon: String?
    }
}

extension TerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    init(from controller: TerminalController) {
        let group = controller.customTabGroup
        let selected = group?.selectedSession
        let selectedIndex = selected.flatMap { selected in
            group?.sessions.firstIndex { $0 === selected }
        }

        self.init(
            focusedSurface: controller.focusedSurface?.id.uuidString,
            surfaceTree: controller.surfaceTree,
            effectiveFullscreenMode: controller.fullscreenStyle?.fullscreenMode,
            tabColor: (controller.window as? TerminalWindow)?.tabColor,
            titleOverride: controller.titleOverride,
            customTabs: group?.sessions.enumerated().compactMap { index, session in
                guard session !== selected else { return nil }
                return .init(
                    index: index,
                    focusedSurface: session.focusedSurface?.id.uuidString,
                    surfaceTree: session.surfaceTree,
                    titleOverride: session.titleOverride,
                    icon: session.icon)
            },
            selectedCustomTabIndex: selectedIndex,
            selectedCustomTabIcon: selected?.icon,
        )
    }
}
