// Passthru HAL driver (libASPL).
//
// One device, two streams. Apps write into the OUTPUT stream (which carries
// native volume + mute controls); the mixed result is stashed here and served
// back through the INPUT stream to the engine. This is the same role
// BlackHole plays, hand-written on libASPL's typed handlers.
//
// Per-app gain: clients write pid/bundle-to-gain pairs through the custom
// 'lapv' property on the device object; each client's buffer is scaled before
// the mix. Unity stays bit-transparent: with every gain at 1.0, no sample is
// edited. Per-client gains apply at Apple's ProcessOutput ('pout') stage,
// enabled by a small marked patch to the vendored libASPL; master volume and
// mute keep applying exactly once post-mix via OnProcessMixedOutput's default
// Stream::ApplyProcessing(). The two knobs compose multiplicatively across
// stages without touching each other.
//
// Curve: library default (Apple pow-2 sample curve: scalar = raw-fraction
// squared, dB reported linearly -96..0). Contrast with BlackHole's linear
// -64..0 dB labeling: near-unity steps feel finer here.
//
// Logging: counters are sampled by a background watchdog and written via
// os_log (subsystem dev.passthru.driver), visible with:
//   log stream --predicate 'subsystem == "dev.passthru.driver"'
// The realtime IO paths themselves never log.

#include "ClientGain.hpp"
#include "GainStore.hpp"
#include "RingBuffer.hpp"

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>
#include <os/log.h>

#include <atomic>
#include <functional>
#include <memory>
#include <thread>

namespace {

constexpr UInt32 SampleRate = 44100;
constexpr UInt32 ChannelCount = 2;

// Bounded near 100 ms (4096 frames ~ 93 ms at 44.1 kHz). The bridge is a
// same-cycle handoff, so steady state sits far below this; the cap exists to
// fail loud, not to hide drift.
constexpr UInt64 RingCapacityFrames = 1 << 12;

// Custom property carrying per-app gains: CFPropertyList array of
// {pid: Int32, bundle-id: String, gain: Double} dicts (either key optional,
// gain required). Set by the menu app or CLI tool; read back for reconciliation.
const AudioObjectPropertySelector kAppGainsSelector = 'lapv';

os_log_t DriverLog()
{
    static os_log_t log = os_log_create("dev.passthru.driver", "driver");
    return log;
}

// Bridges mixed app audio from the device's output stream to its input stream,
// where the engine reads it. Volume/mute attenuation has already been applied
// by the output stream's controls in OnProcessMixedOutput (default handler),
// so what lands here is what macOS's native volume decided.
//
// Per-client gains additionally scale each client's buffer pre-mix
// (OnProcessClientOutput, 'pout' stage) by that client's stored gain, if any.
// The two time-critical pieces (the SPSC ring and the gain stage) live in
// host-testable modules now; this handler is wiring only.
class BridgeHandler : public aspl::ControlRequestHandler, public aspl::IORequestHandler
{
public:
    explicit BridgeHandler(std::shared_ptr<passthru::GainStore> gains)
        : gains_(std::move(gains))
    {
    }

    OSStatus OnStartIO() override
    {
        os_log(DriverLog(), "IO started");
        inputEverRead_.store(false, std::memory_order_release);
        return kAudioHardwareNoError;
    }

    void OnStopIO() override
    {
        os_log(DriverLog(), "IO stopped");
        inputEverRead_.store(false, std::memory_order_release);
    }

    // Realtime thread ('pout'): scale THIS client's samples by its gain.
    // Deliberately does NOT call Stream::ApplyProcessing() here - master
    // volume/mute are applied exactly once post-mix by OnProcessMixedOutput's
    // default implementation. Unity short-circuits to a bit-transparent no-op.
    void OnProcessClientOutput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount) override
    {
        (void)stream;
        (void)zeroTimestamp;
        (void)timestamp;

        if (!client || frameCount == 0 || channelCount == 0) {
            return;
        }

        const Float32 gain =
            gains_->GainFor(client->GetProcessID(), client->GetBundleID());
        clientGain_.Apply(frames, frameCount * channelCount, gain);
    }

    // Realtime thread: full mix from apps, already attenuated by our
    // native volume control. Stash for the input side.
    //
    // When the engine runs on the aggregate (master = physical DAC,
    // member = Passthru) it reads the aggregate's input plane, NOT this
    // device's input stream. The bridge ring here is then a dead end:
    // nothing reads it back, so the ring fills to capacity and increments
    // the `overruns` counter that would otherwise be a meaningful audio-drop
    // signal. The audio still reaches the speakers (via the aggregate path),
    // but the counter noise is misleading.
    //
    // Track whether the input stream has been read at least once since IO
    // started. If not, skip the write entirely. The data still flows to the
    // aggregate; this just stops feeding an unread ring.
    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const void* bytes,
        UInt32 bytesCount) override
    {
        (void)stream;
        (void)zeroTimestamp;
        (void)timestamp;
        if (!inputEverRead_.load(std::memory_order_acquire)) {
            writeSkippedNoInput_.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        ring_.Write(static_cast<const Float32*>(bytes),
            bytesCount / (ChannelCount * sizeof(Float32)));
    }

    // Realtime thread: the engine (or any other client) reads through the
    // input stream; the ring zero-fills any underrun itself. First read
    // since IO start flips inputEverRead_ so the write side starts feeding
    // the ring. With the aggregate path this rarely fires; the bit-
    // transparent pipeline is the aggregate IOProc, not this read.
    void OnReadClientInput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        void* bytes,
        UInt32 bytesCount) override
    {
        (void)client;
        (void)stream;
        (void)zeroTimestamp;
        (void)timestamp;
        inputEverRead_.store(true, std::memory_order_release);
        (void)ring_.Read(static_cast<Float32*>(bytes),
            bytesCount / (ChannelCount * sizeof(Float32)));
    }

    passthru::RingBuffer& Ring() { return ring_; }

    std::shared_ptr<passthru::GainStore> Gains() const { return gains_; }
    UInt64 GainedBuffers() const { return clientGain_.AppliedBuffers(); }
    UInt64 SkippedWritesNoInput() const { return writeSkippedNoInput_.load(std::memory_order_relaxed); }

private:
    // Per-app gains depend on the small marked 'pout' opt-in patch inside
    // vendored libASPL (third_party/libaspl/src/Device.cpp); a naive vendored
    // upgrade silently kills the per-app feature - see SECURITY.md / repo
    // history for the rationale.
    passthru::RingBuffer ring_{ChannelCount, RingCapacityFrames};
    passthru::ClientGain clientGain_;
    std::shared_ptr<passthru::GainStore> gains_;
    std::atomic<bool> inputEverRead_{false};
    std::atomic<UInt64> writeSkippedNoInput_{0};
};

void StartWatchdog(std::shared_ptr<BridgeHandler> handler)
{
    std::thread([handler = std::move(handler)] {
        UInt64 lastOverruns = 0;
        UInt64 lastUnderruns = 0;
        UInt64 lastGainedBuffers = 0;
        UInt64 lastGainRevision = 0;
        UInt64 lastFillFrames = 0;
        UInt64 lastSkippedNoInput = 0;
        bool firstPass = true;

        while (true) {
            std::this_thread::sleep_for(std::chrono::seconds(5));

            const UInt64 overruns = handler->Ring().Overruns();
            const UInt64 underruns = handler->Ring().Underruns();
            const UInt64 gainedBuffers = handler->GainedBuffers();
            const auto gains = handler->Gains();
            const UInt64 gainRevision = gains ? gains->Revision() : 0;
            const size_t gainEntries = gains ? gains->EntryCount() : 0;
            const UInt64 fillFrames = handler->Ring().Fill();
            const double fillMs =
                fillFrames * 1000.0 / static_cast<double>(SampleRate);
            const UInt64 skippedNoInput = handler->SkippedWritesNoInput();

            if (firstPass || overruns != lastOverruns || underruns != lastUnderruns ||
                gainedBuffers != lastGainedBuffers || gainRevision != lastGainRevision ||
                fillFrames != lastFillFrames || skippedNoInput != lastSkippedNoInput) {
                os_log(DriverLog(),
                    "counters: fill=%llu frames (~%.1f ms) "
                    "overruns=%llu (+%llu) underruns=%llu (+%llu) "
                    "gained-buffers=%llu (+%llu) skipped-no-input=%llu (+%llu) "
                    "app-gains: rev=%llu entries=%zu",
                    fillFrames, fillMs,
                    overruns, overruns - lastOverruns,
                    underruns, underruns - lastUnderruns,
                    gainedBuffers, gainedBuffers - lastGainedBuffers,
                    skippedNoInput, skippedNoInput - lastSkippedNoInput,
                    gainRevision, gainEntries);
                lastOverruns = overruns;
                lastUnderruns = underruns;
                lastGainedBuffers = gainedBuffers;
                lastGainRevision = gainRevision;
                lastFillFrames = fillFrames;
                lastSkippedNoInput = skippedNoInput;
                firstPass = false;
            }
        }
    }).detach();
}

AudioStreamBasicDescription MakeFloat32Format()
{
    AudioStreamBasicDescription fmt{};
    fmt.mSampleRate = SampleRate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian |
                       kAudioFormatFlagIsPacked;
    fmt.mBitsPerChannel = 32;
    fmt.mChannelsPerFrame = ChannelCount;
    fmt.mBytesPerFrame = ChannelCount * sizeof(Float32);
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerPacket = ChannelCount * sizeof(Float32);
    return fmt;
}

std::shared_ptr<aspl::Driver> CreateDriver()
{
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters params;
    params.Name = "Passthru";
    params.Manufacturer = "Passthru";
    params.DeviceUID = "dev.passthru.virtual";
    params.ModelUID = "dev.passthru.virtual.model";
    params.SampleRate = SampleRate;
    params.ChannelCount = ChannelCount;
    params.EnableMixing = true;

    auto device = std::make_shared<aspl::Device>(context, params);

    // Library defaults are Int16/44.1k; the bit-transparency contract wants
    // explicit Float32 on both streams.
    aspl::StreamParameters outParams;
    outParams.Direction = aspl::Direction::Output;
    outParams.Format = MakeFloat32Format();

    // Output stream WITH native volume+mute elements: keyboard keys, Control
    // Center slider, mute key, and HUD act on these once we are default output.
    device->AddStreamWithControlsAsync(outParams);

    aspl::StreamParameters inParams;
    inParams.Direction = aspl::Direction::Input;
    inParams.Format = MakeFloat32Format();

    // Input stream WITHOUT controls: the engine must read exactly what macOS
    // already attenuated - no second knob on the capture side.
    device->AddStreamAsync(inParams);

    // Allow matching the real output's rate (the engine's negotiate flow).
    device->SetAvailableSampleRatesAsync(
        {{44100.0, 44100.0}, {48000.0, 48000.0}});

    // Per-app gain table, exposed as a custom property on the device object.
    // Any process may AudioObjectSetPropertyData it with a CFPropertyList
    // array; the host marshals the plist across processes.
    auto gains = std::make_shared<passthru::GainStore>();

    device->RegisterCustomProperty(kAppGainsSelector,
        std::function<CFPropertyListRef()>([gains] {
            return gains->CopyPlist(); // +1, released by caller
        }),
        std::function<void(CFPropertyListRef)>([gains](CFPropertyListRef value) {
            if (gains->SetFromPlist(value)) {
                os_log(DriverLog(), "app gains updated: %zu entries",
                    gains->EntryCount());
            } else {
                os_log(DriverLog(), "app gains REJECTED: malformed property list");
            }
        }));

    auto handler = std::make_shared<BridgeHandler>(gains);
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);

    StartWatchdog(handler);

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);

    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" void* PassthruEntryPoint(CFAllocatorRef allocator, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    static std::shared_ptr<aspl::Driver> driver = CreateDriver();

    return driver->GetReference();
}
