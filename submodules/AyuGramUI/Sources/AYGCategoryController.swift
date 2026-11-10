import Foundation
import Display
import AccountContext

// AYG: routes an AyuGram settings category to its screen.
//
// Every category now has one, so there is no generic fallback here any more —
// the switch is exhaustive and anything after it would be dead code, which the
// module's `-warnings-as-errors` rejects outright.
public func aygCategoryController(context: AccountContext, category: AYGSettingsCategory) -> ViewController {
    switch category {
    case .ghostMode:
        return aygGhostModeController(context: context)
    case .spy:
        return aygSpyController(context: context)
    case .filters:
        return aygFiltersController(context: context)
    case .customization:
        return aygCustomizationController(context: context)
    }
}
