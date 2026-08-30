---
name: Bug report
about: Report something broken or unexpected
title: "[bug] "
labels: bug
assignees: ""
---

## What happened

A short description of the bug.

## What you expected

What you expected to happen instead.

## Reproduction

Steps to reproduce, ideally minimal.

## Environment

- macOS version (Apple menu -> About This Mac)
- Mac model (Apple menu -> About This Mac -> More Info)
- DAC (model and how it connects: USB / Thunderbolt / hub)
- Passthru version / commit
- Output of `cmusbdump` (driver counters):
  ```
  log stream --predicate 'subsystem == "dev.passthru.driver"'
  ```

## Logs

If the engine is in the loop, attach the relevant slice of
`engine/run.log`. If the driver is misbehaving, attach the Console
slice around the failure.

## Severity

Does the issue block installation, break audio, or just feel off? Has
anything regressed since a previous build?
