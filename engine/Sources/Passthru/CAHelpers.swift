// Small Core Audio conveniences: device lookup, property get/set, listeners,
// AudioBufferList access, and the session log that doubles as the observation
// record. The Passthru control-plane client (discovery, process facts, 'lapv'
// gain channel) lives in the GainChannel library target.

import Foundation
import CoreAudio

enum CA {
    static let globalScope = kAudioObjectPropertyScopeGlobal
    static let inputScope = kAudioObjectPropertyScopeInput
    static let outputScope = kAudioObjectPropertyScopeOutput
    static let mainElement = kAudioObjectPropertyElementMain

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: mainElement)
    }

    // MARK: Device discovery

    static func outputDevices() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var sAddr = address(kAudioDevicePropertyStreams, scope: outputScope)
            var sz: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sz) == noErr && sz > 0
        }
    }

    static func deviceName(_ id: AudioObjectID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var name: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let cfName = name else { return "?" }
        return cfName as String
    }

    static func defaultOutputDevice() -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &id) == noErr else { return 0 }
        return id
    }

    @discardableResult
    static func setDefaultOutput(_ id: AudioObjectID) -> OSStatus {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var dev = id
        let sys = AudioObjectID(kAudioObjectSystemObject)
        return AudioObjectSetPropertyData(sys, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
    }

    static func deviceUID(_ id: AudioObjectID) -> String? {
        var addr = address(kAudioDevicePropertyDeviceUID)
        var uid: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid as String?
    }

    static func device(matchingUID uid: String) -> AudioObjectID? {
        outputDevices().first { deviceUID($0) == uid }
    }

    // MARK: Scalar properties

    static func nominalRate(_ id: AudioObjectID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    @discardableResult
    static func setNominalRate(_ id: AudioObjectID, _ rate: Double) -> OSStatus {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var r = rate
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &r)
    }

    static func bufferFrameSize(_ id: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &frames) == noErr else { return 0 }
        return Int(frames)
    }

    static func streamDescription(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
        var sAddr = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streamIDs = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(id, &sAddr, 0, nil, &size, &streamIDs) == noErr else { return nil }
        var fAddr = address(kAudioStreamPropertyPhysicalFormat)
        var asbd = AudioStreamBasicDescription()
        var fSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(streamIDs[0], &fAddr, 0, nil, &fSize, &asbd) == noErr else { return nil }
        return asbd
    }

    static func formatLine(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> String {
        guard let asbd = streamDescription(id, scope: scope) else { return "unknown" }
        let kind: String
        if asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
            kind = "int"
        } else if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            kind = "float"
        } else {
            kind = "other"
        }
        return "\(kind)\(asbd.mBitsPerChannel)-bit x\(asbd.mChannelsPerFrame)ch"
    }

    /// Compact one-line form for UI: "44.1 kHz · float32".
    static func shortFormatLine(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> String {
        guard let asbd = streamDescription(id, scope: scope) else { return "unknown" }
        let kind: String
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            kind = "float"
        } else if asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
            kind = "int"
        } else {
            kind = "pcm"
        }
        let khz = String(format: "%.1f", asbd.mSampleRate / 1000.0)
        return "\(khz) kHz · \(kind)\(asbd.mBitsPerChannel)"
    }

    // MARK: Virtual device volume/mute observation (native macOS volume lives
    // here; we never write these controls, we log their state and observed
    // external changes)

    static func volumeScalar(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Float? {
        var addr = address(kAudioDevicePropertyVolumeScalar, scope: scope)
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    /// Reported dB alongside scalar; used to inspect the pow-2 vs linear
    /// volume curve near unity.
    static func volumeDecibels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Float? {
        var addr = address(kAudioDevicePropertyVolumeDecibels, scope: scope)
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    static func isMuted(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool? {
        var addr = address(kAudioDevicePropertyMute, scope: scope)
        var m: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &m) == noErr else { return nil }
        return m != 0
    }

    // MARK: Listeners

    static func addListener(_ objectID: AudioObjectID,
                            _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                            queue: DispatchQueue?,
                            block: @escaping AudioObjectPropertyListenerBlock) -> Bool {
        var addr = address(selector, scope: scope)
        return AudioObjectAddPropertyListenerBlock(objectID, &addr, queue, block) == noErr
    }

    static func removeListener(_ objectID: AudioObjectID,
                               _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               block: @escaping AudioObjectPropertyListenerBlock) {
        var addr = address(selector, scope: scope)
        AudioObjectRemovePropertyListenerBlock(objectID, &addr, nil, block)
    }

    // MARK: AudioBufferList access

    static func bufferCount(_ list: UnsafeRawPointer) -> Int {
        Int(list.load(fromByteOffset: 0, as: UInt32.self))
    }

    // AudioBufferList declares mBuffers as a 1-element tuple; the real list has
    // mNumberBuffers entries starting at the same offset (list size - one buffer).
    static func bufferArray(_ list: UnsafeRawPointer) -> UnsafePointer<AudioBuffer> {
        let offset = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size
        return UnsafeRawPointer(list).advanced(by: offset).assumingMemoryBound(to: AudioBuffer.self)
    }
}

// MARK: Log

final class Log {
    static let shared = Log()
    private let queue = DispatchQueue(label: "passthru.log")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private var fileHandle: FileHandle?

    func open(file: URL) {
        queue.sync {
            FileManager.default.createFile(atPath: file.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: file)
            _ = try? fileHandle?.seekToEnd()
            write("=== passthru session start ===")
        }
    }

    func line(_ text: String) {
        queue.sync {
            write(text)
        }
    }

    /// Caller must already be on `queue`.
    private func write(_ text: String) {
        let entry = "\(formatter.string(from: Date()))  \(text)\n"
        if let data = entry.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
            try? fileHandle?.write(contentsOf: data)
        }
    }
}
