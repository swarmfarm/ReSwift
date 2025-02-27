//
//  Subscription.swift
//  ReSwift
//

/// Represents a subscription from a subscriber to the store, with optional transformations.
public class Subscription<State> {
    
    /// The closure that is called with changes from the store.
    /// Subclasses or helper methods can write to this `observer`.
    public var observer: ((State?, State) -> Void)?
    
    public init() {}
    
    /**
     Creates a new subscription by providing a sink closure. You get a callback to pass
     old and new states. This effectively sets `observer` for you.
     */
    public init(sink: @escaping (@escaping (State?, State) -> Void) -> Void) {
        sink { old, new in
            self.newValues(oldState: old, newState: new)
        }
    }
    
    /**
     Select a substate by applying the `selector`. The returned subscription holds
     an observer that, when invoked, calls its own subscribers with that substate.
     */
    public func select<Substate>(
        _ selector: @escaping (State) -> Substate
    ) -> Subscription<Substate> {
        return Subscription<Substate> { sink in
            self.observer = { old, new in
                sink(old.map(selector), selector(new))
            }
        }
    }
    
    /**
     Select a substate via a key path.
     */
    public func select<Substate>(_ keyPath: KeyPath<State, Substate>) -> Subscription<Substate> {
        return select { $0[keyPath: keyPath] }
    }
    
    /**
     Skip repeated states. Provide a closure that returns `true` if the old and new states
     are considered “the same” and should be skipped.
     */
    public func skipRepeats(
        _ isRepeat: @escaping (_ oldState: State, _ newState: State) -> Bool
    ) -> Subscription<State> {
        return Subscription<State> { sink in
            self.observer = { old, new in
                if let old = old {
                    if !isRepeat(old, new) {
                        sink(old, new)
                    }
                } else {
                    sink(old, new)
                }
            }
        }
    }
    
    /**
     If the subscription’s state type is Equatable, this convenience lets you skip
     repeated states automatically.
     */
    public func skipRepeats() -> Subscription<State> where State: Equatable {
        return skipRepeats(==)
    }
    
    /**
     Convenience method. This is effectively the same as `skipRepeats(isRepeat:)`.
     */
    public func skip(when: @escaping (_ old: State, _ new: State) -> Bool) -> Subscription<State> {
        return skipRepeats(when)
    }
    
    /**
     The inverse of `skip(when:)`; only forward updates where `when(old,new)` is true.
     */
    public func only(
        when: @escaping (_ old: State, _ new: State) -> Bool
    ) -> Subscription<State> {
        return skipRepeats { old, new in
            return !when(old, new)
        }
    }
    
    /**
     Internal method to notify this subscription of a state update.
     */
    func newValues(oldState: State?, newState: State) {
        observer?(oldState, newState)
    }
}
