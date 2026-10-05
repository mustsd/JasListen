import SwiftUI

extension View {
    /// Adds the macOS transport keys: the space bar plays or pauses, and the
    /// left and right arrow keys move back and forward. Other platforms are
    /// left unchanged.
    ///
    /// A local event monitor is used rather than `onKeyPress`, so the keys work
    /// wherever focus happens to be, and rather than `keyboardShortcut`, so a
    /// text field being edited (naming a lesson, for example) keeps its spaces,
    /// arrow keys, and caret movement.
    func macPlaybackKeys(
        togglePlayPause: @escaping () -> Void,
        skipBackward: @escaping () -> Void,
        skipForward: @escaping () -> Void
    ) -> some View {
        #if os(macOS)
        modifier(MacPlaybackShortcuts(
            togglePlayPause: togglePlayPause,
            skipBackward: skipBackward,
            skipForward: skipForward
        ))
        #else
        self
        #endif
    }
}

#if os(macOS)
import AppKit

private struct MacPlaybackShortcuts: ViewModifier {
    let togglePlayPause: () -> Void
    let skipBackward: () -> Void
    let skipForward: () -> Void

    @State private var monitor: Any?
    @State private var hostWindow: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(HostingWindowReader { hostWindow = $0 })
            .onAppear(perform: installMonitor)
            .onDisappear(perform: removeMonitor)
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only the window in use answers its transport keys, so a second
            // JasListen window keeps its own player.
            if let hostWindow, NSApp.keyWindow !== hostWindow { return event }
            switch MacPlaybackKeyCommand(event: event) {
            case .togglePlayPause:
                // A held space bar must not flip playback back and forth.
                if !event.isARepeat { togglePlayPause() }
                return nil
            case .skipBackward:
                skipBackward()
                return nil
            case .skipForward:
                skipForward()
                return nil
            case nil:
                return event
            }
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Reports the window that hosts the player. SwiftUI does not expose it, and the
/// transport keys should answer only while that window is the one in use.
private struct HostingWindowReader: NSViewRepresentable {
    let report: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window is attached only after the view joins the hierarchy.
        DispatchQueue.main.async { report(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { report(nsView.window) }
    }
}

/// One of the transport keys the player answers.
private enum MacPlaybackKeyCommand {
    case togglePlayPause
    case skipBackward
    case skipForward

    /// `nil` when the event belongs to something else, so text fields, sheets,
    /// open panels, menus, and modified keys keep working normally.
    init?(event: NSEvent) {
        // Naming an import, renaming a lesson, alerts, and open panels all own
        // their keys while they are up.
        guard NSApp.modalWindow == nil, NSApp.keyWindow?.isSheet != true else { return nil }
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView { return nil }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }

        switch event.specialKey {
        case .leftArrow:
            self = .skipBackward
        case .rightArrow:
            self = .skipForward
        default:
            guard event.charactersIgnoringModifiers == " " else { return nil }
            self = .togglePlayPause
        }
    }
}
#endif
