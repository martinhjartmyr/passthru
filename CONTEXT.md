# Context

Glossary for Passthru. Definitions only - no implementation.

## Glossary

- **DAC**: An external USB or Thunderbolt amplifier/DAC. If it reports no
  hardware volume control to macOS, the system hides its volume keys.
- **Hardware volume control**: A volume feature a USB audio device itself
  reports to macOS. Present: system keys adjust the device. Absent:
  macOS locks the volume for that output.
- **Passthru**: The virtual HAL device this project ships. Apps write
  into it; the engine reads back what macOS already attenuated and
  renders to a real output.
- **Passthru Engine**: The userspace component (menu-bar app) that pulls
  audio from the Passthru device and renders it to a physical output
  via a private Core Audio aggregate.
- **Device volume control**: The volume and mute control the Passthru
  device publishes to macOS. System keys, the Control Center slider, the
  mute key, and the HUD write it; the loudness change lands on the
  stream before the engine reads it.
- **Engine gain**: The per-engine loudness factor the menu bar applies
  in the IOProc, on top of the device volume control. At 100 percent the
  engine is bit-transparent.
- **App gain**: The per-application loudness factor the menu bar writes
  to the driver's `'lapv'` custom property. Pid-keyed entries apply
  exclusively to their own process; bundle-keyed entries apply to every
  process of that bundle.
- **Aggregate**: A private Core Audio composite device the engine
  builds, with the physical DAC as master clock and Passthru as member.
  Capture (Passthru) and render (DAC) share one clock domain on the
  aggregate, so a single IOProc is a same-cycle handoff.
- **Bit-transparent pass-through**: Unity gain on every control. The
  pipeline applies no multiply and no resample.
