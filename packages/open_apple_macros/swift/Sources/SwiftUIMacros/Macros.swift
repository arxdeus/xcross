import OpenAppleMacrosBase

package var all: [Macro.Type] {
    [
        AnimatableValuesMacro.self,
        AnimatableIgnoredMacro.self,
        AnimatableValuesDataPropertyMacro.self,
        AnimatableValuesDataMacro.self,
        AnimatablePairDataPropertyMacro.self,
        AnimatablePairDataMacro.self,
        AnimatablePropertyMacro.self,
        InvalidAnimatablePropertyMacro.self,
        EntryMacro.self,
        EntryDefaultValueMacro.self,
        StateMacro.self,
        ProjectedValueMacro.self,
        StateProjectedValueMacro.self,
        StatePropertyWrapperStorageMacro.self,
        StateInitialStoredValueMacro.self,
    ]
}
