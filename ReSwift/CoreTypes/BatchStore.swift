//
//  BatchStore.swift
//  ReSwift
//
//  Originally created by Benjamin Encz on 11/11/15.
//  Modified by Andrew Lipscomb on 01/03/23
//  Further revised for Swift 6 concurrency by Some Other Person
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
open class BatchStore<State: Sendable> {
    typealias SubscriptionType = SubscriptionBox<State>

    /// The latest state (actor-isolated).
    private(set) public var state: State!
    
    /// Time interval for the system to batch by. Set to nil to disable batching altogether.
    public var batchingWindow: TimeInterval? = nil {
        didSet { self._batchingWindow = self.batchingWindow }
    }
    
    /// Internal storage for the above variable.
    private var _batchingWindow: TimeInterval? = nil
    
    /// Indicates whether a batching run is in progress.
    private var _isBatching: Bool = false
    
    /// Queue of actions to batch process (for unkeyed batch actions).
    private var _batchedActions: [Action] = []
    
    /// Queue of actions keyed by some “batch key.”
    private var _keyedBatchedActions: [String: Action] = [:]

    /// The main dispatch function, which will be wrapped by any middlewares you provide.
    public lazy var dispatchFunction: DispatchFunction! = createDispatchFunction()

    /// The reducer that processes actions and updates state.
    private var reducer: Reducer<State>

    /// Subscriptions are also actor‐isolated now; we no longer need an NSLock.
    private var _subscriptions: Set<SubscriptionType> = []
    var subscriptions: Set<SubscriptionType> {
        get { _subscriptions }
        set { _subscriptions = newValue }
    }

    /// In older ReSwift versions we used Synchronized<Bool> to guard concurrent dispatch.
    /// Because this is an actor, only one function runs at a time, so concurrency is enforced automatically.
    // private var isDispatching = Synchronized<Bool>(false)

    /// Indicates if new subscriptions attempt to apply `skipRepeats` by default.
    fileprivate let subscriptionsAutomaticallySkipRepeats: Bool

    public var middleware: [Middleware<State>] {
        didSet {
            dispatchFunction = createDispatchFunction()
        }
    }

    // MARK: - Initializer

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

    // MARK: - Middleware Chain

    private func createDispatchFunction() -> DispatchFunction {
        // 1) Define the “base” or “final” dispatch closure for the pipeline.
        //    This is what ultimately calls `_defaultDispatch`.
        //    Mark it as @Sendable and capture `self` weakly so that Swift
        //    sees it as safe to run on any task/thread.
        let baseDispatch: @Sendable (Action) async -> Void = { [weak self] action in
            // If the store was deinitialized, do nothing.
            guard let self = self else { return }
            // Because we are inside the actor, we can call the method directly:
            await self._defaultDispatch(action: action)
        }

        // 2) Fold in each middleware from last to first.
        //    Instead of reduce(...), we do a for-loop. This makes
        //    the captures more explicit and tends to quiet concurrency warnings.
        var currentDispatch = baseDispatch
        for mw in middleware.reversed() {
            let oldDispatch = currentDispatch

            // We build a new function that:
            //  - calls `mw(dispatch, getState)` to get a new function
            //  - calls that function with `next` to get yet another function
            //  - finally calls that with the `action`.
            let newDispatch: @Sendable (Action) async -> Void = { [weak self] action in
                guard let self = self else { return }

                // The "dispatch" parameter passed into the middleware
                let dispatch: DispatchFunction = { act in
                    await oldDispatch(act)
                }

                // The "getState" parameter passed into the middleware
                let getState: @Sendable () async -> State? = { [weak self] in
                    guard let self = self else { return nil }
                    // Because we are inside the actor, this is safe:
                    return await self.state
                }

                // The middleware returns a function that expects “next: DispatchFunction”
                let partiallyApplied = mw(dispatch, getState)

                // Now we define “next” for that function:
                let next: DispatchFunction = { act in
                    await oldDispatch(act)
                }

                // Then we get the final DispatchFunction:
                let finalDispatch = partiallyApplied(next)

                // And finally we call it with the original action.
                await finalDispatch(action)
            }

            currentDispatch = newDispatch
        }

        // 3) Return the fully assembled dispatch function
        return currentDispatch
    }


    // MARK: - Subscriptions

    fileprivate func _subscribe<SelectedState, S: StoreSubscriber>(
        _ subscriber: S,
        originalSubscription: Subscription<State>,
        transformedSubscription: Subscription<SelectedState>?
    ) async where S.StoreSubscriberStateType == SelectedState {
        let subscriptionBox = self.subscriptionBox(
            originalSubscription: originalSubscription,
            transformedSubscription: transformedSubscription,
            subscriber: subscriber
        )

        subscriptions.update(with: subscriptionBox)
        // Immediately notify new subscriber of current state:
        await originalSubscription.newValues(oldState: nil, newState: state)
    }

    open func subscribe<S: StoreSubscriber>(_ subscriber: S) async
        where S.StoreSubscriberStateType == State {
            await subscribe(subscriber, transform: nil)
    }

    open func subscribe<SelectedState, S: StoreSubscriber>(
        _ subscriber: S,
        transform: ((Subscription<State>) -> Subscription<SelectedState>)?
    ) async where S.StoreSubscriberStateType == SelectedState {
        let originalSubscription = Subscription<State>()
        let transformedSubscription = transform?(originalSubscription)
        await _subscribe(
            subscriber,
            originalSubscription: originalSubscription,
            transformedSubscription: transformedSubscription
        )
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

    open func unsubscribe(_ subscriber: AnyStoreSubscriber) {
        if let index = self.subscriptions.firstIndex(where: { $0.subscriber === subscriber }) {
            let subscription = self.subscriptions[index]
            subscription.subscriber = nil
            self.subscriptions.remove(at: index)
        }
    }

    // MARK: - Notifying Subscriptions

    /// Updates all active subscribers with the new state.
    /// (Even though we call it “concurrent” below, the store’s actor isolation ensures
    /// that we never call this simultaneously with another dispatch.)
    // MARK: - Notifying Subscriptions

    func notifySubscriptions(previousState: State) async {
        guard let nextState = self.state else { return }

        // First, remove any subscriptions whose subscriber is nil
        var subscriptionsToRemove = Set<SubscriptionBox<State>>()
        for subscription in subscriptions {
            if subscription.subscriber == nil {
                subscriptionsToRemove.insert(subscription)
            }
        }
        subscriptions.subtract(subscriptionsToRemove)

        // Now we have a stable set of valid subscriptions.
        // We can call them concurrently.
        let validSubscriptions = subscriptions

        await withTaskGroup(of: Void.self) { group in
            for subscription in validSubscriptions {
                group.addTask {
                    // Each subscriber is invoked on its own Task in parallel
                    await subscription.newValues(
                        oldState: previousState,
                        newState: nextState
                    )
                }
            }
            // We automatically wait for all tasks in the group to complete here
        }
    }


    // MARK: - Dispatching

    /// The actual “pure” dispatch that calls your reducer.
    /// Swift actors automatically guarantee only one caller runs this at a time.
    open func _defaultDispatch(action: Action) {
        // The old concurrency check is no longer needed.
        // guard !isDispatching.value else { ... }
        reducer(action, &state)
    }

    /// Public dispatch method. Calls our `dispatchFunction` (which includes the middleware chain),
    /// then notifies subscribers.
    public func dispatch(_ action: Action) async {
        guard let currentState = state else { return }
        await dispatchFunction(action)
        await notifySubscriptions(previousState: currentState)
    }
    
//    // Convenience for code that might pass `Action` existential explicitly.
//    public func dispatch(_ action: any Action) async {
//        await dispatch(action as Action)
//    }

    /// Batching support: queue up actions for a fixed time window, then apply them all at once.
    open func dispatchBatched(_ action: Action) async {
        // If batching is disabled, dispatch immediately:
        guard let batchingWindow = self._batchingWindow else {
            await self.dispatch(action)
            return
        }
        
        // If we have a keyed batched action, overwrite previous for that key:
        if let keyedAction = action as? BatchedKeyedAction {
            self._keyedBatchedActions[keyedAction.batchKey] = action
        } else {
            self._batchedActions.append(action)
        }
        
        // If we aren’t already waiting, set a flag, then wait for the batching window:
        if !_isBatching {
            _isBatching = true
            Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(batchingWindow))
                } catch { /* Task canceled, just return */ return }
                guard let self = self, let currentState = self.state else { return }
                
                // Dispatch each queued action:
                for act in self._batchedActions {
                    await self.dispatchFunction(act)
                }
                for keyedAct in self._keyedBatchedActions.values {
                    await self.dispatchFunction(keyedAct)
                }
                
                // Clear the queues and notify:
                self._batchedActions.removeAll()
                self._keyedBatchedActions.removeAll()
                await self.notifySubscriptions(previousState: currentState)
                self._isBatching = false
            }
        }
    }
    
    // MARK: - Deprecated / ActionCreator stubs

    public func dispatch(_ asyncActionCreator: Action, callback: ((State) -> Void)?) {
        assertionFailure("Not implemented for BatchStore. Use Thunks or other patterns.")
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

    public func dispatch(
        _ actionCreator: (State, BatchStore<State>) -> (any Action)?
    ) async {
        if let action = actionCreator(state, self) {
            await dispatch(action)
        }
    }
    
    public func dispatch(
        _ asyncActionCreator: (
            State,
            BatchStore<State>,
            @escaping (
                (State, BatchStore<State>) -> (any Action)?
            ) async -> Void
        ) -> Void
    ) {
        dispatch(asyncActionCreator, callback: nil)
    }
    
    public func dispatch(
        _ asyncActionCreator: (
            State,
            BatchStore<State>,
            @escaping (
                (State, BatchStore<State>) -> (any Action)?
            ) async -> Void
        ) -> Void,
        callback: ((State) -> Void)?
    ) {
        asyncActionCreator(state, self) { [weak self] actionProvider in
            guard let self = self else { return }
            let action = actionProvider(self.state, self)
            if let action = action {
                await self.dispatch(action)
                callback?(self.state)
            }
        }
    }
}

// MARK: - Skip Repeats for Equatable States

extension BatchStore {
    public func subscribe<SelectedState: Equatable, S: StoreSubscriber>(
        _ subscriber: S,
        transform: ((Subscription<State>) -> Subscription<SelectedState>)?
    ) async where S.StoreSubscriberStateType == SelectedState {
        let originalSubscription = Subscription<State>()
        
        var transformedSubscription = transform?(originalSubscription)
        if self.subscriptionsAutomaticallySkipRepeats {
            transformedSubscription = transformedSubscription?.skipRepeats()
        }
        await self._subscribe(
            subscriber,
            originalSubscription: originalSubscription,
            transformedSubscription: transformedSubscription
        )
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

// MARK: - Utility

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
