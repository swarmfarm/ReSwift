import XCTest
@testable import ReSwift

final class BatchStoreBatchingTests: XCTestCase {
    func testDispatchBatchedFallsBackToImmediateDispatchWhenWindowIsNil() {
        let store = Store(reducer: appReducer, state: TestAppState())
        let subscriber = RecordingSubscriber<TestAppState>()

        store.subscribe(subscriber)
        store.dispatchBatched(SetValueAction(value: 4))

        let expectation = expectation(description: "queue drained")
        dispatchAsync { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(store.state.testValue, 4)
        XCTAssertEqual(subscriber.receivedStates.map(\.testValue), [nil, 4])
    }

    func testDispatchBatchedQueuesUntilWindowExpires() {
        let store = Store(reducer: appReducer, state: TestAppState(), batchingWindow: 0.05)
        let completion = expectation(description: "batched action delivered")
        let subscriber = ClosureSubscriber<TestAppState> { state in
            if state.testValue == 7 {
                completion.fulfill()
            }
        }
        store.subscribe(subscriber)

        store.dispatchBatched(SetValueAction(value: 7))

        XCTAssertNil(store.state.testValue)

        wait(for: [completion], timeout: 1.0)
        XCTAssertEqual(store.state.testValue, 7)
    }

    func testMultipleUnkeyedBatchedActionsReduceInOrder() {
        let store = Store(reducer: appReducer, state: TestAppState(), batchingWindow: 0.05)
        let completion = expectation(description: "batched log updated")
        let subscriber = ClosureSubscriber<TestAppState> { state in
            if state.log == ["first", "second", "third"] {
                completion.fulfill()
            }
        }
        store.subscribe(subscriber)

        store.dispatchBatched(AppendLogAction(value: "first"))
        store.dispatchBatched(AppendLogAction(value: "second"))
        store.dispatchBatched(AppendLogAction(value: "third"))

        wait(for: [completion], timeout: 1.0)
        XCTAssertEqual(store.state.log, ["first", "second", "third"])
    }

    func testKeyedBatchedActionsKeepOnlyLatestValueForSameKey() {
        let store = Store(reducer: appReducer, state: TestAppState(), batchingWindow: 0.05)
        let completion = expectation(description: "keyed batch reduced")
        let subscriber = ClosureSubscriber<TestAppState> { state in
            if state.testValue == 9 {
                completion.fulfill()
            }
        }
        store.subscribe(subscriber)

        store.dispatchBatched(KeyedValueAction(batchKey: "main", value: 1))
        store.dispatchBatched(KeyedValueAction(batchKey: "main", value: 9))

        wait(for: [completion], timeout: 1.0)
        XCTAssertEqual(store.state.testValue, 9)
    }

    func testKeyedAndUnkeyedBatchedActionsFlushTogetherWithSingleNotification() {
        let store = Store(reducer: appReducer, state: TestAppState(), batchingWindow: 0.05)
        let subscriber = RecordingSubscriber<TestAppState>()

        store.subscribe(subscriber)
        store.dispatchBatched(AppendLogAction(value: "one"))
        store.dispatchBatched(KeyedValueAction(batchKey: "main", value: 5))

        let completion = expectation(description: "flush complete")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            completion.fulfill()
        }
        wait(for: [completion], timeout: 1.0)

        XCTAssertEqual(store.state.log, ["one"])
        XCTAssertEqual(store.state.testValue, 5)
        XCTAssertEqual(subscriber.receivedStates.count, 2)
    }

    func testChangingBatchingWindowUpdatesSubsequentDispatchBehavior() {
        let store = Store(reducer: appReducer, state: TestAppState(), batchingWindow: 0.2)
        let firstFlush = expectation(description: "first flush")
        let secondFlush = expectation(description: "second flush")
        let subscriber = ClosureSubscriber<TestAppState> { state in
            if state.testValue == 1 {
                firstFlush.fulfill()
            } else if state.testValue == 2 {
                secondFlush.fulfill()
            }
        }
        store.subscribe(subscriber)

        store.dispatchBatched(SetValueAction(value: 1))
        wait(for: [firstFlush], timeout: 1.0)

        store.batchingWindow = nil
        store.dispatchBatched(SetValueAction(value: 2))

        let queueDrain = expectation(description: "immediate dispatch complete")
        dispatchAsync { queueDrain.fulfill() }
        wait(for: [queueDrain], timeout: 1.0)

        XCTAssertEqual(store.state.testValue, 2)
        XCTAssertEqual(XCTWaiter.wait(for: [secondFlush], timeout: 0.1), .completed)
    }
}
