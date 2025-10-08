import Foundation
import Speech
import Combine
import UIKit

// MARK: - Haptic Feedback Type
enum HapticFeedbackType {
    case success
    case error
    case warning
    case selection
}

// MARK: - Voice command for accessibility mode
struct VoiceCommand {
    let text: String
    let position: Int?
    
    static let positionMap: [String: Int] = [
        "top left": 0, "upper left": 0,
        "top center": 1, "upper center": 1,
        "top right": 2, "upper right": 2,
        "middle left": 3, "left center": 3,
        "center": 4, "middle": 4,
        "middle right": 5, "right center": 5,
        "bottom left": 6, "lower left": 6,
        "bottom center": 7, "lower center": 7,
        "bottom right": 8, "lower right": 8
    ]
    
    init(from text: String) {
        self.text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.position = Self.parsePosition(from: self.text)
    }
    
    private static func parsePosition(from command: String) -> Int? {
        for (keyword, index) in positionMap {
            if command.contains(keyword) {
                return index
            }
        }
        return nil
    }
}

// MARK: - Accessibility Manager
@MainActor
class AccessibilityManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var voiceCommandsEnabled = false {
        didSet {
            Task {
                if voiceCommandsEnabled {
                    await startSpeechRecognition()
                } else {
                    await stopSpeechRecognition()
                }
            }
        }
    }
    
    @Published var colorblindModeEnabled = false {
        didSet {
            Task {
                await gameManager?.updatePieceColors()
            }
        }
    }
    
    @Published var hapticFeedbackEnabled = true
    @Published private(set) var lastRecognizedSpeech = ""
    @Published private(set) var speechError = ""
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var resetTimer: Timer?
    private let speechQueue = DispatchQueue(label: "com.tictactoe.speech", qos: .userInteractive)
    private let hapticQueue = DispatchQueue(label: "com.tictactoe.haptic", qos: .userInteractive)
    private var isRecognizing = false

    weak var gameManager: TicTacToeManager?
    weak var multiplayerManager: MultiplayerManager?

    override init() {
        super.init()
        Task {
            await requestSpeechAuthorization()
        }
    }
    
    func tearDown() async {
           await stopSpeechRecognition()
    }


    deinit {
        
        resetTimer?.invalidate()
        resetTimer = nil
        audioEngine.stop()
    }
    

    func startSpeechRecognition() async {
        guard voiceCommandsEnabled, !isRecognizing else { return }
        isRecognizing = true
        
        await stopSpeechRecognition() // Clean up any existing session
        
        guard let speechRecognizer = speechRecognizer, 
              await speechRecognizer.isAvailable() else {
            speechError = "Speech recognizer not available"
            isRecognizing = false
            return
        }
        
        do {
            try await setupAudioSession()
            try await startListening()
        } catch {
            print("Speech recognition setup failed: \(error)")
            speechError = error.localizedDescription
            isRecognizing = false
            await resetRecognition()
        }
    }
    
    func stopSpeechRecognition() async {
        await withCheckedContinuation { continuation in
            speechQueue.async { [weak self] in
                Task { @MainActor in
                    self?.performStop()
                    continuation.resume()
                }
                
            }
        }
    }
    
    func flushSpeechRecognition() async {
        lastRecognizedSpeech = ""
        speechError = ""
        if voiceCommandsEnabled {
            isRecognizing = true
            await startSpeechRecognition()
        }
    }
    
    func triggerHapticFeedback(_ type: HapticFeedbackType) {
        guard hapticFeedbackEnabled else { return }
        
        Task { @MainActor in
            switch type {
            case .success:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .error:
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            case .warning:
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case .selection:
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }


    }
    
    
    
    
    private func requestSpeechAuthorization() async {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        
        if status != .authorized {
            speechError = "Speech recognition not authorized"
        }
    }
    
    private func setupAudioSession() async throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }
    
    private func startListening() async throws {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        guard let recognitionRequest = recognitionRequest else {
            throw NSError(domain: "SpeechRecognition", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create recognition request"])
        }
        
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // Remove any existing tap
        inputNode.removeTap(onBus: 0)
        
        // Install tap with proper error handling
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        // Start recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                await self?.handleRecognitionResult(result, error: error)
            }
        }
        
        
        startResetTimer()
    }
    
    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?) async {
        if let error = error {
            speechError = error.localizedDescription
            isRecognizing = false
            await resetRecognition()
            return
        }
        
        guard let result = result else { return }
        
        let transcription = result.bestTranscription.formattedString
        lastRecognizedSpeech = transcription
        
        if result.isFinal || shouldProcessCommand(transcription) {
            await processVoiceCommand(VoiceCommand(from: transcription))
            resetTimer?.invalidate()
        }
    }
    
    private func shouldProcessCommand(_ text: String) -> Bool {
        // Check if text contains a complete position command
        let command = VoiceCommand(from: text)
        return command.position != nil
    }
    
    private func processVoiceCommand(_ command: VoiceCommand) async {
        guard let position = command.position,
              let gameManager = gameManager else {
            speechError = "Position not recognized: \(command.text)"
            triggerHapticFeedback(.error)
            return
        }
        
        // Validate turn if multiplayer
        if let multiplayer = multiplayerManager, multiplayer.isConnected {
            guard multiplayer.localPlayerType == gameManager.currentPlayer else {
                speechError = "Not your turn"
                triggerHapticFeedback(.error)
                return
            }
        }
        
        // Make move
        let success = await gameManager.makeMove(at: position)
        
        if success {
            triggerHapticFeedback(.success)
            
            // Send move if multiplayer
            if let multiplayer = multiplayerManager, multiplayer.isConnected {
                await multiplayer.sendMove(cellIndex: position)
            }
            
            // Reset for next command
            await resetRecognition()
        } else {
            speechError = "Move failed at position \(position)"
            triggerHapticFeedback(.error)
        }
    }
    
    private func performStop() {
        resetTimer?.invalidate()
        resetTimer = nil
        
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        
        try? AVAudioSession.sharedInstance().setActive(false)
        
        isRecognizing = false
    }
    
    private func resetRecognition() async {
        await stopSpeechRecognition()
        
        // Wait briefly before restarting
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        
        if voiceCommandsEnabled {
            await startSpeechRecognition()
        }
    }
    
    private func startResetTimer() {
        resetTimer?.invalidate()
        resetTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task {
                await self?.resetRecognition()
            }
        }
    }
}

// MARK: - Extension for async availability check
extension SFSpeechRecognizer {
    func isAvailable() async -> Bool {
        return await withCheckedContinuation { continuation in
            continuation.resume(returning: self.isAvailable)
        }
    }
}
