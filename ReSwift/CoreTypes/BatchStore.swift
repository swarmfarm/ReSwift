//
//  BatchStore.swift
//  ReSwift
//

import Foundation
import Dispatch

/**
 The default store implementation. If you have multiple reducers,
 you can combine them into a single "root" reducer.
 
 This store additionally supports "batching" behavior, wherein actions
 can be queued over a time window before the subscribers are notified.
 */

public typealias Store<T> = BatchStore<T>

public final class BatchStore<State>: @unchecked Sendable where State: Sendable {

    // The state managed by this store
    private(set) public var state: State
    
    // Dispatch function (possibly wrapped by middleware)
    public lazy var dispatchFunction: DispatchFunction! = createDispatchFunction()
    
    // The main reducer for this store
    private var reducer: Reducer<State>
    
    // Middleware pipeline
    public var middleware: [Middleware<State>] {
        didSet {
            dispatchFunction = createDispatchFunction()
        }
    }
    
    // Controls how new subscriptions attempt to skip repeated states if equatable
    fileprivate let subscriptionsAutomaticallySkipRepeats: Bool
    
    // Track if we are in the middle of dispatching
    private var isDispatching = Synchronized<Bool>(false)
    
    // Holds subscriptions
    private var subscriptionsLock = NSLock()
    private var _subscriptions: Set<SubscriptionBox<State>> = []
    var subscriptions: Set<SubscriptionBox<State>> {
        get {
            subscriptionsLock.lock()
            defer { subscriptionsLock.unlock() }
            return _subscriptions
        }
        set {
            subscriptionsLock.lock()
            defer { subscriptionsLock.unlock() }
            _subscriptions = newValue
        }
    }
    
    // MARK: - Batching specifics
    
    /// Time interval for the system to batch actions. If `nil`, batching is disabled.
    public var batchingWindow: TimeInterval? = nil {
        didSet {
            batchingQueue.async { [weak self] in
                guard let self = self else { return }
                self._batchingWindow = self.batchingWindow
            }
        }
    }
    
    // Internal storage for `batchingWindow`, only accessed via the batchingQueue
    private var _batchingWindow: TimeInterval? = nil
    
    // Whether we’re currently in a “batching run”
    private var _isBatching: Bool = false
    
    // Queue of actions to be processed at once
    private var _batchedActions: [any Action] = []
    
    // Serial queue for store mutation
    private lazy var queue: DispatchQueue = {
        let q = DispatchQueue(label: "com.swarmfarm-reswift.mainStoreQueue")
        q.setSpecific(key: self.queueKey, value: queueContext)
        return q
    }()
    
    // A separate concurrency queue for subscriber updates, if used
    private lazy var concurrentQueue: DispatchQueue = {
        let q = DispatchQueue(
            label: "com.swarmfarm-reswift.concurrentQueue",
            qos: .userInteractive,
            attributes: .concurrent
        )
        q.setSpecific(key: self.queueKey, value: concurrentQueueContext)
        return q
    }()
    
    // A separate queue for batching actions
    private lazy var batchingQueue: DispatchQueue = {
        return self.queue
    }()
    
    // A concurrency group used to await subscription notifications
    private let group = DispatchGroup()
    private var isRunningInGroup = false
    
    // Keys to identify the queue context
    let queueKey = DispatchSpecificKey<Int>()
    var queueContext = unsafeBitCast(BatchStore.self, to: Int.self)
    var concurrentQueueContext = unsafeBitCast(BatchStore.self, to: Int.self)
    
    // MARK: - Initializer
    
    /**
     - parameter reducer: Main reducer for processing actions.
     - parameter state: Initial state. Can be `nil` if the reducer provides defaults.
     - parameter middleware: Array of middleware. Applied in the given order.
     - parameter automaticallySkipsRepeats: If `true`, store will skip repeated states
       for equatable substate subscriptions. Default is `true`.
     - parameter batchingWindow: Optional time window for batching actions. `nil` = no batching.
     */
    public required init(
        reducer: @escaping Reducer<State>,
        state: State,
        middleware: [Middleware<State>] = [],
        automaticallySkipsRepeats: Bool = true,
        batchingWindow: TimeInterval? = nil
    ) {
        self.reducer = reducer
        self.state = state
        self.middleware = middleware
        self.subscriptionsAutomaticallySkipRepeats = automaticallySkipsRepeats
        self.batchingWindow = batchingWindow
        self._batchingWindow = batchingWindow
    }
    
    // MARK: - Middleware / Dispatch
    
    private func createDispatchFunction() -> DispatchFunction! {
        // Wrap the store’s default dispatch with all the middleware in reverse order
        let defaultDispatch: DispatchFunction = { [unowned self] action in
            self._defaultDispatch(action: action)
        }
        
        return middleware
            .reversed()
            .reduce(defaultDispatch) { nextDispatch, middleware in
                let dispatch: (any Action) -> Void = { [weak self] action in
                    self?.dispatch(action, concurrent: false)
                }
                let getState: () -> State? = { [weak self] in self?.state }
                return middleware(dispatch, getState)(nextDispatch)
            }
    }
    
    /// The default dispatch function that calls the reducer and updates the state.
    public func _defaultDispatch(action: any Action) {
        guard !isDispatching.value else {
            raiseFatalError("""
            ReSwift:ConcurrentMutationError
            Action \(action) dispatched while a previous action is being processed.
            Possibly a reducer is dispatching an action, or ReSwift is used from multiple threads.
            """)
        }
        
        isDispatching.value { $0 = true }
        let newState = reducer(action, &state)
        isDispatching.value { $0 = false }
        
        state = newState
    }
    
    // MARK: - Public Dispatch Methods
    
    public func dispatch(_ action: any Action) {
        dispatch(action, concurrent: false)
    }
    
    /**
     Dispatch an action. If `concurrent == true`, the subscriber updates may be
     called concurrently. Waits for them to complete if concurrency is used,
     so be mindful of potential for re-entrancy.
     */
    public func dispatch(_ action: any Action, concurrent: Bool) {
        
        dispatchFunction(action)
        notifySubscriptions(previousState: state, concurrent: concurrent)
    }
    
    /**
     Dispatch synchronously on the store’s internal serial queue. If we are
     already on that queue (or on the concurrency queue), it will not do
     another sync.
     */
    public func dispatchSync(_ action: consuming any Action, concurrent: Bool = true) {
        if DispatchQueue.getSpecific(key: self.queueKey) != queueContext
            && DispatchQueue.getSpecific(key: self.queueKey) != concurrentQueueContext {
            queue.sync { [weak self] in
                self?.dispatch(action, concurrent: concurrent)
            }
        } else {
            dispatch(action, concurrent: false)
        }
    }
    
    /**
     Dispatch asynchronously on the store’s internal serial queue.
     */
    public func dispatchAsync(_ action:  any Action, concurrent: Bool = false) {
        queue.async { [weak self] in
            self?.dispatch(action, concurrent: concurrent)
        }
    }
    
    /**
     Dispatch an action in a batched manner if a batching window is set.
     Otherwise dispatch immediately (synchronously on the queue).
     */
    public func dispatchBatched(_ action:  any Action) {
        batchingQueue.async { [weak self] in
            guard let self = self else { return }
            if let batchingWindow = self._batchingWindow {
                self._batchedActions.append(action)
                // If we are not currently batching, schedule a flush
                if !self._isBatching {
                    self._isBatching = true
                    self.batchingQueue.asyncAfter(deadline: .now() + batchingWindow) { [weak self] in
                        guard let self = self else { return }
//                        guard let currentState = self.state else { return }
                        
                        for action in self._batchedActions {
                            self.dispatchFunction(action)
                        }
                        self._batchedActions.removeAll()
                        
                        self.notifySubscriptions(previousState: self.state)
                        self._isBatching = false
                    }
                }
            } else {
                // If batching disabled, fall back to immediate dispatch
                self.dispatch(action, concurrent: false)
            }
        }
    }
    
    // Helper for code that must run on the serial store queue synchronously
    func runSync(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: self.queueKey) != queueContext
            && DispatchQueue.getSpecific(key: self.queueKey) != concurrentQueueContext {
            queue.sync(execute: block)
        } else {
            block()
        }
    }
    
    // MARK: - Subscriber Management
    
    fileprivate func _subscribe<SelectedState, S: StoreSubscriber>(
        _ subscriber: S,
        originalSubscription: Subscription<State>,
        transformedSubscription: Subscription<SelectedState>?
    ) where S.StoreSubscriberStateType == SelectedState {
        
        let subscriptionBox = subscriptionBox(
            originalSubscription: originalSubscription,
            transformedSubscription: transformedSubscription,
            subscriber: subscriber
        )
        
        subscriptions.update(with: subscriptionBox)
        
        // Immediately inform new subscriber of the current state
        originalSubscription.newValues(oldState: nil, newState: state)
    }
    
    public func subscribe<S: StoreSubscriber>(_ subscriber: S)
        where S.StoreSubscriberStateType == State {
            subscribe(subscriber, transform: nil)
    }
    
    public func subscribe<SelectedState, S: StoreSubscriber>(
        _ subscriber: S,
        transform: ((Subscription<State>) -> Subscription<SelectedState>)?
    ) where S.StoreSubscriberStateType == SelectedState {
        
        let originalSubscription = Subscription<State>()
        let transformedSubscription = transform?(originalSubscription)
        _subscribe(subscriber, originalSubscription: originalSubscription,
                   transformedSubscription: transformedSubscription)
    }
    
    func subscriptionBox<T>(
        originalSubscription: Subscription<State>,
        transformedSubscription: Subscription<T>?,
        subscriber: AnyStoreSubscriber
    ) -> SubscriptionBox<State> {
        
        SubscriptionBox(
            originalSubscription: originalSubscription,
            transformedSubscription: transformedSubscription,
            subscriber: subscriber
        )
    }
    
    public func unsubscribe(_ subscriber: AnyStoreSubscriber) {
        runSync { [weak self] in
            guard let self = self else { return }
            if let index = self.subscriptions.firstIndex(where: { $0.subscriber === subscriber }) {
                let subscription = self.subscriptions[index]
                subscription.subscriber = nil
                self.subscriptions.remove(at: index)
            }
        }
    }
    
    /**
     Notify all subscriptions of a state change.
     If concurrent == true, we call them from a concurrent queue and wait.
     Otherwise, we call them inline.
     */
    func notifySubscriptions(previousState: State?, concurrent: Bool = false) {
        let nextState = self.state
        let shouldRunConcurrently = !isRunningInGroup && concurrent
        
        if shouldRunConcurrently {
            isRunningInGroup = true
        }
        
        var subscriptionsToRemove = [SubscriptionBox<State>]()
        
        for subscription in subscriptions {
            if subscription.subscriber == nil {
                subscriptionsToRemove.append(subscription)
            } else {
                if shouldRunConcurrently {
                    group.enter()
                    concurrentQueue.async { [weak self] in
                        defer { self?.group.leave() }
                        subscription.newValues(oldState: previousState, newState: nextState)
                    }
                } else {
                    subscription.newValues(oldState: previousState, newState: nextState)
                }
            }
        }
        
        if shouldRunConcurrently {
            group.wait()
            isRunningInGroup = false
        }
        
        // Remove dead subscriptions
        for subscription in subscriptionsToRemove {
            subscription.subscriber = nil
            subscriptions.remove(subscription)
        }
    }
    
    // MARK: - ActionCreators (deprecated approach)
    
    public func dispatch(_ asyncActionCreator: any Action, callback: ((State) -> Void)?) {
        assertionFailure("Not implemented for BatchStore.")
    }
    
    @available(*, deprecated, message: "Use ReSwift-Thunk or your own approach for async actions.")
    public typealias ActionCreator = (_ state: State, _ store: BatchStore<State>) -> (any Action)?
    
    @available(*, deprecated, message: "Use ReSwift-Thunk or your own approach for async actions.")
    public typealias AsyncActionCreator = (
        _ state: State,
        _ store: BatchStore<State>,
        _ actionCreatorCallback: @escaping ((ActionCreator) -> Void)
    ) -> Void
    
    public func dispatch(_ actionCreator: (State, BatchStore<State>) -> (any Action)?) {
        if let action = actionCreator(state, self) {
            dispatch(action)
        }
    }
    
    public func dispatch(
        _ asyncActionCreator: @escaping (
            State,
            BatchStore<State>,
            @escaping (((State, BatchStore<State>) -> (any Action)?) -> Void)
        ) -> Void
    ) {
        dispatch(asyncActionCreator, callback: nil)
    }
    
    public func dispatch(
        _ asyncActionCreator: (
            State,
            BatchStore<State>,
            @escaping (((State, BatchStore<State>) -> (any Action)?) -> Void)
        ) -> Void,
        callback: ((State) -> Void)?
    ) {
        asyncActionCreator(state, self) { [weak self] actionProvider in
            guard let self = self else { return }
            let action = actionProvider(self.state, self)
            if let action = action {
                self.dispatch(action)
                callback?(self.state)
            }
        }
    }
}

// MARK: - SkipRepeats convenience

extension BatchStore {
    public func subscribe<SelectedState: Equatable, S: StoreSubscriber>(
        _ subscriber: S,
        transform: ((Subscription<State>) -> Subscription<SelectedState>)?
    ) where S.StoreSubscriberStateType == SelectedState {
        runSync { [weak self] in
            guard let self = self else { return }
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
