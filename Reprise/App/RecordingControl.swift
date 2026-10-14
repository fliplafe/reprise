import AppIntents
import notify
#if !CONTROLS
import WidgetKit
#endif

/// The Record control in Control Center and the menu bar. Built into Reprise and into its controls
/// extension: the extension draws the control, Reprise records.
enum RecordingControl {
    static let kind = "dev.nikiomori.reprise.record"
    /// A Darwin notification's state, 1 while Reprise records: the sandboxed extension can't ask
    /// Reprise, but it can read this.
    private static let name = "dev.nikiomori.reprise.recording"

    static var isRecording: Bool {
        var token: Int32 = 0, state: UInt64 = 0
        guard notify_register_check(name, &token) == NOTIFY_STATUS_OK else { return false }
        defer { notify_cancel(token) }
        notify_get_state(token, &state)
        return state == 1
    }

    #if !CONTROLS
    /// Held for Reprise's life: notifyd keeps a name's state only while someone is registered for it.
    private static let token: Int32? = {
        var token: Int32 = 0
        return notify_register_check(name, &token) == NOTIFY_STATUS_OK ? token : nil
    }()

    static func show(recording: Bool) {
        guard let token else { return }
        notify_set_state(token, recording ? 1 : 0)
        ControlCenter.shared.reloadControls(ofKind: kind)
    }
    #endif
}

/// Records the call going on, or stops the recording: the control's switch. It runs in Reprise.
struct RecordingToggleIntent: SetValueIntent, AudioRecordingIntent {
    static let title: LocalizedStringResource = "Record"
    static let description = IntentDescription("Records the call going on, or stops the recording.")
    static let isDiscoverable = false // Start Recording and Stop Recording are the ones for Shortcuts
    @available(macOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Recording") var value: Bool

    func perform() async throws -> some IntentResult {
        #if !CONTROLS
        await value ? AppModel.shared.record() : AppModel.shared.stopRecording()
        #endif
        return .result()
    }
}
