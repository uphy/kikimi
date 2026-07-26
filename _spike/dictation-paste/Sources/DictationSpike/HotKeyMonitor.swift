import Carbon.HIToolbox
import Foundation

/// Carbon `RegisterEventHotKey`, chosen over `NSEvent.addGlobalMonitorForEvents`
/// because it needs no Input Monitoring permission and delivers key-up as well
/// as key-down — required for the press-and-hold ("record while held") gesture.
///
/// Whether `kEventHotKeyReleased` fires reliably when the modifier is lifted
/// before the main key is one of the things this spike is here to measure.
final class HotKeyMonitor {
    enum Event {
        case pressed(UInt32)
        case released(UInt32)
    }

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private let onEvent: (Event) -> Void

    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context -> OSStatus in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.dispatch(event)
                return noErr
            },
            types.count,
            &types,
            context,
            &handler
        )
    }

    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B4B_4D49), id: id)  // 'KKMI'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            refs.append(ref)
        } else {
            Log.write("hotkey registration failed: id=\(id) status=\(status)")
        }
    }

    private func dispatch(_ event: EventRef) {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else { return }

        switch Int(GetEventKind(event)) {
        case kEventHotKeyPressed: onEvent(.pressed(hotKeyID.id))
        case kEventHotKeyReleased: onEvent(.released(hotKeyID.id))
        default: break
        }
    }

    deinit {
        for ref in refs.compactMap({ $0 }) {
            UnregisterEventHotKey(ref)
        }
        if let handler {
            RemoveEventHandler(handler)
        }
    }
}
