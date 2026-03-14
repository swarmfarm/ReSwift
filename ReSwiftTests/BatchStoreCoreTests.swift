import XCTest
@testable import ReSwift

final class BatchStoreCoreTests: XCTestCase {
    func testStoreTypeAliasResolvesToBatchStore() {
        let store = Store(reducer: appReducer, state: TestAppState())

        XCTAssertTrue(type(of: store) == BatchStore<TestAppState>.self)
    }

    func testInitWithProvidedStateKeepsState() {
        let store = Store(reducer: appReducer, state: TestAppState(testValue: 3, label: "Ready"))

        XCTAssertEqual(store.state.testValue, 3)
        XCTAssertEqual(store.state.label, "Ready")
    }

    func testInitWithNilStateDoesNotInvokeReducer() {
        var reducerCallCount = 0
        let store = Store<TestAppState>(
            reducer: { _, _ in
                reducerCallCount += 1
            },
            state: nil
        )

        XCTAssertNil(store.state)
        XCTAssertEqual(reducerCallCount, 0)
    }

    func testStoreDeinitializesWhenReferenceIsReleased() {
        let deinitExpectation = expectation(description: "store deinitialized")

        autoreleasepool {
            _ = DeinitObservingStore(
                reducer: appReducer,
                state: TestAppState(),
                onDeinit: { deinitExpectation.fulfill() }
            )
        }

        wait(for: [deinitExpectation], timeout: 1.0)
    }

    func testDispatchMutatesStateAndNotifiesSubscriber() {
        let store = Store(reducer: appReducer, state: TestAppState())
        let subscriber = RecordingSubscriber<TestAppState>()

        store.subscribe(subscriber)
        store.dispatch(SetValueAction(value: 9))

        XCTAssertEqual(store.state.testValue, 9)
        XCTAssertEqual(subscriber.receivedStates.map(\.testValue), [nil, 9])
    }

    func testDispatchWithNilStateIsIgnored() {
        let store = Store<TestAppState>(reducer: appReducer, state: nil)
        store.dispatch(SetValueAction(value: 10))

        XCTAssertNil(store.state)
    }
}
