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
    func newValues(oldState: State?, newState: State) {}
}

final class DirectSubscriptionBox<State, S: StoreSubscriber>: SubscriptionBox<State>, @unchecked Sendable
where S.StoreSubscriberStateType == State {
    weak var typedSubscriber: S?

    init(subscriber: S) {
        self.typedSubscriber = subscriber
        super.init(subscriber: subscriber)
    }

    @inline(__always)
    override func newValues(oldState: State?, newState: State) {
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
    ) {
        self.originalSubscription = originalSubscription
        transformedSubscription.observer = { [weak subscriber] _, newState in
            subscriber?.newState(state: newState)
        }
        super.init(subscriber: subscriber)
    }

    @inline(__always)
    override func newValues(oldState: State?, newState: State) {
        originalSubscription.newValues(oldState: oldState, newState: newState)
    }
}

extension SubscriptionBox: @unchecked Sendable {}

public class Subscription<State> {
    public var observer: ((State?, State) -> Void)?

    public init(sink: @escaping (@escaping (State?, State) -> Void) -> Void) {
        sink { old, new in
            self.newValues(oldState: old, newState: new)
        }
    }

    init() {}

    private func _select<Substate>(
        _ selector: @escaping (borrowing State) -> Substate
    ) -> Subscription<Substate> {
        Subscription<Substate> { sink in
            self.observer = { oldState, newState in
                sink(oldState.map(selector) ?? nil, selector(newState))
            }
        }
    }

    public func select<Substate>(
        _ selector: @escaping (borrowing State) -> Substate
    ) -> Subscription<Substate> {
        _select(selector)
    }

    public func select<Substate>(
        _ keyPath: KeyPath<State, Substate>
    ) -> Subscription<Substate> {
        _select { $0[keyPath: keyPath] }
    }

    public func skipRepeats(_ isRepeat: @escaping (_ oldState: State, _ newState: State) -> Bool)
        -> Subscription<State> {
        Subscription<State> { sink in
            self.observer = { oldState, newState in
                switch (oldState, newState) {
                case let (old?, new):
                    guard !isRepeat(old, new) else { return }
                    sink(oldState, newState)
                default:
                    sink(oldState, newState)
                }
            }
        }
    }

    @inline(__always)
    func newValues(oldState: State?, newState: State) {
        observer?(oldState, newState)
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
