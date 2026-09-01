# Output chain routing on disconnect

When the engine's current real output disappears, the engine walks an
ordered, most-recent-first chain of up to five real output UIDs and
promotes the first entry that is currently online, rather than falling
through to an error.

## Considered options

- **Single persisted slot.** Today the engine remembers one UID and, if
  that device is also offline, stops IO and surfaces an error. This
  matches the previous behavior and the existing `PersistedLastOutput`
  storage, but it errors out on a class of disconnects that has a clear
  better answer: any other real output the user has previously played
  to is almost certainly what they want next.
- **Unbounded MRU history.** More headroom, no real upside on a desktop
  with at most a handful of outputs, and the stored blob grows without
  bound. Rejected.
- **Walk the picker list instead of a stored chain.** The picker list
  reflects what is online *now*, not what the user has used before. A
  fresh device the user has never played to would rank equal to one
  they used yesterday. Rejected — recency matters.

## Consequences

- `PersistedLastOutput` becomes `PersistedOutputChain`. Storage key
  changes; first-launch migration reads the legacy single-UID key and
  seeds the chain with it.
- The Passthru UID is rejected at both write and read sites, not just
  by the implicit exclusion from the engine's `realOutputIDs` set.
  This is defense in depth: the routing invariant "Passthru is never
  the engine sink" is now testable independent of which code path
  calls the decider.
- Auto-fallback writes the chain. If the device we fell back to then
  disappears, the chain remembers we already tried it and walks
  further, instead of looping back to the original sink.
- Chain promotion on explicit user picks is "promote if present,
  otherwise prepend" — duplicates are not re-positioned on every
  selection.