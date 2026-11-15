import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

/// SCRecordingOutput writes screen, system audio and microphone directly to a local MP4 file.
@MainActor
final class RecordingService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var lastError: String?

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var callbacks: RecordingCallbacks?
    private var outputURL: URL?
    private var timer: Timer?
    private var startedAt: Date?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var finishTimeout: Task<Void, Never>?
    private var completed = false
    private var completionError: Error?
    private var sessionID = UUID()

    func start(screen: NSScreen, url: URL, includeSystemAudio: Bool,
               includeMicrophone: Bool, excluding: [NSWindow] = []) async throws {
        guard !isRecording, !isBusy, stream == nil else { throw CaptureError.recordingInProgress }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CaptureError.destinationExists }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        let session = UUID()
        sessionID = session
        completed = false
        completionError = nil
        if includeMicrophone {
            let authorized = await AVCaptureDevice.requestAccess(for: .audio)
            guard authorized else { throw CaptureError.microphoneDenied }
        }
        let filter = try await ScreenCaptureService.makeFilter(screen: screen, excluding: excluding)
        let configuration = ScreenCaptureService.configuration(screen: screen)
        // Keep H.264 within standard 4K encoder limits, preserving the display aspect ratio.
        let scale = min(1.0, 3840.0 / Double(configuration.width), 2160.0 / Double(configuration.height))
        configuration.width = max(2, Int(Double(configuration.width) * scale) / 2 * 2)
        configuration.height = max(2, Int(Double(configuration.height) * scale) / 2 * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = includeSystemAudio
        configuration.captureMicrophone = includeMicrophone
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureDynamicRange = .SDR

        let callbacks = RecordingCallbacks(
            onStart: { [weak self] in
                Task { @MainActor in
                    guard let self, self.sessionID == session, !self.completed else { return }
                    self.didStart()
                }
            },
            onFinish: { [weak self] error in
                Task { @MainActor in
                    guard let self, self.sessionID == session else { return }
                    self.didFinish(error: error)
                }
            }
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: callbacks)
        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = url
        outputConfiguration.outputFileType = .mp4
        outputConfiguration.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: outputConfiguration, delegate: callbacks)
        try stream.addRecordingOutput(output)
        self.callbacks = callbacks
        self.stream = stream
        self.output = output
        self.outputURL = url
        elapsed = 0
        do {
            try await stream.startCapture()
            // Delegates can finish while startCapture() is suspended. Do not retain
            // that completed stream or report a recording that already ended.
            if completed { throw completionError ?? CaptureError.recordingStoppedDuringStart }
            didStart()
        } catch {
            try? await stream.stopCapture()
            releaseSession()
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Returns only after ScreenCaptureKit has finalized the MP4 container.
    @discardableResult
    func stop() async throws -> URL? {
        guard !isBusy else { throw CaptureError.recordingInProgress }
        guard let stream else {
            if let error = completionError { throw error }
            return nil
        }
        isBusy = true
        timer?.invalidate()
        timer = nil
        let url = outputURL
        defer {
            isBusy = false
            releaseSession()
        }
        if completed {
            if let error = completionError { throw error }
            return url
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                finishContinuation = continuation
                finishTimeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                    guard let self, !self.completed else { return }
                    self.didFinish(error: CaptureError.recordingTimedOut)
                }
                Task { [weak self] in
                    do { try await stream.stopCapture() }
                    catch { self?.didFinish(error: error) }
                }
            }
            return url
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func didStart() {
        guard !isRecording else { return }
        isRecording = true
        startedAt = Date()
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func didFinish(error: Error?) {
        guard !completed else { return }
        completed = true
        completionError = error
        isRecording = false
        timer?.invalidate()
        timer = nil
        finishTimeout?.cancel()
        finishTimeout = nil
        if let error { lastError = error.localizedDescription }
        let continuation = finishContinuation
        finishContinuation = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
        // On unexpected system interruption there may be no caller awaiting stop().
        if !isBusy { releaseSession() }
    }

    private func releaseSession() {
        isRecording = false
        timer?.invalidate()
        timer = nil
        startedAt = nil
        stream = nil
        output = nil
        callbacks = nil
        outputURL = nil
        finishTimeout?.cancel()
        finishTimeout = nil
    }
}

private final class RecordingCallbacks: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    private let onStart: () -> Void
    private let onFinish: (Error?) -> Void
    init(onStart: @escaping () -> Void, onFinish: @escaping (Error?) -> Void) {
        self.onStart = onStart
        self.onFinish = onFinish
    }
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) { onStart() }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { onFinish(nil) }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { onFinish(error) }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onFinish(error) }
}
