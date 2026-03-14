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

    private final class TerminalMiddlewareRuntime: MiddlewareRuntime<State, ActionType>, @unchecked Sendable {
        weak var store: BatchStore?

        init(store: BatchStore) {
            self.store = store
        }

        override func send(_ action: consuming ActionType) {
            store?._defaultDispatch(action: action)
        }

        override func dispatch(_ action: consuming ActionType) {
            store?.dispatchTyped(action, concurrent: false)
        }

        override func next(_ action: consuming ActionType) {
            send(action)
        }

        override func getState() -> State? {
            store?.state
        }
    }

    private final class StageMiddlewareRuntime: MiddlewareRuntime<State, ActionType>, @unchecked Sendable {
        weak var store: BatchStore?
        let middleware: Middleware<State, ActionType>
        let nextRuntime: MiddlewareRuntime<State, ActionType>
        lazy var context = MiddlewareContext(runtime: self)

        init(
            store: BatchStore,
            middleware: @escaping Middleware<State, ActionType>,
            nextRuntime: MiddlewareRuntime<State, ActionType>
        ) {
            self.store = store
            self.middleware = middleware
            self.nextRuntime = nextRuntime
        }

        override func send(_ action: consuming ActionType) {
            middleware(action, context)
        }

        override func dispatch(_ action: consuming ActionType) {
            store?.dispatchTyped(action, concurrent: false)
        }

        override func next(_ action: consuming ActionType) {
            nextRuntime.send(action)
        }

        override func getState() -> State? {
            store?.state
        }
    }

    private struct UnsafeTransfer<Value>: @unchecked Sendable {
        let value: Value
    }

    private final class RemovalBuffer: @unchecked Sendable {
        private let lock = UnfairLock()
        private var ids: ContiguousArray<Int> = []

        func append(_ id: Int) {
            lock.withLock {
                ids.append(id)
            }
        }

        func append(contentsOf newIDs: some Sequence<Int>) {
            lock.withLock {
                ids.append(contentsOf: newIDs)
            }
        }

        func snapshot() -> [Int] {
            lock.withLock { Array(ids) }
        }
    }

    private let reducer: Reducer<State, ActionType>
    private var compiledMiddleware: MiddlewareRuntime<State, ActionType>! = nil

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

    public private(set) lazy var dispatchFunction: DispatchFunction! = createDispatchFunction()

    private let subscriptionsLock = UnfairLock()
    private var _subscriptions: ContiguousArray<SubscriptionRecord> = []
    private var nextSubscriptionID = 0
    private let concurrentNotificationChunkCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
    var subscriptions: [SubscriptionType] {
        subscriptionsLock.withLock { _subscriptions.map(\.box) }
    }

    private let isDispatchingLock = UnfairLock()
    private var isDispatching = false

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
        self.compiledMiddleware = createMiddlewareRuntime()
    }

    @inlinable
    public func withState<Result>(_ body: (State?) throws -> Result) rethrows -> Result {
        try body(state)
    }

    private func createMiddlewareRuntime() -> MiddlewareRuntime<State, ActionType> {
        var nextRuntime: MiddlewareRuntime<State, ActionType> = TerminalMiddlewareRuntime(store: self)
        for middleware in middleware.reversed() {
            nextRuntime = StageMiddlewareRuntime(
                store: self,
                middleware: middleware,
                nextRuntime: nextRuntime
            )
        }
        return nextRuntime
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

        subscriptionsLock.withLock {
            _subscriptions.append(SubscriptionRecord(id: nextSubscriptionID, box: subscriptionBox))
            nextSubscriptionID &+= 1
        }

        originalSubscription.newValues(newState: state)
    }

    public func subscribe<S: StoreSubscriber>(_ subscriber: S)
        where S.StoreSubscriberStateType == State {
        subscribe(subscriber, transform: nil)
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
        subscriptionsLock.withLock {
            if let index = _subscriptions.firstIndex(where: { $0.box.subscriber === subscriber }) {
                _subscriptions[index].box.subscriber = nil
                _subscriptions.remove(at: index)
            }
        }
    }

    private func removeSubscriptions(withIDs ids: [Int]) {
        guard !ids.isEmpty else { return }
        subscriptionsLock.withLock {
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
        }
    }

    @inline(__always)
    private func subscriptionSnapshot() -> ContiguousArray<SubscriptionRecord> {
        subscriptionsLock.withLock { _subscriptions }
    }

    @inline(__always)
    private func notifySubscriptionsSequential(
        _ snapshot: ContiguousArray<SubscriptionRecord>,
        nextState: State
    ) {
        var subscriptionsToRemove: ContiguousArray<Int> = []
        subscriptionsToRemove.reserveCapacity(snapshot.count / 8)

        for record in snapshot {
            guard record.box.subscriber != nil else {
                subscriptionsToRemove.append(record.id)
                continue
            }
            record.box.newValues(newState: nextState)
        }

        removeSubscriptions(withIDs: Array(subscriptionsToRemove))
    }

    private func notifySubscriptionsConcurrent(
        _ snapshot: ContiguousArray<SubscriptionRecord>,
        nextState: State
    ) {
        let nextState = UnsafeTransfer(value: nextState)
        let subscriptionsToRemove = RemovalBuffer()
        let chunkCount = min(concurrentNotificationChunkCount, snapshot.count)

        isRunningInGroup = true
        defer { isRunningInGroup = false }

        let chunkSize = (snapshot.count + chunkCount - 1) / chunkCount
        for chunkIndex in 0..<chunkCount {
            let start = chunkIndex * chunkSize
            let end = min(start + chunkSize, snapshot.count)
            guard start < end else { break }

            group.enter()
            concurrentQueue.async { [snapshot, nextState, subscriptionsToRemove] in
                defer { self.group.leave() }
                var localRemovals: ContiguousArray<Int> = []
                localRemovals.reserveCapacity((end - start) / 8)

                for index in start..<end {
                    let record = snapshot[index]
                    guard record.box.subscriber != nil else {
                        localRemovals.append(record.id)
                        continue
                    }

                    record.box.newValues(newState: nextState.value)
                }

                if !localRemovals.isEmpty {
                    subscriptionsToRemove.append(contentsOf: localRemovals)
                }
            }
        }

        group.wait()
        removeSubscriptions(withIDs: subscriptionsToRemove.snapshot())
    }

    @inline(__always)
    private func notifySubscriptions(
        snapshot: ContiguousArray<SubscriptionRecord>,
        concurrent: Bool = false
    ) {
        let nextState = self.state!
        let shouldRunConcurrently = !isRunningInGroup && concurrent

        if shouldRunConcurrently {
            notifySubscriptionsConcurrent(snapshot, nextState: nextState)
        } else {
            notifySubscriptionsSequential(snapshot, nextState: nextState)
        }
    }

    private func actionDescription(_ action: ActionType) -> String {
        String(describing: action)
    }

    @inline(__always)
    private func typedAction(from action: any Action) -> ActionType? {
        action as? ActionType
    }

    public func _defaultDispatch(action: ActionType) {
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

    @inline(__always)
    private func dispatchTyped(_ action: consuming ActionType, concurrent: Bool = false) {
        guard state != nil else { return }

        let snapshot = subscriptionSnapshot()
        guard !snapshot.isEmpty else {
            compiledMiddleware.send(action)
            return
        }

        compiledMiddleware.send(action)
        notifySubscriptions(snapshot: snapshot, concurrent: concurrent)
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

                    for action in self._batchedActions {
                        self.compiledMiddleware.send(action)
                    }
                    self._batchedActions = []

                    let snapshot = self.subscriptionSnapshot()
                    self.notifySubscriptions(snapshot: snapshot)
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
