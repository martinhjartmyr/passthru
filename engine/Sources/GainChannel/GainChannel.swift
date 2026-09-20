// Single owner of everything about talking to the Passthru device's
// control plane: device discovery, process enumeration facts, and the
// 'lapv' gain channel (constants, payload encode/decode, read, write).
// Both executables (menu app, CLI tool) are thin callers on top.
//
// Facts, not policy: the module returns raw enumeration results and raw
// payloads. Excluding our own pid, skipping unity entries when compacting,
// sort order, and external-change adoption stay with the callers.
//
// The driver is untouched by design (driver and engine never link); this
// is purely the engine-side client of the Core Audio IPC seam. Payload
// shape mirrors GainStore.hpp; see also contract/lapv/SCHEMA.md and
// the golden-vector plists.

import CoreAudio
import Foundation

public enum GainChannel {

    // MARK: Constants (single source)

    /// Driver-side custom property carrying per-app gains ('lapv').
    /// Payload: array of {pid?, bundle-id?, gain} dicts; see GainStore.hpp.
    public static let selector = AudioObjectPropertySelector(fourCC: "lapv")

    /// Accepted gain range; 1.0 = unity pass-through. The driver clamps into
    /// the same range on accept (GainStore::MinGain/MaxGain).
    public static let minGain: Double = 0.0
    public static let maxGain: Double = 4.0

    /// Clamps like the driver does on accept: into [minGain, maxGain], with
    /// NaN mapped to unity (GainStore.cpp ClampGain).
    public static func clamped(_ gain: Double) -> Double {
        guard !gain.isNaN else { return 1.0 }
        return min(max(gain, minGain), maxGain)
    }

    // MARK: Device discovery

    /// First audio device whose name starts with the prefix ("Passthru"
    /// matches the default device name; the prefix lets a tester install
    /// variants without changing the engine).
    public static func findVirtualDevice(namePrefix: String = "Passthru") -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var name: CFString?
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            if AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name) == noErr,
               let cfName = name, (cfName as String).hasPrefix(namePrefix) {
                return id
            }
        }
        return nil
    }

    // MARK: Process enumeration facts ('prs#'; public APIs, macOS 14.2+)

    /// Raw facts about one HAL process object. Policy-free: callers decide
    /// what to filter (own pid, running-output, plays-through checks).
    public struct ProcessFacts {
        public let objectID: AudioObjectID
        public let pid: Int32
        public let bundleID: String
        /// True when the process runs IO with an active output stream ('piro').
        public let isRunningOutput: Bool
        /// Devices the process is connected to for OUTPUT ('pdv#', output scope).
        public let outputDevices: [AudioObjectID]
    }

    /// All processes currently connected to the HAL, in list order.
    public static func processes() -> [ProcessFacts] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.map { object in
            var pidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid = Int32(0)
            var pidSize = UInt32(MemoryLayout<Int32>.size)
            _ = AudioObjectGetPropertyData(object, &pidAddr, 0, nil, &pidSize, &pid)

            var bidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var bid: CFString?
            var bidSize = UInt32(MemoryLayout<CFString?>.size)
            _ = AudioObjectGetPropertyData(object, &bidAddr, 0, nil, &bidSize, &bid)

            var runAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(object, &runAddr, 0, nil, &runSize, &running)

            var devAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var devSize: UInt32 = 0
            var devices: [AudioObjectID] = []
            if AudioObjectGetPropertyDataSize(object, &devAddr, 0, nil, &devSize) == noErr, devSize > 0 {
                var ids = [AudioObjectID](repeating: 0, count: Int(devSize) / MemoryLayout<AudioObjectID>.size)
                if AudioObjectGetPropertyData(object, &devAddr, 0, nil, &devSize, &ids) == noErr {
                    devices = ids
                }
            }

            return ProcessFacts(
                objectID: object,
                pid: pid,
                bundleID: bid as String? ?? "",
                isRunningOutput: running != 0,
                outputDevices: devices)
        }
    }

    // MARK: Gain table read/write

    /// Raw 'lapv' payload as delivered by the driver; nil on read failure or
    /// when nothing was ever written.
    public static func gains(on device: AudioObjectID) -> [[String: Any]]? {
        var addr = address(selector)
        var result: Unmanaged<AnyObject>?
        var size = UInt32(MemoryLayout<Unmanaged<AnyObject>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &result) == noErr,
              let array = result?.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }
        return array
    }

    @discardableResult
    public static func setGains(on device: AudioObjectID, _ payload: [[String: Any]]) -> OSStatus {
        // Box the CFArray in Unmanaged so the property data buffer is a plain
        // 8-byte slot holding the reference (what the C API expects), retained
        // for the duration of the synchronous call.
        var boxed = Unmanaged.passRetained(payload as NSArray)
        defer { boxed.release() }
        var addr = address(selector)
        return AudioObjectSetPropertyData(device, &addr, 0, nil,
            UInt32(MemoryLayout.size(ofValue: boxed)), &boxed)
    }

    // MARK: Payload encode/decode

    /// One typed gain-table entry. Exactly one of pid/bundleID is normally
    /// set; both unset encodes to an entry the driver skips as inert.
    public struct Entry: Equatable {
        public var pid: Int32?
        public var bundleID: String?
        public var gain: Double

        public init(pid: Int32? = nil, bundleID: String? = nil, gain: Double) {
            self.pid = pid
            self.bundleID = bundleID
            self.gain = gain
        }
    }

    /// Builds the wire payload: array of dicts with optional "pid"
    /// (positive Int) and "bundle-id" (String), required numeric "gain".
    public static func encode(_ entries: [Entry]) -> [[String: Any]] {
        entries.map { entry in
            var dict: [String: Any] = [:]
            if let pid = entry.pid, pid > 0 { dict["pid"] = Int(pid) }
            if let bundleID = entry.bundleID { dict["bundle-id"] = bundleID }
            dict["gain"] = entry.gain
            return dict
        }
    }

    /// Parses a payload with the same accept/reject semantics as the
    /// driver's GainStore::SetFromPlist:
    /// - nil payload means clear-the-table -> empty result;
    /// - non-array root or a non-dict element rejects the WHOLE payload (nil);
    /// - wrong-typed keys, missing or non-numeric gain reject the whole payload;
    /// - gains are clamped into [minGain, maxGain], NaN becomes unity;
    /// - well-formed entries carrying neither pid nor bundle-id are skipped;
    /// - non-positive pids count as not pid-keyed.
    /// Returns nil only for rejected payloads.
    public static func decode(_ payload: Any?) -> [Entry]? {
        guard let payload else { return [] }
        guard let array = payload as? [[String: Any]] else { return nil }

        var entries: [Entry] = []
        for item in array {
            // Absent key = entry not keyed by it; present-but-wrong-typed key
            // rejects the whole payload (mirrors GainStore's LookupTyped).
            var pid: Int32?
            if let raw = item["pid"] {
                guard let value = Self.numberValue(raw),
                      value >= Double(Int32.min), value <= Double(Int32.max),
                      value == value.rounded() else { return nil }
                pid = value > 0 ? Int32(value) : nil
            }
            var bundleID: String?
            if let raw = item["bundle-id"] {
                guard let value = raw as? String else { return nil }
                bundleID = value
            }
            guard let rawGain = item["gain"], let gain = Self.numberValue(rawGain) else {
                return nil
            }

            if pid == nil && bundleID == nil {
                continue // well-formed but inert; skip
            }
            entries.append(Entry(pid: pid, bundleID: bundleID, gain: clamped(gain)))
        }
        return entries
    }

    /// Numbers arrive either as native Swift numerics or as NSNumbers (what
    /// PropertyListSerialization / Core Audio hand back). Booleans are
    /// plist-native objects and never valid numbers here - the driver's
    /// CFNumber type check rejects them too (CFBoolean != CFNumber).
    /// Detection must go by Core Foundation type id: an NSNumber holding 0
    /// or 1 answers `is Bool` / `as? Bool` positively, which would misread
    /// legitimate gains at the clamp boundary.
    private static func numberValue(_ raw: Any) -> Double? {
        guard let number = raw as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        return number.doubleValue
    }
}

private func address(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

extension AudioObjectPropertySelector {
    init(fourCC: String) {
        var value: UInt32 = 0
        for byte in fourCC.utf8.prefix(4) {
            value = (value << 8) | UInt32(byte)
        }
        self.init(value)
    }
}
