# 'lapv' contract: schema and golden vectors

This directory is the single statement of the `'lapv'` property contract
across the Core Audio IPC seam between the Passthru driver (C++,
`GainStore`) and the engine side (Swift, `GainChannel`). The two sides
never link; these checked-in files are the only thing they honestly
share, and both sides' tests consume the exact same bytes.

## The property

- Custom property on the device object, selector `'lapv'`
  (`0x6C617076`, global scope, main element).
- Any process may read or write it with plain Core Audio calls
  (`AudioObjectGetPropertyData` / `AudioObjectSetPropertyData`). The payload
  is a `CFPropertyList`; the host marshals it across processes.

## Payload grammar

A payload is either:

- **null** - meaning: clear the whole table (accept). There is no XML
  representation of CF null, so this case is pinned as a zero-byte fixture
  file (`null-clears-table.plist`); both harnesses treat an empty file as the
  null payload.
- **an array** of entries. An empty array is valid and clears the table.
- Anything else (string, dictionary, number, boolean, data, date) is
  structurally malformed and **rejects the whole update**.

Each entry is a dictionary with:

| Key          | Type                | Required | Notes                                   |
| ------------ | ------------------- | -------- | --------------------------------------- |
| `pid`        | integer             | no       | Non-positive values count as not keyed. |
| `bundle-id`  | string              | no       |                                         |
| `gain`       | number              | yes      | Booleans are NOT numbers here.          |

An entry carrying neither `pid` nor `bundle-id` is well-formed but inert; it
is skipped while the rest of the payload is still accepted.

## Accept/reject semantics

- Structural violations (non-array root, non-dict element, missing gain,
  non-numeric gain, wrong-typed keys) reject the **whole payload**: the prior
  table stays intact and the revision counter does not move.
- An accepted update replaces the whole table.
- Gains are clamped into `[0.0, 4.0]` on accept; NaN becomes unity (1.0).

## Resolution rules (read side)

For a client with process id `p` and bundle id `b`:

1. An entry whose `pid` equals `p` wins outright (exact-pid beats any bundle
   fallback), even if that entry also carries a bundle id.
2. Otherwise the first pure bundle-keyed entry (no pid) matching `b` applies;
   it covers every other process of the same bundle.
3. Pid-keyed entries apply exclusively to their own process.
4. No match means unity (1.0): bit-transparent pass-through.

## Fixtures

| File                                    | Scenario                                        |
| --------------------------------------- | ----------------------------------------------- |
| `null-clears-table.plist`               | zero-byte; null payload clears the table        |
| `empty-table.plist`                     | empty array clears the table                    |
| `single-pid-entry.plist`                | one pid-keyed entry                             |
| `single-bundle-entry.plist`             | one bundle-keyed entry                          |
| `pid-entry-plus-bundle-fallback.plist`  | pid+bundle entry; pure bundle fallback for others |
| `gain-clamp-boundaries.plist`           | gains exactly at 0.0 and 4.0                    |
| `invalid-non-array-root.plist`          | root is a string -> reject                      |
| `invalid-non-dict-element.plist`        | array element is a string -> reject             |
| `invalid-non-numeric-gain.plist`        | gain is a string -> reject                      |
| `invalid-boolean-gain.plist`            | gain is a boolean -> reject                     |

## Harnesses

- C++ driver side: `driver/test/GainStoreTests.cpp` loads these files via the
  `LAPV_FIXTURE_DIR` compile definition set in `driver/CMakeLists.txt`.
- Swift engine side: `engine/Tests/GainChannelTests/LapvContractTests.swift`
  locates them by walking up from `#filePath`.

Interop test = same bytes through both adapters: parsing must yield equal
tables, and each side's serializer must reproduce an equivalent payload
(semantic equality - `CFEqual` / plist object equality - not byte identity).
