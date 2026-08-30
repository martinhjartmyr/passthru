# Security

Passthru installs a Core Audio HAL plug-in into
`/Library/Audio/Plug-Ins/HAL/`, which requires `sudo`. The bundled
driver is signed ad-hoc (`codesign --force --deep -s -`) at install
time. Ad-hoc signing satisfies coreaudiod's loadability check on the
typical macOS host but offers no identity guarantee. Replace with a
Developer ID signature before distribution.

The driver runs in coreaudiod's audio plugin host context and reads
public Core Audio properties only. It does not read files, network, or
hardware outside the audio subsystem.

The engine runs in the user's session. It writes one UserDefaults
domain (`persisted-app-gains.v1`, `persisted-last-output.v1.*`) and
creates one private Core Audio aggregate per session. It does not
expose a network listener.

## Reporting a vulnerability

Email the maintainers (see the repository's GitHub profile). Please
include:

- macOS version and hardware model
- a minimal reproduction
- whether the issue is local, requires the install path, or requires
  the engine to be running

For encryption-sensitive reports, request the maintainer's PGP key in
the initial email.
