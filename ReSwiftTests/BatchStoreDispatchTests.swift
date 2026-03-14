import XCTest
@testable import ReSwift

private final class WeakStoreBox<State>: @unchecked Sendable {
    weak var store: Store<State>?
}

final class BatchStoreDispatchTests: XCTestCase {
    func testMiddlewareDecoratesActionsInOrder() {
        let first: Middleware<TestAppState> = { _, _ in
            { next in
                { action in
                    if let action = action as? SetLabelAction {
                        next(SetLabelAction(value: action.value + " First"))
                    } else {
                        next(action)
                    }
                }
            }
        }
        let second: Middleware<TestAppState> = { _, _ in
            { next in
                { action in
                    if let action = action as? SetLabelAction {
                        next(SetLabelAction(value: action.value + " Second"))
                    } else {
                        next(action)
                    }
                }
            }
        }
        let store = Store(
            reducer: appReducer,
            state: TestAppState(),
            middleware: [first, second]
        )

        store.dispatch(SetLabelAction(value: "Value"))

        XCTAssertEqual(store.state.label, "Value First Second")
    }

    func testMiddlewareCanDispatchAdditionalActions() {
        let middleware: Middleware<TestAppState> = { dispatch, _ in
            { next in
                { action in
                    if let action = action as? SetValueAction {
                        dispatch(SetLabelAction(value: "\(action.value ?? 0)"))
                    }
                    next(action)
                }
            }
        }
        let store = Store(
            reducer: appReducer,
            state: TestAppState(),
            middleware: [middleware]
        )

        store.dispatch(SetValueAction(value: 10))

        XCTAssertEqual(store.state.testValue, 10)
        XCTAssertEqual(store.state.label, "10")
    }

    func testMiddlewareCanReadStateAndSwallowAction() {
        let middleware: Middleware<TestAppState> = { dispatch, getState in
            { next in
                { action in
                    if getState()?.label == "OK", (action as? SetLabelAction)?.value != "Blocked" {
                        dispatch(SetLabelAction(value: "Blocked"))
                        next(NoOpAction())
                    } else {
                        next(action)
                    }
                }
            }
        }
        let store = Store(
            reducer: appReducer,
            state: TestAppState(label: "OK"),
            middleware: [middleware]
        )

        store.dispatch(SetLabelAction(value: "Ignored"))

        XCTAssertEqual(store.state.label, "Blocked")
    }

    func testMiddlewareCanBeReplacedAfterInit() {
        let store = Store(reducer: appReducer, state: TestAppState())

        store.middleware = [{ _, _ in
            { next in
                { action in
                    if let action = action as? SetLabelAction {
                        next(SetLabelAction(value: action.value + " Added"))
                    } else {
                        next(action)
                    }
                }
            }
        }]
        store.dispatch(SetLabelAction(value: "One"))
        XCTAssertEqual(store.state.label, "One Added")

        store.middleware = []
        store.dispatch(SetLabelAction(value: "Two"))
        XCTAssertEqual(store.state.label, "Two")
    }

    func testActionCreatorDispatchesReturnedAction() {
        let store = Store(reducer: appReducer, state: TestAppState(testValue: 5))

        store.dispatch { state, _ in
            SetValueAction(value: (state.testValue ?? 0) * 2)
        }

        XCTAssertEqual(store.state.testValue, 10)
    }

    func testActionCreatorReturningNilDoesNothing() {
        let store = Store(reducer: appReducer, state: TestAppState(testValue: 5))

        store.dispatch { _, _ in nil }

        XCTAssertEqual(store.state.testValue, 5)
    }

    func testAsyncActionCreatorDispatchesLaterAction() {
        let store = Store(reducer: appReducer, state: TestAppState())
        let completion = expectation(description: "async action dispatched")
        let subscriber = ClosureSubscriber<TestAppState> { state in
            if state.testValue == 6 {
                completion.fulfill()
            }
        }
        store.subscribe(subscriber)

        store.dispatch { _, _, callback in
            dispatchAsync {
                callback { _, _ in
                    SetValueAction(value: 6)
                }
            }
        }

        wait(for: [completion], timeout: 1.0)
        XCTAssertEqual(store.state.testValue, 6)
    }

    func testAsyncActionCreatorCallbackRunsAfterStateMutation() {
        let store = Store(reducer: appReducer, state: TestAppState())
        let completion = expectation(description: "async callback invoked")

        store.dispatch({ _, _, callback in
            dispatchAsync {
                callback { _, _ in
                    SetValueAction(value: 11)
                }
            }
        }, callback: { state in
            XCTAssertEqual(state.testValue, 11)
            XCTAssertEqual(store.state.testValue, 11)
            completion.fulfill()
        })

        wait(for: [completion], timeout: 1.0)
    }

    func testDispatchSyncFromOutsideQueueBlocksUntilStateUpdates() {
        let store = Store(reducer: appReducer, state: TestAppState())

        store.dispatchSync(SetValueAction(value: 12))

        XCTAssertEqual(store.state.testValue, 12)
    }

    func testDispatchAsyncEventuallyUpdatesState() {
        let store = Store(reducer: appReducer, state: TestAppState())
        let completion = expectation(description: "async dispatch notified")
        let subscriber = ClosureSubscriber<TestAppState> { state in
            if state.testValue == 14 {
                completion.fulfill()
            }
        }
        store.subscribe(subscriber)

        store.dispatchAsync(SetValueAction(value: 14))

        wait(for: [completion], timeout: 1.0)
        XCTAssertEqual(store.state.testValue, 14)
    }

    func testDispatchConcurrentUsesConcurrentQueueForSubscriberCallbacks() {
        let store = Store(reducer: appReducer, state: TestAppState())
        let queueKey = DispatchSpecificKey<Int>()
        let callbackExpectation = expectation(description: "callback on concurrent queue")
        store.concurrentQueue.setSpecific(key: queueKey, value: store.concurrentQueueContext)

        let subscriber = QueueRecordingSubscriber<TestAppState>(
            queueKey: queueKey,
            expectedValue: store.concurrentQueueContext,
            expectation: callbackExpectation
        )
        store.subscribe(subscriber)

        store.dispatch(SetValueAction(value: 20), concurrent: true)

        wait(for: [callbackExpectation], timeout: 1.0)
        XCTAssertTrue(subscriber.callbackSawExpectedQueue)
    }

    func testConcurrentDispatchWaitsForAllSubscribersBeforeReturning() {
        let store = Store(reducer: appReducer, state: TestAppState())
        let firstStarted = expectation(description: "first started")
        let secondStarted = expectation(description: "second started")
        let releaseSemaphore = DispatchSemaphore(value: 0)
        let dispatchReturned = DispatchSemaphore(value: 0)

        let first = WaitingSubscriber<TestAppState>(started: firstStarted, releaseSemaphore: releaseSemaphore)
        let second = WaitingSubscriber<TestAppState>(started: secondStarted, releaseSemaphore: releaseSemaphore)
        store.subscribe(first)
        store.subscribe(second)

        dispatchAsync {
            store.dispatch(SetValueAction(value: 1), concurrent: true)
            dispatchReturned.signal()
        }

        wait(for: [firstStarted, secondStarted], timeout: 1.0)
        XCTAssertEqual(dispatchReturned.wait(timeout: .now() + 0.05), .timedOut)

        releaseSemaphore.signal()
        releaseSemaphore.signal()

        XCTAssertEqual(dispatchReturned.wait(timeout: .now() + 1.0), .success)
    }

    func testConcurrentDispatchRemovesDeallocatedSubscribers() {
        let store = Store(reducer: appReducer, state: TestAppState())

        autoreleasepool {
            let subscriber = RecordingSubscriber<TestAppState>()
            store.subscribe(subscriber)
            XCTAssertEqual(store.subscriptions.count, 1)
        }

        store.dispatch(SetValueAction(value: 2), concurrent: true)

        XCTAssertEqual(store.subscriptions.count, 0)
    }

    func testReducerDispatchingDuringReductionRaisesFatalError() {
        let weakStore = WeakStoreBox<TestAppState>()
        let store = Store<TestAppState>(
            reducer: { action, state in
                guard action is SetValueAction else { return }
                MainActor.assumeIsolated {
                    self.expectFatalError(expectedMessage:
                        "ReSwift:ConcurrentMutationError- Action has been dispatched while a previous action is being processed. A reducer is dispatching an action, or ReSwift is used in a concurrent context (e.g. from multiple threads). Action: SetValueAction(value: Optional(20))"
                    ) {
                        weakStore.store?.dispatch(SetValueAction(value: 20))
                    }
                }
            },
            state: TestAppState()
        )
        weakStore.store = store

        store.dispatch(SetValueAction(value: 10))
    }
}

extension BatchStoreDispatchTests: @unchecked Sendable {}
