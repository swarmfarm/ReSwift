//
//  Synchronized.swift
//

import Foundation

/**
 A thread-safe wrapper for a value, using a concurrent queue with a barrier.
 
 Example usage:
     var safeNumber = Synchronized(0)
     safeNumber.value { $0 += 10 }
     print(safeNumber.value)
 */
public struct Synchronized<Value> {
    private let mutex = DispatchQueue(
        label: "io.reswift.Synchronized",
        attributes: .concurrent
    )
    private var _value: Value
    
    public init(_ value: Value) {
        self._value = value
    }
    
    /// Retrieve the value synchronously.
    public var value: Value {
        mutex.sync { _value }
    }
    
    /// Mutate the value or retrieve custom data from it, in a thread-safe manner.
    @discardableResult
    public mutating func value<T>(execute task: (inout Value) throws -> T) rethrows -> T {
        try mutex.sync(flags: .barrier) {
            try task(&_value)
        }
    }
}
