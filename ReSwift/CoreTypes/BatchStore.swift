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

@globalActor
public actor ReSwiftStoreActor {
    public static let shared = ReSwiftStoreActor()
}

@ReSwiftStoreActor
open class BatchStore<State: Sendable>:  @unchecked Sendable {

    
    
    typealias SubscriptionType = SubscriptionBox<State>

    private(set) public var state: State!
    
   
    
    /// Time interval for the system to batch by. Set to nil to disable batching altogether
    public var batchingWindow: TimeInterval? = nil {
        didSet {
            self._batchingWindow = self.batchingWindow
        }
    }
    
    /// Internal storage for the above variable, only accessed privately via the workingQueue
    private var _batchingWindow: TimeInterval? = nil
    
    /// Becomes true when a batching run is in progress
    private var _isBatching: Bool = false
    
    /// Queue of actions to batch process
    private var _batchedActions: [Action] = []
    private var _keyedBatchedActions: [String: Action] = [:]

    public lazy var dispatchFunction: DispatchFunction! = createDispatchFunction()

    private var reducer: Reducer<State>

    private var subscriptionsLock = NSLock()
    private var _subscriptions: Set<SubscriptionType> = []
    var subscriptions: Set<SubscriptionType>   {
        get {
            subscriptionsLock.lock()
            defer {
                subscriptionsLock.unlock()
            }
            return _subscriptions
        }
        set {
            subscriptionsLock.lock()
            defer {
                subscriptionsLock.unlock()
            }
            _subscriptions = newValue
        }
    }

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
                    let dispatch: (Action) async -> Void = { [weak self] in await self?.dispatch($0, concurrent: false) }
                    let getState: () -> State? = { [weak self] in self?.state }
                    return middleware(dispatch, getState)(dispatchFunction)
            })
    }

    fileprivate func _subscribe<SelectedState, S: StoreSubscriber>(
        _ subscriber: S, originalSubscription: Subscription<State>,
        transformedSubscription: Subscription<SelectedState>?) async
        where S.StoreSubscriberStateType == SelectedState
    {
        let subscriptionBox = self.subscriptionBox(
            originalSubscription: originalSubscription,
            transformedSubscription: transformedSubscription,
            subscriber: subscriber
        )

        subscriptions.update(with: subscriptionBox)

        await originalSubscription.newValues(oldState: nil, newState: state)
    }

    open func subscribe<S: StoreSubscriber>(_ subscriber: S) async
        where S.StoreSubscriberStateType == State {
            await subscribe(subscriber, transform: nil)
    }

    open func subscribe<SelectedState, S: StoreSubscriber>(
        _ subscriber: S, transform: ((Subscription<State>) -> Subscription<SelectedState>)?
    ) async where S.StoreSubscriberStateType == SelectedState
    {
        // Create a subscription for the new subscriber.
        let originalSubscription = Subscription<State>()
        // Call the optional transformation closure. This allows callers to modify
        // the subscription, e.g. in order to subselect parts of the store's state.
        let transformedSubscription = transform?(originalSubscription)

        await _subscribe(subscriber, originalSubscription: originalSubscription,
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
    #if DEBUG
    let log = OSLog(subsystem: "com.reswift", category: "notify")
    #endif
    open func unsubscribe(_ subscriber: AnyStoreSubscriber) {
        
        if let index = self.subscriptions.firstIndex(where: { return $0.subscriber === subscriber }) {
            let subscription = self.subscriptions[index]
            subscription.subscriber = nil
            self.subscriptions.remove(at: index)
        }
    
    }

    let group = DispatchGroup()
    

    private var isRunningInGroup = false
    func notifySubscriptions(previousState: State, concurrent: Bool = false) async {
        let nextState = self.state!
        let previousState = previousState
        
        
        
        let shouldRunConcurrently = !isRunningInGroup && concurrent
        
        if shouldRunConcurrently {
            isRunningInGroup = true
           
        }
       
        var subscriptionsToRemove = Set<SubscriptionBox<State>>()
        for subscription in subscriptions {
            if subscription.subscriber == nil {
                subscriptionsToRemove.insert(subscription)
            }
            else {
                #if DEBUG
                let signpostID = OSSignpostID(log: log)
                let subscriberTypeName =  subscription.subscriber?.idKey ?? "none"
               
                #endif
//                TODO: Make this concurrent again
                if shouldRunConcurrently {

                        if subscription.subscriber != nil {
                            #if DEBUG
                            let log = OSLog(subsystem: "com.reswift", category: "notify.concurrent")
                            os_signpost(.begin, log: log, name: "subscription.newValues", signpostID: signpostID, "%{public}s", subscriberTypeName)
                            defer {
                                os_signpost(.end, log: log, name: "subscription.newValues", signpostID: signpostID, "%{public}s", subscriberTypeName)
                            }
                            #endif
                            await subscription.newValues(oldState: previousState, newState: nextState)
                           
                        }
                } else {
                    #if DEBUG
                    os_signpost(.begin, log: log, name: "subscription.newValues", signpostID: signpostID, "%{public}s", subscriberTypeName)
                    defer {
                        os_signpost(.end, log: log, name: "subscription.newValues", signpostID: signpostID, "%{public}s", subscriberTypeName)
                    }
                    #endif
                    await subscription.newValues(oldState: previousState, newState: nextState)
                    
                    
                }
                
            }
        }
       
        
//        if shouldRunConcurrently {
//            
//    
//            isRunningInGroup = false
//            
//        }
        subscriptions.subtract(subscriptionsToRemove)
        
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
        reducer(action, &state)
        isDispatching.value { $0 = false }
    }
    
    public func dispatch(_ action: Action, concurrent: Bool = false) async {
        guard let currentState = state else {
            return
        }
        await dispatchFunction(action)
        await notifySubscriptions(previousState: currentState, concurrent: concurrent)
    }

  
    public func dispatch(_ action: any Action) async {
        await dispatch(action, concurrent: false)
    }
    
  

   
    open func dispatchSync(_ action: Action, concurrent: Bool = true) async {
        await self.dispatch(action, concurrent: concurrent)
    }
    
    func runSync(_ block: @Sendable @escaping () -> Void) {
        block()
    }
  
    
   
    open func dispatchAsync(_ action: Action, concurrent: Bool = false) async {
        await self.dispatch(action, concurrent: concurrent)
    }
    open func dispatchBatched(_ action: Action) async {
        
            if let batchingWindow = self._batchingWindow {
                if let action = action as? BatchedKeyedAction {
                    self._keyedBatchedActions[action.batchKey] = action
                }
                else {
                    self._batchedActions.append(action)
                }
               
                if !self._isBatching {
                    self._isBatching = true
                    Task { @Sendable [weak self] in
                            try await Task.sleep(for: .seconds(batchingWindow))
                            guard let self = self else {
                                return
                            }
                            guard let currentState = self.state else {
                                return
                            }
                            for action in self._batchedActions {
                                await self.dispatchFunction(action)
                            }
                            for action in self._keyedBatchedActions.values {
                                await self.dispatchFunction(action)
                            }
                            self._batchedActions = []
                            self._keyedBatchedActions = [:]
                            
                            await self.notifySubscriptions(previousState: currentState)
                            self._isBatching = false
                        }
                    
                }
            }
            else
            {
                // Fallback to synchronous (within the context of the DispatchQueue) if batching is off
                await self.dispatch(action, concurrent: false)
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
    
    public func dispatch(_ actionCreator: (State, BatchStore<State>) -> (any Action)?) async {
        if let action = actionCreator(state, self) {
            await dispatch(action)
        }
    }
    
    public func dispatch(
        _ asyncActionCreator: (
            State,
            BatchStore<State>,
            @escaping (
                (
                    (
                        State,
                        BatchStore<State>
                    )  -> (
                        any Action
                    )?
                ) async -> Void
            )
        ) -> Void
    ) {
        dispatch(
            asyncActionCreator,
            callback: nil
        )
    }
    
    public func dispatch(
        _ asyncActionCreator: (
            State,
            BatchStore<State>,
            @escaping (
                (
                    (
                        State,
                        BatchStore<State>
                    )  -> (
                        any Action
                    )?
                ) async -> Void
            )
        ) -> Void,
        callback: (
            @Sendable (
                State
            ) -> Void
        )?
    ) {
        asyncActionCreator(
            state,
            self
        ) { [weak self] actionProvider in
            guard let self else {
                return
            }
            let action =  actionProvider(
                self.state,
                self
            )
            
            if let action = action {
                await self.dispatch(
                    action
                )
                callback?(
                    self.state
                )
            }
        }
    }
    


   
   
    
}

// MARK: Skip Repeats for Equatable States

extension BatchStore {
    public func subscribe<SelectedState: Equatable, S: StoreSubscriber>(
        _ subscriber: S, transform: ((Subscription<State>) -> Subscription<SelectedState>)?
        ) async where S.StoreSubscriberStateType == SelectedState
    {
        #if DEBUG
        let subscriberTypeName = String(describing: type(of: subscriber))
            
        // Start the signpost interval
        let signpostID = OSSignpostID(log: log)
        
        os_signpost(.begin, log: log, name: "Subscribe", signpostID: signpostID, "%{public}s", subscriberTypeName)
        #endif
        
        
        let originalSubscription = Subscription<State>()

        var transformedSubscription = transform?(originalSubscription)
        if self.subscriptionsAutomaticallySkipRepeats {
            transformedSubscription = transformedSubscription?.skipRepeats()
        }
        await self._subscribe(subscriber, originalSubscription: originalSubscription,
                   transformedSubscription: transformedSubscription)
    
        
        // End the signpost interval
#if DEBUG
        os_signpost(.end, log: log, name: "Subscribe", signpostID: signpostID, "%{public}s", subscriberTypeName)
#endif
    }
}

extension BatchStore where State: Equatable {
    public func subscribe<S: StoreSubscriber>(_ subscriber: S)
        async where S.StoreSubscriberStateType == State {
            guard subscriptionsAutomaticallySkipRepeats else {
                await subscribe(subscriber, transform: nil)
                return
            }
            await subscribe(subscriber, transform: { $0.skipRepeats() })
    }
}

extension Array {
    func asyncReduce<T>(
        _ initialResult: T,
        _ nextPartialResult: @escaping (T, Element) async -> T
    ) async -> T {
        var result = initialResult
        for element in self {
            result = await nextPartialResult(result, element)
        }
        return result
    }
}
