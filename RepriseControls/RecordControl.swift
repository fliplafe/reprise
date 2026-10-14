import SwiftUI
import WidgetKit

@main
struct RepriseControls: WidgetBundle {
    var body: some Widget {
        RecordControl()
    }
}

/// A switch for recording in Control Center and the menu bar, red while it records, like the pill's dot.
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: RecordingControl.kind, provider: Provider()) { recording in
            ControlWidgetToggle(isOn: recording, action: RecordingToggleIntent()) {
                Label("Record", systemImage: "record.circle")
            } valueLabel: { recording in
                Text(recording ? "Recording" : "Off")
            }
            .tint(.red)
        }
        .displayName("Record")
        .description("Records the call going on, or stops the recording.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }
        func currentValue() async throws -> Bool { RecordingControl.isRecording }
    }
}
