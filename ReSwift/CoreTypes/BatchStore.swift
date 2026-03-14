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

open class BatchStore<State: Sendable, ActionType: Sendable>: StoreType {
    typealias SubscriptionType = SubscriptionBox<State>

    private struct SubscriptionRecord {
        let id: Int
        let box: SubscriptionType
    }

    private struct UnsafeTransfer<Value>: @unchecked Sendable {
        let value: Value
    }

    private final class RemovalBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [Int] = []

        func append(_ id: Int) {
            lock.lock()
            ids.append(id)
            lock.unlock()
        }

        func snapshot() -> [Int] {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }
    }

    private let actionMapper: @Sendable (any Action) -> ActionType?
    private let reducer: Reducer<State, ActionType>
    private var compiledDispatch: TypedDispatchFunction<ActionType>!

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
    private var _batchedActions: [ActionType] = []
    private var _keyedBatchedActions: [String: ActionType] = [:]

    public private(set) lazy var dispatchFunction: DispatchFunction! = createDispatchFunction()

    private var subscriptionsLock = NSLock()
    private var _subscriptions: [SubscriptionRecord] = []
    private var nextSubscriptionID = 0
    var subscriptions: [SubscriptionType] {
        subscriptionsLock.lock()
        defer { subscriptionsLock.unlock() }
        return _subscriptions.map(\.box)
    }

    private let isDispatchingLock = NSLock()
    private var isDispatching = false

    fileprivate let subscriptionsAutomaticallySkipRepeats: Bool

    public var middleware: [Middleware<State, ActionType>] {
        didSet {
            compiledDispatch = createTypedDispatchFunction()
            dispatchFunction = createDispatchFunction()
        }
    }

    public required init(
        reducer: @escaping Reducer<State, ActionType>,
        state: State?,
        middleware: [Middleware<State, ActionType>] = [],
        automaticallySkipsRepeats: Bool = true,
        batchingWindow: TimeInterval? = nil,
        actionMapper: @escaping @Sendable (any Action) -> ActionType?
    ) {
        self.reducer = reducer
        self.state = state
        self.middleware = middleware
        self.subscriptionsAutomaticallySkipRepeats = automaticallySkipsRepeats
        self.batchingWindow = batchingWindow
        self._batchingWindow = batchingWindow
        self.actionMapper = actionMapper
        self.compiledDispatch = createTypedDispatchFunction()
    }

    public convenience init(
        reducer: @escaping Reducer<State, ActionType>,
        state: State?,
        middleware: [Middleware<State, ActionType>] = [],
        automaticallySkipsRepeats: Bool = true,
        batchingWindow: TimeInterval? = nil
    ) where ActionType: Action {
        self.init(
            reducer: reducer,
            state: state,
            middleware: middleware,
            automaticallySkipsRepeats: automaticallySkipsRepeats,
            batchingWindow: batchingWindow,
            actionMapper: { $0 as? ActionType }
        )
    }

    public convenience init(
        reducer: @escaping DefaultReducer<State>,
        state: State?,
        middleware: [DefaultMiddleware<State>] = [],
        automaticallySkipsRepeats: Bool = true,
        batchingWindow: TimeInterval? = nil
    ) where ActionType == any Action {
        self.init(
            reducer: reducer,
            state: state,
            middleware: middleware,
            automaticallySkipsRepeats: automaticallySkipsRepeats,
            batchingWindow: batchingWindow,
            actionMapper: { $0 }
        )
    }

    private func createTypedDispatchFunction() -> TypedDispatchFunction<ActionType> {
        let terminal: TypedDispatchFunction<ActionType> = { [unowned self] action in
            self._defaultDispatch(action: action)
        }

        guard !middleware.isEmpty else {
            return terminal
        }

        let dispatch: TypedDispatchFunction<ActionType> = { [weak self] action in
            self?.dispatchTyped(action, concurrent: false)
        }
        let getState: @Sendable () -> State? = { [weak self] in
            self?.state
        }

        var next = terminal
        for middleware in middleware.reversed() {
            let nextStage = next
            let context = MiddlewareContext(
                dispatch: dispatch,
                next: nextStage,
                getState: getState
            )
            next = { action in
                middleware(action, context)
            }
        }
        return next
    }

    private func createDispatchFunction() -> DispatchFunction {
        let compiledDispatch = self.compiledDispatch!
        return { [unowned self] action in
            guard let typed = self.actionMapper(action) else { return }
            compiledDispatch(typed)
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

        originalSubscription.newValues(oldState: nil, newState: state)
    }

    open func subscribe<S: StoreSubscriber>(_ subscriber: S)
        where S.StoreSubscriberStateType == State {
        subscribe(subscriber, transform: nil)
    }

    open func subscribe<SelectedState, S: StoreSubscriber>(
        _ subscriber: S,
        transform: ((Subscription<State>) -> Subscription<SelectedState>)?
    ) where S.StoreSubscriberStateType == SelectedState {
        let originalSubscription = Subscription<State>()
        let transformedSubscription = transform?(originalSubscription)

        _subscribe(
            subscriber,
            originalSubscription: originalSubscription,
            transformedSubscription: transformedSubscription
        )
    }

    func subscriptionBox<S: StoreSubscriber>(
        originalSubscription: Subscription<State>,
        transformedSubscription: Subscription<State>?,
        subscriber: S
    ) -> SubscriptionBox<State> where S.StoreSubscriberStateType == State {
        SubscriptionBox(
            originalSubscription: originalSubscription,
            subscriber: subscriber
        )
    }

    func subscriptionBox<T, S: StoreSubscriber>(
        originalSubscription: Subscription<State>,
        transformedSubscription: Subscription<T>?,
        subscriber: S
    ) -> SubscriptionBox<State> where S.StoreSubscriberStateType == T {
        SubscriptionBox(
            originalSubscription: originalSubscription,
            transformedSubscription: transformedSubscription!,
            subscriber: subscriber
        )
    }

    open func unsubscribe(_ subscriber: AnyStoreSubscriber) {
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
        defer { subscriptionsLock.unlock() }

        if let index = _subscriptions.firstIndex(where: { $0.box.subscriber === subscriber }) {
            _subscriptions[index].box.subscriber = nil
            _subscriptions.remove(at: index)
        }
    }

    private func removeSubscriptions(withIDs ids: [Int]) {
        guard !ids.isEmpty else { return }

        let idSet = Set(ids)
        subscriptionsLock.lock()
        _subscriptions.removeAll { record in
            if idSet.contains(record.id) {
                record.box.subscriber = nil
                return true
            }
            return false
        }
        subscriptionsLock.unlock()
    }

    private func subscriptionSnapshot() -> [SubscriptionRecord] {
        subscriptionsLock.lock()
        defer { subscriptionsLock.unlock() }
        return _subscriptions
    }

    private func notifySubscriptionsSequential(
        _ snapshot: [SubscriptionRecord],
        previousState: State?,
        nextState: State
    ) {
        var subscriptionsToRemove: [Int] = []
        subscriptionsToRemove.reserveCapacity(snapshot.count / 8)

        for record in snapshot {
            guard record.box.subscriber != nil else {
                subscriptionsToRemove.append(record.id)
                continue
            }
            record.box.newValues(oldState: previousState, newState: nextState)
        }

        removeSubscriptions(withIDs: subscriptionsToRemove)
    }

    private func notifySubscriptionsConcurrent(
        _ snapshot: [SubscriptionRecord],
        previousState: State?,
        nextState: State
    ) {
        let previousState = UnsafeTransfer(value: previousState)
        let nextState = UnsafeTransfer(value: nextState)
        let subscriptionsToRemove = RemovalBuffer()

        isRunningInGroup = true
        defer { isRunningInGroup = false }

        for record in snapshot {
            if record.box.subscriber == nil {
                subscriptionsToRemove.append(record.id)
                continue
            }

            group.enter()
            concurrentQueue.async { [record, previousState, nextState, subscriptionsToRemove] in
                defer { self.group.leave() }

                guard record.box.subscriber != nil else {
                    subscriptionsToRemove.append(record.id)
                    return
                }

                record.box.newValues(oldState: previousState.value, newState: nextState.value)
            }
        }

        group.wait()
        removeSubscriptions(withIDs: subscriptionsToRemove.snapshot())
    }

    private func shouldCapturePreviousState(for snapshot: [SubscriptionRecord]) -> Bool {
        snapshot.contains { $0.box.requiresOldState }
    }

    private func notifySubscriptions(
        snapshot: [SubscriptionRecord],
        previousState: State?,
        concurrent: Bool = false
    ) {
        let nextState = self.state!
        let shouldRunConcurrently = !isRunningInGroup && concurrent

        if shouldRunConcurrently {
            notifySubscriptionsConcurrent(snapshot, previousState: previousState, nextState: nextState)
        } else {
            notifySubscriptionsSequential(snapshot, previousState: previousState, nextState: nextState)
        }
    }

    private func actionDescription(_ action: ActionType) -> String {
        String(describing: action)
    }

    open func _defaultDispatch(action: ActionType) {
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

        reducer(action, &state)

        isDispatchingLock.lock()
        isDispatching = false
        isDispatchingLock.unlock()
    }

    private func dispatchTyped(_ action: consuming ActionType, concurrent: Bool = false) {
        guard state != nil else { return }

        let snapshot = subscriptionSnapshot()
        guard !snapshot.isEmpty else {
            compiledDispatch(action)
            return
        }

        let currentState = shouldCapturePreviousState(for: snapshot) ? state! : nil
        compiledDispatch(action)
        notifySubscriptions(snapshot: snapshot, previousState: currentState, concurrent: concurrent)
    }

    public func dispatch(_ action: any Action, concurrent: Bool = false) {
        guard let typed = actionMapper(action) else { return }
        dispatchTyped(typed, concurrent: concurrent)
    }

    public func dispatch(_ action: any Action) {
        dispatch(action, concurrent: false)
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

    open func dispatchSync(_ action: any Action, concurrent: Bool = true) {
        if !isOnStoreQueue {
            queue.sync { [weak self] in
                self?.dispatch(action, concurrent: concurrent)
            }
        } else {
            dispatch(action, concurrent: false)
        }
    }

    func runSync(_ block: @escaping () -> Void) {
        if !isOnStoreQueue {
            queue.sync(execute: block)
        } else {
            block()
        }
    }

    open func dispatchAsync(_ action: any Action, concurrent: Bool = false) {
        let action = UnsafeTransfer(value: action)
        queue.async { [weak self] in
            self?.dispatch(action.value, concurrent: concurrent)
        }
    }

    open func dispatchBatched(_ action: any Action) {
        let action = UnsafeTransfer(value: action)
        batchingQueue.async { [weak self] in
            guard let self else { return }
            guard let typed = self.actionMapper(action.value) else { return }

            if let batchingWindow = self._batchingWindow {
                if let keyed = typed as? any BatchedKeyedAction {
                    self._keyedBatchedActions[keyed.batchKey] = typed
                } else {
                    self._batchedActions.append(typed)
                }

                if !self._isBatching {
                    self._isBatching = true
                    self.batchingQueue.asyncAfter(deadline: .now() + batchingWindow) { [weak self] in
                        guard let self else { return }
                        guard let currentState = self.state else { return }

                        for action in self._batchedActions {
                            self.compiledDispatch(action)
                        }
                        for action in self._keyedBatchedActions.values {
                            self.compiledDispatch(action)
                        }
                        self._batchedActions = []
                        self._keyedBatchedActions = [:]

                        let snapshot = self.subscriptionSnapshot()
                        let previousState = self.shouldCapturePreviousState(for: snapshot) ? currentState : nil
                        self.notifySubscriptions(snapshot: snapshot, previousState: previousState)
                        self._isBatching = false
                    }
                }
            } else {
                self.dispatchTyped(typed, concurrent: false)
            }
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
