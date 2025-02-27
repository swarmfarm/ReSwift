//
//  Coding.swift
//  ReSwift
//

public protocol Coding {
    init?(dictionary: [String: AnyObject])
    var dictionaryRepresentation: [String: AnyObject] { get }
}
