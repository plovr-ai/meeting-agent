import XCTest
@testable import MeetingAgentCore

final class TranslationResultPersistenceStoreTests: XCTestCase {
    func testAppendsAndReadsTranslationResultRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("translation-result-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = TranslationResultPersistenceStore(directoryURL: directory)
        let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let record = TranslationResultPersistenceRecord(
            meetingID: meetingID,
            resultID: "final",
            sourceID: "block-1",
            laneID: lane,
            sourceSegmentIDs: ["segment-1"],
            sourceTextHash: "hash",
            sourceText: "We approve the launch.",
            translatedText: "我们批准发布。",
            displayState: .stableFinal,
            boundaryReason: .terminalPunctuation,
            providerID: "test",
            createdAt: Date(timeIntervalSince1970: 1),
            finalizedAt: Date(timeIntervalSince1970: 2)
        )

        try store.append(record)
        let records = try store.load()

        XCTAssertEqual(records, [record])
    }
}
