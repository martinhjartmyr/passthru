# Passthru

A bit-transparent virtual audio device for macOS that exposes native volume
keys and adds per-app loudness control.

macOS hides its system volume for external DACs that report no hardware
volume control. Passthru ships a small Core Audio HAL driver that sits
between apps and your DAC: it advertises a native volume element, so the
keyboard volume keys, Control Center slider, mute key, and on-screen HUD
all act on it like any built-in output. When every gain is at unity,
audio is not touched. When you want to fix the loudness of one app while
everything else stays at unity, you can.

## How it works

Two pieces, one IPC seam.

- **Driver** (`driver/`, C++ on libASPL) - registers a HAL plug-in called
  "Passthru" with one output stream (native volume + mute) and one input
  stream (no controls, reads back what macOS already attenuated). The
  custom property `'lapv'` on the device object carries per-app gains:
  pid/bundle-id to a float in `[0.0, 4.0]`. Per-client gains apply
  pre-mix, master volume/mute apply post-mix, the two compose
  multiplicatively. At every gain = 1.0 no sample is multiplied. Code
  lives under `passthru::`.

- **Engine** (`engine/`, Swift) - a menu-bar app that creates a private
  Core Audio aggregate (master clock = the physical output, member =
  Passthru), runs a single IOProc that copies the virtual input to the
  output with the user's per-engine gain/mute, and lists the apps
  currently playing through Passthru with per-app sliders. On the
  aggregate, capture and render share one clock domain, so the copy is a
  same-cycle handoff. A small CLI tool, `PassthruGain`, reads and writes
  the same `'lapv'` property without any UI.

The contract between the two sides is the payload schema documented in
`contract/lapv/SCHEMA.md` plus the checked-in golden-vector plists. Both
sides' tests consume the same bytes.

## Build and install

Requirements: macOS 14+, Xcode command-line tools, CMake 3.12+.

```sh
# Build the driver (also builds the GainStore and SamplePath unit tests).
cmake -B driver/build -S driver && cmake --build driver/build

# Install the driver into the system HAL plug-in directory. Requires sudo.
sudo ./install.sh
```

The install script restarts `coreaudiod` and confirms Passthru is
enumerated. Some hosts need a reboot for the driver to appear - the
script reports which case you hit.

```sh
# Build and run the engine.
cd engine && swift run Passthru
```

Quit with the menu's Quit button or Ctrl+C. Select "Passthru" as the
system default output from the macOS Sound settings to route audio
through the engine.

## Tests

Host-side tests run without audio hardware. The C++ tests grade the
`GainStore` parser against the golden plists in `contract/lapv/`. The
Swift tests cover payload encode/decode, the routing decision, the
governed ring, and the per-cycle telemetry counter.

```sh
# C++ (driver)
cmake --build driver/build --target GainStoreTests && ./driver/build/GainStoreTests
cmake --build driver/build --target SamplePathTests && ./driver/build/SamplePathTests

# Swift (engine)
cd engine && swift test
```

## CLI

`PassthruGain` lists who's playing through the device, and sets or
clears per-app gains without a UI:

```sh
cd engine
swift run PassthruGain list
swift run PassthruGain set --pid 1234 0.3
swift run PassthruGain set --bundle com.apple.Music 0.6
swift run PassthruGain clear
```

## Layout

```
driver/                 C++ libASPL driver (Passthru.driver)
  src/                  Driver.cpp, GainStore, ClientGain, RingBuffer
  test/                 GainStoreTests, SamplePathTests
  third_party/libaspl/  vendored libASPL v3.1.2 (with a small marked
                        patch to opt into Apple's 'pout' IO stage)
engine/                 Swift package
  Sources/Passthru/         the menu-bar app (PassthruApp, Engine,
                            PerAppMixer, PersistedGains, CAHelpers)
  Sources/GainChannel/     control-plane client (discovery, process
                            enumeration, 'lapv' encode/decode)
  Sources/LatencyCore/     GovernedRing + per-cycle telemetry
  Sources/PassthruGain/    CLI driving 'lapv' without UI
  Sources/AggregateSpike/  lockstep probe
  Sources/EngineOnAggregate/ engine-on-aggregate probe
  Tests/                  XCTest targets
contract/lapv/          'lapv' schema + golden-vector plists
tools/                  measurement scripts
install.sh / uninstall.sh
LICENSE                 MIT
```

## License

MIT, see `LICENSE`. The vendored `libASPL` is MIT as well; see
`driver/third_party/libaspl/LICENSE`.
