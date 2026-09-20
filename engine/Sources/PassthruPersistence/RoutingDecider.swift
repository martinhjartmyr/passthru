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
    public let rememberedChain: [String]

    public init(
        diff: DeviceListDiff,
        uidByID: [UInt32: String],
        currentSinkID: UInt32?,
        currentSinkName: String?,
        currentSinkUID: String?,
        rememberedChain: [String]
    ) {
        self.diff = diff
        self.uidByID = uidByID
        self.currentSinkID = currentSinkID
        self.currentSinkName = currentSinkName
        self.currentSinkUID = currentSinkUID
        self.rememberedChain = rememberedChain
    }
}

public enum RoutingDecider {
    public static func decide(_ inputs: RoutingInputs) -> RoutingDecision {
        let idByUID = Dictionary(uniqueKeysWithValues:
            inputs.uidByID.map { ($1, $0) })
        let chain = inputs.rememberedChain.filter { $0 != PersistedOutputChain.passthruUID }

        // 1. Disconnect: current sink gone. Check first so a same-tick
        //    add+remove resolves as fallback, not switch.
        if let sinkID = inputs.currentSinkID,
           inputs.diff.removed.contains(sinkID) {
            // Walk the chain, picking the first entry that maps to an
            // online device. The disappeared sink has no entry in
            // idByUID (it was just removed), so the walk naturally
            // skips it. If the chain was effectively a single-slot
            // (one entry, and that entry is the disappeared device),
            // the user deliberately unplugged the only-remembered
            // output; noop rather than surprise them. Otherwise surface
            // an error so they can pick a new one.
            for remembered in chain {
                if idByUID[remembered] != nil {
                    return .fallbackTo(uid: remembered)
                }
            }
            if chain.count == 1, chain.first == inputs.currentSinkUID {
                return .noop
            }
            return .stopAndError(name: inputs.currentSinkName ?? "previous output")
        }

        // 2. Hot-plug: remembered head just appeared.
        let head = chain.first
        if let remembered = head,
           let rememberedID = idByUID[remembered],
           inputs.diff.added.contains(rememberedID),
           rememberedID != inputs.currentSinkID {
            return .switchTo(uid: remembered)
        }

        // 3. Reconnect after disconnect: a remembered device is online and
        //    the engine currently has no live sink (e.g., laptop wake, the
        //    previous .stopAndError has cleared outputDevice). The hot-plug
        //    branch is gated on the new device being different from the
        //    current sink; this branch is gated on there being no current
        //    sink at all. Walk the chain so a head that is offline does
        //    not block promotion of the next online entry.
        if inputs.currentSinkID == nil,
           let remembered = chain.first(where: { idByUID[$0] != nil }) {
            return .switchTo(uid: remembered)
        }

        return .noop
    }
}
