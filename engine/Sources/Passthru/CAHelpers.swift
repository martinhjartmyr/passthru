// Small Core Audio conveniences: property listeners and the session log
// that doubles as the observation record. The pure Core Audio getter
// surface (device discovery, scalar properties, AudioBufferList access)
// lives in GainChannel.CA; the engine-side control-plane client
// (discovery, process facts, 'lapv' gain channel) also lives there.

import Foundation
import CoreAudio

enum CA {
    // MARK: Listeners (app-only; the probes don't use them)

    static func addListener(_ objectID: AudioObjectID,
                            _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                            queue: DispatchQueue?,
                            block: @escaping AudioObjectPropertyListenerBlock) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectAddPropertyListenerBlock(objectID, &addr, queue, block) == noErr
    }

    static func removeListener(_ objectID: AudioObjectID,
                               _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               block: @escaping AudioObjectPropertyListenerBlock) {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(objectID, &addr, nil, block)
    }
}

// MARK: Log

final class Log {
    static let shared = Log()
    private let queue = DispatchQueue(label: "passthru.log")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private var fileHandle: FileHandle?

    func open(file: URL) {
        queue.sync {
            FileManager.default.createFile(atPath: file.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: file)
            _ = try? fileHandle?.seekToEnd()
            write("=== passthru session start ===")
        }
    }

    func line(_ text: String) {
        queue.sync {
            write(text)
        }
    }

    /// Caller must already be on `queue`.
    private func write(_ text: String) {
        let entry = "\(formatter.string(from: Date()))  \(text)\n"
        if let data = entry.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
            try? fileHandle?.write(contentsOf: data)
        }
    }
}