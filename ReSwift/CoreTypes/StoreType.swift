//
//  StoreType.swift
//  ReSwift
//

/**
 Defines the interface of Stores in ReSwift. Concrete stores like `BatchStore`
 or a simpler `Store` usually implement this.
 */
public protocol StoreType: DispatchingStoreType {
    associatedtype State
    
    /// The current state in the store
    var state: State! { get }
    
    /// The main dispatch function used by convenience dispatch methods, possibly wrapped by middleware.
    var dispatchFunction: DispatchFunction! { get }
    
    /// Subscribe a subscriber to this store to receive state updates.
    func subscribe<S: StoreSubscriber>(_ subscriber: S) where S.StoreSubscriberStateType == State
    
    /// Subscribe with a transform closure that can select a subset of the state or skip repeats.
    func subscribe<SelectedState, S: StoreSubscriber>(
        _ subscriber: S,
        transform: ((Subscription<State>) -> Subscription<SelectedState>)?
    ) where S.StoreSubscriberStateType == SelectedState
    
    /// Subscribe with a transform closure for equatable sub-state. Potentially skip repeated states.
    func subscribe<SelectedState: Equatable, S: StoreSubscriber>(
        _ subscriber: S,
        transform: ((Subscription<State>) -> Subscription<SelectedState>)?
    ) where S.StoreSubscriberStateType == SelectedState
    
    /// Unsubscribe a subscriber from further state updates.
    func unsubscribe(_ subscriber: AnyStoreSubscriber)
    
    // MARK: Deprecated/ReSwift-thunk style signatures
    
    @available(*, deprecated)
    func dispatch(_ actionCreator: ActionCreator)
    
    func dispatch(_ action: any Action, concurrent: Bool)
    
    @available(*, deprecated)
    func dispatch(_ asyncActionCreator: AsyncActionCreator)
    
    @available(*, deprecated)
    func dispatch(_ asyncActionCreator: AsyncActionCreator, callback: DispatchCallback?)
    
    associatedtype DispatchCallback = (State) -> Void
    
    @available(*, deprecated)
    associatedtype ActionCreator = (_ state: State, _ store: Self) -> (any Action)?
    
    @available(*, deprecated)
    associatedtype AsyncActionCreator = (
        _ state: State,
        _ store: Self,
        _ actionCreatorCallback: (ActionCreator) -> Void
    ) -> Void
}
