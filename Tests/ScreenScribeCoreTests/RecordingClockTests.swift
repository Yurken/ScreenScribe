import XCTest
@testable import ScreenScribeCore

final class RecordingClockTests: XCTestCase {
    func testElapsedAdvancesAndFreezesWhenSavingStarts() {
        var clock = RecordingClock()
        clock.start(at: 100)
        clock.update(at: 101.4)
        XCTAssertEqual(clock.elapsed, 1.4, accuracy: 0.001)
        clock.update(at: 107.8)
        XCTAssertEqual(RecordingClock.formatted(clock.elapsed), "00:07")
        clock.stop(at: 108.2)
        clock.update(at: 130)
        XCTAssertEqual(clock.elapsed, 8.2, accuracy: 0.001)
    }

    func testClockDoesNotGoBackwardsAndNextRecordingStartsAtZero() {
        var clock = RecordingClock()
        clock.start(at: 100)
        clock.update(at: 112)
        clock.update(at: 105)
        XCTAssertEqual(clock.elapsed, 12)
        clock.stop(at: 113)
        clock.start(at: 200)
        XCTAssertEqual(clock.elapsed, 0)
        clock.update(at: 201)
        XCTAssertEqual(clock.elapsed, 1)
    }

    func testTimeFormattingHandlesHourBoundaryAndInvalidInput() {
        XCTAssertEqual(RecordingClock.formatted(0), "00:00")
        XCTAssertEqual(RecordingClock.formatted(59.9), "00:59")
        XCTAssertEqual(RecordingClock.formatted(60), "01:00")
        XCTAssertEqual(RecordingClock.formatted(3599), "59:59")
        XCTAssertEqual(RecordingClock.formatted(3600), "01:00:00")
        XCTAssertEqual(RecordingClock.formatted(3661), "01:01:01")
        XCTAssertEqual(RecordingClock.formatted(-10), "00:00")
        XCTAssertEqual(RecordingClock.formatted(.infinity), "00:00")
    }
}
