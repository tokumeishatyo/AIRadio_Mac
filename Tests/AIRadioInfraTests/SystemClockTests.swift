import Testing
import Foundation
import AIRadioCore
import AIRadioInfra

struct SystemClockTests {
    @Test func nowIsMonotonicNonDecreasing() {
        let clock = SystemClock()
        let t1 = clock.now
        let t2 = clock.now
        #expect(t2 >= t1)
    }

    @Test func zeroSleepReturnsImmediately() async throws {
        let clock = SystemClock()
        try await clock.sleep(seconds: 0)
    }

    @Test func smallSleepElapses() async throws {
        let clock = SystemClock()
        let start = clock.now
        try await clock.sleep(seconds: 0.05)
        #expect(clock.now.timeIntervalSince(start) >= 0.04)
    }
}
