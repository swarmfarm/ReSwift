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
 You initialize the store with a reducer and an initial application state. If your app has multiple
 reducers you can combine them by initializing a `MainReducer` with all of your reducers as an
 argument.
 */
typealias Store<T> = BatchStore<T, DefaultStoreAction>

open class BatchStore<State, ActionType: Action>: StoreType {
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

    private(set) public var state: State!
    
    /// Working queue for timing purposes
    private lazy var batchingQueue: DispatchQueue = {
        self.queue
    }()
    
    /// Time interval for the system to batch by. Set to nil to disable batching altogether
    public var batchingWindow: TimeInterval? = nil {
        didSet {
            batchingQueue.async { [weak self] in
                guard let self = self else {
                    return
                }
                self._batchingWindow = self.batchingWindow
            }
        }
    }
    
    /// Internal storage for the above variable, only accessed privately via the workingQueue
    private var _batchingWindow: TimeInterval? = nil
    
    /// Becomes true when a batching run is in progress
    private var _isBatching: Bool = false
    
    /// Queue of actions to batch process
    private var _batchedActions: [ActionType] = []
    private var _keyedBatchedActions: [String: ActionType] = [:]

    public lazy var dispatchFunction: DispatchFunction! = createDispatchFunction()

    private var reducer: Reducer<State, ActionType>

    private var subscriptionsLock = NSLock()
    private var _subscriptions: [SubscriptionRecord] = []
    private var nextSubscriptionID = 0
    var subscriptions: [SubscriptionType] {
        get {
            subscriptionsLock.lock()
            defer {
                subscriptionsLock.unlock()
            }
            return _subscriptions.map(\.box)
        }
    }

    private let isDispatchingLock = NSLock()
    private var isDispatching = false

    /// Indicates if new subscriptions attempt to apply `skipRepeats`
    /// by default.
    fileprivate let subscriptionsAutomaticallySkipRepeats: Bool

    public var middleware: [Middleware<State, ActionType>] {
        didSet {
            dispatchFunction = createDispatchFunction()
        }
    }

    /// Converts an `Action` to `ActionType` for processing. For `DefaultStoreAction`, wraps as `.any`.
    /// For other action types, returns `nil` if the action cannot be cast.
    private func toActionType(_ action: Action) -> ActionType? {
        if let typed = action as? ActionType {
            return typed
        }
        if ActionType.self == DefaultStoreAction.self {
            return DefaultStoreAction.any(action) as? ActionType
        }
        return nil
    }

    /// Initializes the store with a reducer, an initial state and a list of middleware.
    ///
    /// Middleware is applied in the order in which it is passed into this constructor.
    ///
    /// - parameter reducer: Main reducer that processes incoming actions.
    /// - parameter state: Initial state, if any. Can be `nil` and will be
    ///   provided by the reducer in that case.
    /// - parameter middleware: Ordered list of action pre-processors, acting
    ///   before the root reducer.
    /// - parameter automaticallySkipsRepeats: If `true`, the store will attempt
    ///   to skip idempotent state updates when a subscriber's state type
    ///   implements `Equatable`. Defaults to `true`.
    public required init(
        reducer: @escaping Reducer<State, ActionType>,
        state: State?,
        middleware: [Middleware<State, ActionType>] = [],
        automaticallySkipsRepeats: Bool = true,
        batchingWindow: TimeInterval? = nil
    ) {
        self.subscriptionsAutomaticallySkipRepeats = automaticallySkipsRepeats
        self.reducer = reducer
        self.middleware = middleware
        self.batchingWindow = batchingWindow
        self._batchingWindow = batchingWindow

        self.state = state
    }

    private func createDispatchFunction() -> DispatchFunction! {
        let typedDispatch: TypedDispatchFunction<ActionType> = { [unowned self] action in
            self._defaultDispatch(action: action)
        }

        let chain: TypedDispatchFunction<ActionType> = middleware
            .reversed()
            .reduce(typedDispatch) { next, middleware in
                let dispatch: TypedDispatchFunction<ActionType> = { [weak self] action in
                    self?.dispatch(action, concurrent: false)
                }
                let getState: () -> State? = { [weak self] in
                    self?.state
                }
                return middleware(dispatch, getState)(next)
            }

        return { [unowned self] action in
            guard let typed = self.toActionType(action) else { return }
            chain(typed)
        }
    }

    fileprivate func _subscribe<SelectedState, S: StoreSubscriber>(
        _ subscriber: S, originalSubscription: Subscription<State>,
        transformedSubscription: Subscription<SelectedState>?)
        where S.StoreSubscriberStateType == SelectedState
    {
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
        _ subscriber: S, transform: ((Subscription<State>) -> Subscription<SelectedState>)?
    ) where S.StoreSubscriberStateType == SelectedState
    {
        // Create a subscription for the new subscriber.
        let originalSubscription = Subscription<State>()
        // Call the optional transformation closure. This allows callers to modify
        // the subscription, e.g. in order to subselect parts of the store's state.
        let transformedSubscription = transform?(originalSubscription)

        _subscribe(subscriber, originalSubscription: originalSubscription,
                   transformedSubscription: transformedSubscription)
    }

    func subscriptionBox<T>(
        originalSubscription: Subscription<State>,
        transformedSubscription: Subscription<T>?,
        subscriber: AnyStoreSubscriber
        ) -> SubscriptionBox<State> {

        return SubscriptionBox(
            originalSubscription: originalSubscription,
            transformedSubscription: transformedSubscription,
            subscriber: subscriber
        )
    }
    #if DEBUG && false
    let log = OSLog(subsystem: "com.reswift", category: "notify")
    #endif
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

                record.box.newValues(
                    oldState: previousState.value,
                    newState: nextState.value
                )
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
    // swiftlint:disable:next identifier_name
    open func _defaultDispatch(action: ActionType) {
        isDispatchingLock.lock()
        guard !isDispatching else {
            isDispatchingLock.unlock()
            raiseFatalError(
                "ReSwift:ConcurrentMutationError- Action has been dispatched while" +
                " a previous action is being processed. A reducer" +
                " is dispatching an action, or ReSwift is used in a concurrent context" +
                " (e.g. from multiple threads). Action: \(action)"
            )
        }
        isDispatching = true
        isDispatchingLock.unlock()

        reducer(action, &state)
        isDispatchingLock.lock()
        isDispatching = false
        isDispatchingLock.unlock()
    }
    
    public func dispatch(_ action: any Action, concurrent: Bool = false) {
        guard state != nil else {
            return
        }
        guard let typed = toActionType(action) else {
            return
        }

        let snapshot = subscriptionSnapshot()
        guard !snapshot.isEmpty else {
            dispatchFunction(typed)
            return
        }

        let currentState = shouldCapturePreviousState(for: snapshot) ? state! : nil
        dispatchFunction(typed)
        notifySubscriptions(snapshot: snapshot, previousState: currentState, concurrent: concurrent)
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
            queue.sync(execute: { [weak self] in
                guard let self else {return}
                self.dispatch(action, concurrent: concurrent)
            })
        }
        else {
            self.dispatch(action, concurrent: false)
        }
    }
    
    func runSync(_ block: @escaping () -> Void) {
        if !isOnStoreQueue {
            queue.sync(execute: block)
        }
        else {
            block()
        }
    }
  
  
   
    open func dispatchAsync(_ action: any Action, concurrent: Bool = false) {
        let action = UnsafeTransfer(value: action)
        queue.async(execute: { [weak self] in
            self?.dispatch(action.value, concurrent: concurrent)
        })
    }
    open func dispatchBatched(_ action: any Action) {
        let action = UnsafeTransfer(value: action)
        batchingQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            guard let typed = self.toActionType(action.value) else {
                return
            }
            if let batchingWindow = self._batchingWindow {
                let batchKey: String?
                if let keyed = typed as? BatchedKeyedAction {
                    batchKey = keyed.batchKey
                } else if case .any(let inner) = typed as? DefaultStoreAction,
                          let keyed = inner as? BatchedKeyedAction {
                    batchKey = keyed.batchKey
                } else {
                    batchKey = nil
                }
                if let key = batchKey {
                    self._keyedBatchedActions[key] = typed
                } else {
                    self._batchedActions.append(typed)
                }
               
                if !self._isBatching {
                    self._isBatching = true
                    self.batchingQueue.asyncAfter(
                        deadline: DispatchTime.now() + batchingWindow,
                        execute: { [weak self] in
                            guard let self = self else {
                                return
                            }
                            guard let currentState = self.state else {
                                return
                            }
                            for action in self._batchedActions {
                                self.dispatchFunction(action)
                            }
                            for action in self._keyedBatchedActions.values {
                                self.dispatchFunction(action)
                            }
                            self._batchedActions = []
                            self._keyedBatchedActions = [:]
                            
                            let snapshot = self.subscriptionSnapshot()
                            let previousState = self.shouldCapturePreviousState(for: snapshot) ? currentState : nil
                            self.notifySubscriptions(snapshot: snapshot, previousState: previousState)
                            self._isBatching = false
                        }
                    )
                }
            }
            else
            {
                // Fallback to synchronous (within the context of the DispatchQueue) if batching is off
                self.dispatch(action.value, concurrent: false)
            }
        }
    }
    
    public func dispatch(_ asyncActionCreator: Action, callback: ((State) -> Void)?) {
        assertionFailure("Not implemented for BatchStore")
    }


  

  
  
    public typealias DispatchCallback = (State) -> Void

    @available(*, deprecated, message: "Deprecated in favor of https://github.com/ReSwift/ReSwift-Thunk")
    public typealias ActionCreator = (_ state: State, _ store: BatchStore<State, ActionType>) -> Action?

    @available(*, deprecated, message: "Deprecated in favor of https://github.com/ReSwift/ReSwift-Thunk")
    public typealias AsyncActionCreator = (
        _ state: State,
        _ store: BatchStore<State, ActionType>,
        _ actionCreatorCallback: @escaping ((ActionCreator) -> Void)
    ) -> Void
    
    public func dispatch(_ actionCreator: (State, BatchStore<State, ActionType>) -> (any Action)?) {
        if let action = actionCreator(state, self) {
            dispatch(action)
        }
    }
    
    public func dispatch(_ asyncActionCreator: @escaping (State, BatchStore<State, ActionType>, @escaping (((State, BatchStore<State, ActionType>) -> (any Action)?) -> Void)) -> Void) {
        dispatch(asyncActionCreator, callback: nil)

    }
    
    public func dispatch(_ asyncActionCreator: (State, BatchStore<State, ActionType>, @escaping (((State, BatchStore<State, ActionType>) -> (any Action)?) -> Void)) -> Void, callback: ((State) -> Void)?) {
        asyncActionCreator(state, self) { [weak self] actionProvider in
            guard let self else {return}
            let action = actionProvider(self.state, self)

            if let action = action {
                self.dispatch(action)
                callback?(self.state)
            }
        }
    }
    
   
    
}

extension BatchStore: @unchecked Sendable {}

// MARK: Skip Repeats for Equatable States

extension BatchStore {
    public func subscribe<SelectedState: Equatable, S: StoreSubscriber>(
        _ subscriber: S, transform: ((Subscription<State>) -> Subscription<SelectedState>)?
        ) where S.StoreSubscriberStateType == SelectedState
    {
        #if DEBUG && false
        let subscriberTypeName = String(describing: type(of: subscriber))
            
        // Start the signpost interval
        let signpostID = OSSignpostID(log: log)
        
        os_signpost(.begin, log: log, name: "Subscribe", signpostID: signpostID, "%{public}s", subscriberTypeName)
        #endif
        runSync { [weak self] in
            guard let self else {return}
            let originalSubscription = Subscription<State>()

            var transformedSubscription = transform?(originalSubscription)
            if self.subscriptionsAutomaticallySkipRepeats {
                transformedSubscription = transformedSubscription?.skipRepeats()
            }
            self._subscribe(subscriber, originalSubscription: originalSubscription,
                       transformedSubscription: transformedSubscription)
        }
        
        // End the signpost interval
#if DEBUG && false
        os_signpost(.end, log: log, name: "Subscribe", signpostID: signpostID, "%{public}s", subscriberTypeName)
#endif
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
