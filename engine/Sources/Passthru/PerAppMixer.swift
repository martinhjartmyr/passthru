// Per-app mixer: who is playing, and how loud per app.
//
// Enumeration uses only public Core Audio process APIs: 'prs#' lists Process
// objects; each carries PID ('ppid'), Bundle ID ('pbid'), Devices ('pdv#')
// and IsRunningOutput ('piro').
//
// Gains are written to the driver's 'lapv' custom property as CFPropertyList
// array entries - bundle-keyed whenever the app has a bundle ID (so gains
// survive relaunches mid-session), pid-keyed only for unnamed helpers.
//
// Threading: confined to the main thread. Listener blocks hop here from an
// internal serial queue; Core Audio property calls are fine off the RT path.

import AppKit
import CoreAudio
import Foundation
import GainChannel
import PassthruPersistence

/// Stable row identity for `ForEach`. PID is not safe: macOS recycles
/// it, and when the engine's sink-switch lands while a helper is in the
/// middle of rejoining, SwiftUI's diff between disposed and re-created
/// lazy state for the same id trips `ForEachState.LazyEdits`.
///
/// - For processes with a bundle ID the row is keyed by the bundle, so a
///   helper relaunching with a fresh PID still maps to the same row and
///   slider.
/// - For unnamed helpers (no bundle ID) the row is keyed by `pid + seq`,
///   where `seq` is a per-session counter that advances every time a new
///   helper appears. Each "join" is a distinct row in the fast-changing
///   helper cloud.
enum AppIdentity: Hashable {
    case bundle(String)
    case helper(pid: Int32, seq: UInt64)
}

struct PlayingApp: Identifiable, Equatable {
    let pid: Int32
    let bundleID: String
    let name: String
    let isHelper: Bool
    /// Path of the resolved .app bundle, if any; lets the UI show the real
    /// app icon instead of a generic symbol.
    let iconPath: String?
    let gain: Float

    let identity: AppIdentity
    var id: AppIdentity { identity }
}

final class PerAppMixer {

    var onUpdate: (([PlayingApp]) -> Void)?

    private let virtualDevice: AudioObjectID
    private let persisted: PersistedGains

    private(set) var playingApps: [PlayingApp] = []

    // Explicit adjustments made through THIS menu during the session.
    private var sessionBundleGains: [String: Float] = [:]
    private var sessionPIDGains: [Int32: Float] = [:]

    // Last payload we pushed; used for echo detection and reload reconcile.
    private var lastPushedSignature: String?

    private let eventQueue = DispatchQueue(label: "passthru.perappmixer")
    private var systemListBlock: AudioObjectPropertyListenerBlock?
    private var processBlocks: [AudioObjectID: [AudioObjectPropertySelector: AudioObjectPropertyListenerBlock]] = [:]
    private var deviceGainsBlock: AudioObjectPropertyListenerBlock?
    private var tickCount = 0

    // Per-session counter for unnamed helpers; combined with PID, gives
    // every "join" a distinct identity. macOS recycles PIDs, so two
    // different helpers appearing under the same PID must still be
    // distinct rows.
    private var helperSeq: UInt64 = 0
    private var helperSeqByPID: [Int32: UInt64] = [:]

    init(virtualDevice: AudioObjectID, persisted: PersistedGains) {
        self.virtualDevice = virtualDevice
        self.persisted = persisted
    }

    // MARK: Lifecycle

    func start() {
        installSystemListener()
        installDeviceGainsListener()
        refresh(reason: "start")
    }

    func stop() {
        removeAllListeners()
        playingApps = []
        publish()
    }

    /// Safety net plus slow-cycle reconcile; called once a second from the UI tick.
    func tick() {
        tickCount += 1
        refresh(reason: "tick")

        // Driver-side table is volatile: after a coreaudiod restart our memory
        // says "pushed" but the driver restarted empty. Periodically read back
        // and re-assert - the owning side reasserts.
        if tickCount % 5 == 0, lastPushedSignature != nil,
           let current = GainChannel.gains(on: virtualDevice),
           Self.signature(of: current) != lastPushedSignature {
            Log.shared.line("app-gains: driver table drifted; re-asserting \(lastPushedSignature ?? "?")")
            push(entries: current, reason: "reconcile")
        }
    }

    // MARK: UI actions

    /// Slider moved for a row. Bundle-keyed when possible so the gain follows
    /// the app across relaunches (new PID, same bundle ID).
    func setUserGain(pid: Int32, bundleID: String, percent: Double) {
        let gain = Float(GainChannel.clamped(percent / 100.0))
        if !bundleID.isEmpty {
            sessionBundleGains[bundleID] = gain
            persisted.set(gain: gain, forBundleID: bundleID)
            Log.shared.line(String(format: "app gain set: %@ -> %.3f", bundleID, gain))
        } else {
            sessionPIDGains[pid] = gain
            Log.shared.line(String(format: "app gain set: pid %d -> %.3f", pid, gain))
        }
        refresh(reason: "user-set")
    }

    // MARK: Enumeration

    private struct Row {
        let objectID: AudioObjectID
        let pid: Int32
        let bundleID: String
    }

    private func enumerateRows() -> [Row] {
        // Policy lives here, facts come from the library: drop our own pid
        // and anything not actively playing output through the virtual device.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return GainChannel.processes().compactMap { process in
            guard process.pid > 0, process.pid != ownPID else { return nil }
            guard process.isRunningOutput else { return nil }
            guard process.outputDevices.contains(virtualDevice) else { return nil }
            return Row(objectID: process.objectID, pid: process.pid, bundleID: process.bundleID)
        }
    }

    // MARK: Refresh

    private func refresh(reason: String) {
        let rows = enumerateRows()
        syncProcessListeners(with: rows.map(\.objectID))

        let previousPIDs = Set(playingApps.map(\.pid))
        let currentPIDs = Set(rows.map(\.pid))

        for row in rows where !previousPIDs.contains(row.pid) {
            let name = resolveIdentity(bundleID: row.bundleID, pid: row.pid).name
            Log.shared.line("app joined: pid=\(row.pid) bundle='\(row.bundleID)' name='\(name)' (\(reason))")
        }
        for gone in previousPIDs.subtracting(currentPIDs) {
            Log.shared.line("app left: pid=\(gone) (\(reason))")
        }

        var apps: [PlayingApp] = []
        for row in rows {
            let identity = resolveIdentity(bundleID: row.bundleID, pid: row.pid)
            apps.append(PlayingApp(
                pid: row.pid,
                bundleID: row.bundleID,
                name: identity.name,
                isHelper: identity.isHelper,
                iconPath: identity.appURL?.path,
                gain: effectiveGain(pid: row.pid, bundleID: row.bundleID),
                identity: rowIdentity(forPID: row.pid, bundleID: row.bundleID)))
        }
        playingApps = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Unnamed helpers that have left the table no longer need a seq
        // reservation; otherwise two helpers with the same PID across
        // sessions could collide on a stale seq.
        let livePIDs = currentPIDs
        for stale in helperSeqByPID.keys where !livePIDs.contains(stale) {
            helperSeqByPID.removeValue(forKey: stale)
        }

        publish()
        pushCurrentState(reason: reason)
    }

    /// Bundled apps are keyed by bundle; unnamed helpers by `pid + seq`.
    private func rowIdentity(forPID pid: Int32, bundleID: String) -> AppIdentity {
        if !bundleID.isEmpty { return .bundle(bundleID) }
        if let reserved = helperSeqByPID[pid] {
            return .helper(pid: pid, seq: reserved)
        }
        helperSeq += 1
        helperSeqByPID[pid] = helperSeq
        return .helper(pid: pid, seq: helperSeq)
    }

    /// Session override, else persisted seed for bundled apps, else unity.
    private func effectiveGain(pid: Int32, bundleID: String) -> Float {
        if !bundleID.isEmpty, let session = sessionBundleGains[bundleID] {
            return session
        }
        if let session = sessionPIDGains[pid] {
            return session
        }
        return persisted.gain(forBundleID: bundleID) ?? 1.0
    }

    /// Human name and app location resolved from the bundle ID, with
    /// fallbacks for helpers that report none.
    private func resolveIdentity(bundleID: String, pid: Int32)
        -> (name: String, isHelper: Bool, appURL: URL?)
    {
        // Prefer the installed app for the bundle ID; else the running
        // process's own bundle URL (resolves many helpers).
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            ?? NSRunningApplication(processIdentifier: pid)?.bundleURL

        if !bundleID.isEmpty {
            if let url, let bundle = Bundle(url: url) {
                let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary ?? [:]
                if let display = (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String {
                    return (display, bundleID.hasSuffix(".helper"), url)
                }
            }
            // No matching app on disk: show the raw bundle ID (typical for
            // browser/Electron helpers that carry their own IDs).
            return (bundleID, bundleID.contains(".helper"), url)
        }
        if let running = NSRunningApplication(processIdentifier: pid),
           let localizedName = running.localizedName {
            return (localizedName, false, running.bundleURL)
        }
        return ("Helper (pid \(pid))", true, nil)
    }

    // MARK: Push to driver

    private func desiredEntries() -> [[String: Any]] {
        var entries: [[String: Any]] = []

        // One bundle entry per bundle (covers every helper sharing it);
        // pid entries only for processes without a usable bundle ID.
        var seenBundles = Set<String>()
        for app in playingApps {
            let value = effectiveGain(pid: app.pid, bundleID: app.bundleID)
            guard value != 1.0 else { continue }
            if !app.bundleID.isEmpty {
                guard seenBundles.insert(app.bundleID).inserted else { continue }
                entries.append(["bundle-id": app.bundleID, "gain": Double(value)])
            } else {
                entries.append(["pid": Int(app.pid), "gain": Double(value)])
            }
        }
        return entries.sorted { Self.sortKey($0) < Self.sortKey($1) }
    }

    private static func sortKey(_ entry: [String: Any]) -> String {
        if let bid = entry["bundle-id"] as? String { return "b:\(bid)" }
        if let pid = entry["pid"] as? Int { return "p:\(String(format: "%08d", pid))" }
        return "?"
    }

    /// "b:<bundle-id>" or "p:<pid>" - which process(es) an entry targets.
    /// Same shape as sortKey but without pid padding.
    private static func targetLabel(_ entry: [String: Any]) -> String {
        if let bid = entry["bundle-id"] as? String { return "b:\(bid)" }
        if let pid = entry["pid"] as? Int { return "p:\(pid)" }
        return "?"
    }

    private static func signature(of entries: [[String: Any]]) -> String {
        return entries
            .map { entry -> String in
                let gain = (entry["gain"] as? Double).map { String(format: "%.3f", $0) } ?? "?"
                return "\(targetLabel(entry))=\(gain)"
            }
            .sorted()
            .joined(separator: ",")
    }

    private func pushCurrentState(reason: String) {
        let desired = desiredEntries()
        let desiredSignature = Self.signature(of: desired)
        guard desiredSignature != lastPushedSignature else { return }
        push(entries: desired, reason: reason)
    }

    /// Writes `entries` and remembers the signature of what actually landed.
    private func push(entries: [[String: Any]], reason: String) {
        let status = GainChannel.setGains(on: virtualDevice, entries)
        lastPushedSignature = Self.signature(of: entries)
        if status == noErr {
            if !entries.isEmpty || reason != "tick" {
                Log.shared.line("app gains pushed (\(reason)): [\(lastPushedSignature ?? "")]")
            }
        } else {
            Log.shared.line("ERROR: app gains push failed (\(reason)): status \(status)")
        }
    }

    // MARK: External changes to 'lapv' (e.g. the CLI tool while the menu runs)

    private func adoptExternalChange() {
        guard let current = GainChannel.gains(on: virtualDevice) else { return }
        let incoming = Self.signature(of: current)
        guard incoming != lastPushedSignature else { return } // our own echo

        for entry in current {
            let gain = (entry["gain"] as? Double).map { Float($0) } ?? 1.0
            if let bid = entry["bundle-id"] as? String {
                sessionBundleGains[bid] = gain
                persisted.set(gain: gain, forBundleID: bid)
            } else if let pid = (entry["pid"] as? NSNumber)?.int32Value {
                sessionPIDGains[pid] = gain
            }
        }
        lastPushedSignature = incoming
        Log.shared.line("app gains adopted from external writer: [\(incoming)]")
        refresh(reason: "external")
    }

    // MARK: Listeners

    private func publish() {
        let snapshot = playingApps
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(snapshot)
        }
    }

    private func installSystemListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh(reason: "process-list") }
        }
        let sys = AudioObjectID(kAudioObjectSystemObject)
        if CA.addListener(sys, kAudioHardwarePropertyProcessObjectList, queue: eventQueue, block: block) {
            systemListBlock = block
        } else {
            Log.shared.line("WARNING: cannot listen for process list changes; falling back to 1s polling")
        }
    }

    private func installDeviceGainsListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.adoptExternalChange() }
        }
        if CA.addListener(virtualDevice, GainChannel.selector, queue: eventQueue, block: block) {
            deviceGainsBlock = block
        }
    }

    /// Keep per-process listeners aligned with who is connected: any change in
    /// IsRunning/Devices for a watched process triggers a refresh.
    private func syncProcessListeners(with objectIDs: [AudioObjectID]) {
        let wanted = Set(objectIDs)
        let have = Set(processBlocks.keys)

        for gone in have.subtracting(wanted) {
            if let blocks = processBlocks.removeValue(forKey: gone) {
                for (selector, block) in blocks {
                    CA.removeListener(gone, selector, block: block)
                }
            }
        }

        for fresh in wanted.subtracting(have) {
            var blocks: [AudioObjectPropertySelector: AudioObjectPropertyListenerBlock] = [:]
            for selector in [kAudioProcessPropertyIsRunning,
                             kAudioProcessPropertyIsRunningOutput,
                             kAudioProcessPropertyDevices] {
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    DispatchQueue.main.async { self?.refresh(reason: "process-change") }
                }
                if CA.addListener(fresh, selector, queue: eventQueue, block: block) {
                    blocks[selector] = block
                }
            }
            processBlocks[fresh] = blocks
        }
    }

    private func removeAllListeners() {
        if let block = systemListBlock {
            CA.removeListener(AudioObjectID(kAudioObjectSystemObject),
                              kAudioHardwarePropertyProcessObjectList, block: block)
            systemListBlock = nil
        }
        if let block = deviceGainsBlock {
            CA.removeListener(virtualDevice, GainChannel.selector, block: block)
            deviceGainsBlock = nil
        }
        for (objectID, blocks) in processBlocks {
            for (selector, block) in blocks {
                CA.removeListener(objectID, selector, block: block)
            }
        }
        processBlocks.removeAll()
    }
}
