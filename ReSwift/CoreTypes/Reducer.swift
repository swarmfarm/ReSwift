//
//  Reducer.swift
//  ReSwift
//
//  Created by Benjamin Encz on 12/14/15.
//  Copyright © 2015 ReSwift Community. All rights reserved.
//

/// A pure function that reduces an action and current state into a new state.
public typealias Reducer<ReducerStateType: Sendable, ActionType: Sendable> =
    (_ action: borrowing ActionType, _ state: inout ReducerStateType) -> Void

/// Convenience alias for `Reducer<State, any Action>`, used with `Store<State>`.
public typealias DefaultReducer<State: Sendable> = Reducer<State, any Action>
