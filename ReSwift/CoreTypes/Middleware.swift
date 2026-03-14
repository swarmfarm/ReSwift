//
//  Middleware.swift
//  ReSwift
//
//  Created by Benji Encz on 12/24/15.
//  Copyright © 2015 ReSwift Community. All rights reserved.
//

public typealias DispatchFunction = @Sendable (any Action) -> Void

/// A typed dispatch function for use in middleware when the store has a specific action type.
public typealias TypedDispatchFunction<ActionType: Sendable> = @Sendable (consuming ActionType) -> Void

public struct MiddlewareContext<State: Sendable, ActionType: Sendable>: Sendable {
    public let dispatch: TypedDispatchFunction<ActionType>
    public let next: TypedDispatchFunction<ActionType>
    public let getState: @Sendable () -> State?

    public init(
        dispatch: @escaping TypedDispatchFunction<ActionType>,
        next: @escaping TypedDispatchFunction<ActionType>,
        getState: @escaping @Sendable () -> State?
    ) {
        self.dispatch = dispatch
        self.next = next
        self.getState = getState
    }
}

/// Middleware wraps the dispatch function. When using a typed store `BatchStore<State, ActionType>`,
/// the middleware works with that `ActionType` for both the action it receives and the actions it
/// forwards through `dispatch` and `next`.
public typealias Middleware<State: Sendable, ActionType: Sendable> =
    @Sendable (_ action: consuming ActionType, _ context: MiddlewareContext<State, ActionType>) -> Void

/// Convenience alias for `Middleware<State, any Action>`, used with `Store<State>`.
public typealias DefaultMiddleware<State: Sendable> = Middleware<State, any Action>
