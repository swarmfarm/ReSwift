//
//  StoreSubscriber.swift
//  ReSwift
//
//  Created by Benjamin Encz on 12/14/15.
//  Copyright © 2015 ReSwift Community. All rights reserved.
//

public protocol AnyStoreSubscriber: AnyObject, Sendable {
    var idKey: String  {get set}

    // swiftlint:disable:next identifier_name
    func _newState(state: Any) async
}

public protocol StoreSubscriber: AnyStoreSubscriber {
    associatedtype StoreSubscriberStateType

    func newState(state: StoreSubscriberStateType) async
}


extension StoreSubscriber {
    public var idKey: String {
        get {
            // type of self
            return "\(type(of: self))"
        }
        set {
            // do nothing
        }
    }
}
extension StoreSubscriber {
    // swiftlint:disable:next identifier_name
    public func _newState(state: Any) async {
        if let typedState = state as? StoreSubscriberStateType {
            await newState(state: typedState)
        }
    }
}
