import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import ScreenScribeCore
import OSLog

enum CanvasMode: String, CaseIterable, Identifiable {
    case live, frozen, whiteboard, blackboard
    var id: String { rawValue }
    var title: String {
        switch self { case .live: return "实时批注"; case .frozen: return "冻结画面"; case .whiteboard: return "白板"; case .blackboard: return "黑板" }
    }
    var symbol: String {
        switch self { case .live: return "pencil.tip"; case .frozen: return "snowflake"; case .whiteboard: return "rectangle.inset.filled"; case .blackboard: return "rectangle.fill" }
    }
}

@MainActor
final class PresentationController: ObservableObject {
    let document = CanvasDocument()
    let capture = ScreenCaptureService()
    let recording = RecordingService()
    let hotkeys = HotKeyManager()
    @Published private(set) var active = false
    @Published private(set) var busy = false
    @Published private(set) var mode: CanvasMode = .frozen
    @Published var passThrough = false { didSet { if passThrough { canvas?.finishEditing() }; overlay?.ignoresMouseEvents = passThrough; if !passThrough { focusCanvas() } } }
    @Published var spotlight = false { didSet { updateEffects() } }
    @Published var cursorHighlight = false { didSet { updateEffects() } }
    @Published var lens = false
    @Published var lensZoom: Double = 2
    @Published var focusRadius: Double = 140
    @Published var dimOpacity: Double = 0.6
    @Published var includeSystemAudio = true
    @Published var includeMicrophone = false
    @Published var autoFreeze = true { didSet { UserDefaults.standard.set(autoFreeze, forKey: "autoFreeze") } }
    @Published var hideDesktop = false { didSet { updateDesktopCover() } }
    @Published var message: String?
    var closePanel: (() -> Void)?
    var showPanel: (() -> Void)?
    var recordingChanged: ((RecordingPhase, String) -> Void)?
    private(set) var overlay: CanvasWindow?
    private(set) var toolbar: NSPanel?
    private var canvas: AnnotationCanvasView?
    private var effects: CursorEffectsView?
    private var effectWindow: NSWindow?
    private var snipView: SnipSelectionView?
    private var recordingPanel: NSPanel?
    private var desktopCovers: [NSWindow] = []
    private var localMonitor: Any?
    private var pointerTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var activeScreen: NSScreen?
    private var lensScreen: NSScreen?
    private var screenObserver: NSObjectProtocol?
    private var messageTask: Task<Void, Never>?
    private var lensRequest = UUID()
    private let captureLogger = Logger(subsystem: "com.yurken.screenscribe", category: "Capture")

    func start() {
        if UserDefaults.standard.object(forKey: "autoFreeze") != nil { autoFreeze = UserDefaults.standard.bool(forKey: "autoFreeze") }
        hotkeys.onAction = { [weak self] action in self?.handle(action) }
        hotkeys.register()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.routeKey(event)
        }
        recording.$phase.removeDuplicates()
            .sink { [weak self] phase in
                guard let self else { return }
                self.recordingChanged?(phase, self.recording.clockText)
                if phase == .idle { self.recordingPanel?.orderOut(nil) }
                else if self.recordingPanel?.isVisible == false { self.recordingPanel?.orderFrontRegardless() }
            }.store(in: &subscriptions)
        recording.$elapsed.map { RecordingClock.formatted($0) }.removeDuplicates()
            .sink { [weak self] clock in
                guard let self else { return }
                self.recordingChanged?(self.recording.phase, clock)
            }.store(in: &subscriptions)
        recording.$lastError.compactMap { $0 }.sink { [weak self] error in self?.notify(error); self?.showPanel?() }.store(in: &subscriptions)
        capture.onLiveError = { [weak self] error in self?.lens = false; self?.notify(error.localizedDescription); self?.updateEffects() }
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 45, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let screen = self.activeScreen, !NSScreen.screens.contains(screen) { self.hideSession(); self.activeScreen = nil }
                if self.lens { await self.setLens(false) }
                if self.hideDesktop { self.updateDesktopCover() }
            }
        }
    }

    func shutdown() {
        hotkeys.unregister()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        pointerTimer?.invalidate()
        recordingPanel?.orderOut(nil)
        messageTask?.cancel()
        desktopCovers.forEach { $0.orderOut(nil) }
        Task { await capture.stopLiveCapture() }
    }

    var screen: NSScreen { activeScreen ?? Self.mouseScreen }
    static var mouseScreen: NSScreen {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
    var ownWindows: [NSWindow] { [overlay, toolbar, effectWindow, recordingPanel].compactMap { $0 } }

    func handle(_ action: GlobalAction) {
        switch action {
        case .live: Task { await begin(.live) }
        case .freeze: Task { await begin(.frozen) }
        case .hide: toggleSession()
        case .snip: Task { await snip() }
        case .spotlight: spotlight.toggle()
        case .lens: Task { await setLens(!lens) }
        case .board: Task { await begin(.whiteboard) }
        }
    }

    func begin(_ requestedMode: CanvasMode? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        closePanel?()
        let requested = requestedMode ?? (autoFreeze ? .frozen : .live)
        let target = active ? screen : Self.mouseScreen
        var image: NSImage?
        if requested == .frozen {
            // Capture before showing the overlay, excluding our existing windows.
            try? await Task.sleep(nanoseconds: 140_000_000)
            do { image = try await capture.capture(screen: target, excluding: ownWindows) }
            catch { reportCaptureError(error); return }
        }
        activeScreen = target
        mode = requested
        if overlay == nil { createOverlay(screen: target) }
        guard let overlay, let canvas else { return }
        overlay.setFrame(target.frame, display: true)
        canvas.frame = NSRect(origin: .zero, size: target.frame.size)
        canvas.backgroundImage = image
        canvas.boardColor = requested == .whiteboard ? NSColor(calibratedWhite: 0.98, alpha: 1) : requested == .blackboard ? NSColor(calibratedRed: 0.055, green: 0.08, blue: 0.10, alpha: 1) : nil
        canvas.needsDisplay = true
        active = true
        passThrough = false
        overlay.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        showToolbar(on: target)
        focusCanvas()
        updateEffects()
    }

    private func createOverlay(screen: NSScreen) {
        let window = CanvasWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        configureOverlay(window, level: .init(rawValue: NSWindow.Level.statusBar.rawValue + 1))
        window.acceptsMouseMovedEvents = true
        let canvas = AnnotationCanvasView(document: document)
        canvas.frame = NSRect(origin: .zero, size: screen.frame.size)
        canvas.autoresizingMask = [.width, .height]
        canvas.onEscape = { [weak self] in self?.escape() }
        window.contentView = canvas
        self.canvas = canvas
        self.overlay = window
    }

    func focusCanvas() {
        guard active, !passThrough, let canvas else { return }
        overlay?.makeKey(); canvas.focusInput()
    }

    func focusToolbar() {
        if active, let toolbar { toolbar.makeKeyAndOrderFront(nil) }
        else if recording.phase != .idle { recordingPanel?.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showToolbar(on screen: NSScreen) {
        if toolbar == nil {
            let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            configureOverlay(panel, level: .init(rawValue: NSWindow.Level.statusBar.rawValue + 4))
            panel.isMovableByWindowBackground = true
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.title = "屏注批注工具条"
            panel.contentView = makeToolbarSurface(AnnotationToolbar(controller: self, document: document))
            toolbar = panel
        }
        let area = screen.visibleFrame
        let width = min(1060, area.width - 32)
        toolbar?.setFrame(NSRect(x: area.midX - width / 2, y: area.minY + 24, width: width, height: 120), display: true)
        toolbar?.orderFrontRegardless()
    }

    func hideSession() {
        canvas?.finishEditing()
        snipView?.removeFromSuperview(); snipView = nil
        overlay?.orderOut(nil); toolbar?.orderOut(nil)
        active = false
    }

    func toggleSession() {
        if active { hideSession() }
        else if let overlay, let activeScreen {
            active = true; overlay.orderFrontRegardless(); showToolbar(on: activeScreen); focusCanvas()
        } else { Task { await begin() } }
    }

    func selectTool(_ tool: AnnotationTool) {
        canvas?.finishEditing()
        if tool == .blur, mode == .live {
            Task { await begin(.frozen); document.tool = tool; focusCanvas() }
        } else { document.tool = tool; passThrough = false; focusCanvas() }
    }

    func applyStyle() { document.applyStyleToSelection(); canvas?.needsDisplay = true }

    func escape() {
        if snipView != nil { snipView?.removeFromSuperview(); snipView = nil; focusCanvas(); return }
        if document.tool == .text { canvas?.finishEditing(); document.tool = .pen; focusCanvas() }
        else { hideSession() }
    }

    private func routeKey(_ event: NSEvent) -> NSEvent? {
        if event.window?.firstResponder is RecorderButton { return event }
        let inCanvas = event.window === overlay || event.window === toolbar
        guard inCanvas else { return event }
        if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
        if event.keyCode == 53, active { escape(); return nil }
        guard active, !passThrough else { return event }
        if event.window?.firstResponder is NSTextView { return event }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let command = event.modifierFlags.contains(.command)
        if command {
            switch key {
            case "z": event.modifierFlags.contains(.shift) ? redo() : undo()
            case "s": Task { await export(save: true) }
            case "c": Task { await export(save: false) }
            case "d": document.duplicateSelection()
            default: return event
            }
            return nil
        }
        if event.modifierFlags.intersection([.control, .option]).isEmpty {
            if event.keyCode == 51 || event.keyCode == 117 { document.deleteSelection(); return nil }
            if key == "[" { document.strokeWidth = max(1, document.strokeWidth - 1); return nil }
            if key == "]" { document.strokeWidth = min(40, document.strokeWidth + 1); return nil }
            if let tool = AnnotationTool.allCases.first(where: { $0.shortcut.lowercased() == key && !key.isEmpty }) { selectTool(tool); return nil }
        }
        return event
    }

    func undo() { canvas?.finishEditing(); document.undo(); focusCanvas() }
    func redo() { canvas?.finishEditing(); document.redo(); focusCanvas() }
    func clear() { canvas?.finishEditing(); document.clear(); focusCanvas() }

    func snip() async {
        if !active || mode == .live { await begin(.frozen) }
        guard active, let canvas else { return }
        canvas.finishEditing()
        passThrough = false
        snipView?.removeFromSuperview()
        let selection = SnipSelectionView(frame: canvas.bounds)
        selection.onComplete = { [weak self, weak selection] rect in
            selection?.removeFromSuperview(); self?.snipView = nil
            guard let self else { return }
            if let rect { Task { await self.export(save: false, rect: rect) } }
            self.focusCanvas()
        }
        canvas.addSubview(selection)
        snipView = selection
        overlay?.makeFirstResponder(selection)
    }

    func export(save: Bool, rect: NSRect? = nil) async {
        guard !busy, let canvas, active else { return }
        canvas.finishEditing()
        busy = true
        defer { busy = false }
        var temporaryBackground = false
        if mode == .live {
            do { canvas.backgroundImage = try await capture.capture(screen: screen, excluding: ownWindows); temporaryBackground = true }
            catch { reportCaptureError(error); return }
        }
        let image = rect.map { canvas.renderedImage(in: $0) } ?? canvas.renderedImage()
        if temporaryBackground { canvas.backgroundImage = nil; canvas.needsDisplay = true }
        guard let image else { notify("图像生成失败。"); return }
        if save {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "ScreenScribe-\(Self.timestamp()).png"
            panel.level = .init(rawValue: NSWindow.Level.statusBar.rawValue + 6)
            guard panel.runModal() == .OK, let url = panel.url else { focusCanvas(); return }
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { notify("PNG 编码失败。"); return }
            do { try data.write(to: url, options: .atomic); notify("已保存 \(url.lastPathComponent)") }
            catch { notify(error.localizedDescription) }
        } else {
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.writeObjects([image]) { notify("已复制截图") } else { notify("无法写入剪贴板。") }
        }
        focusCanvas()
    }

    func toggleRecording() {
        guard !recording.isBusy else { return }
        if recording.isRecording { Task { await stopRecording() }; return }
        closePanel?()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "ScreenScribe-\(Self.timestamp()).mp4"
        panel.level = .init(rawValue: NSWindow.Level.statusBar.rawValue + 6)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let target = active ? screen : Self.mouseScreen
        // Keep an existing movie intact until the new recording has finalized.
        let destination: URL
        if FileManager.default.fileExists(atPath: url.path) {
            destination = url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString.prefix(6) + ".mp4")
            notify("同名文件保留，新录屏将保存为 \(destination.lastPathComponent)")
        } else { destination = url }
        // Create the toolbar before building the recording exclusion filter.
        if toolbar == nil { showToolbar(on: target); if !active { toolbar?.orderOut(nil) } }
        prepareRecordingPanel(on: target)
        Task {
            do { try await recording.start(screen: target, url: destination, includeSystemAudio: includeSystemAudio, includeMicrophone: includeMicrophone, excluding: [toolbar, recordingPanel].compactMap { $0 }); notify("开始录屏") }
            catch {
                if ScreenCaptureService.isPermissionDenied(error) { reportCaptureError(error); return }
                let alert = NSAlert(); alert.messageText = "无法开始录屏"; alert.informativeText = error.localizedDescription; alert.runModal()
            }
        }
    }

    func stopRecording() async {
        do { if let url = try await recording.stop() { notify("已保存 \(url.lastPathComponent)") } }
        catch { notify("录屏保存失败：\(error.localizedDescription)") }
    }

    private func prepareRecordingPanel(on screen: NSScreen) {
        if recordingPanel == nil {
            let panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            configureOverlay(panel, level: .init(rawValue: NSWindow.Level.statusBar.rawValue + 5))
            panel.title = "录屏状态"
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.hasShadow = true
            panel.contentView = makeToolbarSurface(RecordingHUD(recording: recording) { [weak self] in self?.toggleRecording() })
            recordingPanel = panel
        }
        let area = screen.visibleFrame
        recordingPanel?.setFrame(NSRect(x: area.maxX - 358, y: area.maxY - 112, width: 340, height: 94), display: true)
    }

    func setLens(_ enabled: Bool) async {
        let request = UUID(); lensRequest = request
        if !enabled { lens = false; lensScreen = nil; await capture.stopLiveCapture(); updateEffects(); return }
        guard !lens else { return }
        lens = true
        closePanel?()
        let target = active ? screen : Self.mouseScreen
        lensScreen = target
        ensureEffects(on: target)
        do {
            try await capture.startLiveCapture(screen: target, excluding: [toolbar, effectWindow, recordingPanel].compactMap { $0 }) { [weak self] image in
                guard let self, self.lensRequest == request else { return }
                self.effects?.image = image; self.effects?.needsDisplay = true
            }
            guard lensRequest == request else { return }
            updateEffects()
        } catch {
            guard lensRequest == request else { return }
            lens = false; lensScreen = nil; updateEffects(); reportCaptureError(error)
        }
    }

    private func ensureEffects(on screen: NSScreen) {
        if effectWindow == nil {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            configureOverlay(window, level: .init(rawValue: NSWindow.Level.statusBar.rawValue + 2))
            window.ignoresMouseEvents = true
            let view = CursorEffectsView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            effectWindow = window; effects = view
        }
        effectWindow?.setFrame(screen.frame, display: true)
    }

    private func updateEffects() {
        if spotlight || cursorHighlight || lens {
            ensureEffects(on: lensScreen ?? (active ? screen : Self.mouseScreen))
            effects?.spotlight = spotlight; effects?.highlight = cursorHighlight; effects?.lens = lens
            effects?.radius = focusRadius; effects?.dim = dimOpacity; effects?.zoom = lensZoom
            effectWindow?.orderFrontRegardless(); updatePointer()
        } else { effectWindow?.orderOut(nil) }
    }

    private func updatePointer() {
        guard spotlight || cursorHighlight || lens, let effects else { return }
        let target = lensScreen ?? (active ? screen : Self.mouseScreen)
        if effectWindow?.frame != target.frame { effectWindow?.setFrame(target.frame, display: true) }
        let point = NSEvent.mouseLocation
        effects.pointer = NSPoint(x: point.x - target.frame.minX, y: target.frame.maxY - point.y)
        effects.radius = focusRadius; effects.dim = dimOpacity; effects.zoom = lensZoom
        effects.needsDisplay = true
    }

    private func updateDesktopCover() {
        desktopCovers.forEach { $0.orderOut(nil) }; desktopCovers.removeAll()
        guard hideDesktop else { return }
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.14, blue: 0.20, alpha: 1)
            if let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) {
                let view = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
                view.image = image; view.imageScaling = .scaleAxesIndependently; window.contentView = view
            }
            window.orderFrontRegardless(); desktopCovers.append(window)
        }
    }

    func notify(_ text: String) {
        messageTask?.cancel(); message = text
        messageTask = Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if !Task.isCancelled { message = nil } }
    }
    private func reportCaptureError(_ error: Error) {
        let details = error as NSError
        captureLogger.error("Screen capture failed: \(details.domain, privacy: .public) (\(details.code))")
        let alert = NSAlert()
        if ScreenCaptureService.isPermissionDenied(error) {
            alert.messageText = "屏幕访问权限尚未生效"
            alert.informativeText = "请在系统设置 → 隐私与安全 → 录屏与系统录音中允许 ScreenScribe，再完全退出并重新打开屏注。\n\n如果开关已打开，请移除列表中的旧 ScreenScribe，再点“＋”重新添加“应用程序”中的 ScreenScribe。旧构建的授权可能无法用于当前版本。\n\n实时批注、白板和黑板不需要此权限，可以先使用。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "暂用实时批注")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn: openScreenPermissionSettings()
            case .alertSecondButtonReturn: Task { await begin(.live) }
            default: break
            }
        } else {
            alert.messageText = "无法获取屏幕画面"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
    func openScreenPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    static func timestamp() -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HHmmss"; return formatter.string(from: Date())
    }
}

final class CanvasWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
@MainActor func configureOverlay(_ window: NSWindow, level: NSWindow.Level) {
    window.level = level; window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
}
