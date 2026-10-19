// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Adapted for Boring Notch Pedro Edition; original attribution retained.

import AppKit
import AudioToolbox
import CoreAudio
import Darwin

protocol GainEngine: AnyObject {
    var gain: Float { get set }
    var tappedObjects: [AudioObjectID] { get }
    var outputDeviceUID: String { get }
    /// The hardware output that clocks an engine streaming elsewhere (AirPlay),
    /// nil for an engine that plays on `outputDeviceUID` itself.
    var clockDeviceUID: String? { get }
    /// How many IO callbacks the engine has completed. A count that stops
    /// moving while the tapped app is playing means the aggregate is no
    /// longer rendering, so the tap can only mute (issue #341).
    var renderCycles: UInt64 { get }
    func stop()
}

/// The audio path for one routed app: a muted process tap feeding an aggregate
/// device whose IO proc re-renders the samples scaled by `gain` onto the chosen
/// output device.
@available(macOS 14.4, *)
final class TapGainEngine: GainEngine {
    let tappedObjects: [AudioObjectID]
    let outputDeviceUID: String
    var clockDeviceUID: String? { nil }
    var gain: Float {
        get { gainBox.value }
        set { gainBox.value = min(max(newValue, 0), Float(PedroAudioMixer.maxVolume)) }
    }

    private final class AtomicFloatBox {
        private var bits: Int32

        init(_ value: Float) {
            bits = Int32(bitPattern: value.bitPattern)
        }

        var value: Float {
            get {
                Float(bitPattern: UInt32(bitPattern: OSAtomicAdd32Barrier(0, &bits)))
            }
            set {
                let replacement = Int32(bitPattern: newValue.bitPattern)
                while true {
                    let current = OSAtomicAdd32Barrier(0, &bits)
                    if OSAtomicCompareAndSwap32Barrier(current, replacement, &bits) { return }
                }
            }
        }
    }

    private final class AtomicCycleBox {
        private var bits: Int64 = 0
        var value: UInt64 { UInt64(bitPattern: OSAtomicAdd64Barrier(0, &bits)) }
        func increment() { _ = OSAtomicIncrement64Barrier(&bits) }
    }

    /// One limiter per output buffer, preallocated so the realtime thread
    /// never allocates. Touched only by the IO proc once rendering starts.
    private final class LimiterBox {
        let lookahead: BoostLookaheadBufferListLimiter
        var fallback = BoostBufferListLimiter()
        init(channelCapacity: Int) {
            lookahead = BoostLookaheadBufferListLimiter(channelCapacity: channelCapacity)
        }
    }

    /// How fast the limiter recovers, kept beside the limiters rather than
    /// inside them: the device can change its rate while this engine keeps
    /// rendering, and the audio thread must never find another thread halfway
    /// through writing its state. Same one-float exchange as the gain.
    private typealias ReleaseBox = AtomicFloatBox

    private let gainBox = AtomicFloatBox(1)
    private let cycleBox = AtomicCycleBox()
    private let releaseBox = ReleaseBox(BoostLimiter.release(sampleRate: 48000))
    var renderCycles: UInt64 { cycleBox.value }
    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?
    /// The retained `ReleaseBox` handed to the rate listener, released when
    /// the listener goes away.
    private var rateListenerClient: UnsafeMutableRawPointer?

    init?(objects: [AudioObjectID], gain: Float, outputDeviceUID: String) {
        tappedObjects = objects
        gainBox.value = min(max(gain, 0), Float(PedroAudioMixer.maxVolume))
        self.outputDeviceUID = outputDeviceUID

        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != 0 else {
            return nil
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Pedro Notch Mixer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr,
              aggregateID != 0 else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let box = gainBox
        // A boost pushes loud samples past full scale, and clamping the
        // overshoot flattens every peak into audible crackle (issue #326).
        // The limiter turns the whole signal down for just the moment a peak
        // would not fit, so a boosted app gets louder without distorting.
        let limiterBox = LimiterBox(
            channelCapacity: Self.outputChannelCapacity(of: aggregateID))
        releaseBox.value = BoostLimiter.release(sampleRate: Self.nominalSampleRate(of: aggregateID))
        let release = releaseBox
        let cycles = cycleBox
        let tapChannels = Self.tapChannels(of: tapID)
        guard AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil, { _, input, _, output, _ in
            let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
            guard let tapIndex = MixerRender.tapBufferIndex(in: inputBuffers,
                                                            tapChannels: tapChannels) else {
                // No samples to put in the buffer is not a reason to leave it:
                // whatever the HAL left there plays otherwise (issue #326).
                MixerRender.silence(outputBuffers)
                return
            }
            let gain = box.value
            // `render` silences whatever it does not fill, so every path from
            // here on leaves the output written.
            let frames = MixerRender.render(source: inputBuffers[tapIndex],
                                            into: outputBuffers,
                                            gain: gain)
            // Keep the tiny delay filled for every live engine. Crossing from
            // attenuation into boost then changes level without inserting a
            // fresh block of silence into audio that is already playing.
            guard frames > 0 else { return }
            cycles.increment()
            let releaseCoefficient = release.value
            if !limiterBox.lookahead.process(outputBuffers, frames: frames,
                                             release: releaseCoefficient) {
                limiterBox.fallback.process(outputBuffers, frames: frames,
                                            release: releaseCoefficient)
            }
        }) == noErr else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        // Installed only once there is something to keep current, so the
        // failure paths above have nothing to undo.
        startWatchingSampleRate()

        guard AudioDeviceStart(aggregateID, ioProc) == noErr else {
            stop()
            return nil
        }
    }

    /// Keeps the limiter's recovery honest when the output device changes its
    /// rate under a running engine.
    ///
    /// A headset that takes the microphone for a call renegotiates to a
    /// call rate, and the aggregate follows it without the IO proc ever
    /// stopping (measured: the render kept going straight through a
    /// 48k to 44.1k change and back). Nothing else would notice, so a boosted
    /// app would keep recovering at the old rate's speed for as long as the
    /// engine lives.
    private func startWatchingSampleRate() {
        var address = Self.nominalSampleRateAddress()
        let client = Unmanaged.passRetained(releaseBox).toOpaque()
        guard AudioObjectAddPropertyListener(aggregateID, &address,
                                             Self.sampleRateListener, client) == noErr else {
            Unmanaged<ReleaseBox>.fromOpaque(client).release()
            return
        }
        rateListenerClient = client
    }

    /// Where the new rate is read, away from whatever thread the answer
    /// arrived on. Serial, so two changes in a row cannot land out of order.
    fileprivate static let rateQueue = DispatchQueue(label: "theboringteam.boringnotch.pedro.mixer.rate",
                                                 qos: .userInitiated)
    /// How many teardowns may sit in the HAL at once. Operations past the
    /// bound wait in the queue holding no thread, so however often a wedged
    /// HAL parks a destroy, the shared pool loses at most this many workers
    /// (issue #971).
    private static let maximumConcurrentTeardowns = 4
    /// A broken HAL path can park inside teardown — `AudioHardwareDestroyProcessTap`
    /// on a wedged tap is the one that does it. Serialized, that one call left
    /// every later engine's aggregate and tap alive behind it, for as long as
    /// the app ran. Overlapping them lets the rest through, under the bound
    /// above so the parked ones cannot take the thread pool with them.
    fileprivate static let teardownQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "theboringteam.boringnotch.pedro.mixer.teardown"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = maximumConcurrentTeardowns
        return queue
    }()

    /// The smallest possible answer, for the same reason as the mixer's own
    /// callback above: the system decides which thread this arrives on and it
    /// is not always the same one. Reading the audio system here would park
    /// whatever thread that is behind the very device being reconfigured,
    /// which is the change that sent this notification in the first place.
    private static let sampleRateListener: AudioObjectPropertyListenerProc = { deviceID, _, _, client in
        guard let client else { return noErr }
        // Held for the hop, so the engine can stop and hand back its
        // registration without the read landing in memory that is gone.
        let box = Unmanaged<ReleaseBox>.fromOpaque(client).takeUnretainedValue()
        rateQueue.async {
            box.value = BoostLimiter.release(sampleRate: nominalSampleRate(of: deviceID))
        }
        return noErr
    }

    fileprivate static func nominalSampleRateAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// How many channels the tap hands over, used to find it among the
    /// aggregate's input buffers. A stereo mixdown is what the tap is asked
    /// for, so that is also the fallback.
    private static func tapChannels(of tapID: AudioObjectID) -> Int {
        var format = AudioStreamBasicDescription()
        guard PedroAudioMixer.read(tapID, kAudioTapPropertyFormat, &format),
              format.mChannelsPerFrame > 0 else { return 2 }
        return Int(format.mChannelsPerFrame)
    }

    private static func outputChannelCapacity(of deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 2 }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, storage) == noErr else {
            return 2
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self))
        return max(2, buffers.reduce(0) { $0 + Int($1.mNumberChannels) })
    }

    /// The rate the aggregate renders at, for the limiter's release timing.
    /// A failed read falls back to the common device rate; being off by a
    /// device's worth of rate only shifts the release by milliseconds.
    private static func nominalSampleRate(of deviceID: AudioObjectID) -> Double {
        var sampleRate: Float64 = 0
        guard PedroAudioMixer.read(deviceID, kAudioDevicePropertyNominalSampleRate, &sampleRate),
              sampleRate > 0 else { return 48000 }
        return sampleRate
    }

    func stop() {
        let tapID = self.tapID
        let aggregateID = self.aggregateID
        let ioProc = self.ioProc
        let listenerClient = rateListenerClient
        guard tapID != 0 || aggregateID != 0 || ioProc != nil || listenerClient != nil else {
            return
        }

        self.tapID = 0
        self.aggregateID = 0
        self.ioProc = nil
        rateListenerClient = nil

        // `mutedWhenTapped` only suppresses the original output while the tap
        // is being read. Stop that read before returning so audio is handed
        // back immediately; the cleanup calls after it may wait on a broken
        // HAL path and therefore run away from the main thread.
        if let ioProc, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProc)
        }

        Self.teardownQueue.addOperation {
            if let listenerClient {
                var mayReleaseListener = aggregateID == 0
                if aggregateID != 0 {
                    var address = Self.nominalSampleRateAddress()
                    mayReleaseListener = AudioObjectRemovePropertyListener(
                        aggregateID, &address, Self.sampleRateListener, listenerClient) == noErr
                }
                // If HAL refuses removal, retain the tiny callback box. A late
                // callback is safer than dereferencing a released pointer.
                if mayReleaseListener {
                    Unmanaged<ReleaseBox>.fromOpaque(listenerClient).release()
                }
            }
            if let ioProc, aggregateID != 0 {
                AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            }
            if aggregateID != 0 {
                AudioHardwareDestroyAggregateDevice(aggregateID)
            }
            if tapID != 0 {
                AudioHardwareDestroyProcessTap(tapID)
            }
        }
    }

    deinit { stop() }
}
