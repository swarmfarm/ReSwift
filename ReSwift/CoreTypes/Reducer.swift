//
//  Reducer.swift
//  ReSwift
//

/// A Reducer takes an action and the current state, and returns a new state.
public typealias Reducer<ReducerStateType> =
( _ action: borrowing any Action, _ state: inout ReducerStateType) -> ReducerStateType
