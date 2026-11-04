import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: RecordingController
    @ObservedObject var transcriptions: TranscriptionController
    @Binding var showMenuBarIcon: Bool
    @StateObject private var microphone = MicrophoneSettingsModel()

    var body: some View {
        Form {
            microphoneSection

            Section {
                LabeledContent("Folder") {
                    Text(controller.destinationDisplayPath)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Choose Folder…") { controller.chooseDestination() }
                    .disabled(!controller.canChooseDestination)
                Toggle("Show Noty in the menu bar", isOn: $showMenuBarIcon)
            } header: {
                Text("Recording")
            } footer: {
                Text("You can always reopen the Noty window from the Dock. Closing it keeps Noty running.")
            }

            Section {
                Text("English transcripts with Speaker 1, Speaker 2 labels, processed on this Mac.")
                Text("Speaker labels support recordings up to two hours. Longer audio receives text only.")
                    .foregroundStyle(.secondary)
                modelSetup
                Toggle("Automatically transcribe new recordings", isOn: Binding(
                    get: { transcriptions.automaticEnabled },
                    set: { transcriptions.setAutomaticEnabled($0) }
                ))
                .disabled(transcriptions.modelState != .ready)
            } header: {
                Text("Transcription")
            } footer: {
                Text("Your audio stays on this Mac.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { microphone.activate() }
        .onDisappear { microphone.deactivate() }
        .onChange(of: controller.hasActiveRecording) { _, active in
            if active {
                microphone.stopTest()
            }
        }
    }

    private var microphoneSection: some View {
        Section {
            Picker("Microphone", selection: Binding(
                get: { microphone.preference.uid },
                set: { microphone.select(uid: $0) }
            )) {
                Text(defaultMicrophoneLabel).tag(String?.none)
                if microphone.isSelectionMissing, let uid = microphone.preference.uid {
                    Text("\(microphone.preference.name ?? "Unknown microphone") (not connected)").tag(Optional(uid))
                }
                Divider()
                ForEach(microphone.devices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .disabled(controller.hasActiveRecording)
            HStack(spacing: 12) {
                Button(microphone.isTesting ? "Stop Test" : "Test Microphone") {
                    Task { await microphone.toggleTest() }
                }
                .disabled(controller.hasActiveRecording)
                ProgressView(value: min(1, pow(microphone.level, 0.5) * 1.65))
                    .progressViewStyle(.linear)
                    .opacity(microphone.isTesting ? 1 : 0.4)
                    .accessibilityLabel("Microphone level")
            }
            if let error = microphone.testError {
                Text(error)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Microphone")
        } footer: {
            Text("""
            Speak while testing. If the bar doesn’t move, choose another microphone. \
            Changes apply to the next recording.
            """)
        }
    }

    private var defaultMicrophoneLabel: String {
        guard let device = microphone.defaultDevice else { return "System Default" }
        return "System Default (\(device.name))"
    }

    @ViewBuilder
    private var modelSetup: some View {
        switch transcriptions.modelState {
        case .notInstalled:
            Button("Download and Enable", systemImage: "arrow.down.circle") { transcriptions.prepareModels() }
                .disabled(!transcriptions.canPrepareModels)
        case .preparing:
            ProgressView(value: transcriptions.progress) {
                Text(transcriptions.progressMessage ?? "Preparing speech models…")
            }
            Button("Cancel Download") { Task { await transcriptions.cancelModelPreparation() } }
        case .ready:
            Label("Speech models ready", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .needsRepair:
            Text("The speech models need repair before transcription can continue.")
            Button("Repair Models", systemImage: "arrow.clockwise") { transcriptions.prepareModels() }
                .disabled(!transcriptions.canPrepareModels)
        }
    }
}
