//
//  StoreType.swift
//  ReSwift
//
//  Created by Benjamin Encz on 11/28/15.
//  Copyright © 2015 ReSwift Community. All rights reserved.
//


/**
 Defines the interface of Stores in ReSwift. `BatchStore` (or `Store`) is the typical implementation.

 Applications have a single store that stores the entire application state.
 Stores receive actions and use reducers combined with these actions to calculate state changes.
 Upon every state update a store informs all of its subscribers.
 */
@ReSwiftStoreActor
public protocol StoreType: DispatchingStoreType {
    associatedtype State: Sendable

    /// The current state stored in the store. Marked non-optional if you ensure
    /// that it’s always set during initialization.
    var state: State! { get }

    /**
     The main dispatch function that is used by all convenience `dispatch` methods.
     This dispatch function may be extended by providing middlewares.
     */
    var dispatchFunction: DispatchFunction! { get }

    // MARK: - Subscribing

    /**
     Subscribes the provided subscriber to this store.
     Subscribers will receive a call to `newState` whenever the
     state in this store changes.

     - parameter subscriber: Subscriber that will receive store updates
     - note: Subscriptions are not ordered, so an order of state updates cannot be guaranteed.
     */
    func subscribe<S: StoreSubscriber>(_ subscriber: S) async
        where S.StoreSubscriberStateType == State

    /**
     Subscribes the provided subscriber to this store, transforming the subscription
     to optionally select a portion of state.

     - parameter subscriber: Subscriber that will receive store updates
     - parameter transform: A closure that receives a subscription for `State` and returns
       a subscription for the sub-state of interest.
     */
    func subscribe<SelectedState, S: StoreSubscriber>(
        _ subscriber: S,
        transform: ((Subscription<State>) -> Subscription<SelectedState>)?
    ) async where S.StoreSubscriberStateType == SelectedState

    /**
     Subscribes the provided subscriber to this store, with the sub-state being `Equatable`.
     If the store was created with `automaticallySkipsRepeats`, identical state updates are skipped.
     */
    func subscribe<SelectedState: Equatable, S: StoreSubscriber>(
        _ subscriber: S,
        transform: ((Subscription<State>) -> Subscription<SelectedState>)?
    ) async where S.StoreSubscriberStateType == SelectedState

    /**
     Unsubscribes the provided subscriber. The subscriber will no longer
     receive state updates from this store.

     - parameter subscriber: Subscriber that will be unsubscribed
     */
    func unsubscribe(_ subscriber: AnyStoreSubscriber) async

    // MARK: - Dispatching

    /**
     Dispatches a synchronous action to the store. Because this store is actor-isolated,
     only one action may be processed at a time.

     - parameter action: The action to process.
     */
    func dispatch(_ action: Action) async

    /**
     Dispatches an action-creator to the store. Action creators are functions that generate
     actions. They receive the current state and the store itself.
     */
    func dispatch(_ actionCreator: ActionCreator) async

    /**
     Compatibility function: If you still have legacy code that calls `dispatch(_:concurrent:)`,
     you can keep this signature. In an actor‐isolated store, concurrency is moot. Implementations
     can simply ignore the `concurrent` argument or log a warning.
     */
    func dispatch(_ action: Action, concurrent: Bool) async

    // MARK: - Async Action Creators

    /**
     Dispatches an async action creator to the store. An async action creator can generate an
     ActionCreator at some future time.

     Example usage:
     ```
     store.dispatch { state, store, callback in
         Task {
             // do something asynchronous
             // Then dispatch an action by calling the callback:
             await callback { state, store in
                 MyAction()
             }
         }
     }
     ```
     */
    func dispatch(_ asyncActionCreator: AsyncActionCreator)

    /**
     Dispatches an async action creator, providing a callback once the resulting action
     has been processed by the store and new state is calculated.

     - Note: If the asyncActionCreator never actually dispatches anything, `callback` is never invoked.
     */
    func dispatch(_ asyncActionCreator: AsyncActionCreator, callback: DispatchCallback?)

    // MARK: - Callback Types

    /**
     A callback triggered after an asynchronously-dispatched action completes and the new state is calculated.
     */
    associatedtype DispatchCallback = @Sendable (State) -> Void

    /**
     An ActionCreator is a closure that, given the current state and the store, optionally returns an action.
     */
    associatedtype ActionCreator = @Sendable (
        _ state: State,
        _ store: BatchStore<State> // or `Self` if you prefer
    ) -> (any Action)?

    /**
     An AsyncActionCreator is a closure that may produce an ActionCreator asynchronously.
     The store calls your closure, passing `state`, `store`, and a `callback`.
     You run your async code, then call `await callback { ... }` with a closure that returns
     the final `Action` to dispatch.
     */
    associatedtype AsyncActionCreator = @Sendable (
        _ state: State,
        _ store: Self,
        _ callback: @escaping @Sendable (
            @Sendable (State, Self) -> (any Action)?
        ) async -> Void
    ) -> Void
}
