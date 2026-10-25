// Pick which microphone it listens to and which speaker it talks through (Settings → Microphone / Speaker).
// Devices are stored by Core Audio UID, so they survive reboots and re-plugging. Empty = system default.
import AppKit
import AudioToolbox
import CoreAudio

struct AudioDevice: Hashable { let id: AudioDeviceID; let uid: String; let name: String; let input: Bool; let output: Bool }

enum AudioDevices {
    private static func prop<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ def: T) -> T {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var v = def; var size = UInt32(MemoryLayout<T>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
        return v
    }
    private static func hasStreams(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
        return size > 0
    }
    static func all() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return ids.compactMap { id in
            let uid = prop(id, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, "" as CFString) as String
            let name = prop(id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, "" as CFString) as String
            guard !uid.isEmpty else { return nil }
            return AudioDevice(id: id, uid: uid, name: name, input: hasStreams(id, kAudioDevicePropertyScopeInput), output: hasStreams(id, kAudioDevicePropertyScopeOutput))
        }
    }
    static func defaultInputUID() -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return all().first { $0.id == id }?.uid ?? ""
    }
    static func defaultOutputName() -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return all().first { $0.id == id }?.name ?? ""
    }
    /// Is some app playing sound on this speaker right now? (empty uid = system default output)
    /// nil when we can't tell — the speaker is part of the device we listen on (USB headset), so it's always running.
    static func outputBusy(_ uid: String, micUID: String) -> Bool? {
        var id = device(uid: uid)?.id ?? 0
        if id == 0 {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        }
        let mic = device(uid: micUID)?.id ?? {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var m = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &m)
            return m
        }()
        if mic == id { return nil }
        return prop(id, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, UInt32(0)) != 0
    }
    /// Bundle IDs of apps recording from a microphone right now (macOS 14.2+ Core Audio process list).
    static func micUsers() -> [String] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        return ids.compactMap { id in
            guard prop(id, kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal, UInt32(0)) != 0 else { return nil }
            let b = prop(id, kAudioProcessPropertyBundleID, kAudioObjectPropertyScopeGlobal, "" as CFString) as String
            return b.isEmpty ? nil : b
        }
    }
    static func inputs() -> [AudioDevice] { all().filter(\.input) }
    static func outputs() -> [AudioDevice] { all().filter(\.output) }
    static func device(uid: String) -> AudioDevice? { uid.isEmpty ? nil : all().first { $0.uid == uid } }

    /// Points an AVAudioEngine input/output node's audio unit at a specific device.
    @discardableResult
    static func use(_ uid: String, on unit: AudioUnit?) -> Bool {
        guard let unit, let d = device(uid: uid) else { return false }
        var id = d.id
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }
}

/// Chimes, greeting and boot sound through the chosen speaker.
enum Sound {
    static var outputUID = ""
    static var keep: [NSSound] = []
    static func play(_ s: NSSound?) {
        guard let s else { return }
        if !outputUID.isEmpty { s.playbackDeviceIdentifier = outputUID }
        keep.append(s); if keep.count > 8 { keep.removeFirst() }
        s.play()
    }
    static func named(_ n: String) { play(NSSound(named: NSSound.Name(n))?.copy() as? NSSound) }
    static func soft(_ n: String) { let s = NSSound(named: NSSound.Name(n))?.copy() as? NSSound; s?.volume = 0.35; play(s) }
    static func file(_ u: URL) { play(NSSound(contentsOf: u, byReference: true)) }
}
