import Foundation
import Testing
@testable import SpillcheckCore

struct ProcessStopTests {
    @Test func forceStopEndsARunningChildWithinItsDeadline() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let started = ProcessInfo.processInfo.systemUptime
        process.forceStop()
        #expect(!process.isRunning)
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
        #expect(process.terminationReason == .uncaughtSignal)
    }

    @Test func forceStopLeavesAnExitedChildAlone() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
        process.forceStop()
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
    }
}
