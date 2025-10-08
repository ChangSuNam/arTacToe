import SwiftUI
import ARKit
import RealityKit

struct ContentView: View {
    @StateObject private var gameManager = TicTacToeManager()
    @StateObject private var multiplayerManager = MultiplayerManager()
    @StateObject private var accessibilityManager = AccessibilityManager()
    
    @State private var showingSettings = false
    @State private var connectionState: ConnectionState = .idle
    
    enum ConnectionState {
        case idle, hosting, joining
    }
    
    var body: some View {
        ZStack {
            ARViewContainer(gameManager: gameManager,
                          multiplayerManager: multiplayerManager,
                          accessibilityManager: accessibilityManager)
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                if accessibilityManager.voiceCommandsEnabled {
                    VoiceCommandOverlay(accessibilityManager: accessibilityManager)
                }
                
                Spacer()
                
                if gameManager.gameState == .finished {
                    GameEndOverlay(gameManager: gameManager, multiplayerManager: multiplayerManager)
                }
                
                GameStatusBar(
                    gameManager: gameManager,
                    multiplayerManager: multiplayerManager,
                    connectionState: connectionState,
                    showingSettings: $showingSettings
                )
                
                if !multiplayerManager.isConnected && connectionState == .idle {
                    MultiplayerControls(connectionState: $connectionState, multiplayerManager: multiplayerManager)
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(accessibilityManager: accessibilityManager)
        }
        .task {
            await setupManagers()
        }
    }
    
    @MainActor
    private func setupManagers() async {
        gameManager.setupGame()
        gameManager.accessibilityManager = accessibilityManager
        multiplayerManager.gameManager = gameManager
        accessibilityManager.gameManager = gameManager
        accessibilityManager.multiplayerManager = multiplayerManager
        
        if accessibilityManager.voiceCommandsEnabled {
            await accessibilityManager.startSpeechRecognition()
        }
    }
}

// MARK: - Subviews
struct VoiceCommandOverlay: View {
    @ObservedObject var accessibilityManager: AccessibilityManager
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Voice: \(accessibilityManager.lastRecognizedSpeech)")
                    .font(.caption)
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                
                if !accessibilityManager.speechError.isEmpty {
                    Text("Error: \(accessibilityManager.speechError)")
                        .font(.caption)
                        .padding()
                        .background(Color.red.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
            
            Button(action: {
                Task {
                    await accessibilityManager.flushSpeechRecognition()
                }
            }) {
                Image(systemName: "trash")
                    .font(.caption)
                    .padding()
                    .background(Color.gray.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
        }
        .padding(.top, 50)
    }
}

struct GameEndOverlay: View {
    @ObservedObject var gameManager: TicTacToeManager
    @ObservedObject var multiplayerManager: MultiplayerManager
    
    var body: some View {
        VStack(spacing: 20) {
            Text(gameManager.winner != nil ? "Player \(gameManager.winner!.rawValue) Won!" : "It's a Tie!")
                .font(.largeTitle)
                .padding()
                .background(Color.black.opacity(0.7))
                .foregroundColor(.white)
                .cornerRadius(10)
            
            Button(action: {
                Task {
                    await gameManager.reset()
                    if multiplayerManager.isConnected {
                        // Consider syncing with opponent in future
                    }
                }
            }) {
                Text("Reset Game")
                    .font(.headline)
                    .padding()
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
        }
    }
}

struct GameStatusBar: View {
    @ObservedObject var gameManager: TicTacToeManager
    @ObservedObject var multiplayerManager: MultiplayerManager
    let connectionState: ContentView.ConnectionState
    @Binding var showingSettings: Bool
    
    private var statusMessage: String {
        if multiplayerManager.isConnected {
            return gameManager.currentPlayer == multiplayerManager.localPlayerType
                ? "Your turn, tap on a grid to make a move"
                : "Waiting for the opponent to move..."
        } else if connectionState == .hosting {
            return "Looking for someone to join. Tap the blue plane to activate AR board!"
        } else if connectionState == .joining {
            return "Looking for a host. Tap the blue plane to activate AR board!"
        } else {
            return ""
        }
    }
    
    var body: some View {
        HStack {
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.headline)
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            
            Spacer()
            
            Button(action: { showingSettings = true }) {
                Image(systemName: "gear")
                    .font(.title)
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
        }
        .padding()
    }
}

struct MultiplayerControls: View {
    @Binding var connectionState: ContentView.ConnectionState
    let multiplayerManager: MultiplayerManager
    
    var body: some View {
        HStack {
            Button(action: {
                connectionState = .hosting
                Task {
                    await multiplayerManager.startHosting()
                }
            }) {
                Text("Host Game")
                    .font(.headline)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            
            Button(action: {
                connectionState = .joining
                Task {
                    await multiplayerManager.joinGame()
                }
            }) {
                Text("Join Game")
                    .font(.headline)
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
        }
        .padding(.bottom, 20)
    }
}

// MARK: - AR View
struct ARViewContainer: UIViewRepresentable {
    let gameManager: TicTacToeManager
    let multiplayerManager: MultiplayerManager
    let accessibilityManager: AccessibilityManager
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        context.coordinator.setupAR(arView: arView)
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, ARSessionDelegate {
        let parent: ARViewContainer
        weak var arView: ARView?
        private var planeEntities: [UUID: AnchorEntity] = [:]
        
        init(_ parent: ARViewContainer) {
            self.parent = parent
        }
        
        @MainActor func setupAR(arView: ARView) {
            self.arView = arView
            
            let configuration = ARWorldTrackingConfiguration()
            configuration.planeDetection = [.horizontal]
            arView.session.run(configuration)
            arView.session.delegate = self
            
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            arView.addGestureRecognizer(tapGesture)
            
            parent.gameManager.arView = arView
        }
        
        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView = arView else { return }
            let location = gesture.location(in: arView)
            
            Task {
                await handleTapAsync(at: location, in: arView)
            }
        }
        
        @MainActor
        private func handleTapAsync(at location: CGPoint, in arView: ARView) async {
            if !parent.gameManager.boardPlaced {
                let results = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .horizontal)
                if let firstResult = results.first {
                    await parent.gameManager.placeBoard(at: firstResult)
                    removePlaneVisualizations()
                }
            } else {
                await handleGameTap(at: location, in: arView)
            }
        }
        
        @MainActor
        private func handleGameTap(at location: CGPoint, in arView: ARView) async {
            if parent.multiplayerManager.isConnected &&
               parent.gameManager.currentPlayer != parent.multiplayerManager.localPlayerType {
                parent.accessibilityManager.triggerHapticFeedback(.error)
                return
            }
            
            if let entity = arView.entity(at: location) as? ModelEntity,
               let cellIndex = parent.gameManager.getCellIndex(for: entity) {
                let moveSuccess = await parent.gameManager.makeMove(at: cellIndex)
                if moveSuccess && parent.multiplayerManager.isConnected {
                    await parent.multiplayerManager.sendMove(cellIndex: cellIndex)
                }
            }
        }
        
        private func removePlaneVisualizations() {
            planeEntities.values.forEach { $0.removeFromParent() }
            planeEntities.removeAll()
        }
        
        // MARK: - ARSessionDelegate
        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            Task { @MainActor in
                for anchor in anchors {
                    if let planeAnchor = anchor as? ARPlaneAnchor {
                        addPlaneVisualization(for: planeAnchor)
                    }
                }
            }
        }
        
        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            Task { @MainActor in
                for anchor in anchors {
                    if let planeAnchor = anchor as? ARPlaneAnchor {
                        updatePlaneVisualization(for: planeAnchor)
                    }
                }
            }
        }
        
        @MainActor
        private func addPlaneVisualization(for anchor: ARPlaneAnchor) {
            let planeEntity = AnchorEntity(anchor: anchor)
            let planeMesh = MeshResource.generatePlane(
                width: anchor.planeExtent.width,
                depth: anchor.planeExtent.height
            )
            let planeMaterial = SimpleMaterial(color: .blue.withAlphaComponent(0.3), isMetallic: false)
            let planeModel = ModelEntity(mesh: planeMesh, materials: [planeMaterial])
            planeEntity.addChild(planeModel)
            arView?.scene.addAnchor(planeEntity)
            planeEntities[anchor.identifier] = planeEntity
        }
        
        @MainActor
        private func updatePlaneVisualization(for anchor: ARPlaneAnchor) {
            guard let planeEntity = planeEntities[anchor.identifier] else { return }
            
            planeEntity.children.removeAll()
            let planeMesh = MeshResource.generatePlane(
                width: anchor.planeExtent.width,
                depth: anchor.planeExtent.height
            )
            let planeMaterial = SimpleMaterial(color: .blue.withAlphaComponent(0.3), isMetallic: false)
            let planeModel = ModelEntity(mesh: planeMesh, materials: [planeMaterial])
            planeEntity.addChild(planeModel)
        }
    }
}
