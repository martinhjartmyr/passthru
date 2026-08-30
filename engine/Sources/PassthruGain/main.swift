// CLI driving the driver's per-app gain property ('lapv') on the Passthru
// device without any UI. Also the quickest way to inspect process
// enumeration.
//
// All Core Audio plumbing lives in the GainChannel library; this executable
// is a thin reporter and writer on top of it.
//
// Usage:
//   swift run PassthruGain list
//   swift run PassthruGain set --pid 1234 0.3
//   swift run PassthruGain set --bundle com.apple.Music 0.6
//   swift run PassthruGain clear

import Foundation
import CoreAudio
import GainChannel

func printState(device: AudioObjectID) {
    let fourCC = String(format: "%c%c%c%c",
        UInt32((GainChannel.selector >> 24) & 0xFF), UInt32((GainChannel.selector >> 16) & 0xFF),
        UInt32((GainChannel.selector >> 8) & 0xFF), UInt32(GainChannel.selector & 0xFF))
    print("Passthru device #\(device)")
    print("gain table ('\(fourCC)'): ")
    let gains = GainChannel.gains(on: device) ?? []
    if gains.isEmpty {
        print("  (empty - everything at unity)")
    }
    for entry in gains {
        let target = entry["pid"].map { "pid \($0)" } ?? entry["bundle-id"].map { "\($0)" } ?? "?"
        let gain = entry["gain"] ?? "?"
        print("  \(target): gain \(gain)")
    }

    print("processes:")
    for p in GainChannel.processes()
        where p.outputDevices.contains(device) || p.isRunningOutput {
        let marker = p.outputDevices.contains(device) ? "->" : "  "
        let running = p.isRunningOutput ? "running-output" : "connected"
        print("  \(marker) #\(p.objectID) pid=\(p.pid) bundle='\(p.bundleID)' \(running)")
    }
}

func usage() -> Never {
    print("""
    usage:
      swift run PassthruGain list
      swift run PassthruGain set --pid <pid> <gain>
      swift run PassthruGain set --bundle <bundle-id> <gain>
      swift run PassthruGain clear
    gain range: \(GainChannel.minGain) ... \(GainChannel.maxGain) (1.0 = unity pass-through)
    """)
    exit(2)
}

guard CommandLine.arguments.count >= 2 else { usage() }
let command = CommandLine.arguments[1]

guard let device = GainChannel.findVirtualDevice() else {
    FileHandle.standardError.write("ERROR: Passthru not found; install driver first.\n".data(using: .utf8)!)
    exit(1)
}

switch command {
case "list":
    printState(device: device)

case "set":
    // set --pid <pid> <gain>   OR   set --bundle <bundle-id> <gain>
    guard CommandLine.arguments.count == 5,
          ["--pid", "--bundle"].contains(CommandLine.arguments[2]),
          let gain = Double(CommandLine.arguments[4]),
          (GainChannel.minGain...GainChannel.maxGain).contains(gain) else { usage() }

    var entries = GainChannel.gains(on: device) ?? []
    switch CommandLine.arguments[2] {
    case "--pid":
        guard let pid = Int32(CommandLine.arguments[3]), pid > 0 else {
            FileHandle.standardError.write("bad pid\n".data(using: .utf8)!)
            exit(2)
        }
        entries.removeAll { ($0["pid"] as? Int) == Int(pid) }
        entries += GainChannel.encode([GainChannel.Entry(pid: pid, gain: gain)])
    case "--bundle":
        let bundleID = CommandLine.arguments[3]
        entries.removeAll { ($0["bundle-id"] as? String) == bundleID }
        entries += GainChannel.encode([GainChannel.Entry(bundleID: bundleID, gain: gain)])
    default:
        usage()
    }

    let status = GainChannel.setGains(on: device, entries)
    if status == noErr {
        print("OK: gain table now has \(entries.count) entr\(entries.count == 1 ? "y" : "ies")")
        for entry in entries {
            let target = entry["pid"].map { "pid \($0)" } ?? entry["bundle-id"].map { "\($0)" } ?? "?"
            print("  \(target): gain \(entry["gain"] ?? "?")")
        }
    } else {
        FileHandle.standardError.write("ERROR: set failed with status \(status)\n".data(using: .utf8)!)
        exit(1)
    }

case "clear":
    let status = GainChannel.setGains(on: device, [])
    print(status == noErr ? "OK: gain table cleared" : "ERROR: clear failed with status \(status)")
    exit(status == noErr ? 0 : 1)

default:
    usage()
}
