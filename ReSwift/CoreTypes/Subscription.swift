//
//  SubscriberWrapper.swift
//  ReSwift
//
//  Created by Virgilio Favero Neto on 4/02/2016.
//  Copyright © 2016 ReSwift Community. All rights reserved.
//

import Foundation

class SubscriptionBox<State> {
    weak var subscriber: AnyStoreSubscriber?

    init(subscriber: AnyStoreSubscriber?) {
        self.subscriber = subscriber
    }

    @inline(__always)
    func newValues(newState: State) {}
}

final class DirectSubscriptionBox<State, S: StoreSubscriber>: SubscriptionBox<State>, @unchecked Sendable
where S.StoreSubscriberStateType == State {
    weak var typedSubscriber: S?

    init(subscriber: S) {
        self.typedSubscriber = subscriber
        super.init(subscriber: subscriber)
    }

    override func newValues(newState: State) {
        typedSubscriber?.newState(state: newState)
    }
}

final class TransformedSubscriptionBox<State, SelectedState, S: StoreSubscriber>: SubscriptionBox<State>, @unchecked Sendable
where S.StoreSubscriberStateType == SelectedState {
    private let originalSubscription: Subscription<State>

    init(
        originalSubscription: Subscription<State>,
        transformedSubscription: Subscription<SelectedState>,
        subscriber: S
    ) where S.StoreSubscriberStateType == SelectedState {
        self.originalSubscription = originalSubscription
        transformedSubscription.observer = { [weak subscriber] newState in
            subscriber?.newState(state: newState)
        }
        super.init(subscriber: subscriber)
    }

    override func newValues(newState: State) {
        originalSubscription.newValues(newState: newState)
    }
}

extension SubscriptionBox: @unchecked Sendable {}

public class Subscription<State> {
    public var observer: ((State) -> Void)?

    public init(sink: @escaping (@escaping (State) -> Void) -> Void) {
        sink { new in
            self.newValues(newState: new)
        }
    }

    init() {}

    public func select<Substate>(
        _ selector: @escaping (borrowing State) -> Substate
    ) -> Subscription<Substate> {
        Subscription<Substate> { sink in
            self.observer = { newState in
                sink(selector(newState))
            }
        }
    }

    public func select<Substate>(
        _ keyPath: KeyPath<State, Substate>
    ) -> Subscription<Substate> {
        Subscription<Substate> { sink in
            self.observer = { newState in
                sink(newState[keyPath: keyPath])
            }
        }
    }

    public func skipRepeats(_ isRepeat: @escaping (_ oldState: State, _ newState: State) -> Bool)
        -> Subscription<State> {
        let stateBox = RepeatStateBox<State>()
        return Subscription<State> { sink in
            self.observer = { newState in
                switch stateBox.update(with: newState) {
                case .first(let current):
                    sink(current)
                case let .next(previous, current):
                    guard !isRepeat(previous, current) else { return }
                    sink(current)
                }
            }
        }
    }

    @inline(__always)
    func newValues(newState: State) {
        observer?(newState)
    }
}

private enum RepeatState<Value> {
    case empty
    case value(Value)
}

private enum RepeatTransition<Value> {
    case first(Value)
    case next(Value, Value)
}

private final class RepeatStateBox<Value>: @unchecked Sendable {
    private var state: RepeatState<Value> = .empty

    @inline(__always)
    func update(with newValue: Value) -> RepeatTransition<Value> {
        switch state {
        case .empty:
            state = .value(newValue)
            return .first(newValue)
        case let .value(previous):
            state = .value(newValue)
            return .next(previous, newValue)
        }
    }
}

extension Subscription: @unchecked Sendable {}

extension Subscription where State: Equatable {
    public func skipRepeats() -> Subscription<State> {
        skipRepeats(==)
    }
}

extension Subscription {
    public func skip(when: @escaping (_ oldState: State, _ newState: State) -> Bool) -> Subscription<State> {
        skipRepeats(when)
    }

    public func only(when: @escaping (_ oldState: State, _ newState: State) -> Bool) -> Subscription<State> {
        skipRepeats { oldState, newState in
            !when(oldState, newState)
        }
    }
}
