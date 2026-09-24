import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon's `RegisterEventHotKey`.
///
/// Unlike an event tap, this needs no Accessibility or Input Monitoring permission
/// and works inside the App Sandbox.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private static let signature: OSType = 0x4F50_5348 // 'OPSH'
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var registered: [UInt32: (Shortcut, () -> Void)] = [:]
    private var handlerRef: EventHandlerRef?
    private var pauseCount = 0

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            Task { @MainActor in HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    /// Registers (or replaces) the hotkey with `id`. Returns false if the combination is taken.
    @discardableResult
    func register(id: UInt32, shortcut: Shortcut, handler: @escaping () -> Void) -> Bool {
        unregister(id: id)
        registered[id] = (shortcut, handler)
        return pauseCount > 0 ? true : install(id: id, shortcut: shortcut)
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        registered[id] = nil
    }

    func unregisterAll(in range: ClosedRange<UInt32>) {
        for id in registered.keys where range.contains(id) { unregister(id: id) }
    }

    /// Temporarily disables all hotkeys, e.g. while recording a new shortcut.
    func pause() {
        pauseCount += 1
        guard pauseCount == 1 else { return }
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    func resume() {
        guard pauseCount > 0 else { return }
        pauseCount -= 1
        guard pauseCount == 0 else { return }
        for (id, entry) in registered { install(id: id, shortcut: entry.0) }
    }

    @discardableResult
    private func install(id: UInt32, shortcut: Shortcut) -> Bool {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    private func fire(_ id: UInt32) {
        guard pauseCount == 0 else { return }
        registered[id]?.1()
    }
}
