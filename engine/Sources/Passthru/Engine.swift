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

    // MARK: UI state (write only on the main thread; see publishOnMain)

    @Published private(set) var formatSummary = ""
    @Published private(set) var outputName = ""
    @Published private(set) var dropStats: String?
    @Published private(set) var isDefaultOutput = false
    @Published private(set) var currentSystemOutputName = ""
    @Published private(set) var availableOutputs: [OutputOption] = []
    @Published private(set) var selectedOutputID: AudioObjectID = 0
    @Published var gainPercent: Double = 100
    @Published var muted = false
    @Published private(set) var fatalErrorText: String?
    @Published private(set) var recoverableErrorText: String?
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

    private var virtualListeners: [(selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, block: AudioObjectPropertyListenerBlock)] = []
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var signalSources: [DispatchSourceSignal] = []
    private var lastLoggedMode: Mode?

    // Auto-switch engine sink to the last-used output. Ordered, capped
    // output chain (most-recent first); system-object listener on the
    // device list; decision via the pure RoutingDecider. The chain is
    // written on a successful selectOutput (user pick OR auto-fallback)
    // and read on every routing decision. The Passthru UID is rejected
    // at the persistence seam itself; the engine's own Passthru refusal
    // in selectOutput is in addition to that, not a replacement.
    private let persistedOutputChain: PersistedOutputChain
    private var knownDevices: Set<UInt32> = []
    private var devicesBlock: AudioObjectPropertyListenerBlock?
    private var routingReady = false
    private var lastDebounced: (uid: String, name: String, at: Date)?

    // Who is playing and per-app gains (inactive until start()).
    private var perAppMixer: PerAppMixer?

    init(persistedOutputChain: PersistedOutputChain = PersistedOutputChain()) {
        self.persistedOutputChain = persistedOutputChain
    }

    // MARK: Lifecycle

    /// The system default output is sometimes the virtual device itself
    /// (fresh install, or a previous session left the routing toggle on).
    /// Rendering Passthru back into itself is undefined, so pick a sane
    /// real sink: the chain head if online, otherwise any real output,
    /// otherwise nothing (the engine defers to Retry).
    private func resolveInitialSink(defaultOutput: AudioObjectID) -> AudioObjectID {
        guard defaultOutput == virtualDevice else { return defaultOutput }
        if let remembered = persistedOutputChain.read().first,
           let rememberedID = GainChannel.CA.device(matchingUID: remembered),
           rememberedID != virtualDevice {
            Log.shared.line("start: default was virtual; promoted remembered '\(GainChannel.CA.deviceName(rememberedID))'")
            return rememberedID
        }
        if let any = GainChannel.CA.outputDevices().first(where: { $0 != 0 && $0 != virtualDevice }) {
            Log.shared.line("start: default was virtual; promoted any real output '\(GainChannel.CA.deviceName(any))'")
            return any
        }
        Log.shared.line("start: default was virtual and no real output is online; engine deferred to Retry")
        publishRecoverableError("No real output is available. Plug in a speaker or DAC, then click Retry.")
        return 0
    }

    @discardableResult
    func start() -> Bool {
        Log.shared.open(file: Self.logFileURL)

        guard let dev = GainChannel.findVirtualDevice() else {
            publishFatalError("Passthru not found. Install the driver first: sudo ./install.sh, then relaunch.")
            return false
        }
        virtualDevice = dev

        var out = GainChannel.CA.defaultOutputDevice()
        guard out != 0 else {
            publishFatalError("No default output device found.")
            return false
        }

        out = resolveInitialSink(defaultOutput: out)

        if out == 0 {
            return false
        }

        outputDevice = out

        Log.shared.line("devices: virtual='\(GainChannel.CA.deviceName(dev))' (#\(dev)) real='\(GainChannel.CA.deviceName(out))' (#\(out))")
        Log.shared.line("rates (pre-aggregate): virtual=\(GainChannel.CA.nominalRate(dev)) Hz, real=\(GainChannel.CA.nominalRate(out)) Hz")

        Log.shared.line("formats: virtual-in=\(GainChannel.CA.formatLine(dev, scope: GainChannel.CA.inputScope)), real-out=\(GainChannel.CA.formatLine(out, scope: GainChannel.CA.outputScope))")
        Log.shared.line("io quanta: virtual=\(GainChannel.CA.bufferFrameSize(dev)) frames, real=\(GainChannel.CA.bufferFrameSize(out)) frames")

        guard configureAggregate() else { return false }

        logVirtualControls()
        installListeners()
        installSignalHandlers()
        startTickLoopIfNeeded()

        let mixer = PerAppMixer(virtualDevice: dev, persisted: PersistedGains())
        mixer.onUpdate = { [weak self] apps in
            self?.publishOnMain(\.playingApps, apps)
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

        availableOutputs = buildOutputsSnapshot()
        selectedOutputID = outputDevice
        applyStatusLine()
        Log.shared.line("engine running")
        // A clean start clears any stale recoverable banner from a prior
        // attempt; fatal errors are deliberately preserved (install the
        // driver is still the right next step).
        publishOnMain(\.recoverableErrorText, nil)
        return true
    }

    func shutdown() {
        stopIO()
        removeListeners()
        perAppMixer?.stop()
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
        guard let virtualUID = GainChannel.CA.deviceUID(virtualDevice),
              let physicalUID = GainChannel.CA.deviceUID(outputDevice) else {
            publishRecoverableError("Cannot read device UIDs for the aggregate")
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
            publishRecoverableError("Cannot create aggregate (master='\(GainChannel.CA.deviceName(outputDevice))', member='\(GainChannel.CA.deviceName(virtualDevice))'): \(status)")
            Log.shared.line("aggregate: AudioHardwareCreateAggregateDevice \(status); aggregate path not available on this host")
            return false
        }
        aggregateID = newID
        let aggRate = GainChannel.CA.nominalRate(newID)
        Log.shared.line("aggregate: master='\(GainChannel.CA.deviceName(outputDevice))' member='\(GainChannel.CA.deviceName(virtualDevice))' quantum=\(GainChannel.CA.bufferFrameSize(newID)) frames rate=\(aggRate) Hz")
        return true
    }

    // MARK: Native control observation (native macOS volume IS the system
    // volume. macOS writes OUR volume element; we log and let it stand.)

    private func logVirtualControls() {
        for scope in [GainChannel.CA.inputScope, GainChannel.CA.outputScope] {
            let vol = GainChannel.CA.volumeScalar(virtualDevice, scope: scope).map { "\($0)" } ?? "?"
            let db = GainChannel.CA.volumeDecibels(virtualDevice, scope: scope).map { "\($0)" } ?? "?"
            let mute = GainChannel.CA.isMuted(virtualDevice, scope: scope).map { "\($0)" } ?? "?"
            Log.shared.line("observed Passthru \(scopeName(scope)): scalar \(vol), dB \(db), muted \(mute) (not modified)")
        }
    }

    private func scopeName(_ scope: AudioObjectPropertyScope) -> String {
        scope == GainChannel.CA.inputScope ? "input-master" : "output-master"
    }

    // MARK: Observation listeners (record whether keys/slider/HUD act
    // natively on OUR volume element while Passthru is default output)

    private func installListeners() {
        let eventQueue = eventQueue

        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for scope in [GainChannel.CA.inputScope, GainChannel.CA.outputScope] {
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
        guard let vol = GainChannel.CA.volumeScalar(virtualDevice, scope: GainChannel.CA.outputScope),
              let mute = GainChannel.CA.isMuted(virtualDevice, scope: GainChannel.CA.outputScope) else { return }
        let db = GainChannel.CA.volumeDecibels(virtualDevice, scope: GainChannel.CA.outputScope).map { "\($0)" } ?? "?"

        Log.shared.line("OBSERVED external Passthru change: scalar=\(vol) dB=\(db) muted=\(mute) - native system volume moved; letting it stand")
    }

    private func defaultOutputChanged() {
        refreshSystemDefaultState()
        let name = currentSystemOutputName.isEmpty ? "?" : currentSystemOutputName
        Log.shared.line("default output -> '\(name)' (changed externally)")
    }

    /// Re-reads macOS's current default output device and publishes whether
    /// it is our virtual device, plus the device name for the UI. The
    /// engine does not own this property; the user picks the system default
    /// via Sound settings. Called from the `kAudioHardwarePropertyDefaultOutputDevice`
    /// listener (snappy) and once per tick (1 s backstop for coalesced events).
    private func refreshSystemDefaultState() {
        let id = GainChannel.CA.defaultOutputDevice()
        let name = id != 0 ? GainChannel.CA.deviceName(id) : ""
        let isDefault = id != 0 && id == virtualDevice
        publishOnMain(\.isDefaultOutput, isDefault)
        publishOnMain(\.currentSystemOutputName, name)
    }

    // MARK: Auto-switch on device-list change

    /// Real output devices on the system, excluding our own virtual device.
    private var realOutputIDs: [AudioObjectID] {
        GainChannel.CA.outputDevices().filter { $0 != 0 && $0 != virtualDevice }
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
                GainChannel.CA.deviceUID(id).map { (UInt32(id), $0) }
            })
        let inputs = RoutingInputs(
            diff: diff,
            uidByID: uidByID,
            currentSinkID: outputDevice == 0 ? nil : UInt32(outputDevice),
            currentSinkName: outputDevice == 0 ? nil : GainChannel.CA.deviceName(outputDevice),
            currentSinkUID: outputDevice == 0 ? nil : GainChannel.CA.deviceUID(outputDevice),
            rememberedChain: persistedOutputChain.read())
        let decision = RoutingDecider.decide(inputs)
        guard decision != .noop else { return }
        guard !shouldDebounce(decision: decision) else { return }
        execute(decision: decision, source: source)
    }

    private func shouldDebounce(decision: RoutingDecision) -> Bool {
        let (uid, name): (String, String)
        switch decision {
        case .switchTo(let u), .fallbackTo(let u):
            let id = GainChannel.CA.device(matchingUID: u)
            uid = u
            name = id.map { GainChannel.CA.deviceName($0) } ?? u
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
            guard let id = GainChannel.CA.device(matchingUID: uid) else {
                Log.shared.line("auto-switch (\(source)): '\(uid)' not present; skipping")
                return
            }
            Log.shared.line("auto-switch (\(source)): moving sink to '\(GainChannel.CA.deviceName(id))'")
            selectOutput(id)
        case .fallbackTo(let uid):
            guard let id = GainChannel.CA.device(matchingUID: uid) else {
                let name = outputDevice == 0 ? "previous output" : GainChannel.CA.deviceName(outputDevice)
                Log.shared.line("auto-fallback (\(source)): '\(uid)' not present; stopping")
                stopIO()
                publishRecoverableError("Output '\(name)' disconnected. Plug it back in or pick another, then click Retry.")
                return
            }
            let oldName = outputDevice == 0 ? "?" : GainChannel.CA.deviceName(outputDevice)
            Log.shared.line("auto-fallback (\(source)): '\(oldName)' gone; falling back to '\(GainChannel.CA.deviceName(id))'")
            selectOutput(id)
        case .stopAndError(let name):
            Log.shared.line("auto-stop (\(source)): sink '\(name)' gone; no remembered fallback")
            stopIO()
            publishRecoverableError("Output '\(name)' disconnected. Plug it back in or pick another, then click Retry.")
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
            publishRecoverableError("Cannot attach IO proc to aggregate: \(status)")
            return false
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            if let created = procID {
                AudioDeviceDestroyIOProcID(aggregateID, created)
            }
            publishRecoverableError("Cannot start aggregate IO: \(status)")
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
            start: GainChannel.CA.bufferArray(inRaw), count: GainChannel.CA.bufferCount(inRaw)))
        let outBuffers = Array(UnsafeBufferPointer(
            start: GainChannel.CA.bufferArray(outRaw), count: GainChannel.CA.bufferCount(outRaw)))
        guard let src = inBuffers.first?.mData?.assumingMemoryBound(to: Float.self),
              let dst = outBuffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }

        let inChannels = GainChannel.CA.channelCount(buffer: inBuffers[0])
        let outChannels = GainChannel.CA.channelCount(buffer: outBuffers[0])
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
        publishOnMain(\.gainPercent, percent)
        applyControls()
    }

    func setMuted(_ newValue: Bool) {
        publishOnMain(\.muted, newValue)
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

    // MARK: Output destination picker

    /// Pure: enumerate output devices and build the Picker model. No
    /// `@Published` writes; safe to call from any queue. The Picker
    /// binds to selectedOutputID; if the current sink is no longer in
    /// Core Audio's enumeration (e.g., the user picked and then
    /// unplugged a device) the Picker's tag falls off the list and the
    /// selection renders as empty. Pin the current output into the list
    /// so the selection is always visible, even when the device has
    /// just disappeared.
    private func buildOutputsSnapshot() -> [OutputOption] {
        var ids = GainChannel.CA.outputDevices()
            .filter { $0 != 0 && $0 != virtualDevice }
        if outputDevice != 0, !ids.contains(outputDevice) {
            ids.append(outputDevice)
        }
        return ids
            .map { OutputOption(id: $0, name: GainChannel.CA.deviceName($0)) }
            .sorted { $0.name < $1.name }
    }

    /// Main-thread status line + Picker refresh. Synchronous; off-main
    /// callers (eventQueue) go through `publishStatusLine` instead.
    private func applyStatusLine() {
        let s = buildStatusLineSnapshot()
        availableOutputs = buildOutputsSnapshot()
        formatSummary = s.format
        outputName = s.name
    }

    /// Off-main status line + Picker refresh. Builds the snapshot on the
    /// calling queue, hops to main for the `@Published` writes (AppKit
    /// only permits NSMenu mutation on main; SwiftUI's `makeMainMenu`
    /// trips an assertion otherwise).
    private func publishStatusLine() {
        let outputs = buildOutputsSnapshot()
        let status = buildStatusLineSnapshot()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.availableOutputs = outputs
            self.formatSummary = status.format
            self.outputName = status.name
        }
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

        let oldName = GainChannel.CA.deviceName(outputDevice)

        if rebuildAggregate(on: id) {
            let outputs = buildOutputsSnapshot()
            let status = buildStatusLineSnapshot()
            // One transaction: every UI field that depends on the new sink
            // lands in the same run-loop turn so SwiftUI diffs them together
            // instead of across two turns (which is what was tripping
            // ForEachState.LazyEdits when a helper rejoined with a recycled
            // PID in the same window).
            publishOnMain { [weak self] in
                guard let self else { return }
                self.selectedOutputID = id
                self.availableOutputs = outputs
                self.formatSummary = status.format
                self.outputName = status.name
                self.recoverableErrorText = nil
            }
            if let uid = GainChannel.CA.deviceUID(id) {
                // Belt-and-braces: the chain also rejects the Passthru UID,
                // so even if the engine's own refusal above were ever bypassed
                // the chain stays clean. Record AFTER the successful
                // rebuild - a failed switch (revert path below) does not
                // write the chain.
                persistedOutputChain.record(uid: uid)
            }
            Log.shared.line("output switched '\(oldName)' -> '\(GainChannel.CA.deviceName(id))' @\(Int(GainChannel.CA.nominalRate(id))) Hz")
        } else {
            Log.shared.line("switch to '\(GainChannel.CA.deviceName(id))' failed; reverting to '\(oldName)'")
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
                let outputs = buildOutputsSnapshot()
                let status = buildStatusLineSnapshot()
                publishOnMain { [weak self] in
                    guard let self else { return }
                    self.selectedOutputID = 0
                    self.availableOutputs = outputs
                    self.formatSummary = status.format
                    self.outputName = status.name
                }
                publishRecoverableError("Playback stopped: cannot resume '\(oldName)'. Pick another output or click Retry.")
            }
        }
    }

    func tick() {
        publishStatusLine()
        refreshSystemDefaultState()
        if dropStats != nil { publishOnMain(\.dropStats, nil) }
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
    }

    // MARK: Peak amplitude (sample, per cycle, on the IOProc) - diagnostic
    // for confirming that audio is actually reaching the aggregate (not
    // silence).

    private let peakAmplitude = OSAllocatedUnfairLock<PeakAmp>(initialState: PeakAmp())
    private struct PeakAmp { var peak: Float = 0 }

    // MARK: Per-app gain actions

    func setAppGain(_ app: PlayingApp, percent: Double) {
        // Match the row's identity, not its pid. A bundled app's row may be
        // mid-drag when its helper relaunches with a fresh pid; the slider's
        // closure captures the prior `PlayingApp` value, so the call must
        // still land on the live row.
        guard playingApps.contains(where: { $0.id == app.id }) else { return }
        lastPerAppGainCall = (pid: app.pid, bundleID: app.bundleID, percent: percent)
        perAppMixer?.setUserGain(pid: app.pid, bundleID: app.bundleID, percent: percent)
    }

    // MARK: Test seams

    /// Last call forwarded to `PerAppMixer.setUserGain`; `nil` until the
    /// first call. Used by `PlayingAppIdentityTests` to pin the
    /// identity-based guard.
    private(set) var lastPerAppGainCall: (pid: Int32, bundleID: String, percent: Double)?

    func injectPlayingAppsForTest(_ apps: [PlayingApp]) {
        playingApps = apps
    }

    // MARK: Status surface

    /// Pure: compute the (format, name) pair for the current output. No
    /// `@Published` writes; safe to call from any queue.
    private func buildStatusLineSnapshot() -> (format: String, name: String) {
        let format = outputDevice != 0
            ? GainChannel.CA.shortFormatLine(virtualDevice, scope: GainChannel.CA.inputScope)
            : ""
        let name = outputDevice != 0 ? GainChannel.CA.deviceName(outputDevice) : ""
        return (format, name)
    }

    // MARK: Main-thread publishing

    /// All `@Published` writes must land on the main thread; this helper
    /// makes that unmissable. Off-main callers (eventQueue, listener
    /// callbacks, the per-app mixer bridge) hop through here. On the main
    /// thread the assignment is synchronous.
    ///
    /// `internal` so the main-thread publishing rule can be pinned by
    /// `PassthruTests`; the helper is only meaningful to the Engine
    /// itself.
    func publishOnMain<T>(_ keyPath: ReferenceWritableKeyPath<Engine, T>, _ value: T) {
        if Thread.isMainThread {
            self[keyPath: keyPath] = value
        } else {
            DispatchQueue.main.async { [weak self] in
                self?[keyPath: keyPath] = value
            }
        }
    }

    /// Run an arbitrary batch of writes as a single transaction. Use this
    /// when several `@Published` fields must change together so SwiftUI
    /// diffs them in one run-loop turn (e.g. on sink switch, the new
    /// `selectedOutputID`, `availableOutputs`, `formatSummary`,
    /// `outputName`, and `recoverableErrorText` are mutually dependent).
    func publishOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
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

    private func publishFatalError(_ message: String) {
        Log.shared.line("FATAL: \(message)")
        publishOnMain(\.fatalErrorText, message)
    }

    private func publishRecoverableError(_ message: String) {
        Log.shared.line("ERROR: \(message)")
        publishOnMain(\.recoverableErrorText, message)
    }

    /// Re-runs the routing decision against the current device set. Used by
    /// the recoverable banner's Retry button after a wake/unplug left the
    /// engine in a torn-down state. Clears the banner on success; leaves it
    /// up so the user can keep trying if no real output is online yet.
    func retry() {
        evaluateRoutingForCurrentDevices()
        if outputDevice != 0 {
            publishOnMain(\.recoverableErrorText, nil)
            Log.shared.line("retry: recovered; sink='\(GainChannel.CA.deviceName(outputDevice))'")
        } else {
            Log.shared.line("retry: no online output yet")
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

    // MARK: Telemetry tick
    //
    // Production tick is driven by the menu's view task (PassthruApp.swift),
    // which calls `engine.tick()` once per second on main. That is the only
    // tick the host crash needed: the engine's status line and per-app mixer
    // run from there.
    //
    // The latency instrument (--io-telemetry) needs the [io] line to emit
    // even when the menu has not been opened, so when the flag is on we
    // start a second tick source on `eventQueue`. With both sources live
    // the 1-second cadence can land on the same run-loop turn as a
    // sink-switch's publishes, which is what tripped
    // ForEachState.LazyEdits; gating the timer behind the flag keeps
    // production single-source.

    private var tickSource: DispatchSourceTimer?

    private func startTickLoopIfNeeded() {
        guard Self.ioTelemetryEnabled else { return }
        let source = DispatchSource.makeTimerSource(queue: eventQueue)
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        source.resume()
        tickSource = source
    }
}
