import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case permissionDenied
    case displayUnavailable
    case microphoneDenied
    case recordingInProgress
    case destinationExists
    case recordingTimedOut
    case recordingStoppedDuringStart

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许屏注，然后重新打开应用。"
        case .displayUnavailable: return "该显示器已断开，请重新选择显示器。"
        case .microphoneDenied: return "麦克风未获授权，请在系统设置 → 隐私与安全性 → 麦克风中允许屏注，或关闭麦克风录音。"
        case .recordingInProgress: return "已有录屏正在进行或保存中。"
        case .destinationExists: return "保存位置已有同名文件，请选择另一个文件名。"
        case .recordingTimedOut: return "录屏结束超时，请检查保存位置是否仍可用。"
        case .recordingStoppedDuringStart: return "录屏在启动时已结束，请重新开始录屏。"
        }
    }
}

/// ScreenCaptureKit keeps all capture inside the process; no desktop images leave the Mac.
@MainActor
final class ScreenCaptureService {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    var onLiveError: ((Error) -> Void)?
    private var liveStream: SCStream?
    private var liveOutput: LiveFrameOutput?
    private var liveDelegate: LiveCaptureDelegate?
    private var liveGeneration = UUID()

    func capture(screen: NSScreen, excluding windows: [NSWindow] = []) async throws -> NSImage {
        let filter = try await Self.makeFilter(screen: screen, excluding: windows)
        let configuration = Self.configuration(screen: screen)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return NSImage(cgImage: image, size: screen.frame.size)
    }

    func startLiveCapture(screen: NSScreen, excluding windows: [NSWindow] = [],
                          onFrame: @escaping @MainActor (NSImage) -> Void) async throws {
        await stopLiveCapture()
        let generation = UUID()
        liveGeneration = generation
        let filter = try await Self.makeFilter(screen: screen, excluding: windows)
        guard liveGeneration == generation else { return }
        let configuration = Self.configuration(screen: screen)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        let output = LiveFrameOutput(size: screen.frame.size) { [weak self] image in
            Task { @MainActor in
                guard let self, self.liveGeneration == generation else { return }
                onFrame(image)
            }
        }
        let delegate = LiveCaptureDelegate { [weak self] error in
            Task { @MainActor in
                guard let self, self.liveGeneration == generation else { return }
                self.liveStream = nil
                self.liveOutput = nil
                self.liveDelegate = nil
                self.onLiveError?(error)
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        try stream.addStreamOutput(output, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "app.screenscribe.live-frame", qos: .userInteractive))
        liveOutput = output
        liveDelegate = delegate
        liveStream = stream
        do {
            try await stream.startCapture()
            if liveGeneration != generation { try? await stream.stopCapture() }
        } catch {
            if liveGeneration == generation {
                liveStream = nil
                liveOutput = nil
                liveDelegate = nil
            }
            throw error
        }
    }

    func stopLiveCapture() async {
        liveGeneration = UUID()
        let stream = liveStream
        liveStream = nil
        liveOutput = nil
        liveDelegate = nil
        try? await stream?.stopCapture()
    }

    /// Display IDs, rather than origin comparisons, also work for displays left of or above the main display.
    static func makeFilter(screen: NSScreen, excluding windows: [NSWindow]) async throws -> SCContentFilter {
        guard requestPermission() else { throw CaptureError.permissionDenied }
        // Include off-screen windows so a temporarily hidden toolbar remains excluded
        // when the presenter later opens it during this capture session.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == displayID.uint32Value }) else {
            throw CaptureError.displayUnavailable
        }
        let excludedIDs = Set(windows.filter { $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) })
        let excluded = content.windows.filter { excludedIDs.contains($0.windowID) }
        return SCContentFilter(display: display, excludingWindows: excluded)
    }

    static func configuration(screen: NSScreen) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((screen.frame.width * screen.backingScaleFactor).rounded()))
        configuration.height = max(1, Int((screen.frame.height * screen.backingScaleFactor).rounded()))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureResolution = .best
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        return configuration
    }
}

private final class LiveFrameOutput: NSObject, SCStreamOutput {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let size: NSSize
    private let onFrame: (NSImage) -> Void

    init(size: NSSize, onFrame: @escaping (NSImage) -> Void) {
        self.size = size
        self.onFrame = onFrame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: status) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        autoreleasepool {
            let source = CIImage(cvPixelBuffer: buffer)
            guard let image = context.createCGImage(source, from: source.extent) else { return }
            onFrame(NSImage(cgImage: image, size: size))
        }
    }
}

private final class LiveCaptureDelegate: NSObject, SCStreamDelegate {
    private let onError: (Error) -> Void
    init(onError: @escaping (Error) -> Void) { self.onError = onError }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onError(error) }
}
