import Foundation
import Testing
import BubblesCore

@Suite struct DataFolderTests {
    @Test func defaultIsApplicationSupportBubbles() {
        #expect(DataFolder.resolve(environment: [:]).path.hasSuffix("Application Support/Bubbles"))
        #expect(DataFolder.resolve(environment: ["BUBBLES_DATA_DIR": "  "]).path.hasSuffix("Application Support/Bubbles"))
    }

    @Test func environmentOverridesTheFolder() {
        let folder = DataFolder.resolve(environment: ["BUBBLES_DATA_DIR": "/tmp/qa-data/"])
        #expect(folder.path == "/tmp/qa-data")
        let home = DataFolder.resolve(environment: ["BUBBLES_DATA_DIR": "~/qa-data"])
        #expect(home.path == NSHomeDirectory() + "/qa-data")
    }

    @Test func everyFileLivesInTheOneFolder() {
        let folder = DataFolder.url
        #expect(TaskStore.defaultURL == folder.appendingPathComponent("state.json"))
        #expect(TaskStore.dataFolder.standardizedFileURL == folder.standardizedFileURL)
        #expect(TranscriptDraftStore.defaultURL == folder.appendingPathComponent("dictation-draft.json"))
        #expect(WhisperModel.defaultDownloadedURL.deletingLastPathComponent().deletingLastPathComponent()
            .standardizedFileURL == folder.standardizedFileURL)
    }
}
