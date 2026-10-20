import AppKit
import Carbon
import Observation

/// Display-local logical points, with the origin at the display's top left.
struct ScreenCaptureRegion: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let displaySize: CGSize
    let rect: CGRect

    static func rectangle(from start: CGPoint, to end: CGPoint, bounds: CGRect) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
    }
}

@MainActor
final class RegionScreenshotSelector {
    private var panel: ProtectedAnswerPanel?
    private var continuation: CheckedContinuation<ScreenCaptureRegion?, Never>?
    private var escapeKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var screenObserver: NSObjectProtocol?

    func select(on screen: NSScreen) async -> ScreenCaptureRegion? {
        guard continuation == nil,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            // Leave existing answer and main windows in place throughout selection.
            NSApp.unhideWithoutActivation()
            let panel = preparePanel(frame: screen.frame)
            let view = panel.contentView as! RegionSelectionView
            view.onSelection = { [weak self] rect in
                self?.finish(.init(displayID: number.uint32Value, displaySize: screen.frame.size, rect: rect))
            }
            view.onCancel = { [weak self] in self?.cancel() }
            view.escapeAvailable = registerEscape()
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
            panel.orderFrontRegardless()
        }
    }

    /// Tests can inspect the policy before the panel is ever ordered onto the screen.
    func preparePanel(frame: CGRect) -> ProtectedAnswerPanel {
        let panel = ProtectedAnswerPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("regionScreenshotSelector")
        panel.sharingType = .none
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = RegionSelectionView(frame: CGRect(origin: .zero, size: frame.size))
        ScreenCapturePrivacy.apply(to: panel)
        self.panel = panel
        return panel
    }

    private func registerEscape() -> Bool {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x43505247 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<RegionScreenshotSelector>.fromOpaque(context).takeUnretainedValue().cancel() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return false }
        return RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x43505247, id: 1),
                                   GetApplicationEventTarget(), 0, &escapeKey) == noErr
    }

    func cancel() { finish(nil) }

    private func finish(_ result: ScreenCaptureRegion?) {
        if let escapeKey { UnregisterEventHotKey(escapeKey) }
        if let handler { RemoveEventHandler(handler) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        escapeKey = nil
        handler = nil
        screenObserver = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
        let completion = continuation
        continuation = nil
        completion?.resume(returning: result)
    }
}

/// No system crosshair cursor or screenshot HUD: all selection graphics belong
/// to this protected window; the ordinary system pointer remains unchanged.
@MainActor
final class RegionSelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var escapeAvailable = true { didSet { needsDisplay = true } }
    private var start: CGPoint?
    private var end: CGPoint?
    private var tooSmall = false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.22).setFill()
        bounds.fill()
        if let start, let end {
            let rect = ScreenCaptureRegion.rectangle(from: start, to: end, bounds: bounds)
            if !rect.isNull {
                let context = NSGraphicsContext.current!.cgContext
                context.saveGState()
                context.setBlendMode(.clear)
                context.fill(rect)
                context.restoreGState()
                NSColor.white.setStroke()
                let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 1
                border.stroke()
            }
        }
        let hint = tooSmall ? "范围太小，请重新拖拽 · 右键取消" : (escapeAvailable
            ? "拖拽选择区域 · 松开完成 · Esc / 右键取消"
            : "拖拽选择区域 · 松开完成 · 右键取消（Esc 被占用）")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
        let size = (hint as NSString).size(withAttributes: attributes)
        let bubble = CGRect(x: max(8, (bounds.width - size.width - 28) / 2), y: 24, width: size.width + 28, height: size.height + 20)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 8, yRadius: 8).fill()
        (hint as NSString).draw(at: CGPoint(x: bubble.minX + 14, y: bubble.minY + 10), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        end = start
        tooSmall = false
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { end = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        let rect = ScreenCaptureRegion.rectangle(from: start, to: convert(event.locationInWindow, from: nil), bounds: bounds)
        guard !rect.isNull, rect.width >= 8, rect.height >= 8 else {
            self.start = nil; end = nil; tooSmall = true; needsDisplay = true
            return
        }
        onSelection?(rect)
    }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
}
