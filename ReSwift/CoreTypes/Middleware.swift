//
//  Middleware.swift
//  ReSwift
//

/// The function signature for dispatch in ReSwift
public typealias DispatchFunction = (any Action) -> Void

/**
 Middleware is a function that takes a `dispatch` function and a `getState` closure, and returns
 a new dispatch function. This allows you to "wrap" the dispatch function and do additional work
 before or after calling the original dispatch.
 */
public typealias Middleware<State> = (
    @escaping DispatchFunction,
    @escaping () -> State?
) -> (
    @escaping DispatchFunction
) -> DispatchFunction
