import SwiftUI
import ReachProtocol

/// App settings. Everything is stored with `@AppStorage`, so sessions pick changes up immediately.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.inputMode) private var inputMode = InputMode.trackpad
    @AppStorage(SettingsKey.pointerSpeed) private var pointerSpeed = 1.0
    @AppStorage(SettingsKey.naturalScrolling) private var naturalScrolling = true
    @AppStorage(SettingsKey.haptics) private var haptics = true
    @AppStorage(SettingsKey.qualityMode) private var qualityMode = QualityMode.balanced
    @AppStorage(SettingsKey.maxFPS) private var maxFPS = 60
    @AppStorage(SettingsKey.showStats) private var showStats = false
    @State private var guideReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Default Mode", selection: $inputMode) {
                        ForEach(InputMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Pointer Speed")
                            Spacer()
                            Text("\(pointerSpeed, format: .number.precision(.fractionLength(1)))×")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $pointerSpeed, in: 0.4...2.5, step: 0.1) {
                            Text("Pointer Speed")
                        } minimumValueLabel: {
                            Image(systemName: "tortoise").foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Image(systemName: "hare").foregroundStyle(.secondary)
                        }
                        .tint(Theme.accent)
                    }
                    .padding(.vertical, 2)
                    Toggle("Natural Scrolling", isOn: $naturalScrolling)
                    Toggle("Haptics", isOn: $haptics)
                } header: {
                    Text("Input")
                } footer: {
                    Text("Pointer speed applies in Trackpad mode. Natural scrolling: content follows your fingers, like on iPhone.")
                }

                Section {
                    Picker("Quality", selection: $qualityMode) {
                        ForEach(QualityMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Picker("Frame Rate", selection: $maxFPS) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    Toggle("Always Show Connection Status", isOn: $showStats)
                } header: {
                    Text("Screen")
                } footer: {
                    Text(qualityMode.detail)
                }

                Section {
                    Button {
                        AppSettings.resetCoachMarks()
                        guideReset = true
                    } label: {
                        HStack {
                            Text("Show Gesture Guides Again")
                            Spacer()
                            if guideReset {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .disabled(guideReset)
                } header: {
                    Text("Help")
                }

                Section {
                    LabeledContent("This iPhone’s Key") {
                        Text(model.thisDeviceFingerprint).monospaced()
                    }
                    LabeledContent("Internet Relays", value: !model.relayStatusKnown ? "Not connected" : model.relaysReachable ? "Reachable" : "Unreachable")
                    LabeledContent("Version", value: DeviceInfo.appVersion)
                } header: {
                    Text("About")
                } footer: {
                    Text("Your Mac shows the same key fingerprint for this iPhone under Paired Devices.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
