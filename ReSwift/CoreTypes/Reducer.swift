//
//  Reducer.swift
//  ReSwift
//
//  Created by Benjamin Encz on 12/14/15.
//  Copyright © 2015 ReSwift Community. All rights reserved.
//

/// A pure function that reduces an action and current state into a new state.
/// When using a typed store `BatchStore<State, ActionType>`, the reducer must accept that `ActionType`.
public typealias Reducer<ReducerStateType, ActionType: Action> =
    (_ action: ActionType, _ state: inout ReducerStateType) -> Void

/// Convenience alias for `Reducer<State, DefaultStoreAction>`, used with `Store<State>`.
public typealias DefaultReducer<State> = Reducer<State, DefaultStoreAction>
