# Migration Guide

This guide covers the middleware and store API changes introduced by the middleware/runtime refactor.

## Behavior

Runtime behavior is unchanged:

- `dispatch`, `dispatchSync`, `dispatchAsync`, and `dispatchBatched` are still available.
- Middleware still runs in declaration order.
- Middleware can still dispatch additional actions, swallow actions, and read current state.
- Middleware contexts can still escape and be used later.
- Concurrent subscriber delivery behavior is unchanged.

## What Changed

`MiddlewareContext` is now method-based instead of exposing stored escaping closures.

Before:

```swift
let middleware: DefaultMiddleware<AppState> = { action, context in
    if context.getState()?.isEnabled == true {
        context.dispatch(DoSomething())
    }
    context.next(action)
}
```

After:

```swift
let middleware: DefaultMiddleware<AppState> = { action, context in
    if context.getState()?.isEnabled == true {
        context.dispatch(DoSomething())
    }
    context.next(action)
}
```

The common call sites are intentionally the same. What changed is the shape of `MiddlewareContext` itself.

## Breaking API Changes

- `BatchStore` is now `final`.
- `MiddlewareContext.dispatch`, `MiddlewareContext.next`, and `MiddlewareContext.getState` are methods now, not stored closure properties.
- `MiddlewareContext` is no longer intended to be manually initialized by library users.
- Code that captured `context.dispatch`, `context.next`, or `context.getState` as standalone function values must now capture `context` and call the method later.
- `BatchedKeyedAction` was removed. `dispatchBatched` now preserves insertion order for all batched actions and no longer coalesces by key.

Before:

```swift
let later = context.dispatch
later(MyAction())
```

After:

```swift
let later = context
later.dispatch(MyAction())
```

Typed stores now have typed overloads for:

- `dispatch(_ action: ActionType)`
- `dispatch(_ action: ActionType, concurrent: Bool)`
- `dispatchSync(_ action: ActionType, concurrent: Bool)`
- `dispatchAsync(_ action: ActionType, concurrent: Bool)`
- `dispatchBatched(_ action: ActionType)`

This means typed stores no longer have to go through the existential `any Action` entry point for normal dispatch.

## Migration Checklist

- Keep existing middleware bodies as-is if they already call `context.dispatch(...)`, `context.next(...)`, and `context.getState()`.
- Replace any stored references to `context.dispatch`, `context.next`, or `context.getState` with stored references to `context`.
- Keep using `context.getState()` for middleware state reads.
- Prefer typed dispatch overloads when working with `BatchStore<State, ActionType>` directly.
- Remove any `BatchStore` subclasses and use composition instead.
- Replace any `BatchedKeyedAction` conformances with plain `Action` types.
