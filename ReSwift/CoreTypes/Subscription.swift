//
//  SubscriberWrapper.swift
//  ReSwift
//
//  Created by Virgilio Favero Neto on 4/02/2016.
//  Copyright © 2016 ReSwift Community. All rights reserved.
//

import Foundation

class SubscriptionBox<State> {
    private let originalSubscription: Subscription<State>
    weak var subscriber: AnyStoreSubscriber?

    init<T>(
        originalSubscription: Subscription<State>,
        transformedSubscription: Subscription<T>?,
        subscriber: AnyStoreSubscriber
    ) {
        self.originalSubscription = originalSubscription
        self.subscriber = subscriber

        if let transformedSubscription {
            transformedSubscription.observer = { [weak self] _, newState in
                self?.subscriber?._newState(state: newState as Any)
            }
        } else {
            originalSubscription.observer = { [weak self] _, newState in
                self?.subscriber?._newState(state: newState as Any)
            }
        }
    }

    @inline(__always)
    func newValues(oldState: State?, newState: State) {
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
