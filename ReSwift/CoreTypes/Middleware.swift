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

@usableFromInline
class MiddlewareRuntime<State: Sendable, ActionType: Sendable>: @unchecked Sendable {
    @usableFromInline
    init() {}

    @usableFromInline
    func send(_ action: consuming ActionType) {
        fatalError("Override in subclass")
    }

    @usableFromInline
    func dispatch(_ action: consuming ActionType) {
        fatalError("Override in subclass")
    }

    @usableFromInline
    func next(_ action: consuming ActionType) {
        fatalError("Override in subclass")
    }

    @usableFromInline
    func getState() -> State? {
        fatalError("Override in subclass")
    }
}

public struct MiddlewareContext<State: Sendable, ActionType: Sendable>: Sendable {
    @usableFromInline
    let runtime: MiddlewareRuntime<State, ActionType>

    @usableFromInline
    init(runtime: MiddlewareRuntime<State, ActionType>) {
        self.runtime = runtime
    }

    @inlinable
    public func dispatch(_ action: consuming ActionType) {
        runtime.dispatch(action)
    }

    @inlinable
    public func next(_ action: consuming ActionType) {
        runtime.next(action)
    }

    @inlinable
    public func getState() -> State? {
        runtime.getState()
    }
}

/// Middleware wraps the dispatch function. When using a typed store `BatchStore<State, ActionType>`,
/// the middleware works with that `ActionType` for both the action it receives and the actions it
/// forwards through `dispatch` and `next`.
public typealias Middleware<State: Sendable, ActionType: Sendable> =
    @Sendable (_ action: consuming ActionType, _ context: MiddlewareContext<State, ActionType>) -> Void

/// Convenience alias for `Middleware<State, any Action>`, used with `Store<State>`.
public typealias DefaultMiddleware<State: Sendable> = Middleware<State, any Action>
