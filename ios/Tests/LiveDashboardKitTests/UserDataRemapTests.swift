import XCTest
@testable import LiveDashboardKit

@MainActor
final class UserDataRemapTests: XCTestCase {
    private func makeStore() -> UserDataStore {
        UserDataStore(container: UserDataStore.makeContainer(inMemory: true))
    }

    func testFollowedEventIDMovesAndSecondApplyDoesNotDuplicate() {
        let store = makeStore()
        store.setFollowed(true, eventID: "old")
        let remap = UserDataRemap(fromEventID: "old", toEventID: "new")
        store.applyRemaps([remap])
        XCTAssertTrue(store.state(for: "new").isFollowed)
        XCTAssertFalse(store.state(for: "old").isFollowed)
        XCTAssertEqual(store.eventStates.keys.sorted(), ["new"])

        store.applyRemaps([remap])
        XCTAssertTrue(store.state(for: "new").isFollowed)
        XCTAssertFalse(store.state(for: "old").isFollowed)
        XCTAssertEqual(store.eventStates.keys.sorted(), ["new"])
    }

    func testParticipationAndRoundRecordMoveWithEventID() {
        let store = makeStore()
        store.setParticipation(eventID: "old", performanceID: "day-1", participate: true, knownPerformanceIDs: ["day-1"])
        store.setRoundRecord(UserRoundRecord(roundID: "round-1", applied: true, paid: true), eventID: "old")
        store.applyRemaps([UserDataRemap(fromEventID: "old", toEventID: "new")])

        let moved = store.state(for: "new")
        XCTAssertEqual(moved.participatingPerformanceIDs, ["day-1"])
        XCTAssertEqual(moved.roundRecords.map(\.roundID), ["round-1"])
        XCTAssertEqual(moved.roundRecords.first?.applied, true)
        XCTAssertEqual(moved.roundRecords.first?.paid, true)
        XCTAssertTrue(store.state(for: "old").participatingPerformanceIDs.isEmpty)
        XCTAssertTrue(store.state(for: "old").roundRecords.isEmpty)
        XCTAssertNil(store.eventStates["old"])
    }

    func testMappedPerformanceIDIsRewrittenAndUnmappedSelectionIsKept() {
        let store = makeStore()
        store.setFollowed(true, eventID: "old")
        store.setSelectedPerformance("keep-me", eventID: "old")
        store.setParticipation(eventID: "old", performanceID: "old-perf", participate: true, knownPerformanceIDs: ["old-perf"])
        store.applyRemaps([UserDataRemap(fromEventID: "old", toEventID: "new", performanceIDs: ["old-perf": "new-perf"])])

        XCTAssertEqual(store.selectedPerformanceID(eventID: "new"), "keep-me")
        XCTAssertEqual(store.state(for: "new").participatingPerformanceIDs, ["new-perf"])
        XCTAssertNil(store.selectedPerformanceID(eventID: "old"))
    }

    func testSameEventPerformanceRenameRemapsSelection() {
        let store = makeStore()
        store.setSelectedPerformance("old-perf", eventID: "same")
        store.setParticipation(eventID: "same", performanceID: "old-perf", participate: true, knownPerformanceIDs: ["old-perf"])
        let remap = UserDataRemap(fromEventID: "same", toEventID: "same", performanceIDs: ["old-perf": "new-perf"])
        store.applyRemaps([remap])
        XCTAssertEqual(store.selectedPerformanceID(eventID: "same"), "new-perf")
        XCTAssertEqual(store.state(for: "same").participatingPerformanceIDs, ["new-perf"])

        store.applyRemaps([remap])
        XCTAssertEqual(store.selectedPerformanceID(eventID: "same"), "new-perf")
        XCTAssertEqual(store.state(for: "same").participatingPerformanceIDs, ["new-perf"])
    }

    func testRoundCollisionORsFlagsAndKeepsSourceSelectionWhenDestinationHasNone() {
        let store = makeStore()
        store.setFollowed(true, eventID: "new")
        store.setRoundRecord(UserRoundRecord(roundID: "r", applied: false, paid: true, hasBaseTicket: false), eventID: "new")
        store.setFollowed(true, eventID: "old")
        store.setSelectedPerformance("p1", eventID: "old")
        store.setRoundRecord(UserRoundRecord(roundID: "r", applied: true, paid: false, hasBaseTicket: true), eventID: "old")
        store.applyRemaps([UserDataRemap(fromEventID: "old", toEventID: "new")])

        XCTAssertEqual(store.selectedPerformanceID(eventID: "new"), "p1")
        let record = store.state(for: "new").roundRecords.first { $0.roundID == "r" }
        XCTAssertEqual(record?.applied, true)
        XCTAssertEqual(record?.paid, true)
        XCTAssertEqual(record?.hasBaseTicket, true)
        XCTAssertNil(store.eventStates["old"])
        XCTAssertTrue(store.state(for: "old").roundRecords.isEmpty)
    }

    func testEmptyToEventIDDoesNotDeleteSourceFollow() {
        let store = makeStore()
        store.setFollowed(true, eventID: "old")
        store.applyRemaps([UserDataRemap(fromEventID: "old", toEventID: "")])
        XCTAssertTrue(store.state(for: "old").isFollowed)
        XCTAssertEqual(store.eventStates.keys.sorted(), ["old"])
    }
}
