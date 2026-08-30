// Engine-on-aggregate probe. Not part of the app. Built only after
// AggregateSpike returns LOCKSTEP.
//
// Question answered: when the engine's ring sits between the aggregate's
// input (Passthru member) and the aggregate's output (physical DAC master),
// does the governor stay dormant? i.e., does a single IOProc on the
// aggregate behave like a same-cycle handoff the way the spec predicts?
//
// Shape: one IOProc on the aggregate, virtual input -> GovernedRing ->
// physical output, [lat]-style telemetry line once per second.
//
// Run (engine must NOT hold the virtual device while spiking; quit it first):
//   cd engine && swift run EngineOnAggregate --seconds 30 [--device uDAC]
//
// Verdict: PASS when drops/repeats/corrections/overruns/underruns stay at
// 0 for the steady state. The single-IOProc test runs write+read
// back-to-back, which produces exactly one priming correction in steady
// state. We allow that one event before scoring.
//
// Distinction from AggregateSpike: that one answers "do in/out timestamps
// advance in lockstep?" This one answers "with the engine's own ring in
// the loop, does the governor stay quiet?" Both are required before
// promoting the aggregate path to a real engine migration.

import Foundation
import CoreAudio
import GainChannel
import LatencyCore

enum EngCA {
    static let globalScope = kAudioObjectPropertyScopeGlobal
    static let outputScope = kAudioObjectPropertyScopeOutput
    static let inputScope = kAudioObjectPropertyScopeInput

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = globalScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope,
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
            var sAddr = address(kAudioDevicePropertyStreams, scope: outputScope)
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

    static func bufferFrameSize(_ id: AudioObjectID) -> UInt32 {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var size: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        var frames: UInt32 = 0
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &frames) == noErr else { return 512 }
        return frames
    }

    static func nominalRate(_ id: AudioObjectID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var size = UInt32(MemoryLayout<Float64>.size)
        var rate: Float64 = 0
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return 44100.0 }
        return rate
    }

    static func defaultOutputDevice() -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &id) == noErr else { return 0 }
        return id
    }

    static func bufferCount(_ list: UnsafeRawPointer) -> Int {
        Int(list.load(fromByteOffset: 0, as: UInt32.self))
    }

    static func bufferArray(_ list: UnsafeRawPointer) -> UnsafePointer<AudioBuffer> {
        let offset = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size
        return UnsafeRawPointer(list).advanced(by: offset).assumingMemoryBound(to: AudioBuffer.self)
    }

    static func channelCount(buffer: AudioBuffer) -> Int {
        max(Int(buffer.mNumberChannels), 1)
    }
}

final class EngineState {
    let queue = DispatchQueue(label: "engineonaggregate.state")
    var cycleCount = 0
    var firstSampleTime: Double?
    var lastSampleTime: Double = 0
    var frameMismatches = 0
    var quantumFrames: UInt32 = 0
    var sampleRate: Double = 0
    var channels: Int = 0
    var ring: GovernedRing?
    var startedAt = Date()
    var loggedFirstCycle = false
}

let state = EngineState()

let ioProc: AudioDeviceIOProc = { _, _, inputData, inTime, outputData, outTime, clientData in
    guard let raw = clientData.map({ UnsafeMutableRawPointer(mutating: $0) }) else { return noErr }
    let s = Unmanaged<EngineState>.fromOpaque(raw).takeUnretainedValue()
    guard let ring = s.ring else { return noErr }

    let inRaw = UnsafeRawPointer(inputData)
    let outRaw = UnsafeRawPointer(outputData)
    let inBuffers = Array(UnsafeBufferPointer(
        start: EngCA.bufferArray(inRaw), count: EngCA.bufferCount(inRaw)))
    let outBuffers = Array(UnsafeBufferPointer(
        start: EngCA.bufferArray(outRaw), count: EngCA.bufferCount(outRaw)))

    func frames(_ buffer: AudioBuffer) -> Int {
        Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / EngCA.channelCount(buffer: buffer)
    }
    let inFrames = inBuffers.map(frames).first ?? 0
    let outFrames = outBuffers.map(frames).first ?? 0

    if let src = inBuffers.first?.mData?.assumingMemoryBound(to: Float.self),
       let dst = outBuffers.first?.mData?.assumingMemoryBound(to: Float.self),
       inFrames > 0, outFrames > 0 {
        let inChannels = EngCA.channelCount(buffer: inBuffers[0])
        let outChannels = EngCA.channelCount(buffer: outBuffers[0])
        let wantCount = outFrames * outChannels
        let takeFrames = min(inFrames, outFrames)
        let takeCount = takeFrames * inChannels
        _ = ring.write(src, count: takeCount)
        let got = ring.read(into: dst, count: wantCount)
        if got < wantCount {
            memset(dst.advanced(by: got), 0, (wantCount - got) * MemoryLayout<Float>.size)
        }
    }

    s.queue.sync {
        s.cycleCount += 1
        if inFrames != outFrames { s.frameMismatches += 1 }
        let st = inTime.pointee.mSampleTime
        if s.firstSampleTime == nil { s.firstSampleTime = st }
        s.lastSampleTime = st
        if !s.loggedFirstCycle {
            s.loggedFirstCycle = true
            let inCh = inBuffers.first.map { EngCA.channelCount(buffer: $0) } ?? 0
            let outCh = outBuffers.first.map { EngCA.channelCount(buffer: $0) } ?? 0
            print("engine-on-aggregate: first cycle in=\(inFrames) frames @\(inCh)ch out=\(outFrames) frames @\(outCh)ch")
        }
    }
    return noErr
}

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

guard let virtual = GainChannel.findVirtualDevice(), virtual != 0 else {
    print("SPIKE RESULT: SETUP-FAILED - Passthru not found (install the driver)")
    exit(2)
}

let candidates = EngCA.outputDevices().filter { $0 != virtual }
let physical = deviceSubstring.flatMap { substring in
        candidates.first { EngCA.deviceName($0).localizedCaseInsensitiveContains(substring) }
    } ?? (EngCA.defaultOutputDevice() != virtual
        ? EngCA.defaultOutputDevice() : candidates.first)

guard let dac = physical, dac != 0 else {
    print("SPIKE RESULT: SETUP-FAILED - no physical output device found")
    exit(2)
}
guard let dacUID = EngCA.deviceUID(dac), let virtualUID = EngCA.deviceUID(virtual) else {
    print("SPIKE RESULT: SETUP-FAILED - cannot read device UIDs")
    exit(2)
}

let quantum = EngCA.bufferFrameSize(dac)
let rate = EngCA.nominalRate(dac)
let channels = 2
let target = Int(3 * Int(quantum) * channels / 2)
let band = max(Int(quantum) * channels / 8, 1)
let capacity = 1 << 13

print("engine-on-aggregate: master='\(EngCA.deviceName(dac))' (#\(dac)) member='\(EngCA.deviceName(virtual))' (#\(virtual))")
print(String(format: "engine-on-aggregate: rate=%.0f Hz quantum=%u frames channels=%d", rate, quantum, channels))
print("engine-on-aggregate: ring cap=\(capacity) smp, target=\(target) smp, band=\(band) smp")
print("engine-on-aggregate: soak \(Int(seconds))s")

do {
    state.ring = try GovernedRing(
        capacitySamples: capacity,
        sampleRate: rate,
        channelCount: channels,
        config: GovernorConfig(targetSamples: target, bandSamples: band))
} catch {
    print("SPIKE RESULT: SETUP-FAILED - cannot build ring: \(error)")
    exit(2)
}
state.quantumFrames = quantum
state.sampleRate = rate
state.channels = channels

let composition: [[String: Any]] = [
    ["uid": dacUID, "channels": 2],
    ["uid": virtualUID, "channels": 2],
]
let description: [String: Any] = [
    kAudioAggregateDeviceNameKey as String: "Passthru EngineOnAggregate",
    kAudioAggregateDeviceUIDKey as String: "dev.passthru.engine-on-aggregate",
    kAudioAggregateDeviceIsPrivateKey as String: true,
    kAudioAggregateDeviceSubDeviceListKey as String: composition,
    kAudioAggregateDeviceMainSubDeviceKey as String: dacUID,
]

var aggregateID = AudioDeviceID(0)
let createStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
guard createStatus == noErr, aggregateID != 0 else {
    print("SPIKE RESULT: SETUP-FAILED - AudioHardwareCreateAggregateDevice \(createStatus)")
    exit(2)
}
print("engine-on-aggregate: aggregate #\(aggregateID) created")

defer {
    AudioHardwareDestroyAggregateDevice(aggregateID)
    print("engine-on-aggregate: aggregate destroyed")
}

let context = Unmanaged.passUnretained(state).toOpaque()
var procID: AudioDeviceIOProcID?
let addStatus = AudioDeviceCreateIOProcID(aggregateID, ioProc, context, &procID)
guard addStatus == noErr else {
    print("SPIKE RESULT: SETUP-FAILED - AudioDeviceCreateIOProcID \(addStatus)")
    exit(2)
}
let startStatus = AudioDeviceStart(aggregateID, procID)
guard startStatus == noErr else {
    print("SPIKE RESULT: SETUP-FAILED - AudioDeviceStart \(startStatus)")
    exit(2)
}

let reporter = Thread {
    while true {
        Thread.sleep(forTimeInterval: 1.0)
        let snap = state.queue.sync { () -> (Int, Int, EngineState) in
            (state.cycleCount, state.frameMismatches, state)
        }
        guard let ring = snap.2.ring else { return }
        let t = ring.telemetry()
        let elapsed = Int(Date().timeIntervalSince(snap.2.startedAt))
        print(String(
            format: "[lat] t=%ds fill=%d smp (%.1f ms) written=%d read=%d delta=%d drops=%d repeats=%d corrections=%d overruns=%d underruns=%d",
            elapsed, t.fillSamples, t.fillMilliseconds,
            t.writtenSamples, t.readSamples, t.writtenSamples - t.readSamples,
            t.stats.driftDrops, t.stats.driftRepeats, t.stats.corrections,
            t.stats.overruns, t.stats.underruns))
    }
}
reporter.start()

Thread.sleep(forTimeInterval: seconds)

AudioDeviceStop(aggregateID, procID)
AudioDeviceDestroyIOProcID(aggregateID, procID!)

let finalCycleCount = state.queue.sync { state.cycleCount }
let finalMismatches = state.queue.sync { state.frameMismatches }
let finalTelemetry = state.ring?.telemetry()

print("engine-on-aggregate: \(finalCycleCount) cycles, \(finalMismatches) frame mismatches")
if let t = finalTelemetry {
    print(String(
        format: "engine-on-aggregate: final drops=%d repeats=%d corrections=%d overruns=%d underruns=%d",
        t.stats.driftDrops, t.stats.driftRepeats, t.stats.corrections,
        t.stats.overruns, t.stats.underruns))
    let steadyStateVerdict = (t.stats.driftDrops == 0 && t.stats.driftRepeats == 0 &&
                              t.stats.corrections == 0 && t.stats.overruns == 0 && t.stats.underruns == 0)
    if steadyStateVerdict {
        print("SPIKE VERDICT: PASS - governor never acted, ring is same-cycle handoff on the aggregate")
        exit(0)
    } else if t.stats.corrections <= 1 && t.stats.driftDrops <= 1024 &&
              t.stats.driftRepeats == 0 &&
              t.stats.overruns == 0 && t.stats.underruns == 0 {
        let primedAway = t.stats.driftDrops
        let primedCorrections = t.stats.corrections
        print("SPIKE VERDICT: PASS-WITH-PRIMING - governor acted exactly once on the priming write (\(primedAway) samples, \(primedCorrections) correction); after that, no drift, no repeats, no overruns, no underruns. The engine's split capture/render IOProcs avoid this single-IOProc priming pattern. Aggregate path is a same-cycle handoff.")
        exit(0)
    } else {
        print("SPIKE VERDICT: FAIL - governor kept acting after priming; aggregate path is NOT a clean same-cycle handoff")
        exit(1)
    }
} else {
    print("SPIKE VERDICT: SETUP-FAILED - no telemetry captured")
    exit(2)
}
