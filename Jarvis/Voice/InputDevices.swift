import CoreAudio
import AVFoundation

/// Mikrofon listesi ve seçimi. Ölçüldü: AirPods mikrofonu kullanılınca kulaklık telefon profiline (24 kHz,
/// dar bant) düşüyor, ses kalitesi bozuluyor, motor her profil geçişinde yeniden kuruluyor ve konuşmacı
/// profili farklı mikrofonla tutmuyor. Mac'in dahili mikrofonu bunların hiçbirini yaşatmıyor.
enum InputDevices {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let isBuiltIn: Bool
    }

    /// Girişi olan ses aygıtları.
    static func list() -> [Device] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0 else { return nil }
            return Device(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                          name: string(id, kAudioObjectPropertyName) ?? "Aygıt \(id)",
                          isBuiltIn: transport(id) == kAudioDeviceTransportTypeBuiltIn)
        }
    }

    /// Tercih edilen aygıt: kullanıcının seçtiği, yoksa dahili mikrofon, o da yoksa sistem varsayılanı (nil).
    static func preferred(uid: String?) -> Device? {
        let all = list()
        if let uid, let d = all.first(where: { $0.uid == uid }) { return d }
        return all.first(where: { $0.isBuiltIn })
    }

    /// Sistemin varsayılan mikrofonu. Ölçüldü: motorun giriş birimine aygıt atamak (kAudioOutputUnitProperty_CurrentDevice)
    /// kulaklık çıkışıyla çakışıp -10875 veriyor; sistem varsayılanını değiştirmek ise sorunsuz. Dinle kapanınca
    /// eski aygıt geri yüklenir.
    static func systemDefaultInput() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    @discardableResult
    static func setSystemDefaultInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var v = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &v) == noErr
    }

    static func name(of id: AudioDeviceID) -> String {
        string(id, kAudioObjectPropertyName) ?? "Aygıt \(id)"
    }

    // MARK: - CoreAudio yardımcıları

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
        return v
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}
