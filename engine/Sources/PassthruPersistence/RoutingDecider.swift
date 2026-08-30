// Routing decision for the engine sink on device-list changes. Pure
// function: takes the diff and current state, returns the intended action.
// The engine calls this and executes via the existing IO paths.
//
// Why pure: the listener fires from a CoreAudio queue, the UI tick is on
// the main actor, and the IO side-effects go through selectOutput/stopIO.
// Lifting the decision out lets the test target cover all branches
// host-side without any audio hardware or UserDefaults involvement.

import Foundation

public enum RoutingDecision: Equatable {
    case noop
    case switchTo(uid: String)
    case fallbackTo(uid: String)
    case stopAndError(name: String)
}

public struct RoutingInputs: Equatable {
    public let diff: DeviceListDiff
    public let uidByID: [UInt32: String]
    public let currentSinkID: UInt32?
    public let currentSinkName: String?
    public let currentSinkUID: String?
    public let rememberedUID: String?
    public let isRouted: Bool

    public init(
        diff: DeviceListDiff,
        uidByID: [UInt32: String],
        currentSinkID: UInt32?,
        currentSinkName: String?,
        currentSinkUID: String?,
        rememberedUID: String?,
        isRouted: Bool
    ) {
        self.diff = diff
        self.uidByID = uidByID
        self.currentSinkID = currentSinkID
        self.currentSinkName = currentSinkName
        self.currentSinkUID = currentSinkUID
        self.rememberedUID = rememberedUID
        self.isRouted = isRouted
    }
}

public enum RoutingDecider {
    public static func decide(_ inputs: RoutingInputs) -> RoutingDecision {
        let idByUID = Dictionary(uniqueKeysWithValues:
            inputs.uidByID.map { ($1, $0) })

        // 1. Disconnect: current sink gone. Check first so a same-tick
        //    add+remove resolves as fallback, not switch.
        if let sinkID = inputs.currentSinkID,
           inputs.diff.removed.contains(sinkID) {
            // If the device that disappeared IS the remembered one,
            // don't fall back to itself; also don't surface an error
            // for a deliberate unplug.
            if let remembered = inputs.rememberedUID,
               remembered == inputs.currentSinkUID {
                return .noop
            }
            if let remembered = inputs.rememberedUID,
               idByUID[remembered] != nil {
                return .fallbackTo(uid: remembered)
            }
            return .stopAndError(name: inputs.currentSinkName ?? "previous output")
        }

        // 2. Hot-plug: remembered device just appeared.
        if let remembered = inputs.rememberedUID,
           let rememberedID = idByUID[remembered],
           inputs.diff.added.contains(rememberedID),
           rememberedID != inputs.currentSinkID {
            return .switchTo(uid: remembered)
        }

        // 3. Already-present-at-launch: remembered device is here and
        //    not the current sink, AND routing is on.
        if inputs.isRouted,
           let remembered = inputs.rememberedUID,
           let rememberedID = idByUID[remembered],
           rememberedID != inputs.currentSinkID {
            return .switchTo(uid: remembered)
        }

        return .noop
    }
}
