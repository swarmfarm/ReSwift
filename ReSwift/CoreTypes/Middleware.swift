//
//  Middleware.swift
//  ReSwift
//
//  Created by Benji Encz on 12/24/15.
//  Copyright © 2015 ReSwift Community. All rights reserved.
//

/// A dispatch function takes an `Action` and processes it, potentially asynchronously.
public typealias DispatchFunction = @Sendable (Action) async -> Void

/// A middleware function can wrap the dispatch and getState logic, potentially intercepting actions.
/// The shape is basically:
///    middleware(dispatch, getState) -> (next: DispatchFunction) -> DispatchFunction
public typealias Middleware<State> = @Sendable (
    @escaping @Sendable DispatchFunction,         // dispatch
    @escaping @Sendable () async -> State?        // getState
) -> @Sendable (
    @escaping @Sendable DispatchFunction
) -> DispatchFunction
