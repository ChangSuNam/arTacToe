import SwiftUI
import  AVFoundation


struct SettingsView: View {
    @ObservedObject var accessibilityManager: AccessibilityManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                AccessibilitySection(accessibilityManager: accessibilityManager)
                InformationSection()
            }
            .navigationBarTitle("Settings", displayMode: .inline)
            .navigationBarItems(trailing: dismissButton)
        }
    }
    
    private var dismissButton: some View {
        Button("Done") {
            dismiss()
        }
    }
}

// MARK: - Accessibility Section
struct AccessibilitySection: View {
    @ObservedObject var accessibilityManager: AccessibilityManager
    
    var body: some View {
        Section(header: Text("Accessibility")) {
            Toggle("Voice Commands", isOn: $accessibilityManager.voiceCommandsEnabled)
            
            Toggle("Colorblind Mode", isOn: $accessibilityManager.colorblindModeEnabled)
            
            Toggle("Haptic Feedback", isOn: $accessibilityManager.hapticFeedbackEnabled)
                .onChange(of: accessibilityManager.hapticFeedbackEnabled) {
                
                        // Provide test feedback
                        accessibilityManager.triggerHapticFeedback(.selection)
                    
                }
        }
    }
}

// MARK: - Information Section
struct InformationSection: View {
    var body: some View {
        Group {
            Section(header: Text("Voice Commands Info")) {
                Text(SettingsContent.voiceCommandsInfo)
                    .font(.caption)
            }
            
            Section(header: Text("Colorblind Mode Info")) {
                Text(SettingsContent.colorblindModeInfo)
                    .font(.caption)
            }
            
            Section(header: Text("Haptic Feedback Info")) {
                Text(SettingsContent.hapticFeedbackInfo)
                    .font(.caption)
            }
        }
    }
}

// MARK: - Settings Descriptions
struct SettingsContent {
    static let voiceCommandsInfo = """
    During your turn, say a position to place your move.
    
    Example: "upper left" places a move in the top-left corner.
    
    Available commands:
    • Top row: "top/upper" + "left", "center", or "right"
    • Middle row: "middle/center" + "left" or "right", or just "center"
    • Bottom row: "bottom/lower" + "left", "center", or "right"
    
    Use the trash icon to clear accumulated commands if needed.
    """
    
    static let colorblindModeInfo = """
    When enabled:
    • X pieces appear in black
    • O pieces appear in white
    • Winning line appears in grey
    """
    
    static let hapticFeedbackInfo = """
    When enabled, feel vibrations for:
    • Successful moves
    • Invalid move attempts
    • Turn notifications
    • Game events
    """
}



// MARK: - Preview
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(accessibilityManager: AccessibilityManager())
    }
}

