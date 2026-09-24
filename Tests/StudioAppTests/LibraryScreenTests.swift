import Foundation
import Testing
import StudioCore
@testable import QwenAudioStudioMacApp

@MainActor struct LibraryScreenTests {
    @Test func visibleRunningJobRefreshesUntilTerminalAndStopsAfterCancellation() async {
        let poller = LibraryLiveRefresh()
        var state = JobState.queued
        var refreshes = 0
        let work = Task {
            await poller.run(interval: .milliseconds(20), shouldRefresh: { state == .queued }, refresh: {
                refreshes += 1
                state = .success
            })
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(refreshes == 1)
        work.cancel()
        await work.value
        let stoppedCount = refreshes
        try? await Task.sleep(for: .milliseconds(60))
        #expect(refreshes == stoppedCount)
    }
}
