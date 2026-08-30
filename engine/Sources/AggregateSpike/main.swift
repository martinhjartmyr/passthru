// Aggregate-lockstep probe. Not part of the app.
//
// Question answered: does a CoreAudio aggregate device with the
// PHYSICAL DAC as master clock and the Passthru device as member make
// capture and render advance in lockstep from one clock domain?
//
// What it does: creates a PRIVATE aggregate (members = [DAC, Passthru],
// master clock = DAC), attaches ONE IOProc that copies the virtual
// device's input straight to the DAC plane (virtual plane gets silence -
// no feedback), and samples mSampleTime of input vs output every cycle
// for --seconds.
//
// Verdict: LOCKSTEP when the input/output timestamp delta never wanders
// more than half a frame across the whole soak; otherwise NOT-LOCKSTEP.
// Setup failures are findings too (exit code 2) - aggregation of libASPL
// devices is exactly what this probe exists to verify.
//
// Run (engine must NOT hold the virtual device while spiking; quit it first):
//   cd engine && swift run AggregateSpike --seconds 30 [--device uDAC]
// Dry-runnable against built-in speakers: lockstep feasibility shows up
// the same way without the amplifier plugged in.

import Foundation
import CoreAudio
import GainChannel

// Local AudioBufferList access (the app's CA enum is not linkable here).
enum SpikeCA {
    static let globalScope = kAudioObjectPropertyScopeGlobal
    static let outputScope = kAudioObjectPropertyScopeOutput

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: globalScope,
            mElement: kAudioObjectPropertyElementMain)
    }

    static func outputDevices() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var sAddr = address(kAudioDevicePropertyStreams)
            sAddr.mScope = outputScope
            var sz: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sz) == noErr && sz > 0
        }
    }

    static func deviceName(_ id: AudioObjectID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var name: CFString? = nil
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr,
              let cfName = name else { return "?" }
        return cfName as String
    }

    static func deviceUID(_ id: AudioObjectID) -> String? {
        var addr = address(kAudioDevicePropertyDeviceUID)
        var uid: CFString? = nil
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid as String?
    }

    static func defaultOutputDevice() -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &id) == noErr else { return 0 }
        return id
    }

    // MARK: AudioBufferList access

    static func bufferCount(_ list: UnsafeRawPointer) -> Int {
        Int(list.load(fromByteOffset: 0, as: UInt32.self))
    }

    static func bufferArray(_ list: UnsafeRawPointer) -> UnsafePointer<AudioBuffer> {
        let offset = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size
        return UnsafeRawPointer(list).advanced(by: offset).assumingMemoryBound(to: AudioBuffer.self)
    }
}

final class SpikeState {
    let queue = DispatchQueue(label: "aggregatespike.samples")
    var deltas: [Double] = []
    var frameMismatches = 0
}

var state = SpikeState()

func exitCode(_ status: String) -> Int32 {
    switch status {
    case "LOCKSTEP": return 0
    case "NOT-LOCKSTEP": return 1
    default: return 2
    }
}

let ioProc: AudioDeviceIOProc = { _, _, inputData, inTime, outputData, outTime, clientData in
    guard let raw = clientData.map({ UnsafeMutableRawPointer(mutating: $0) }) else {
        return noErr
    }
    let spike = Unmanaged<SpikeState>.fromOpaque(raw).takeUnretainedValue()

    let inRaw = UnsafeRawPointer(inputData)
    let outRaw = UnsafeRawPointer(outputData)
    let inBuffers = Array(UnsafeBufferPointer(
        start: SpikeCA.bufferArray(inRaw), count: SpikeCA.bufferCount(inRaw)))
    let outBuffers = Array(UnsafeBufferPointer(
        start: SpikeCA.bufferArray(outRaw), count: SpikeCA.bufferCount(outRaw)))

    func frames(_ buffer: AudioBuffer) -> Int {
        Int(buffer.mDataByteSize) / MemoryLayout<Float>.size /
            max(Int(buffer.mNumberChannels), 1)
    }
    let inFrames = inBuffers.map(frames).first ?? 0
    let outFrames = outBuffers.map(frames).first ?? 0

    // Copy virtual input -> DAC plane (outBuffers[0]); mute the virtual plane
    // so nothing loops back through the driver bridge.
    if let src = inBuffers.first?.mData?.assumingMemoryBound(to: Float.self),
       let dst = outBuffers.first?.mData?.assumingMemoryBound(to: Float.self),
       inFrames > 0, outFrames > 0 {
        memcpy(dst, src, min(inFrames, outFrames) *
            max(Int(outBuffers[0].mNumberChannels), 1) * MemoryLayout<Float>.size)
    }
    if outBuffers.count > 1, let rest = outBuffers[1].mData?.assumingMemoryBound(to: Float.self) {
        memset(rest, 0, Int(outBuffers[1].mDataByteSize))
    }

    let delta = outTime.pointee.mSampleTime - inTime.pointee.mSampleTime
    spike.queue.sync {
        spike.deltas.append(delta)
        if inFrames != outFrames { spike.frameMismatches += 1 }
    }
    return noErr
}

// MARK: Argument scan

var seconds = 30.0
var deviceSubstring: String?
var args = ArraySlice(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args = args.dropFirst()
    switch arg {
    case "--seconds":
        seconds = Double(args.first ?? "") ?? 30.0
        args = args.dropFirst()
    case "--device":
        deviceSubstring = args.first
        args = args.dropFirst()
    default:
        FileHandle.standardError.write("unknown argument: \(arg)\n".data(using: .utf8)!)
    }
}

// MARK: Device discovery

guard let virtual = GainChannel.findVirtualDevice(), virtual != 0 else {
    print("SPIKE RESULT: SETUP-FAILED - Passthru not found (install the driver)")
    exit(exitCode("SETUP-FAILED"))
}

let candidates = SpikeCA.outputDevices().filter { $0 != virtual }
let physical = deviceSubstring.flatMap { substring in
        candidates.first { SpikeCA.deviceName($0).localizedCaseInsensitiveContains(substring) }
    } ?? (SpikeCA.defaultOutputDevice() != virtual
        ? SpikeCA.defaultOutputDevice() : candidates.first)

guard let dac = physical, dac != 0 else {
    print("SPIKE RESULT: SETUP-FAILED - no physical output device found")
    exit(exitCode("SETUP-FAILED"))
}
guard let dacUID = SpikeCA.deviceUID(dac), let virtualUID = SpikeCA.deviceUID(virtual) else {
    print("SPIKE RESULT: SETUP-FAILED - cannot read device UIDs")
    exit(exitCode("SETUP-FAILED"))
}

print("spike: master-clock='\(SpikeCA.deviceName(dac))' (#\(dac)) member='\(SpikeCA.deviceName(virtual))' (#\(virtual))")
print("spike: soak \(Int(seconds))s")

// MARK: Aggregate creation

let composition: [[String: Any]] = [
    ["uid": dacUID, "channels": 2],
    ["uid": virtualUID, "channels": 2],
]
let description: [String: Any] = [
    kAudioAggregateDeviceNameKey as String: "Passthru Lockstep Spike",
    kAudioAggregateDeviceUIDKey as String: "dev.passthru.lockstep-spike",
    kAudioAggregateDeviceIsPrivateKey as String: true,
    kAudioAggregateDeviceSubDeviceListKey as String: composition,
    kAudioAggregateDeviceMainSubDeviceKey as String: dacUID,
]

var aggregateID = AudioDeviceID(0)
let createStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
guard createStatus == noErr, aggregateID != 0 else {
    print("SPIKE RESULT: SETUP-FAILED - AudioHardwareCreateAggregateDevice \(createStatus)")
    print("(finding: libASPL device refused aggregation - governor fallback stands)")
    exit(exitCode("SETUP-FAILED"))
}
print("spike: aggregate #\(aggregateID) created, master clock = '\(SpikeCA.deviceName(dac))'")

defer {
    AudioHardwareDestroyAggregateDevice(aggregateID)
    print("spike: aggregate destroyed")
}

// MARK: Soak

let context = Unmanaged.passUnretained(state).toOpaque()
var procID: AudioDeviceIOProcID?
var addStatus = AudioDeviceCreateIOProcID(aggregateID, ioProc, context, &procID)
guard addStatus == noErr else {
    print("SPIKE RESULT: SETUP-FAILED - AudioDeviceCreateIOProcID \(addStatus)")
    exit(exitCode("SETUP-FAILED"))
}
addStatus = AudioDeviceStart(aggregateID, procID)
guard addStatus == noErr else {
    print("SPIKE RESULT: SETUP-FAILED - AudioDeviceStart \(addStatus)")
    exit(exitCode("SETUP-FAILED"))
}

Thread.sleep(forTimeInterval: seconds)

AudioDeviceStop(aggregateID, procID)
AudioDeviceDestroyIOProcID(aggregateID, procID!)

// MARK: Verdict

let samples = state.queue.sync { state.deltas }
let mismatches = state.queue.sync { state.frameMismatches }

guard samples.count > 10 else {
    print("SPIKE RESULT: SETUP-FAILED - only \(samples.count) IO cycles observed")
    exit(exitCode("SETUP-FAILED"))
}

let first = samples.first!
let wander = samples.map { abs($0 - first) }.max()!
let mean = samples.reduce(0, +) / Double(samples.count)

print(String(format: "spike: %d cycles, mean in/out delta %.3f frames", samples.count, mean))
print(String(format: "spike: max wander from first delta %.3f frames, frame mismatches %d",
             wander, mismatches))

if wander <= 0.5 && mismatches == 0 {
    print("SPIKE VERDICT: LOCKSTEP - one clock domain confirmed; move engine IO onto the aggregate")
} else {
    print("SPIKE VERDICT: NOT-LOCKSTEP - timestamps wander across domains; governor fallback stands")
}
exit(exitCode(wander <= 0.5 && mismatches == 0 ? "LOCKSTEP" : "NOT-LOCKSTEP"))
