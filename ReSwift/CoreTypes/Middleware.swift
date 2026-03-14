//
//  Middleware.swift
//  ReSwift
//
//  Created by Benji Encz on 12/24/15.
//  Copyright © 2015 ReSwift Community. All rights reserved.
//

public typealias DispatchFunction = (Action) -> Void

/// A typed dispatch function for use in middleware when the store has a specific action type.
public typealias TypedDispatchFunction<ActionType: Action> = (ActionType) -> Void

/// Middleware wraps the dispatch function. When using a typed store `BatchStore<State, ActionType>`,
/// the middleware must work with that `ActionType` for both the action it receives and the dispatch it provides.
public typealias Middleware<State, ActionType: Action> =
    (@escaping TypedDispatchFunction<ActionType>, @escaping () -> State?)
    -> (@escaping TypedDispatchFunction<ActionType>) -> TypedDispatchFunction<ActionType>

/// Convenience alias for `Middleware<State, DefaultStoreAction>`, used with `Store<State>`.
public typealias DefaultMiddleware<State> = Middleware<State, DefaultStoreAction>
