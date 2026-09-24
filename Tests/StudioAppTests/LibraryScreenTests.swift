import Foundation
import Testing
@testable import StudioCore
@testable import QwenAudioStudioMacApp

@MainActor struct LibraryScreenTests {
    private func item(_ id: String, state: JobState = .queued, name: String = "存储名称") -> LibraryItem {
        LibraryItem(job: StoredJob(id: id, batchID: "batch", candidateIndex: 0, seed: 1,
            state: state, resultUncertain: false, message: nil),
            project: ProjectDraft(fields: DraftFields(name: "作品", prompt: "合成")),
            metadata: JobMetadata(name: name, note: "存储备注"), createdAt: Date(), isFinal: false)
    }

    @Test func pollingKeepsUnsavedNameAndNoteEdits() {
        let rows = LibraryRowsState()
        rows.apply(pages: [LibraryPage(items: [item("job", state: .queued)], nextBeforeID: nil)], reset: true)
        rows.editName("正在输入的新名")
        rows.editNote("尚未保存的备注")
        rows.apply(pages: [LibraryPage(items: [item("job", state: .requesting, name: "存储名称")], nextBeforeID: nil)], reset: false)
        #expect(rows.name == "正在输入的新名")
        #expect(rows.note == "尚未保存的备注")
        #expect(rows.items[0].job.state == .requesting)
    }

    @Test func dirtySelectedRowRemainsEditableAfterLeavingStatusFilter() {
        let rows = LibraryRowsState()
        let queued = item("changing", state: .queued)
        rows.apply(pages: [LibraryPage(items: [queued], nextBeforeID: nil)], reset: true)
        rows.editNote("工作中的备注")
        let completed = item("changing", state: .success)
        rows.apply(pages: [LibraryPage(items: [], nextBeforeID: nil)], reset: false,
                   retainedSelection: completed)
        #expect(rows.selectedJobID == "changing")
        #expect(rows.note == "工作中的备注")
        #expect(rows.selected?.job.state == .success)
    }

    @Test func manualFilterResetRetainsDirtySelectedMetadata() {
        let rows = LibraryRowsState()
        let original = item("changing", state: .queued)
        rows.apply(pages: [LibraryPage(items: [original], nextBeforeID: nil)], reset: true)
        rows.editName("手动筛选前的新名")
        rows.editNote("未保存的重要备注")
        rows.apply(pages: [LibraryPage(items: [], nextBeforeID: nil)], reset: true,
                   retainedSelection: item("changing", state: .success))
        #expect(rows.selectedJobID == "changing")
        #expect(rows.name == "手动筛选前的新名")
        #expect(rows.note == "未保存的重要备注")
        #expect(rows.pinnedSelectedJobID == "changing")
    }

    @Test func pollingRetainsLoadedSecondPageAndCursor() {
        let rows = LibraryRowsState()
        rows.apply(pages: [LibraryPage(items: [item("new")], nextBeforeID: "new")], reset: true)
        rows.append(LibraryPage(items: [item("old")], nextBeforeID: "old"))
        #expect(rows.loadedPages == 2)
        rows.apply(pages: [LibraryPage(items: [item("new", state: .requesting)], nextBeforeID: "new"),
                           LibraryPage(items: [item("old", state: .success)], nextBeforeID: "old")], reset: false)
        #expect(rows.items.map(\.job.id) == ["new", "old"])
        #expect(rows.loadedPages == 2)
        #expect(rows.nextBeforeID == "old")
    }

    @Test func pollTickCanRevealCompletedRowWhenFilteredListHadNoRunningRow() async {
        let rows = LibraryRowsState()
        rows.apply(pages: [LibraryPage(items: [], nextBeforeID: nil)], reset: true)
        #expect(rows.items.isEmpty)
        #expect(!LibraryLiveRefresh.shouldRefresh(tab: 1, loading: false, visibleRows: []))
        #expect(!LibraryLiveRefresh.shouldRefresh(tab: 0, loading: true, visibleRows: []))
        await LibraryLiveRefresh().tick(shouldRefresh: {
            LibraryLiveRefresh.shouldRefresh(tab: 0, loading: false, visibleRows: rows.items)
        }, refresh: {
            rows.apply(pages: [LibraryPage(items: [item("completed", state: .success)], nextBeforeID: nil)], reset: false)
        })
        #expect(rows.items.map(\.job.id) == ["completed"])
    }
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
