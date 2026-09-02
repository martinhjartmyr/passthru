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
    public let isRouted: Bool

    public init(
        diff: DeviceListDiff,
        uidByID: [UInt32: String],
        currentSinkID: UInt32?,
        currentSinkName: String?,
        currentSinkUID: String?,
        rememberedChain: [String],
        isRouted: Bool
    ) {
        self.diff = diff
        self.uidByID = uidByID
        self.currentSinkID = currentSinkID
        self.currentSinkName = currentSinkName
        self.currentSinkUID = currentSinkUID
        self.rememberedChain = rememberedChain
        self.isRouted = isRouted
    }
}

public enum RoutingDecider {
    /// The Passthru virtual device's UID. Same constant as
    /// `PersistedOutputChain.passthruUID`; the decider filters it from
    /// the chain before walking so the "Passthru is never the engine
    /// sink" invariant holds at the routing seam itself.
    public static let passthruUID: String = "dev.passthru.virtual"

    public static func decide(_ inputs: RoutingInputs) -> RoutingDecision {
        let idByUID = Dictionary(uniqueKeysWithValues:
            inputs.uidByID.map { ($1, $0) })
        let chain = inputs.rememberedChain.filter { $0 != passthruUID }

        // 1. Disconnect: current sink gone. Check first so a same-tick
        //    add+remove resolves as fallback, not switch.
        if let sinkID = inputs.currentSinkID,
           inputs.diff.removed.contains(sinkID) {
            // Walk the chain past the head if the head IS the device that
            // disappeared (deliberate unplug of the most-recent entry).
            // Pick the first entry that maps to an online device.
            for remembered in chain {
                if remembered == inputs.currentSinkUID { continue }
                if idByUID[remembered] != nil {
                    return .fallbackTo(uid: remembered)
                }
            }
            // Walk exhausted. If the chain was effectively a single-slot
            // (one entry, and that entry is the disappeared device), the
            // user deliberately unplugged the only-remembered output;
            // noop rather than surprise them. Otherwise surface an error
            // so they can pick a new one.
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

        // 3. Already-present-at-launch: remembered head is here and
        //    not the current sink, AND routing is on.
        if inputs.isRouted,
           let remembered = head,
           let rememberedID = idByUID[remembered],
           rememberedID != inputs.currentSinkID {
            return .switchTo(uid: remembered)
        }

        return .noop
    }
}
