import XCTest
@testable import ReSwift

private final class WeakStoreBox<State: Sendable>: @unchecked Sendable {
    weak var store: Store<State>?
}

final class BatchStoreDispatchTests: XCTestCase {
    private final class EscapedContextBox: @unchecked Sendable {
        var context: MiddlewareContext<TestAppState, any Action>?
    }

    func testTypedStoreIgnoresActionsOfTheWrongType() {
        struct TypedState: Equatable, Sendable {
            var value: Int = 0
        }
        struct TypedAction: Action {
            let value: Int
        }
        struct WrongAction: Action {
            let value: Int
        }

        let store = BatchStore<TypedState, TypedAction>(
            reducer: { action, state in
                state.value = action.value
            },
            state: TypedState()
        )

        store.dispatch(WrongAction(value: 99))

        XCTAssertEqual(store.state.value, 0)
    }

    func testMiddlewareDecoratesActionsInOrder() {
        let first: DefaultMiddleware<TestAppState> = { action, context in
            if let labelAction = action as? SetLabelAction {
                context.next(SetLabelAction(value: labelAction.value + " First"))
            } else {
                context.next(action)
            }
        }
        let second: DefaultMiddleware<TestAppState> = { action, context in
            if let labelAction = action as? SetLabelAction {
                context.next(SetLabelAction(value: labelAction.value + " Second"))
            } else {
                context.next(action)
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
        let middleware: DefaultMiddleware<TestAppState> = { action, context in
            if let valueAction = action as? SetValueAction {
                context.dispatch(SetLabelAction(value: "\(valueAction.value ?? 0)"))
            }
            context.next(action)
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

    func testMiddlewareDispatchRunsBeforeContinuingCurrentAction() {
        let middleware: DefaultMiddleware<TestAppState> = { action, context in
            guard action is NoOpAction else {
                context.next(action)
                return
            }

            context.dispatch(AppendLogAction(value: "dispatched"))
            context.next(AppendLogAction(value: "continued"))
        }
        let store = Store(
            reducer: appReducer,
            state: TestAppState(),
            middleware: [middleware]
        )

        store.dispatch(NoOpAction())

        XCTAssertEqual(store.state.log, ["dispatched", "continued"])
    }

    func testMiddlewareCanReadStateAndSwallowAction() {
        let middleware: DefaultMiddleware<TestAppState> = { action, context in
            if context.getState()?.label == "OK", (action as? SetLabelAction)?.value != "Blocked" {
                context.dispatch(SetLabelAction(value: "Blocked"))
                context.next(NoOpAction())
            } else {
                context.next(action)
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

    func testMiddlewareContextCanEscapeAndDispatchLater() {
        let box = EscapedContextBox()
        let completion = expectation(description: "escaped context dispatched action")
        let middleware: DefaultMiddleware<TestAppState> = { action, context in
            if action is NoOpAction {
                box.context = context
            }
            context.next(action)
        }
        let store = Store(
            reducer: appReducer,
            state: TestAppState(),
            middleware: [middleware]
        )
        let subscriber = ClosureSubscriber<TestAppState> { state in
            if state.label == "Escaped" {
                completion.fulfill()
            }
        }
        store.subscribe(subscriber)

        store.dispatch(NoOpAction())
        dispatchAsync {
            box.context?.dispatch(SetLabelAction(value: "Escaped"))
        }

        wait(for: [completion], timeout: 1.0)
        XCTAssertEqual(store.state.label, "Escaped")
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

    func testTypedDispatchOverloadsPreserveBehavior() {
        struct TypedState: Equatable, Sendable {
            var value = 0
        }
        struct TypedAction: Action {
            let value: Int
        }

        let store = BatchStore<TypedState, TypedAction>(
            reducer: { action, state in
                state.value = action.value
            },
            state: TypedState()
        )
        let completion = expectation(description: "typed async dispatched")
        let subscriber = ClosureSubscriber<TypedState> { state in
            if state.value == 4 {
                completion.fulfill()
            }
        }
        store.subscribe(subscriber)

        store.dispatch(TypedAction(value: 1))
        XCTAssertEqual(store.state.value, 1)

        store.dispatchSync(TypedAction(value: 2))
        XCTAssertEqual(store.state.value, 2)

        let batched = expectation(description: "typed batched dispatched")
        let batchedSubscriber = ClosureSubscriber<TypedState> { state in
            if state.value == 3 {
                batched.fulfill()
            }
        }
        store.subscribe(batchedSubscriber)

        store.dispatchBatched(TypedAction(value: 3))
        wait(for: [batched], timeout: 1.0)
        XCTAssertEqual(store.state.value, 3)

        store.dispatchAsync(TypedAction(value: 4))

        wait(for: [completion], timeout: 1.0)
        XCTAssertEqual(store.state.value, 4)
    }

    func testStoreWithStateExposesCurrentValue() {
        let store = Store(reducer: appReducer, state: TestAppState(testValue: 21))

        let value = store.withState { $0?.testValue }

        XCTAssertEqual(value, 21)
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
