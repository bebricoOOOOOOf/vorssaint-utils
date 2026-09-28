// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The ring between a tapped app's IO thread and the AirPlay feed. Frame
/// positions only ever grow, so an all-day stream must stay correct once they
/// pass the 32-bit range (about 12 hours at 48 kHz).
enum AirPlayRingBufferContract {
    static func run(_ suite: TestSuite) {
        roundTrip(suite)
        fullRingDropsNewestFrames(suite)
        positionsPastThirtyTwoBits(suite)
    }

    private static func frames(_ count: Int, from start: Int) -> [Float] {
        (0..<count).flatMap { [Float(start + $0), -Float(start + $0)] }
    }

    private static func roundTrip(_ suite: TestSuite) {
        let ring = AudioRingBuffer(sampleRate: 48_000, capacityFrames: 64)
        let input = frames(10, from: 1)
        input.withUnsafeBufferPointer { ring.write(frames: $0.baseAddress!, frameCount: 10, gain: 0.5) }

        var output = [Float](repeating: 99, count: 16 * 2)
        let read = output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frameCount: 16) }
        suite.expect(read == 10, "a read returns only the frames that were written")
        suite.expect(output[0] == 0.5 && output[1] == -0.5 && output[18] == 5 && output[19] == -5,
                     "written frames come back in order with the gain applied")
        suite.expect(output[20...].allSatisfy { $0 == 0 }, "the rest of a short read is silence")
    }

    private static func fullRingDropsNewestFrames(_ suite: TestSuite) {
        let ring = AudioRingBuffer(sampleRate: 48_000, capacityFrames: 8)
        let input = frames(12, from: 1)
        input.withUnsafeBufferPointer { ring.write(frames: $0.baseAddress!, frameCount: 12, gain: 1) }

        var output = [Float](repeating: 0, count: 12 * 2)
        let read = output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frameCount: 12) }
        suite.expect(read == 8 && output[14] == 8, "a full ring keeps the oldest frames and drops the overflow")
    }

    private static func positionsPastThirtyTwoBits(_ suite: TestSuite) {
        let start = Int64(Int32.max) - 100
        let ring = AudioRingBuffer(sampleRate: 48_000, capacityFrames: 1 << 10, startingFramePosition: start)
        var output = [Float](repeating: 0, count: 256 * 2)
        var delivered = 0
        var inOrder = true
        // Stream across the old wrap point in IO-sized chunks.
        for chunk in 0..<8 {
            let input = frames(256, from: chunk * 256)
            input.withUnsafeBufferPointer { ring.write(frames: $0.baseAddress!, frameCount: 256, gain: 1) }
            let read = output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frameCount: 256) }
            delivered += read
            inOrder = inOrder && output[0] == Float(chunk * 256) && output[510] == Float(chunk * 256 + 255)
        }
        suite.expect(delivered == 8 * 256 && inOrder,
                     "streaming continues without loss once frame positions pass the 32-bit range")
    }
}

/// Only Vorssaint's own AirPlay entry streams through the route picker. Every
/// other output, including AirPlay devices macOS exposes, follows the normal
/// device rules: listed means usable, missing means fall back to the default.
enum AirPlayRouteContract {
    static func run(_ suite: TestSuite) {
        let sentinel = AirPlayRouteManager.airPlaySentinelUID
        // Real AirPlay outputs carry a session UID; third-party virtual drivers
        // may well mention AirPlay in theirs.
        let macOSAirPlay = "50ea6ba0-8555-4fce-b618-b4cb1729da75-326608458962375-Audio"
        let namedLikeAirPlay = "com.example.AirPlayReceiver.output"

        suite.expect(MixerRoutingSupport.isAirPlaySentinel(sentinel)
                     && !MixerRoutingSupport.isAirPlaySentinel(macOSAirPlay)
                     && !MixerRoutingSupport.isAirPlaySentinel(namedLikeAirPlay)
                     && !MixerRoutingSupport.isAirPlaySentinel("AirPlay"),
                     "only the exact AirPlay entry counts as the picker route")

        let listed: Set<String> = ["BuiltInSpeakerDevice", sentinel]
        suite.expect(MixerRoutingSupport.effectiveDeviceUID(selectedUID: sentinel,
                                                            availableUIDs: listed,
                                                            defaultUID: "BuiltInSpeakerDevice") == sentinel
                     && !MixerRoutingSupport.selectedDeviceUnavailable(selectedUID: sentinel,
                                                                       availableUIDs: listed),
                     "a listed AirPlay entry is used as the app's route")

        let unlisted: Set<String> = ["BuiltInSpeakerDevice"]
        suite.expect(MixerRoutingSupport.effectiveDeviceUID(selectedUID: sentinel,
                                                            availableUIDs: unlisted,
                                                            defaultUID: "BuiltInSpeakerDevice") == "BuiltInSpeakerDevice"
                     && MixerRoutingSupport.selectedDeviceUnavailable(selectedUID: sentinel,
                                                                      availableUIDs: unlisted),
                     "without the picker API the AirPlay route falls back and shows as unavailable")

        suite.expect(MixerRoutingSupport.effectiveDeviceUID(selectedUID: namedLikeAirPlay,
                                                            availableUIDs: unlisted,
                                                            defaultUID: "BuiltInSpeakerDevice") == "BuiltInSpeakerDevice"
                     && MixerRoutingSupport.selectedDeviceUnavailable(selectedUID: namedLikeAirPlay,
                                                                      availableUIDs: unlisted),
                     "a missing output that mentions AirPlay falls back like any other device")

        connection(suite, sentinel: sentinel)
    }

    /// Losing the speaker must hand the app back to the default output, not
    /// keep it tapped and silent; picking one again restores the AirPlay route.
    private static func connection(_ suite: TestSuite, sentinel: String) {
        let listedOutputs = ["BuiltInSpeakerDevice", "ArctisNovaPro", sentinel]

        let disconnected = MixerRoutingSupport.routableOutputUIDs(listedOutputs, airPlayConnected: false)
        suite.expect(disconnected == ["BuiltInSpeakerDevice", "ArctisNovaPro"],
                     "without a picked speaker the AirPlay entry carries no audio")
        suite.expect(MixerRoutingSupport.effectiveDeviceUID(selectedUID: sentinel,
                                                            availableUIDs: disconnected,
                                                            defaultUID: "ArctisNovaPro") == "ArctisNovaPro"
                     && MixerRoutingSupport.selectedDeviceUnavailable(selectedUID: sentinel,
                                                                      availableUIDs: disconnected),
                     "an app routed to AirPlay plays on the default output while no speaker is picked")
        suite.expect(!MixerRoutingSupport.requiresEngine(volume: 1,
                                                         selectedOutputDeviceUID: sentinel,
                                                         targetOutputDeviceUID: "ArctisNovaPro",
                                                         defaultOutputDeviceUID: "ArctisNovaPro"),
                     "at 100% that fallback is untapped passthrough, not a muting tap")

        let connected = MixerRoutingSupport.routableOutputUIDs(listedOutputs, airPlayConnected: true)
        suite.expect(MixerRoutingSupport.effectiveDeviceUID(selectedUID: sentinel,
                                                            availableUIDs: connected,
                                                            defaultUID: "ArctisNovaPro") == sentinel,
                     "picking a speaker again restores the AirPlay route")
        suite.expect(MixerRoutingSupport.effectiveDeviceUID(selectedUID: "BuiltInSpeakerDevice",
                                                            availableUIDs: disconnected,
                                                            defaultUID: "ArctisNovaPro") == "BuiltInSpeakerDevice",
                     "other routes are untouched by the AirPlay connection")
    }
}

/// Boosted apps, or several loud apps together, must not be hard-clipped on
/// their way to the speaker (the AirPlay twin of issue #326).
enum AirPlayMixLimiterContract {
    static func run(_ suite: TestSuite) {
        let mixer = MixingAudioSource()
        let frames = 4096
        let loud = [Float](repeating: 0.9, count: frames * 2)
        for key in ["a", "b"] {
            let ring = AudioRingBuffer(sampleRate: 44_100, capacityFrames: frames)
            loud.withUnsafeBufferPointer { ring.write(frames: $0.baseAddress!, frameCount: frames, gain: 1) }
            mixer.setBuffer(ring, forKey: key)
        }

        var output = [Int16](repeating: 0, count: frames * 2)
        output.withUnsafeMutableBufferPointer { mixer.readFrames(into: $0.baseAddress!, frameCount: frames) }
        let ceiling = Int16(BoostLimiter.ceiling * 32_767)
        let settled = output[(frames - 64) * 2..<frames * 2]
        suite.expect(settled.allSatisfy { abs(Int($0) - Int(ceiling)) <= 2 },
                     "a mix past full scale is limited to the ceiling instead of clipped")

        let quiet = MixingAudioSource()
        let ring = AudioRingBuffer(sampleRate: 44_100, capacityFrames: frames)
        [Float](repeating: 0.25, count: frames * 2)
            .withUnsafeBufferPointer { ring.write(frames: $0.baseAddress!, frameCount: frames, gain: 1) }
        quiet.setBuffer(ring, forKey: "a")
        output.withUnsafeMutableBufferPointer { quiet.readFrames(into: $0.baseAddress!, frameCount: frames) }
        suite.expect(output[(frames - 1) * 2] == Int16(0.25 * 32_767),
                     "a mix inside full scale passes through at its level")
    }
}

/// An app is heard once in the AirPlay mix, through its newest live engine.
/// A replacement registers before its predecessor stops, so the mix must not
/// carry both, and ending one engine must never remove another one's stream.
enum AirPlayStreamRegistryContract {
    static func run(_ suite: TestSuite) {
        let mixer = MixingAudioSource()
        let registry = AirPlayStreamRegistry(mixer: mixer)
        var emptied: [Bool] = []
        func register(_ appID: String, _ level: Float) -> AirPlayStreamRegistration {
            let ring = AudioRingBuffer(sampleRate: 44_100, capacityFrames: 1 << 15)
            [Float](repeating: level, count: 32_768 * 2)
                .withUnsafeBufferPointer { ring.write(frames: $0.baseAddress!, frameCount: 32_768, gain: 1) }
            return registry.register(appID: appID, buffer: ring) { token in emptied.append(registry.remove(token)) }
        }
        func heard(_ level: Float) -> Bool {
            var output = [Int16](repeating: 0, count: 2_048 * 2)
            output.withUnsafeMutableBufferPointer { mixer.readFrames(into: $0.baseAddress!, frameCount: 2_048) }
            return abs(Int(output[2_047 * 2]) - Int(Int16(level * 32_767))) <= 2
        }

        let previous = register("spotify", 0.1)
        let replacement = register("spotify", 0.2)
        suite.expect(heard(0.2),
                     "while the previous engine still runs, the mix carries the app once, from the replacement")

        previous.end()
        suite.expect(emptied == [false] && heard(0.2),
                     "stopping the previous engine keeps the replacement's stream playing")
        previous.end()
        suite.expect(emptied == [false] && heard(0.2), "a second stop (from deinit) changes nothing")

        let discarded = register("spotify", 0.3)
        discarded.end()
        suite.expect(emptied == [false, false] && heard(0.2),
                     "a discarded build hands the app back to the engine that is still running")

        let other = register("music", 0.05)
        suite.expect(heard(0.25), "different apps are mixed together")

        replacement.end()
        suite.expect(emptied == [false, false, false] && heard(0.05), "ending one app leaves the others")
        other.end()
        suite.expect(emptied == [false, false, false, true], "only the last live stream reports the mix as empty")
    }
}

/// Stopping a renderer's feed waits for a running step, and no step starts
/// afterwards, so a replacement renderer never shares the mix with it.
enum AirPlayFeedDriverContract {
    static func run(_ suite: TestSuite) {
        let queue = DispatchQueue(label: "test.airplay.feed")
        let driver = AirPlayFeedDriver(queue: queue, interval: .milliseconds(5))
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var steps = 0
        var blockNext = true

        driver.start {
            lock.lock()
            steps += 1
            let block = blockNext
            blockNext = false
            lock.unlock()
            if block {
                entered.signal()
                release.wait()
            }
        }
        suite.expect(entered.wait(timeout: .now() + 2) == .success, "the feed step runs")

        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            driver.stop()
            stopped.signal()
        }
        suite.expect(stopped.wait(timeout: .now() + 0.2) == .timedOut,
                     "stop waits while a feed step is still running")
        release.signal()
        suite.expect(stopped.wait(timeout: .now() + 2) == .success, "stop returns once the step finished")

        lock.lock(); let atStop = steps; lock.unlock()
        Thread.sleep(forTimeInterval: 0.05)
        lock.lock(); let later = steps; lock.unlock()
        suite.expect(later == atStop, "no feed step runs after stop returned")

        let selfStopping = AirPlayFeedDriver(queue: queue, interval: .milliseconds(5))
        let finished = DispatchSemaphore(value: 0)
        selfStopping.start {
            selfStopping.stop()
            finished.signal()
        }
        suite.expect(finished.wait(timeout: .now() + 2) == .success, "a step may stop its own driver without deadlocking")
    }
}
