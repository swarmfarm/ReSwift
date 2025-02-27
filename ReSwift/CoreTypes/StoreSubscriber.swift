//
//  StoreSubscriber.swift
//  ReSwift
//

public protocol AnyStoreSubscriber: AnyObject {
    var idKey: String { get set }
    func _newState(state: Any)
}

public protocol StoreSubscriber: AnyStoreSubscriber {
    associatedtype StoreSubscriberStateType
    func newState(state: StoreSubscriberStateType)
}

extension StoreSubscriber {
    public var idKey: String {
        get { return "\(type(of: self))" }
        set { /* No-op by default */ }
    }
    
    public func _newState(state: Any) {
        if let typedState = state as? StoreSubscriberStateType {
            newState(state: typedState)
        }
    }
}
