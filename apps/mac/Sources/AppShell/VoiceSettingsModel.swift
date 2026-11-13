import Combine
import Foundation

@MainActor
final class VoiceSettingsModel: ObservableObject {
    @Published var devices: [VoiceInputDevice] = []
    @Published var inputID = ""
    @Published var modelTitle = "Parakeet"
    @Published var modelState = "Checking"
    @Published var modelDetail = "Checking the offline dictation model."
    @Published var inputNote: String?
    @Published var busy = false

    func refresh() {
        devices = LatticesVoiceRuntime.inputDevices()
        let saved = LatticesVoiceRuntime.preferredInputDeviceID()
        inputID = saved
        inputNote = nil
        Task { await reloadStatus() }
    }

    func selectInput(_ id: String) {
        inputID = id
        do {
            try LatticesVoiceRuntime.setPreferredInputDeviceID(id)
            inputNote = id.isEmpty ? "Dictation uses the system microphone." : "Dictation uses this microphone."
        } catch {
            inputNote = error.localizedDescription
        }
    }

    func reloadStatus() async {
        let status = await LatticesVoiceRuntime.dictationStatus()
        apply(status)
    }

    func loadModel() async {
        guard !busy else { return }
        busy = true
        modelState = "Loading"
        modelDetail = "Loading \(modelTitle) on this Mac."
        let status = await LatticesVoiceRuntime.prepareDictationModel()
        apply(status)
        busy = false
    }

    func restart() async {
        guard !busy else { return }
        busy = true
        modelState = "Restarting"
        modelDetail = "Restarting the voice runtime."
        LatticesVoiceRuntime.resetEmbeddedRuntime()
        devices = LatticesVoiceRuntime.inputDevices()
        let status = await LatticesVoiceRuntime.dictationStatus()
        apply(status)
        busy = false
    }

    private func apply(_ status: VoiceDictationStatus) {
        modelTitle = status.title
        modelState = status.state
        modelDetail = status.detail
    }
}
