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
/**
 This class is the default implementation of the `StoreType` protocol. You will use this store in most
 of your applications. You shouldn't need to implement your own store.
 You initialize the store with a reducer and an initial application state. If your app has multiple
 reducers you can combine them by initializing a `MainReducer` with all of your reducers as an
 argument.
 */
open class BatchStore<State>: StoreType {
    
    typealias SubscriptionType = SubscriptionBox<State>

    private(set) public var state: State!
    
    /// Working queue for timing purposes
    private var batchingQueue: DispatchQueue
    
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
        state: State,
        batchingQueue: DispatchQueue,
        middleware: [Middleware<State>] = [],
        automaticallySkipsRepeats: Bool = true,
        batchingWindow: TimeInterval? = nil
    ) {
        self.subscriptionsAutomaticallySkipRepeats = automaticallySkipsRepeats
        self.reducer = reducer
        self.middleware = middleware
        self.batchingQueue = batchingQueue
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
                    let dispatch: (Action) -> Void = { [weak self] in self?.dispatch($0) }
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

    open func unsubscribe(_ subscriber: AnyStoreSubscriber) {
        #if swift(>=5.0)
        if let index = subscriptions.firstIndex(where: { return $0.subscriber === subscriber }) {
            subscriptions.remove(at: index)
        }
        #else
        if let index = subscriptions.index(where: { return $0.subscriber === subscriber }) {
            subscriptions.remove(at: index)
        }
        #endif
    }
    let subscriptionQueue = DispatchQueue(label: "com.reswift.subscriptionQueue", attributes: .concurrent)


    func notifySubscriptions(previousState: State) {
        let nextState = self.state!
        let previousState = previousState
        
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.reswift.subscriptionQueue", attributes: .concurrent)
        
        subscriptions.forEach { subscription in
            group.enter()
            queue.async {
                if subscription.subscriber == nil {
                    DispatchQueue.main.async { [weak self] in
                        self?.subscriptions.remove(subscription)
                    }
                } else {
                    subscription.newValues(oldState: previousState, newState: nextState)
                }
                group.leave()
            }
        }
        
        group.wait()
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

    open func dispatch(_ action: Action) {
        guard let currentState = state else {
            return
        }
        dispatchFunction(action)
        notifySubscriptions(previousState: currentState)
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
                self.dispatch(action)
            }
        }
    }
    
    public func dispatch(_ asyncActionCreator: Action, callback: ((State) -> Void)?) {
        assertionFailure("Not implemented for BatchStore")
    }

    public typealias DispatchCallback = (State) -> Void
}

// MARK: Skip Repeats for Equatable States

extension BatchStore {
    public func subscribe<SelectedState: Equatable, S: StoreSubscriber>(
        _ subscriber: S, transform: ((Subscription<State>) -> Subscription<SelectedState>)?
        ) where S.StoreSubscriberStateType == SelectedState
    {
        let originalSubscription = Subscription<State>()

        var transformedSubscription = transform?(originalSubscription)
        if subscriptionsAutomaticallySkipRepeats {
            transformedSubscription = transformedSubscription?.skipRepeats()
        }
        _subscribe(subscriber, originalSubscription: originalSubscription,
                   transformedSubscription: transformedSubscription)
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