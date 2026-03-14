//
//  BatchStore.swift
//  ReSwift
//
//  Originally created by Benjamin Encz on 11/11/15.
//  Modifed by Andrew Lipscomb on 01/03/23
//  Copyright © 2015 ReSwift Community. All rights reserved.
//
import Foundation
@preconcurrency import Dispatch
import os

/**
 This class is the default implementation of the `StoreType` protocol. You will use this store in most
 of your applications. You shouldn't need to implement your own store.
 */
public typealias Store<T: Sendable> = BatchStore<T, any Action>

public final class BatchStore<State: Sendable, ActionType: Sendable>: StoreType {
    typealias SubscriptionType = SubscriptionBox<State>

    private struct SubscriptionRecord {
        let id: Int
        let box: SubscriptionType
    }

    private enum Frame {
        case runAction(ActionType)
        case resumeMiddleware(action: ActionType, index: Int)
        case reduce(ActionType)
        case notifySubscribers(
            startIndex: Int,
            snapshot: ContiguousArray<SubscriptionRecord>,
            oldState: State?,
            newState: State
        )
    }

    /// Runtime used when invoking middleware; records dispatch/next for adapter translation.
    /// When used as escaped context (dispatch called later from outside adapter), pushes and runs.
    private final class RecordingMiddlewareRuntime: MiddlewareRuntime<State, ActionType>, @unchecked Sendable {
        weak var store: BatchStore?
        var dispatches: ContiguousArray<ActionType> = []
        var nextAction: ActionType?
        var isInAdapterCall = false
        var pushRunActionAndRunEngineLoop: (@Sendable (ActionType) -> Void)?

        init(store: BatchStore) {
            self.store = store
        }

        func reset() {
            dispatches.removeAll()
            nextAction = nil
        }

        override func send(_ action: consuming ActionType) {
            fatalError("RecordingMiddlewareRuntime.send should not be used")
        }

        override func dispatch(_ action: consuming ActionType) {
            if isInAdapterCall {
                dispatches.append(action)
            } else {
                pushRunActionAndRunEngineLoop?(action)
            }
        }

        override func next(_ action: consuming ActionType) {
            nextAction = action
        }

        override func getState() -> State? {
            store?.state
        }
    }

    private lazy var recordingRuntime: RecordingMiddlewareRuntime = {
        let r = RecordingMiddlewareRuntime(store: self)
        r.pushRunActionAndRunEngineLoop = { [weak self] action in
            self?.pushRunActionAndRunEngineLoop(action)
        }
        return r
    }()

    private struct UnsafeTransfer<Value>: @unchecked Sendable {
        let value: Value
    }

    private final class RemovalBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: ContiguousArray<Int> = []

        func append(_ id: Int) {
            lock.lock()
            ids.append(id)
            lock.unlock()
        }

        func append(contentsOf newIDs: some Sequence<Int>) {
            lock.lock()
            ids.append(contentsOf: newIDs)
            lock.unlock()
        }

        func snapshot() -> [Int] {
            lock.lock()
            let snapshot = Array(ids)
            lock.unlock()
            return snapshot
        }
    }

    private let reducer: Reducer<State, ActionType>

    private var frameStack: ContiguousArray<Frame> = []
    private(set) var isEngineLoopRunning = false

    private(set) public var state: State!

    private lazy var batchingQueue: DispatchQueue = { self.queue }()

    public var batchingWindow: TimeInterval? = nil {
        didSet {
            batchingQueue.async { [weak self] in
                guard let self else { return }
                self._batchingWindow = self.batchingWindow
            }
        }
    }

    private var _batchingWindow: TimeInterval? = nil
    private var _isBatching = false
    private var _batchedActions: ContiguousArray<ActionType> = []
    private var isSuppressingNotifications = false
    private var suppressedOldState: State?
    private var hasSuppressedNotification = false

    public private(set) lazy var dispatchFunction: DispatchFunction! = createDispatchFunction()

    private let subscriptionsLock = NSLock()
    private var _subscriptions: ContiguousArray<SubscriptionRecord> = []
    private var nextSubscriptionID = 0
    var subscriptions: [SubscriptionType] {
        subscriptionsLock.lock()
        let subscriptions = _subscriptions.map(\.box)
        subscriptionsLock.unlock()
        return subscriptions
    }

    private let isDispatchingLock = NSLock()
    private var isDispatching = false
    private var currentNotificationConcurrent = false

    fileprivate let subscriptionsAutomaticallySkipRepeats: Bool
    public let middleware: [Middleware<State, ActionType>]

    public required init(
        reducer: @escaping Reducer<State, ActionType>,
        state: State?,
        middleware: [Middleware<State, ActionType>] = [],
        automaticallySkipsRepeats: Bool = true,
        batchingWindow: TimeInterval? = nil
    ) {
        self.reducer = reducer
        self.state = state
        self.middleware = middleware
        self.subscriptionsAutomaticallySkipRepeats = automaticallySkipsRepeats
        self.batchingWindow = batchingWindow
        self._batchingWindow = batchingWindow
        recordingRuntime.pushRunActionAndRunEngineLoop = { [weak self] action in
            self?.pushRunActionAndRunEngineLoop(action)
        }
    }

    @inlinable
    public func withState<Result>(_ body: (State?) throws -> Result) rethrows -> Result {
        try body(state)
    }

    private func createDispatchFunction() -> DispatchFunction {
        return { [unowned self] action in
            self.dispatch(action)
        }
    }

    fileprivate func _subscribe<SelectedState, S: StoreSubscriber>(
        _ subscriber: S,
        originalSubscription: Subscription<State>,
        transformedSubscription: Subscription<SelectedState>?
    ) where S.StoreSubscriberStateType == SelectedState {
        let subscriptionBox = self.subscriptionBox(
            originalSubscription: originalSubscription,
            transformedSubscription: transformedSubscription,
            subscriber: subscriber
        )

        subscriptionsLock.lock()
        _subscriptions.append(SubscriptionRecord(id: nextSubscriptionID, box: subscriptionBox))
        nextSubscriptionID &+= 1
        subscriptionsLock.unlock()

        if let state {
            subscriptionBox.newValues(oldState: nil, newState: state)
        }
    }

    fileprivate func _subscribeDirect<S: StoreSubscriber>(_ subscriber: S)
        where S.StoreSubscriberStateType == State {
        let subscriptionBox = DirectSubscriptionBox(subscriber: subscriber)

        subscriptionsLock.lock()
        _subscriptions.append(SubscriptionRecord(id: nextSubscriptionID, box: subscriptionBox))
        nextSubscriptionID &+= 1
        subscriptionsLock.unlock()

        if let state {
            subscriptionBox.newValues(oldState: nil, newState: state)
        }
    }

    public func subscribe<S: StoreSubscriber>(_ subscriber: S)
        where S.StoreSubscriberStateType == State {
        runSync { [weak self] in
            self?._subscribeDirect(subscriber)
        }
    }

    public func subscribe<SelectedState, S: StoreSubscriber>(
        _ subscriber: S,
        transform: ((Subscription<State>) -> Subscription<SelectedState>)?
    ) where S.StoreSubscriberStateType == SelectedState {
        runSync { [weak self] in
            guard let self else { return }
            let originalSubscription = Subscription<State>()
            let transformedSubscription = transform?(originalSubscription)

            self._subscribe(
                subscriber,
                originalSubscription: originalSubscription,
                transformedSubscription: transformedSubscription
            )
        }
    }

    func subscriptionBox<S: StoreSubscriber>(
        originalSubscription: Subscription<State>,
        transformedSubscription: Subscription<State>?,
        subscriber: S
    ) -> SubscriptionBox<State> where S.StoreSubscriberStateType == State {
        DirectSubscriptionBox(subscriber: subscriber)
    }

    func subscriptionBox<T, S: StoreSubscriber>(
        originalSubscription: Subscription<State>,
        transformedSubscription: Subscription<T>?,
        subscriber: S
    ) -> SubscriptionBox<State> where S.StoreSubscriberStateType == T {
        TransformedSubscriptionBox(
            originalSubscription: originalSubscription,
            transformedSubscription: transformedSubscription!,
            subscriber: subscriber
        )
    }

    public func unsubscribe(_ subscriber: AnyStoreSubscriber) {
        runSync { [weak self] in
            self?.removeFirstSubscription(for: subscriber)
        }
    }

    let group = DispatchGroup()
    private var isRunningInGroup = false

    private var isOnStoreQueue: Bool {
        let currentContext = DispatchQueue.getSpecific(key: queueKey)
        return currentContext == queueContext || currentContext == concurrentQueueContext
    }

    private func removeFirstSubscription(for subscriber: AnyStoreSubscriber) {
        subscriptionsLock.lock()
        if let index = _subscriptions.firstIndex(where: { $0.box.subscriber === subscriber }) {
            _subscriptions[index].box.subscriber = nil
            _subscriptions.remove(at: index)
        }
        subscriptionsLock.unlock()
    }

    private func removeSubscriptions(withIDs ids: [Int]) {
        guard !ids.isEmpty else { return }
        subscriptionsLock.lock()
        switch ids.count {
        case 1:
            let target = ids[0]
            _subscriptions.removeAll { record in
                guard record.id == target else { return false }
                record.box.subscriber = nil
                return true
            }
        default:
            let idSet = Set(ids)
            _subscriptions.removeAll { record in
                guard idSet.contains(record.id) else { return false }
                record.box.subscriber = nil
                return true
            }
        }
        subscriptionsLock.unlock()
    }

    @inline(__always)
    private func subscriptionSnapshot() -> ContiguousArray<SubscriptionRecord> {
        subscriptionsLock.lock()
        let snapshot = _subscriptions
        subscriptionsLock.unlock()
        return snapshot
    }

    @inline(__always)
    private func notifySubscriptionsSequential(
        _ snapshot: ContiguousArray<SubscriptionRecord>,
        oldState: State?,
        newState: State
    ) {
        var subscriptionsToRemove: ContiguousArray<Int> = []
        subscriptionsToRemove.reserveCapacity(snapshot.count / 8)

        for record in snapshot {
            guard record.box.subscriber != nil else {
                subscriptionsToRemove.append(record.id)
                continue
            }
            record.box.newValues(oldState: oldState, newState: newState)
        }

        removeSubscriptions(withIDs: Array(subscriptionsToRemove))
    }

    private func notifySubscriptionsConcurrent(
        _ snapshot: ContiguousArray<SubscriptionRecord>,
        oldState: State?,
        newState: State
    ) {
        let oldState = UnsafeTransfer(value: oldState)
        let newState = UnsafeTransfer(value: newState)
        let subscriptionsToRemove = RemovalBuffer()

        isRunningInGroup = true
        defer { isRunningInGroup = false }

        for record in snapshot {
            if record.box.subscriber == nil {
                subscriptionsToRemove.append(record.id)
                continue
            }

            group.enter()
            concurrentQueue.async { [record, oldState, newState, subscriptionsToRemove] in
                defer { self.group.leave() }

                guard record.box.subscriber != nil else {
                    subscriptionsToRemove.append(record.id)
                    return
                }

                record.box.newValues(oldState: oldState.value, newState: newState.value)
            }
        }

        group.wait()
        removeSubscriptions(withIDs: subscriptionsToRemove.snapshot())
    }

    @inline(__always)
    private func notifySubscriptions(
        snapshot: ContiguousArray<SubscriptionRecord>,
        oldState: State?,
        newState: State,
        concurrent: Bool = false
    ) {
        let shouldRunConcurrently = !isRunningInGroup && concurrent

        if shouldRunConcurrently {
            notifySubscriptionsConcurrent(snapshot, oldState: oldState, newState: newState)
        } else {
            notifySubscriptionsSequential(snapshot, oldState: oldState, newState: newState)
        }
    }

    private func actionDescription(_ action: ActionType) -> String {
        String(describing: action)
    }

    @inline(__always)
    private func typedAction(from action: any Action) -> ActionType? {
        action as? ActionType
    }

    private func pushRunActionAndRunEngineLoop(_ action: ActionType) {
        isDispatchingLock.lock()
        guard !isDispatching else {
            isDispatchingLock.unlock()
            raiseFatalError(
                "ReSwift:ConcurrentMutationError- Action has been dispatched while" +
                " a previous action is being processed. A reducer" +
                " is dispatching an action, or ReSwift is used in a concurrent context" +
                " (e.g. from multiple threads). Action: \(actionDescription(action))"
            )
        }
        isDispatchingLock.unlock()
        frameStack.append(.runAction(action))
        runEngineLoop()
    }

    private func runEngineLoop() {
        guard !isEngineLoopRunning else { return }
        isEngineLoopRunning = true
        defer { isEngineLoopRunning = false }

        while let frame = frameStack.popLast() {
            switch frame {
            case .runAction(let action):
                if middleware.isEmpty {
                    frameStack.append(.reduce(action))
                } else {
                    frameStack.append(.resumeMiddleware(action: action, index: 0))
                }

            case .resumeMiddleware(let action, let index):
                if index == middleware.count {
                    frameStack.append(.reduce(action))
                    continue
                }
                applyAdapterResult(at: index, action: action)

            case .reduce(let action):
                isDispatchingLock.lock()
                guard !isDispatching else {
                    isDispatchingLock.unlock()
                    raiseFatalError(
                        "ReSwift:ConcurrentMutationError- Action has been dispatched while" +
                        " a previous action is being processed. A reducer" +
                        " is dispatching an action, or ReSwift is used in a concurrent context" +
                        " (e.g. from multiple threads). Action: \(actionDescription(action))"
                    )
                }
                isDispatching = true
                isDispatchingLock.unlock()

                let oldState = state
                reducer(action, &state)

                isDispatchingLock.lock()
                isDispatching = false
                isDispatchingLock.unlock()

                guard let newState = state else { continue }
                if isSuppressingNotifications {
                    if !hasSuppressedNotification {
                        suppressedOldState = oldState
                        hasSuppressedNotification = true
                    }
                    continue
                }
                let snapshot = subscriptionSnapshot()
                if snapshot.isEmpty { continue }

                let shouldRunConcurrently = !isRunningInGroup && currentNotificationConcurrent
                if shouldRunConcurrently {
                    notifySubscriptionsConcurrent(snapshot, oldState: oldState, newState: newState)
                } else {
                    frameStack.append(.notifySubscribers(
                        startIndex: 0,
                        snapshot: snapshot,
                        oldState: oldState,
                        newState: newState
                    ))
                }

            case .notifySubscribers(let startIndex, let snapshot, let oldState, let newState):
                if startIndex >= snapshot.count {
                    var idsToRemove: [Int] = []
                    for record in snapshot where record.box.subscriber == nil {
                        idsToRemove.append(record.id)
                    }
                    removeSubscriptions(withIDs: idsToRemove)
                    continue
                }
                frameStack.append(.notifySubscribers(
                    startIndex: startIndex + 1,
                    snapshot: snapshot,
                    oldState: oldState,
                    newState: newState
                ))
                let record = snapshot[startIndex]
                if record.box.subscriber != nil {
                    record.box.newValues(oldState: oldState, newState: newState)
                }
            }
        }
    }

    private func applyAdapterResult(at index: Int, action: ActionType) {
        recordingRuntime.reset()
        recordingRuntime.isInAdapterCall = true
        defer { recordingRuntime.isInAdapterCall = false }

        let context = MiddlewareContext(runtime: recordingRuntime)
        middleware[index](action, context)

        let dispatches = recordingRuntime.dispatches
        let nextAction = recordingRuntime.nextAction

        if let next = nextAction {
            if dispatches.isEmpty {
                frameStack.append(.resumeMiddleware(action: next, index: index + 1))
            } else {
                frameStack.append(.resumeMiddleware(action: next, index: index + 1))
                for d in dispatches.reversed() {
                    frameStack.append(.runAction(d))
                }
            }
        } else {
            if !dispatches.isEmpty {
                for d in dispatches.reversed() {
                    frameStack.append(.runAction(d))
                }
            }
        }
    }

    @inline(__always)
    private func dispatchTyped(_ action: consuming ActionType, concurrent: Bool = false) {
        guard state != nil else { return }
        let previousConcurrent = currentNotificationConcurrent
        currentNotificationConcurrent = concurrent
        pushRunActionAndRunEngineLoop(action)
        currentNotificationConcurrent = previousConcurrent
    }

    public func dispatch(_ action: any Action, concurrent: Bool = false) {
        guard let typed = typedAction(from: action) else { return }
        dispatchTyped(typed, concurrent: concurrent)
    }

    public func dispatch(_ action: consuming ActionType, concurrent: Bool = false) where ActionType: Action {
        dispatchTyped(action, concurrent: concurrent)
    }

    public func dispatch(_ action: any Action) {
        dispatch(action, concurrent: false)
    }

    public func dispatch(_ action: consuming ActionType) where ActionType: Action {
        dispatchTyped(action, concurrent: false)
    }

    let queueKey = DispatchSpecificKey<Int>()
    var queueContext = unsafeBitCast(BatchStore.self, to: Int.self)
    var concurrentQueueContext = unsafeBitCast(BatchStore.self, to: Int.self)

    lazy var concurrentQueue: DispatchQueue = {
        let value = DispatchQueue(
            label: "com.swarmfarm-reswift.concurrentQueue",
            qos: .userInteractive,
            attributes: .concurrent
        )
        value.setSpecific(key: self.queueKey, value: concurrentQueueContext)
        return value
    }()

    lazy var queue: DispatchQueue = {
        let value = DispatchQueue(label: "com.swarmfarm-reswift.mainStoreQueue")
        value.setSpecific(key: self.queueKey, value: queueContext)
        return value
    }()

    public func dispatchSync(_ action: any Action, concurrent: Bool = true) {
        if !isOnStoreQueue {
            queue.sync { [weak self] in
                self?.dispatch(action, concurrent: concurrent)
            }
        } else {
            dispatch(action, concurrent: false)
        }
    }

    public func dispatchSync(_ action: consuming ActionType, concurrent: Bool = true) where ActionType: Action {
        if !isOnStoreQueue {
            let action = UnsafeTransfer(value: action)
            queue.sync { [weak self] in
                self?.dispatchTyped(action.value, concurrent: concurrent)
            }
        } else {
            dispatchTyped(action, concurrent: false)
        }
    }

    func runSync(_ block: @escaping () -> Void) {
        if !isOnStoreQueue {
            queue.sync(execute: block)
        } else {
            block()
        }
    }

    public func dispatchAsync(_ action: any Action, concurrent: Bool = false) {
        let action = UnsafeTransfer(value: action)
        queue.async { [weak self] in
            self?.dispatch(action.value, concurrent: concurrent)
        }
    }

    public func dispatchAsync(_ action: consuming ActionType, concurrent: Bool = false) where ActionType: Action {
        let action = UnsafeTransfer(value: action)
        queue.async { [weak self] in
            self?.dispatchTyped(action.value, concurrent: concurrent)
        }
    }

    public func dispatchBatched(_ action: any Action) {
        let action = UnsafeTransfer(value: action)
        batchingQueue.async { [weak self] in
            guard let self else { return }
            guard let typed = self.typedAction(from: action.value) else { return }

            self.enqueueBatchedAction(typed)
        }
    }

    public func dispatchBatched(_ action: consuming ActionType) where ActionType: Action {
        let action = UnsafeTransfer(value: action)
        batchingQueue.async { [weak self] in
            self?.enqueueBatchedAction(action.value)
        }
    }

    private func enqueueBatchedAction(_ action: ActionType) {
        if let batchingWindow = _batchingWindow {
            if _batchedActions.isEmpty {
                _batchedActions.reserveCapacity(16)
            }
            _batchedActions.append(action)

            if !_isBatching {
                _isBatching = true
                batchingQueue.asyncAfter(deadline: .now() + batchingWindow) { [weak self] in
                    guard let self else { return }
                    guard self.state != nil else { return }

                    let previousConcurrent = self.currentNotificationConcurrent
                    self.currentNotificationConcurrent = false
                    self.isSuppressingNotifications = true
                    self.suppressedOldState = nil
                    self.hasSuppressedNotification = false
                    for action in self._batchedActions {
                        self.pushRunActionAndRunEngineLoop(action)
                    }
                    self.isSuppressingNotifications = false
                    self.currentNotificationConcurrent = previousConcurrent
                    self._batchedActions = []
                    if self.hasSuppressedNotification, let newState = self.state {
                        let snapshot = self.subscriptionSnapshot()
                        if !snapshot.isEmpty {
                            self.notifySubscriptions(
                                snapshot: snapshot,
                                oldState: self.suppressedOldState,
                                newState: newState,
                                concurrent: false
                            )
                        }
                    }
                    self.suppressedOldState = nil
                    self.hasSuppressedNotification = false
                    self._isBatching = false
                }
            }
        } else {
            dispatchTyped(action, concurrent: false)
        }
    }

    public func dispatch(_ asyncActionCreator: any Action, callback: ((State) -> Void)?) {
        assertionFailure("Not implemented for BatchStore")
    }

    public typealias DispatchCallback = (State) -> Void

    @available(*, deprecated, message: "Deprecated in favor of https://github.com/ReSwift/ReSwift-Thunk")
    public typealias ActionCreator = (_ state: State, _ store: BatchStore<State, ActionType>) -> (any Action)?

    @available(*, deprecated, message: "Deprecated in favor of https://github.com/ReSwift/ReSwift-Thunk")
    public typealias AsyncActionCreator = (
        _ state: State,
        _ store: BatchStore<State, ActionType>,
        _ actionCreatorCallback: @escaping (ActionCreator) -> Void
    ) -> Void

    public func dispatch(_ actionCreator: (State, BatchStore<State, ActionType>) -> (any Action)?) {
        if let action = actionCreator(state, self) {
            dispatch(action)
        }
    }

    public func dispatch(
        _ asyncActionCreator: @escaping (
            State,
            BatchStore<State, ActionType>,
            @escaping (((State, BatchStore<State, ActionType>) -> (any Action)?) -> Void)
        ) -> Void
    ) {
        dispatch(asyncActionCreator, callback: nil)
    }

    public func dispatch(
        _ asyncActionCreator: (
            State,
            BatchStore<State, ActionType>,
            @escaping (((State, BatchStore<State, ActionType>) -> (any Action)?) -> Void)
        ) -> Void,
        callback: ((State) -> Void)?
    ) {
        asyncActionCreator(state, self) { [weak self] actionProvider in
            guard let self else { return }
            let action = actionProvider(self.state, self)
            if let action {
                self.dispatch(action)
                callback?(self.state)
            }
        }
    }
}

extension BatchStore: @unchecked Sendable {}

extension BatchStore {
    public func subscribe<SelectedState: Equatable, S: StoreSubscriber>(
        _ subscriber: S,
        transform: ((Subscription<State>) -> Subscription<SelectedState>)?
    ) where S.StoreSubscriberStateType == SelectedState {
        runSync { [weak self] in
            guard let self else { return }
            let originalSubscription = Subscription<State>()

            var transformedSubscription = transform?(originalSubscription)
            if self.subscriptionsAutomaticallySkipRepeats {
                transformedSubscription = transformedSubscription?.skipRepeats()
            }

            self._subscribe(
                subscriber,
                originalSubscription: originalSubscription,
                transformedSubscription: transformedSubscription
            )
        }
    }
}

extension BatchStore where State: Equatable {
    public func subscribe<S: StoreSubscriber>(_ subscriber: S)
        where S.StoreSubscriberStateType == State {
        guard subscriptionsAutomaticallySkipRepeats else {
            subscribe(subscriber, transform: nil)
            return
        }
        subscribe(subscriber, transform: { $0.skipRepeats() })
    }
}
