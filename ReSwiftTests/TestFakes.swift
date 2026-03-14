import Foundation
import XCTest
@testable import ReSwift

struct TestAppState: Equatable, Sendable {
    var testValue: Int?
    var label: String
    var nested: NestedState
    var log: [String]

    init(
        testValue: Int? = nil,
        label: String = "Initial",
        nested: NestedState = NestedState(),
        log: [String] = []
    ) {
        self.testValue = testValue
        self.label = label
        self.nested = nested
        self.log = log
    }
}

struct NestedState: Equatable, Sendable {
    var value: Int

    init(value: Int = 0) {
        self.value = value
    }
}

struct TestNonEquatableState: Sendable {
    var payload: NonEquatablePayload

    init(payload: NonEquatablePayload = NonEquatablePayload()) {
        self.payload = payload
    }
}

struct NonEquatablePayload: Sendable {
    var value: String

    init(value: String = "Initial") {
        self.value = value
    }
}

struct NoOpAction: Action {}

struct SetValueAction: Action {
    let value: Int?
}

struct IncrementAction: Action {
    let amount: Int
}

struct SetLabelAction: Action {
    let value: String
}

struct SetNestedValueAction: Action {
    let value: Int
}

struct AppendLogAction: Action {
    let value: String
}

struct SetNonEquatableAction: Action {
    let value: String
}

func appReducer(action: any Action, state: inout TestAppState) {
    switch action {
    case let action as SetValueAction:
        state.testValue = action.value
    case let action as IncrementAction:
        state.testValue = (state.testValue ?? 0) + action.amount
    case let action as SetLabelAction:
        state.label = action.value
    case let action as SetNestedValueAction:
        state.nested.value = action.value
    case let action as AppendLogAction:
        state.log.append(action.value)
    default:
        break
    }
}

func nonEquatableReducer(action: any Action, state: inout TestNonEquatableState) {
    if let action = action as? SetNonEquatableAction {
        state.payload = NonEquatablePayload(value: action.value)
    }
}

final class RecordingSubscriber<State>: StoreSubscriber {
    typealias StoreSubscriberStateType = State

    private(set) var receivedStates: [State] = []

    func newState(state: State) {
        receivedStates.append(state)
    }
}

final class ClosureSubscriber<State>: StoreSubscriber {
    typealias StoreSubscriberStateType = State

    private let handler: (State) -> Void

    init(handler: @escaping (State) -> Void) {
        self.handler = handler
    }

    func newState(state: State) {
        handler(state)
    }
}

final class WaitingSubscriber<State>: StoreSubscriber {
    typealias StoreSubscriberStateType = State

    private let started: XCTestExpectation
    private let releaseSemaphore: DispatchSemaphore
    private let lock = NSLock()
    private var hasDeliveredInitialState = false

    init(started: XCTestExpectation, releaseSemaphore: DispatchSemaphore) {
        self.started = started
        self.releaseSemaphore = releaseSemaphore
    }

    func newState(state: State) {
        lock.lock()
        let shouldBlock = hasDeliveredInitialState
        hasDeliveredInitialState = true
        lock.unlock()

        guard shouldBlock else { return }
        started.fulfill()
        _ = releaseSemaphore.wait(timeout: .now() + 1.0)
    }
}

final class QueueRecordingSubscriber<State>: StoreSubscriber {
    typealias StoreSubscriberStateType = State

    private let queueKey: DispatchSpecificKey<Int>
    private let expectedValue: Int
    private let expectation: XCTestExpectation
    private let lock = NSLock()
    private var didReceiveInitialState = false
    private(set) var callbackSawExpectedQueue = false

    init(
        queueKey: DispatchSpecificKey<Int>,
        expectedValue: Int,
        expectation: XCTestExpectation
    ) {
        self.queueKey = queueKey
        self.expectedValue = expectedValue
        self.expectation = expectation
    }

    func newState(state: State) {
        lock.lock()
        let shouldEvaluate = didReceiveInitialState
        didReceiveInitialState = true
        lock.unlock()

        guard shouldEvaluate else { return }
        callbackSawExpectedQueue = DispatchQueue.getSpecific(key: queueKey) == expectedValue
        expectation.fulfill()
    }
}

final class DispatchingSubscriber: StoreSubscriber {
    typealias StoreSubscriberStateType = TestAppState

    private let store: Store<TestAppState>
    private var hasDispatchedFollowUp = false

    init(store: Store<TestAppState>) {
        self.store = store
    }

    func newState(state: TestAppState) {
        guard state.testValue == 2, !hasDispatchedFollowUp else { return }
        hasDispatchedFollowUp = true
        store.dispatchSync(SetValueAction(value: 5))
    }
}

final class DeinitObserver: @unchecked Sendable {
    private let onDeinit: () -> Void

    init(onDeinit: @escaping () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit()
    }
}

final class OwnedStore<State: Sendable>: @unchecked Sendable {
    let observer: DeinitObserver
    let store: Store<State>

    init(
        reducer: @escaping DefaultReducer<State>,
        state: State?,
        middleware: [DefaultMiddleware<State>] = [],
        automaticallySkipsRepeats: Bool = true,
        batchingWindow: TimeInterval? = nil,
        onDeinit: @escaping () -> Void
    ) {
        self.observer = DeinitObserver(onDeinit: onDeinit)
        self.store = Store(
            reducer: reducer,
            state: state,
            middleware: middleware,
            automaticallySkipsRepeats: automaticallySkipsRepeats,
            batchingWindow: batchingWindow
        )
    }
}
