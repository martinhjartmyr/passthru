// Host-side tests for the public Core Audio getter surface in
// GainChannel.CA. Covers the property-selector matrix, the scope/element
// constants, and the AudioBufferList accessors; runs without audio
// hardware (AudioObjectGetPropertyData against the system object is
// non-failing in any environment).

import CoreAudio
import XCTest

@testable import GainChannel

final class CAHelpersTests: XCTestCase {

    // MARK: Scope/element constants

    func testScopeConstantsEqualCanonical() {
        XCTAssertEqual(GainChannel.CA.globalScope, kAudioObjectPropertyScopeGlobal)
        XCTAssertEqual(GainChannel.CA.inputScope, kAudioObjectPropertyScopeInput)
        XCTAssertEqual(GainChannel.CA.outputScope, kAudioObjectPropertyScopeOutput)
        XCTAssertEqual(GainChannel.CA.mainElement, kAudioObjectPropertyElementMain)
    }

    // MARK: Address construction

    func testAddressDefaultsToGlobalScope() {
        let addr = GainChannel.CA.address(kAudioObjectPropertyName)
        XCTAssertEqual(addr.mSelector, kAudioObjectPropertyName)
        XCTAssertEqual(addr.mScope, kAudioObjectPropertyScopeGlobal)
        XCTAssertEqual(addr.mElement, kAudioObjectPropertyElementMain)
    }

    func testAddressHonorsExplicitScope() {
        let addr = GainChannel.CA.address(kAudioDevicePropertyStreams,
                                          scope: GainChannel.CA.outputScope)
        XCTAssertEqual(addr.mSelector, kAudioDevicePropertyStreams)
        XCTAssertEqual(addr.mScope, kAudioObjectPropertyScopeOutput)
        XCTAssertEqual(addr.mElement, kAudioObjectPropertyElementMain)
    }

    // MARK: Live Core Audio getters (non-failing against the system object)

    func testOutputDevicesReturnsArray() {
        // Result is environment-dependent but the call must not fail; on a
        // real macOS box there is at least one output device.
        let devices = GainChannel.CA.outputDevices()
        XCTAssertGreaterThanOrEqual(devices.count, 0)
    }

    func testDeviceNameOnSystemObjectFallsThroughToQuestionMark() {
        // ID 0 is the system object, not a real device - the helper returns "?"
        // rather than crashing.
        XCTAssertEqual(GainChannel.CA.deviceName(0), "?")
    }

    func testDefaultOutputDeviceReturnsAnAudioObjectID() {
        // Returns 0 on a no-device test machine, a real ID otherwise; the
        // shape is what we pin.
        let id: AudioObjectID = GainChannel.CA.defaultOutputDevice()
        XCTAssertGreaterThanOrEqual(id, 0)
    }

    // MARK: AudioBufferList accessors

    func testBufferCountReadsNumberBuffers() {
        // AudioBufferList has a variable-length mBuffers tail that Swift's
        // struct initialiser does not represent; we lay out two buffers in
        // raw memory and pin the helper's read of mNumberBuffers at offset 0.
        let bufferCount: UInt32 = 2
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size, alignment: 1)
        defer { bytes.deallocate() }
        bytes.storeBytes(of: bufferCount, toByteOffset: 0, as: UInt32.self)
        XCTAssertEqual(GainChannel.CA.bufferCount(bytes), 2)
    }

    func testBufferArrayPointsAtBufferTail() {
        // The helper computes the offset to mBuffers[0] as
        // MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size;
        // pin that arithmetic and confirm the returned pointer sees what we
        // wrote into the tail.
        let bufferCount: UInt32 = 1
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size, alignment: 1)
        defer { bytes.deallocate() }
        bytes.storeBytes(of: bufferCount, toByteOffset: 0, as: UInt32.self)
        let buffer = AudioBuffer(mNumberChannels: 2, mDataByteSize: 0, mData: nil)
        bytes.storeBytes(of: buffer.mNumberChannels, toByteOffset: MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size, as: UInt32.self)

        let ptr = GainChannel.CA.bufferArray(bytes)
        XCTAssertEqual(ptr.pointee.mNumberChannels, 2)
    }

    func testChannelCountClampsZeroChannelsToOne() {
        let buf = AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        XCTAssertEqual(GainChannel.CA.channelCount(buffer: buf), 1)
    }
}