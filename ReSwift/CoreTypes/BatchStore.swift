//
//  BatchStore.swift
//  ReSwift
//
//  Originally created by Benjamin Encz on 11/11/15.
//  Modifed by Andrew Lipscomb on 01/03/23
//  Copyright © 2015 ReSwift Community. All rights reserved.
//
import Foundation
import Dispatch
import os
/**
 This class is the default implementation of the `StoreType` protocol. You will use this store in most
 of your applications. You shouldn't need to implement your own store.
 You initialize the store with a reducer and an initial application state. If your app has multiple
 reducers you can combine them by initializing a `MainReducer` with all of your reducers as an
 argument.
 */
typealias Store<T> = BatchStore<T>

open class BatchStore<State>: StoreType {
  
   
    
    
    typealias SubscriptionType = SubscriptionBox<State>

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
    private var _batchedActions: [Action] = []

    public lazy var dispatchFunction: DispatchFunction! = createDispatchFunction()

    private var reducer: Reducer<State>

    var subscriptions: Set<SubscriptionType> = []

    private var isDispatching = Synchronized<Bool>(false)

    /// Indicates if new subscriptions attempt to apply `skipRepeats`
    /// by default.
    fileprivate let subscriptionsAutomaticallySkipRepeats: Bool

    public var middleware: [Middleware<State>] {
        didSet {
            dispatchFunction = createDispatchFunction()
        }
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
        reducer: @escaping Reducer<State>,
        state: State?,
        middleware: [Middleware<State>] = [],
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
        // Wrap the dispatch function with all middlewares
        return middleware
            .reversed()
            .reduce(
                { [unowned self] action in
                    self._defaultDispatch(action: action) },
                { dispatchFunction, middleware in
                    // If the store get's deinitialized before the middleware is complete; drop
                    // the action without dispatching.
                    let dispatch: (Action) -> Void = { [weak self] in self?.dispatch($0, concurrent: false) }
                    let getState: () -> State? = { [weak self] in self?.state }
                    return middleware(dispatch, getState)(dispatchFunction)
            })
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

        subscriptions.update(with: subscriptionBox)

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
    let log = OSLog(subsystem: "com.reswift", category: "notify")

    open func unsubscribe(_ subscriber: AnyStoreSubscriber) {
        runSync {
            if let index = self.subscriptions.firstIndex(where: { return $0.subscriber === subscriber }) {
                self.subscriptions.remove(at: index)
            }
        }
    }

    let group = DispatchGroup()
    

    private var isRunningInGroup = false
    func notifySubscriptions(previousState: State, concurrent: Bool = false) {
        let nextState = self.state!
        let previousState = previousState
        
        
        
        let shouldRunConcurrently = !isRunningInGroup && concurrent
        
        if shouldRunConcurrently {
            isRunningInGroup = true
           
        }
       
        
        subscriptions.forEach { subscription in
            if subscription.subscriber == nil {
                subscriptions.remove(subscription)
            }
            else {
                let signpostID = OSSignpostID(log: log)
                let subscriberTypeName =  subscription.subscriber?.idKey ?? "none"
               
                
                if shouldRunConcurrently {
                    group.enter()
                    concurrentQueue.async { [weak self] in
                        if subscription.subscriber != nil {
                            let log = OSLog(subsystem: "com.reswift", category: "notify.concurrent")
                            os_signpost(.begin, log: log, name: "subscription.newValues", signpostID: signpostID, "%{public}s", subscriberTypeName)
                            defer {
                                os_signpost(.end, log: log, name: "subscription.newValues", signpostID: signpostID, "%{public}s", subscriberTypeName)
                            }
                            subscription.newValues(oldState: previousState, newState: nextState)
                           
                        }
                        self?.group.leave()
                    }
                } else {
                    os_signpost(.begin, log: log, name: "subscription.newValues", signpostID: signpostID, "%{public}s", subscriberTypeName)
                    defer {
                        os_signpost(.end, log: log, name: "subscription.newValues", signpostID: signpostID, "%{public}s", subscriberTypeName)
                    }
                    subscription.newValues(oldState: previousState, newState: nextState)
                    
                    
                }
                
            }
            
        }
        
        if shouldRunConcurrently {
            group.wait()
    
            isRunningInGroup = false
            
        }
        
    }
    // swiftlint:disable:next identifier_name
    open func _defaultDispatch(action: Action) {
        guard !isDispatching.value else {
            raiseFatalError(
                "ReSwift:ConcurrentMutationError- Action has been dispatched while" +
                " a previous action is being processed. A reducer" +
                " is dispatching an action, or ReSwift is used in a concurrent context" +
                " (e.g. from multiple threads). Action: \(action)"
            )
        }

        isDispatching.value { $0 = true }
        let newState = reducer(action, state)
        isDispatching.value { $0 = false }

        state = newState
    }
    
    public func dispatch(_ action: Action, concurrent: Bool = false) {
        guard let currentState = state else {
            return
        }
        dispatchFunction(action)
        notifySubscriptions(previousState: currentState, concurrent: concurrent)
    }

  
    public func dispatch(_ action: any Action) {
        dispatch(action, concurrent: false)
    }
    
    let queueKey = DispatchSpecificKey<Int>()
    var queueContext = unsafeBitCast(BatchStore.self, to: Int.self)
    var concurrentQueueContext = unsafeBitCast(BatchStore.self, to: Int.self)

    lazy var concurrentQueue: DispatchQueue = {
        let value = DispatchQueue(label: "com.swarmfarm-reswift.concurrentQueue", attributes: .concurrent)
        value.setSpecific(key: self.queueKey, value: concurrentQueueContext)
        return value
    }()

    lazy var queue: DispatchQueue = {
        let value = DispatchQueue(label: "com.swarmfarm-reswift.mainStoreQueue")
        value.setSpecific(key: self.queueKey, value: queueContext)
        return value
    }()

    open func dispatchSync(_ action: Action, concurrent: Bool = true) {
       
        if DispatchQueue.getSpecific(key: self.queueKey) != queueContext && DispatchQueue.getSpecific(key: self.queueKey) != concurrentQueueContext {
            queue.sync(execute: {
                self.dispatch(action, concurrent: concurrent)
            })
        }
        else {
            self.dispatch(action, concurrent: false)
        }
       
//        sendToAnalytics()
    }
    
    func runSync(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: self.queueKey) != queueContext && DispatchQueue.getSpecific(key: self.queueKey) != concurrentQueueContext {
            queue.sync(execute: block)
        }
        else {
            block()
        }
    }
  
   
    open func dispatchAsync(_ action: Action, concurrent: Bool = false) {
        queue.async(execute: {
            self.dispatch(action, concurrent: concurrent)
        })
    }
    open func dispatchBatched(_ action: Action) {
        batchingQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            if let batchingWindow = self._batchingWindow {
                self._batchedActions.append(action)
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
                            self._batchedActions = []
                            
                            self.notifySubscriptions(previousState: currentState)
                            self._isBatching = false
                        }
                    )
                }
            }
            else
            {
                // Fallback to synchronous (within the context of the DispatchQueue) if batching is off
                self.dispatch(action, concurrent: false)
            }
        }
    }
    
    public func dispatch(_ asyncActionCreator: Action, callback: ((State) -> Void)?) {
        assertionFailure("Not implemented for BatchStore")
    }


  

  
  
    public typealias DispatchCallback = (State) -> Void

    @available(*, deprecated, message: "Deprecated in favor of https://github.com/ReSwift/ReSwift-Thunk")
    public typealias ActionCreator = (_ state: State, _ store: BatchStore) -> Action?

    @available(*, deprecated, message: "Deprecated in favor of https://github.com/ReSwift/ReSwift-Thunk")
    public typealias AsyncActionCreator = (
        _ state: State,
        _ store: BatchStore,
        _ actionCreatorCallback: @escaping ((ActionCreator) -> Void)
    ) -> Void
    
    public func dispatch(_ actionCreator: (State, BatchStore<State>) -> (any Action)?) {
        if let action = actionCreator(state, self) {
            dispatch(action)
        }
    }
    
    public func dispatch(_ asyncActionCreator: @escaping (State, BatchStore<State>, @escaping (((State, BatchStore<State>) -> (any Action)?) -> Void)) -> Void) {
        dispatch(asyncActionCreator, callback: nil)

    }
    
    public func dispatch(_ asyncActionCreator: (State, BatchStore<State>, @escaping (((State, BatchStore<State>) -> (any Action)?) -> Void)) -> Void, callback: ((State) -> Void)?) {
        asyncActionCreator(state, self) { actionProvider in
            let action = actionProvider(self.state, self)

            if let action = action {
                self.dispatch(action)
                callback?(self.state)
            }
        }
    }
    
   
    
}

// MARK: Skip Repeats for Equatable States

extension BatchStore {
    public func subscribe<SelectedState: Equatable, S: StoreSubscriber>(
        _ subscriber: S, transform: ((Subscription<State>) -> Subscription<SelectedState>)?
        ) where S.StoreSubscriberStateType == SelectedState
    {
        let subscriberTypeName = String(describing: type(of: subscriber))
            
        // Start the signpost interval
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Subscribe", signpostID: signpostID, "%{public}s", subscriberTypeName)
        
        runSync {
            let originalSubscription = Subscription<State>()

            var transformedSubscription = transform?(originalSubscription)
            if self.subscriptionsAutomaticallySkipRepeats {
                transformedSubscription = transformedSubscription?.skipRepeats()
            }
            self._subscribe(subscriber, originalSubscription: originalSubscription,
                       transformedSubscription: transformedSubscription)
        }
        
        // End the signpost interval
        os_signpost(.end, log: log, name: "Subscribe", signpostID: signpostID, "%{public}s", subscriberTypeName)
        
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
