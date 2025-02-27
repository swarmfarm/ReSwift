//
//  TypeHelper.swift
//  ReSwift
//

/**
 Used internally to cast the generic `Any?` state to a known type
 before calling a specialized function.
 
 - parameter action: The action to pass to `function`
 - parameter state: The generic state to cast.
 - parameter function: The reducer or function that uses a specialized state.
 - returns: The possibly-new state, or the original if cast fails.
 */
@discardableResult
func withSpecificTypes<SpecificStateType, ActionType>(
    _ action: ActionType,
    state genericStateType: Any?,
    function: (_ action: ActionType, _ state: SpecificStateType?) -> SpecificStateType
) -> Any {
    guard let unwrappedState = genericStateType else {
        return function(action, nil) as Any
    }
    guard let typedState = unwrappedState as? SpecificStateType else {
        return unwrappedState
    }
    return function(action, typedState) as Any
}
