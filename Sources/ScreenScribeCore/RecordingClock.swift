import Foundation

public enum RecordingPhase: Equatable {
    case idle, starting, recording, saving

    public var title: String {
        switch self {
        case .idle: return "开始录屏"
        case .starting: return "正在准备录屏"
        case .recording: return "正在录屏"
        case .saving: return "正在保存录屏"
        }
    }
}

/// A monotonic clock: changing the wall clock must not change the recording duration.
public struct RecordingClock {
    public private(set) var elapsed: TimeInterval = 0
    private var startedAt: TimeInterval?

    public init() {}
    public mutating func start(at uptime: TimeInterval) { startedAt = uptime; elapsed = 0 }
    public mutating func update(at uptime: TimeInterval) {
        guard let startedAt, uptime.isFinite else { return }
        elapsed = max(elapsed, max(uptime - startedAt, 0))
    }
    public mutating func stop(at uptime: TimeInterval) { update(at: uptime); startedAt = nil }

    public static func formatted(_ elapsed: TimeInterval) -> String {
        let seconds = elapsed.isFinite ? Int(max(0, min(elapsed, 359_999))) : 0
        if seconds >= 3600 { return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
