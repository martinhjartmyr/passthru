## Summary

One or two sentences: what does this change, and why.

## Linked issues

`Closes #NNN` or `Refs #NNN` if applicable.

## Scope

- [ ] Driver (`driver/`)
- [ ] Engine (`engine/`)
- [ ] Contract (`contract/`)
- [ ] Tooling (`tools/`, install/uninstall scripts)
- [ ] Documentation (`README.md`, `CONTEXT.md`, `SECURITY.md`)

## Test plan

What you ran, what you observed.

- [ ] `cmake --build driver/build` succeeds
- [ ] `GainStoreTests` passes
- [ ] `SamplePathTests` passes
- [ ] `swift test` (engine) passes
- [ ] Manual install + routing + native-keys check (if behaviour changed)

## Breaking changes

If this changes the wire contract (`'lapv'` schema, custom property
selector, bundle ID, or device UID), call it out explicitly. The
contract test (`LapvContractTests` + `GainStoreTests`) will catch
regressions on the schema; changing the bundle ID is a hard break for
already-installed systems.

## Checklist

- [ ] No new comments added without a reason
- [ ] `git status` is clean of stray build artifacts
- [ ] If vendored `libaspl` was refreshed, the marked `'pout'` patch in
      `third_party/libaspl/src/Device.cpp` is still present
