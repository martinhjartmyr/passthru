// Engine: pulls mixed audio from the Passthru device and renders it,
// unmodified, to a real output via a private Core Audio aggregate.
//
// On the aggregate, capture (Passthru) and render (the chosen physical
// device) share one clock domain, so the IOProc is a same-cycle in-place
// copy with the user's per-engine gain/mute applied. No ring, no governor,
// no drift seam.

import Foundation
import CoreAudio
import Accelerate
import os
import GainChannel
import LatencyCore
import PassthruPersistence

final class Engine: ObservableObject {
    static let shared = Engine()

    enum Mode { case passthrough, gain, muted }

    // MARK: UI state (main thread)

    @Published private(set) var formatSummary = ""
    @Published private(set) var outputName = ""
    @Published private(set) var dropStats: String?
    @Published private(set) var routedToVirtual = false
    @Published private(set) var availableOutputs: [OutputOption] = []
    @Published private(set) var selectedOutputID: AudioObjectID = 0
    @Published var gainPercent: Double = 100
    @Published var muted = false
    @Published private(set) var errorText: String?
    @Published private(set) var playingApps: [PlayingApp] = []

    struct OutputOption: Identifiable {
        let id: AudioObjectID
        let name: String
    }

    private(set) var virtualDevice: AudioObjectID = 0
    private(set) var outputDevice: AudioObjectID = 0

    // MARK: Control state read by realtime callbacks

    private struct Controls {
        var gain: Float = 1.0
        var muted = false
    }

    private let controls = OSAllocatedUnfairLock<Controls>(initialState: Controls())

    // MARK: Diagnostics toggles

    // Off by default: the per-second [io] line is diagnostic, not part of
    // normal operation. The latency instrument opts in via --io-telemetry.
    static let ioTelemetryEnabled = CommandLine.arguments.contains("--io-telemetry")

    // MARK: IO plumbing

    private var aggregateID: AudioObjectID = 0
    private var aggregateProcID: AudioDeviceIOProcID?
    private let eventQueue = DispatchQueue(label: "passthru.events")

    // Per-cycle IO delivery telemetry: one counter for the single aggregate
    // IOProc.
    private let ioCounter = PerCycleCounter()
    private let ioFiredOnce = OSAllocatedUnfairLock<Bool>(initialState: false)

    private var originalOutputUID: String?
    private var routingChangeIsOurs = false
    private var lastLoggedMode: Mode?

    private var virtualListeners: [(selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, block: AudioObjectPropertyListenerBlock)] = []
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var signalSources: [DispatchSourceSignal] = []

    // Auto-switch engine sink to the last-used output. Persisted UID,
    // system-object listener on the device list, decision via the pure
    // RoutingDecider. Stamps only on a successful selectOutput.
    private let persistedLastOutput = PersistedLastOutput()
    private var knownDevices: Set<UInt32> = []
    private var devicesBlock: AudioObjectPropertyListenerBlock?
    private var routingReady = false
    private var lastDebounced: (uid: String, name: String, at: Date)?

    // Who is playing and per-app gains (inactive until start()).
    private var perAppMixer: PerAppMixer?

    // MARK: Lifecycle

    @discardableResult
    func start() -> Bool {
        Log.shared.open(file: Self.logFileURL)

        guard let dev = GainChannel.findVirtualDevice() else {
            publishError("Passthru not found. Install the driver first: sudo ./install.sh, then relaunch.")
            return false
        }
        virtualDevice = dev

        let out = CA.defaultOutputDevice()
        guard out != 0 else {
            publishError("No default output device found.")
            return false
        }
        outputDevice = out
        originalOutputUID = CA.deviceUID(out)

        Log.shared.line("devices: virtual='\(CA.deviceName(dev))' (#\(dev)) real='\(CA.deviceName(out))' (#\(out))")
        Log.shared.line("rates (pre-aggregate): virtual=\(CA.nominalRate(dev)) Hz, real=\(CA.nominalRate(out)) Hz")

        Log.shared.line("formats: virtual-in=\(CA.formatLine(dev, scope: CA.inputScope)), real-out=\(CA.formatLine(out, scope: CA.outputScope))")
        Log.shared.line("io quanta: virtual=\(CA.bufferFrameSize(dev)) frames, real=\(CA.bufferFrameSize(out)) frames")

        guard configureAggregate() else { return false }

        logVirtualControls()
        installListeners()
        installSignalHandlers()
        startTickLoop()

        let mixer = PerAppMixer(virtualDevice: dev, persisted: PersistedGains())
        mixer.onUpdate = { [weak self] apps in
            self?.playingApps = apps
        }
        perAppMixer = mixer
        mixer.start()

        guard startIO() else { return false }

        // Run the routing decision so an already-present remembered device
        // picks up before any hot-plug listener fires. We do NOT stamp the
        // initial sink as remembered: if the system default is the virtual
        // device on launch, the user has not picked a real output yet.
        // selectOutput is the only stamper.
        routingReady = true
        evaluateRoutingForCurrentDevices()

        refreshOutputs()
        selectedOutputID = outputDevice
        refreshStatusLine()
        Log.shared.line("engine running")
        return true
    }

    func shutdown() {
        stopIO()
        removeListeners()
        perAppMixer?.stop()

        if routedToVirtual, let uid = originalOutputUID, let original = CA.device(matchingUID: uid) {
            routingChangeIsOurs = true
            CA.setDefaultOutput(original)
            Log.shared.line("restored default output to '\(CA.deviceName(original))'")
        }
        DispatchQueue.main.async { self.routedToVirtual = false }
    }

    static var logFileURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/Passthru
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("run.log")
    }
    // MARK: Sample-rate negotiation (aggregate migration)
    //
    // The aggregate's master clock (the physical device) sets the rate; the
    // virtual member is forced to match by Core Audio when the aggregate is
    // created. Pre-match reads of the underlying devices' nominal rates can
    // disagree and still aggregate cleanly.

    // Build the private aggregate (master clock = physical DAC, member =
    // Passthru) that hosts our single IOProc. The aggregate's master clock
    // determines the rate; the virtual member is forced to match. Returns
    // false if Core Audio refuses aggregation.
    private func configureAggregate() -> Bool {
        guard let virtualUID = CA.deviceUID(virtualDevice),
              let physicalUID = CA.deviceUID(outputDevice) else {
            publishError("Cannot read device UIDs for the aggregate")
            return false
        }

        let composition: [[String: Any]] = [
            ["uid": physicalUID, "channels": 2],
            ["uid": virtualUID, "channels": 2],
        ]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Passthru Engine",
            kAudioAggregateDeviceUIDKey as String: "dev.passthru.engine-aggregate",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: composition,
            kAudioAggregateDeviceMainSubDeviceKey as String: physicalUID,
        ]

        var newID = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newID)
        guard status == noErr, newID != 0 else {
            publishError("Cannot create aggregate (master='\(CA.deviceName(outputDevice))', member='\(CA.deviceName(virtualDevice))'): \(status)")
            Log.shared.line("aggregate: AudioHardwareCreateAggregateDevice \(status); aggregate path not available on this host")
            return false
        }
        aggregateID = newID
        let aggRate = CA.nominalRate(newID)
        Log.shared.line("aggregate: master='\(CA.deviceName(outputDevice))' member='\(CA.deviceName(virtualDevice))' quantum=\(CA.bufferFrameSize(newID)) frames rate=\(aggRate) Hz")
        return true
    }

    // MARK: Native control observation (native macOS volume IS the system
    // volume. macOS writes OUR volume element; we log and let it stand.)

    private func logVirtualControls() {
        for scope in [CA.inputScope, CA.outputScope] {
            let vol = CA.volumeScalar(virtualDevice, scope: scope).map { "\($0)" } ?? "?"
            let db = CA.volumeDecibels(virtualDevice, scope: scope).map { "\($0)" } ?? "?"
            let mute = CA.isMuted(virtualDevice, scope: scope).map { "\($0)" } ?? "?"
            Log.shared.line("observed Passthru \(scopeName(scope)): scalar \(vol), dB \(db), muted \(mute) (not modified)")
        }
    }

    private func scopeName(_ scope: AudioObjectPropertyScope) -> String {
        scope == CA.inputScope ? "input-master" : "output-master"
    }

    // MARK: Observation listeners (record whether keys/slider/HUD act
    // natively on OUR volume element while Passthru is default output)

    private func installListeners() {
        let eventQueue = eventQueue

        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for scope in [CA.inputScope, CA.outputScope] {
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    eventQueue.async { self?.virtualControlObserved() }
                }
                if CA.addListener(virtualDevice, selector, scope: scope, queue: nil, block: block) {
                    virtualListeners.append((selector, scope, block))
                }
            }
        }

        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            eventQueue.async { self?.defaultOutputChanged() }
        }
        let sys = AudioObjectID(kAudioObjectSystemObject)
        if CA.addListener(sys, kAudioHardwarePropertyDefaultOutputDevice, queue: nil, block: defaultBlock) {
            defaultOutputListenerBlock = defaultBlock
        }

        // System-object listener on the device list. There is no dedicated
        // added/removed selector on macOS; the listener block diffs the new
        // set against knownDevices. The listener may fire once on install
        // with the current state; we seed knownDevices first so that first
        // fire is a noop.
        knownDevices = Set(realOutputIDs.map { UInt32($0) })
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            eventQueue.async { self?.deviceListChanged() }
        }
        if CA.addListener(sys, kAudioHardwarePropertyDevices, queue: nil, block: devicesBlock) {
            self.devicesBlock = devicesBlock
        }
    }

    private func removeListeners() {
        for entry in virtualListeners {
            CA.removeListener(virtualDevice, entry.selector, scope: entry.scope, block: entry.block)
        }
        virtualListeners.removeAll()
        let sys = AudioObjectID(kAudioObjectSystemObject)
        if let block = defaultOutputListenerBlock {
            CA.removeListener(sys, kAudioHardwarePropertyDefaultOutputDevice, block: block)
            defaultOutputListenerBlock = nil
        }
        if let block = devicesBlock {
            CA.removeListener(sys, kAudioHardwarePropertyDevices, block: block)
            devicesBlock = nil
        }
        routingReady = false
    }

    /// External writes land here: log the observation and let it stand.
    /// Scalar AND dB are logged so near-unity step sizes can be inspected.
    private func virtualControlObserved() {
        guard let vol = CA.volumeScalar(virtualDevice, scope: CA.outputScope),
              let mute = CA.isMuted(virtualDevice, scope: CA.outputScope) else { return }
        let db = CA.volumeDecibels(virtualDevice, scope: CA.outputScope).map { "\($0)" } ?? "?"

        Log.shared.line("OBSERVED external Passthru change: scalar=\(vol) dB=\(db) muted=\(mute) - native system volume moved; letting it stand")
    }

    private func defaultOutputChanged() {
        let id = CA.defaultOutputDevice()
        let name = id != 0 ? CA.deviceName(id) : "?"
        if routingChangeIsOurs {
            routingChangeIsOurs = false
            Log.shared.line("default output -> '\(name)' (our routing toggle)")
        } else {
            Log.shared.line("default output -> '\(name)' (changed externally)")
        }
    }

    // MARK: Auto-switch on device-list change

    /// Real output devices on the system, excluding our own virtual device.
    private var realOutputIDs: [AudioObjectID] {
        CA.outputDevices().filter { $0 != 0 && $0 != virtualDevice }
    }

    private func deviceListChanged() {
        guard routingReady else { return }
        let current = Set(realOutputIDs.map { UInt32($0) })
        let diff = DeviceListDiffer.diff(previous: knownDevices, current: current)
        knownDevices = current
        guard diff != DeviceListDiff(added: [], removed: []) else { return }
        actOnRoutingDecision(diff: diff, source: "hot-plug")
    }

    /// Run the routing decision against the current device set with an
    /// empty diff so the "already-present at launch" branch fires.
    /// Called from start() once IO is up.
    private func evaluateRoutingForCurrentDevices() {
        let current = Set(realOutputIDs.map { UInt32($0) })
        let diff = DeviceListDiffer.diff(previous: [], current: current)
        knownDevices = current
        actOnRoutingDecision(diff: diff, source: "launch")
    }

    private func actOnRoutingDecision(diff: DeviceListDiff, source: String) {
        let uidByID: [UInt32: String] = Dictionary(
            uniqueKeysWithValues: realOutputIDs.compactMap { id in
                CA.deviceUID(id).map { (UInt32(id), $0) }
            })
        let inputs = RoutingInputs(
            diff: diff,
            uidByID: uidByID,
            currentSinkID: outputDevice == 0 ? nil : UInt32(outputDevice),
            currentSinkName: outputDevice == 0 ? nil : CA.deviceName(outputDevice),
            currentSinkUID: outputDevice == 0 ? nil : CA.deviceUID(outputDevice),
            rememberedUID: persistedLastOutput.uid,
            isRouted: routedToVirtual)
        let decision = RoutingDecider.decide(inputs)
        guard decision != .noop else { return }
        guard !shouldDebounce(decision: decision) else { return }
        execute(decision: decision, source: source)
    }

    private func shouldDebounce(decision: RoutingDecision) -> Bool {
        let (uid, name): (String, String)
        switch decision {
        case .switchTo(let u), .fallbackTo(let u):
            let id = CA.device(matchingUID: u)
            uid = u
            name = id.map { CA.deviceName($0) } ?? u
        case .stopAndError(let n):
            uid = n
            name = n
        case .noop:
            return false
        }
        let now = Date()
        if let last = lastDebounced,
           last.uid == uid,
           last.name == name,
           now.timeIntervalSince(last.at) < 2 {
            Log.shared.line("auto-switch: debounced '\(name)' (last seen \(String(format: "%.2f", now.timeIntervalSince(last.at)))s ago)")
            return true
        }
        lastDebounced = (uid, name, now)
        return false
    }

    private func execute(decision: RoutingDecision, source: String) {
        switch decision {
        case .noop:
            return
        case .switchTo(let uid):
            guard let id = CA.device(matchingUID: uid) else {
                Log.shared.line("auto-switch (\(source)): '\(uid)' not present; skipping")
                return
            }
            Log.shared.line("auto-switch (\(source)): moving sink to '\(CA.deviceName(id))'")
            selectOutput(id)
        case .fallbackTo(let uid):
            guard let id = CA.device(matchingUID: uid) else {
                let name = outputDevice == 0 ? "previous output" : CA.deviceName(outputDevice)
                Log.shared.line("auto-fallback (\(source)): '\(uid)' not present; stopping")
                stopIO()
                publishError("Output '\(name)' disconnected. Pick a new one.")
                return
            }
            let oldName = outputDevice == 0 ? "?" : CA.deviceName(outputDevice)
            Log.shared.line("auto-fallback (\(source)): '\(oldName)' gone; falling back to '\(CA.deviceName(id))'")
            selectOutput(id)
        case .stopAndError(let name):
            Log.shared.line("auto-stop (\(source)): sink '\(name)' gone; no remembered fallback")
            stopIO()
            publishError("Output '\(name)' disconnected. Pick a new one.")
        }
    }

    // MARK: IO procs

    private func startIO() -> Bool {
        guard startAggregate() else { return false }
        return true
    }

    private func startAggregate() -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcID(aggregateID, Self.aggregateCallback, context, &procID)
        guard status == noErr else {
            publishError("Cannot attach IO proc to aggregate: \(status)")
            return false
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            if let created = procID {
                AudioDeviceDestroyIOProcID(aggregateID, created)
            }
            publishError("Cannot start aggregate IO: \(status)")
            return false
        }
        aggregateProcID = procID
        return true
    }

    private func stopIO() {
        if let procID = aggregateProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            aggregateProcID = nil
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
    }

    /// Tear down the current aggregate + IO and rebuild against the new
    /// physical output. Used by selectOutput and by the auto-fallback path.
    /// Returns true on success.
    @discardableResult
    private func rebuildAggregate(on newOutput: AudioObjectID) -> Bool {
        stopIO()
        outputDevice = newOutput
        // Aggregate migration: skip the pre-match on the underlying devices.
        // The aggregate's master clock (the physical device) sets the rate;
        // the virtual member is forced to match by Core Audio when the
        // aggregate is created.
        guard configureAggregate() else { return false }
        guard startAggregate() else { return false }
        return true
    }

    // macOS 26 SDK signature: (device, now, inInputData, inInputTime, outOutputData, outOutputTime, clientData)

    private static let aggregateCallback: AudioDeviceIOProc = { _, _, inputData, _, outputData, _, clientData in
        guard let raw = clientData.map({ UnsafeMutableRawPointer(mutating: $0) }) else { return noErr }
        Unmanaged<Engine>.fromOpaque(raw).takeUnretainedValue().runAggregateIO(inputData: inputData, outputData: outputData)
        return noErr
    }

    // MARK: Realtime path

    /// Single in-place copy from aggregate input (Passthru) to aggregate
    /// output (physical DAC), with the user's per-engine gain/mute applied.
    /// On the aggregate, capture and render advance in lockstep from one
    /// clock domain, so the copy is a same-cycle handoff and the buffer
    /// list sizes match. No ring, no governor, no drift seam.
    private func runAggregateIO(inputData: UnsafePointer<AudioBufferList>,
                                outputData: UnsafePointer<AudioBufferList>) {
        let inRaw = UnsafeRawPointer(inputData)
        let outRaw = UnsafeRawPointer(outputData)
        let inBuffers = Array(UnsafeBufferPointer(
            start: CA.bufferArray(inRaw), count: CA.bufferCount(inRaw)))
        let outBuffers = Array(UnsafeBufferPointer(
            start: CA.bufferArray(outRaw), count: CA.bufferCount(outRaw)))
        guard let src = inBuffers.first?.mData?.assumingMemoryBound(to: Float.self),
              let dst = outBuffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }

        let inChannels = max(Int(inBuffers[0].mNumberChannels), 1)
        let outChannels = max(Int(outBuffers[0].mNumberChannels), 1)
        let inFrames = Int(inBuffers[0].mDataByteSize) / (MemoryLayout<Float>.size * inChannels)
        let outFrames = Int(outBuffers[0].mDataByteSize) / (MemoryLayout<Float>.size * outChannels)
        let inSamples = inFrames * inChannels
        let outSamples = outFrames * outChannels
        let ticks = mach_absolute_time()

        if inChannels == outChannels {
            memcpy(dst, src, min(inSamples, outSamples) * MemoryLayout<Float>.size)
        } else {
            let copy = min(inFrames, outFrames)
            for f in 0..<copy {
                for c in 0..<min(inChannels, outChannels) {
                    dst[f * outChannels + c] = src[f * inChannels + c]
                }
            }
        }

        if outSamples > inSamples {
            memset(dst.advanced(by: inSamples), 0, (outSamples - inSamples) * MemoryLayout<Float>.size)
        }

        let (gain, isMuted) = controls.withLock { ($0.gain, $0.muted) }
        if isMuted {
            vDSP_vclr(dst, 1, vDSP_Length(outSamples))
        } else if gain != 1.0 {
            var scalar = gain
            vDSP_vsmul(dst, 1, &scalar, dst, 1, vDSP_Length(outSamples))
        }

        ioCounter.record(frames: outFrames, samples: outSamples, timeTicks: ticks)

        var localPeak: Float = 0
        for i in 0..<min(inSamples, outSamples) {
            let v = abs(src[i])
            if v > localPeak { localPeak = v }
        }
        let capturedPeak = localPeak
        peakAmplitude.withLock { amp in
            if capturedPeak > amp.peak { amp.peak = capturedPeak }
        }

        let firstFire = ioFiredOnce.withLock { fired -> Bool in
            if !fired { fired = true; return true }
            return false
        }
        if firstFire {
            Log.shared.line("aggregate IOProc: first cycle in=\(inFrames) frames @\(inChannels)ch out=\(outFrames) frames @\(outChannels)ch sample=\(localPeak)")
        }
    }

    // MARK: UI actions

    func setGain(percent: Double) {
        gainPercent = percent
        applyControls()
    }

    func setMuted(_ newValue: Bool) {
        muted = newValue
        applyControls()
    }

    private func applyControls() {
        let gain = Float(gainPercent / 100.0)
        controls.withLock {
            $0.gain = gain
            $0.muted = muted
        }
        logModeTransitionIfNeeded()
    }

    func setRouted(_ on: Bool) {
        guard on != routedToVirtual else { return }

        if on {
            routingChangeIsOurs = true
            let status = CA.setDefaultOutput(virtualDevice)
            if status == noErr {
                routedToVirtual = true
                Log.shared.line("routing: system audio now flows through Passthru")
            } else {
                routingChangeIsOurs = false
                Log.shared.line("routing FAILED (\(status)); default output untouched")
            }
        } else if let uid = originalOutputUID, let original = CA.device(matchingUID: uid) {
            routingChangeIsOurs = true
            CA.setDefaultOutput(original)
            routedToVirtual = false
            Log.shared.line("routing: restored '\(CA.deviceName(original))'")
        } else {
            Log.shared.line("routing off skipped: original output no longer present")
        }
        refreshStatusLine()
    }

    // MARK: Output destination picker

    func refreshOutputs() {
        var ids = CA.outputDevices()
            .filter { $0 != 0 && $0 != virtualDevice }
        // The Picker binds to selectedOutputID. If the current sink is no
        // longer in Core Audio's enumeration (e.g., a device the user
        // picked and then unplugged) the Picker's tag falls off the list
        // and the selection renders as empty. Pin the current output into
        // the list so the Picker's selection is always visible, even when
        // the device has just disappeared.
        if outputDevice != 0, !ids.contains(outputDevice) {
            ids.append(outputDevice)
        }
        availableOutputs = ids
            .map { OutputOption(id: $0, name: CA.deviceName($0)) }
            .sorted { $0.name < $1.name }
    }

    /// Moves engine playback to another real output. macOS's default output
    /// (Passthru while routed) is untouched - only the sink changes.
    /// Aggregate migration: stop the old aggregate (which detaches its
    /// IOProc), build a new aggregate with the new device as master clock,
    /// re-attach the IOProc. The bit-transparency contract holds because
    /// both members ride the same clock domain.
    func selectOutput(_ id: AudioObjectID) {
        guard id != 0 else { return }
        guard id != virtualDevice else {
            Log.shared.line("output switch refused: cannot render back into the virtual device")
            return
        }
        guard id != outputDevice else { return }

        let oldName = CA.deviceName(outputDevice)

        if rebuildAggregate(on: id) {
            selectedOutputID = id
            if let uid = CA.deviceUID(id) {
                persistedLastOutput.uid = uid
            }
            Log.shared.line("output switched '\(oldName)' -> '\(CA.deviceName(id))' @\(Int(CA.nominalRate(id))) Hz")
        } else {
            Log.shared.line("switch to '\(CA.deviceName(id))' failed; reverting to '\(oldName)'")
            if rebuildAggregate(on: outputDevice) {
                Log.shared.line("reverted to '\(oldName)'")
                // selectedOutputID was never changed in the success path;
                // it still equals the (now-confirmed-working) outputDevice.
            } else {
                // Engine is dead: clear both the published sink id and the
                // private outputDevice so the Picker shows an empty state
                // and refreshOutputs drops the cached fallback. The error
                // banner tells the user what happened.
                outputDevice = 0
                selectedOutputID = 0
                publishError("Playback stopped: cannot resume '\(oldName)'. Relaunch or pick another output.")
            }
        }
        refreshOutputs()
        refreshStatusLine()
    }

    func tick() {
        refreshOutputs()
        perAppMixer?.tick()

        // The single IOProc on the aggregate is the only thing left to
        // observe. The capture/render split is gone, the ring is gone, the
        // governor is gone - if the IOProc is firing, audio is flowing
        // bit-transparently. The per-second [io] line is gated by
        // ioTelemetryEnabled; default is silent.
        if Self.ioTelemetryEnabled {
            let io = ioCounter.drain()
            if io.cycleCount > 0 {
                let peak: Float = peakAmplitude.withLock { amp in
                    let v = amp.peak
                    amp.peak = 0
                    return v
                }
                Log.shared.line(String(
                    format: "[io] cycles=%d frames_min/avg/max=%d/%.0f/%d samples_min/avg/max=%d/%.0f/%d span=%.1f ms peak=%.4f",
                    io.cycleCount,
                    io.framesMin, io.framesAvg, io.framesMax,
                    io.samplesMin, io.samplesAvg, io.samplesMax,
                    io.timeSpanMs, peak))
            }
        }

        // Drop stats are no longer possible (the aggregate is a same-cycle
        // handoff and the bit-transparency contract no longer has a
        // `corrections` exception). Keep the field in case the contract is
        // revisited.
        if dropStats != nil { dropStats = nil }
    }

    // MARK: Peak amplitude (sample, per cycle, on the IOProc) - diagnostic
    // for confirming that audio is actually reaching the aggregate (not
    // silence).

    private let peakAmplitude = OSAllocatedUnfairLock<PeakAmp>(initialState: PeakAmp())
    private struct PeakAmp { var peak: Float = 0 }

    // MARK: Per-app gain actions

    func setAppGain(_ app: PlayingApp, percent: Double) {
        guard playingApps.contains(where: { $0.pid == app.pid }) else { return }
        perAppMixer?.setUserGain(pid: app.pid, bundleID: app.bundleID, percent: percent)
    }

    // MARK: Status surface

    private func refreshStatusLine() {
        formatSummary = outputDevice != 0
            ? CA.shortFormatLine(virtualDevice, scope: CA.inputScope)
            : ""
        outputName = outputDevice != 0 ? CA.deviceName(outputDevice) : ""
    }

    private func currentMode() -> Mode {
        let (gain, isMuted) = controls.withLock { ($0.gain, $0.muted) }
        if isMuted { return .muted }
        return gain == 1.0 ? .passthrough : .gain
    }

    private func logModeTransitionIfNeeded() {
        let mode = currentMode()
        guard mode != lastLoggedMode else { return }
        lastLoggedMode = mode
        switch mode {
        case .passthrough:
            Log.shared.line("mode -> PASS-THROUGH: straight copy, no multiply, no resample")
        case .gain:
            Log.shared.line("mode -> GAIN \(Int(gainPercent))%")
        case .muted:
            Log.shared.line("mode -> MUTED")
        }
    }

    private func publishError(_ message: String) {
        Log.shared.line("ERROR: \(message)")
        DispatchQueue.main.async {
            self.errorText = message
        }
    }

    // MARK: Signals (Ctrl+C must not strand Passthru as default output)

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: eventQueue)
            source.setEventHandler { [weak self] in
                self?.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Telemetry tick (independent of the menu's view task so the [io]
    // line emits even when the user hasn't opened the menu)

    private var tickSource: DispatchSourceTimer?

    private func startTickLoop() {
        let source = DispatchSource.makeTimerSource(queue: eventQueue)
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        source.resume()
        tickSource = source
    }
}
