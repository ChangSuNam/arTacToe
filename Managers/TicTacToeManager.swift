import Foundation
import RealityKit
import ARKit
import Combine


// MARK: - Board Configuration
struct BoardConfiguration {
    static let size: Float = 0.3
    static let cellSize: Float = size / 3
    static let lineThickness: Float = 0.005
    static let pieceThickness: Float = 0.01
    static let cellPadding: Float = 0.9
    static let pieceZOffset: Float = 0.02
    static let highlightZOffset: Float = 0.03
}

// MARK: - Main Manager
@MainActor
class TicTacToeManager: ObservableObject {
    // MARK: - Published Properties
    @Published private(set) var boardPlaced = false
    @Published private(set) var currentPlayer: PlayerType = .X
    @Published private(set) var gameState: GameState = .playing
    @Published private(set) var winner: PlayerType?

    weak var arView: ARView?
    weak var accessibilityManager: AccessibilityManager?
    
    private var boardAnchor: AnchorEntity?
    private var cellEntities: [ModelEntity] = []
    private var board: [PlayerType?] = Array(repeating: nil, count: 9)
    private let boardRenderer = BoardRenderer()
    private let moveProcessor = MoveProcessor()
    

    func setupGame() {
        Task {
            await reset()
        }
    }
    
    func reset() async {
        currentPlayer = .X
        gameState = .playing
        winner = nil
        board = Array(repeating: nil, count: 9)
        
        if let anchor = boardAnchor {
            await removeBoardFromScene(anchor)
        }
        
        boardAnchor = nil
        cellEntities = []
        boardPlaced = false
    }
    
    func placeBoard(at raycastResult: ARRaycastResult) async {
        guard let arView = arView, !boardPlaced else { return }
        
        let anchor = await boardRenderer.createBoard(at: raycastResult.worldTransform)
        cellEntities = anchor.children.compactMap { $0 as? ModelEntity }
            .filter { $0.name.starts(with: "cell_") }
        
        arView.scene.addAnchor(anchor)
        boardAnchor = anchor
        boardPlaced = true
    }
    
    func getCellIndex(for entity: ModelEntity) -> Int? {
        cellEntities.firstIndex(of: entity)
    }
    
    func makeMove(at index: Int) async -> Bool {
        let validation = moveProcessor.validateMove(
            index: index,
            board: board,
            gameState: gameState
        )
        
        guard validation.isValid else {
            accessibilityManager?.triggerHapticFeedback(.error)
            return false
        }
        
        board[index] = currentPlayer
        await placePiece(at: index, playerType: currentPlayer)
        accessibilityManager?.triggerHapticFeedback(.success)
        
        await processGameState(afterMoveAt: index)
        return true
    }
    
    func remoteMakeMove(at index: Int, playerType: PlayerType) async {
        guard moveProcessor.validateMove(index: index, board: board, gameState: gameState).isValid else {
            return
        }
        
        board[index] = playerType
        await placePiece(at: index, playerType: playerType)
        await processGameState(afterMoveAt: index)
    }
    
    func updatePieceColors() async {
        guard let boardAnchor = boardAnchor,
              let accessibilityManager = accessibilityManager else { return }
        
        for (index, player) in board.enumerated() {
            guard let player = player,
                  let pieceEntity = boardAnchor.findEntity(named: "piece_\(index)") as? ModelEntity else {
                continue
            }
            
            let color = boardRenderer.getPlayerColor(
                player,
                colorblindMode: accessibilityManager.colorblindModeEnabled
            )
            pieceEntity.model?.materials = [SimpleMaterial(color: color, roughness: 0.5, isMetallic: false)]
        }
    }
    
    private func removeBoardFromScene(_ anchor: AnchorEntity) async {
        arView?.scene.removeAnchor(anchor)
    }
    
    private func placePiece(at index: Int, playerType: PlayerType) async {
        guard let cellEntity = cellEntities[safe: index],
              let boardAnchor = boardAnchor else { return }
        
        let pieceEntity = await boardRenderer.createPiece(
            for: playerType,
            at: cellEntity.position,
            colorblindMode: accessibilityManager?.colorblindModeEnabled ?? false
        )
        pieceEntity.name = "piece_\(index)"
        boardAnchor.addChild(pieceEntity)
    }
    
    private func processGameState(afterMoveAt index: Int) async {
        if let winningCombination = moveProcessor.checkForWin(board: board) {
            gameState = .finished
            winner = currentPlayer
            await highlightWinningCombination(winningCombination)
        } else if moveProcessor.isBoardFull(board: board) {
            gameState = .finished
            winner = nil
        } else {
            currentPlayer = currentPlayer.opponent
        }
    }
    
    private func highlightWinningCombination(_ combination: [Int]) async {
        guard let boardAnchor = boardAnchor else { return }
        
        let highlightEntity = await boardRenderer.createWinningHighlight(
            for: combination,
            cellEntities: cellEntities,
            colorblindMode: accessibilityManager?.colorblindModeEnabled ?? false
        )
        boardAnchor.addChild(highlightEntity)
    }
}

// MARK: - Board Renderer
@MainActor
class BoardRenderer {
    func createBoard(at transform: simd_float4x4) async -> AnchorEntity {
        let anchor = AnchorEntity(world: transform)
        
        // Create grid lines
        let lineMaterial = SimpleMaterial(color: .white, isMetallic: false)
        
        for i in 1...2 {
            // Horizontal lines
            let yPos = BoardConfiguration.cellSize * Float(i) - BoardConfiguration.size/2
            let hLine = ModelEntity(
                mesh: .generateBox(size: [BoardConfiguration.size, BoardConfiguration.lineThickness, BoardConfiguration.lineThickness]),
                materials: [lineMaterial]
            )
            hLine.position = [0, yPos, 0]
            anchor.addChild(hLine)
            
            // Vertical lines
            let xPos = BoardConfiguration.cellSize * Float(i) - BoardConfiguration.size/2
            let vLine = ModelEntity(
                mesh: .generateBox(size: [BoardConfiguration.lineThickness, BoardConfiguration.size, BoardConfiguration.lineThickness]),
                materials: [lineMaterial]
            )
            vLine.position = [xPos, 0, 0]
            anchor.addChild(vLine)
        }
        
        // Create cell interaction planes
        for row in 0..<3 {
            for col in 0..<3 {
                let cellPlane = createCellPlane(row: row, col: col)
                anchor.addChild(cellPlane)
            }
        }
        
        return anchor
    }
    
    private func createCellPlane(row: Int, col: Int) -> ModelEntity {
        let x = Float(col) * BoardConfiguration.cellSize - BoardConfiguration.size/3
        let y = Float(2-row) * BoardConfiguration.cellSize - BoardConfiguration.size/3
        
        let cellPlane = ModelEntity(
            mesh: .generatePlane(
                width: BoardConfiguration.cellSize * BoardConfiguration.cellPadding,
                depth: BoardConfiguration.cellSize * BoardConfiguration.cellPadding
            ),
            materials: [SimpleMaterial(color: .clear, isMetallic: false)]
        )
        cellPlane.position = [x, y, 0.01]
        cellPlane.generateCollisionShapes(recursive: true)
        cellPlane.name = "cell_\(row * 3 + col)"
        
        return cellPlane
    }
    
    func createPiece(for player: PlayerType, at position: SIMD3<Float>, colorblindMode: Bool) async -> ModelEntity {
        let color = getPlayerColor(player, colorblindMode: colorblindMode)
        let material = SimpleMaterial(color: color, roughness: 0.5, isMetallic: false)
        
        let pieceEntity: ModelEntity
        if player == .X {
            pieceEntity = createXPiece(material: material)
        } else {
            pieceEntity = createOPiece(material: material)
        }
        
        pieceEntity.position = position
        pieceEntity.position.z = BoardConfiguration.pieceZOffset
        
        return pieceEntity
    }
    
    private func createXPiece(material: SimpleMaterial) -> ModelEntity {
        let length = BoardConfiguration.cellSize * 0.7
        let thickness = BoardConfiguration.pieceThickness
        
        let diagonal1 = ModelEntity(
            mesh: .generateBox(size: [length, thickness, thickness]),
            materials: [material]
        )
        diagonal1.transform.rotation = simd_quatf(angle: .pi/4, axis: [0, 0, 1])
        
        let diagonal2 = ModelEntity(
            mesh: .generateBox(size: [length, thickness, thickness]),
            materials: [material]
        )
        diagonal2.transform.rotation = simd_quatf(angle: -.pi/4, axis: [0, 0, 1])
        
        let pieceEntity = ModelEntity()
        pieceEntity.addChild(diagonal1)
        pieceEntity.addChild(diagonal2)
        
        return pieceEntity
    }
    
    private func createOPiece(material: SimpleMaterial) -> ModelEntity {
        let radius = BoardConfiguration.cellSize * 0.3
        let thickness = BoardConfiguration.pieceThickness
        
        let outerCylinder = ModelEntity(
            mesh: .generateCylinder(height: thickness, radius: radius),
            materials: [material]
        )
        
        let innerCylinder = ModelEntity(
            mesh: .generateCylinder(height: thickness, radius: radius - thickness),
            materials: [SimpleMaterial(color: .clear, isMetallic: false)]
        )
        
        let pieceEntity = ModelEntity()
        pieceEntity.addChild(outerCylinder)
        pieceEntity.addChild(innerCylinder)
        pieceEntity.transform.rotation = simd_quatf(angle: .pi/2, axis: [1, 0, 0])
        
        return pieceEntity
    }
    
    func createWinningHighlight(for combination: [Int], cellEntities: [ModelEntity], colorblindMode: Bool) async -> ModelEntity {
        guard let firstCell = cellEntities[safe: combination.first ?? 0],
              let lastCell = cellEntities[safe: combination.last ?? 0] else {
            return ModelEntity()
        }
        
        let color: UIColor = colorblindMode ? .gray : .green
        let material = SimpleMaterial(color: color, roughness: 0.3, isMetallic: false)
        
        let startPos = firstCell.position
        let endPos = lastCell.position
        let distance = simd_distance(startPos, endPos)
        
        let lineEntity = ModelEntity(
            mesh: .generateBox(size: [distance, BoardConfiguration.pieceThickness, BoardConfiguration.pieceThickness]),
            materials: [material]
        )
        
        let midPoint = (startPos + endPos) / 2
        lineEntity.position = midPoint
        lineEntity.position.z = BoardConfiguration.highlightZOffset
        
        // Calculate rotation
        let direction = normalize(endPos - startPos)
        let defaultDirection = SIMD3<Float>(1, 0, 0)
        let dotProduct = dot(defaultDirection, direction)
        
        if abs(dotProduct) < 0.99 {
            let angle = acos(dotProduct)
            let rotationAxis = cross(defaultDirection, direction)
            lineEntity.transform.rotation = simd_quatf(angle: angle, axis: normalize(rotationAxis))
        }
        
        return lineEntity
    }
    
    func getPlayerColor(_ player: PlayerType, colorblindMode: Bool) -> UIColor {
        if colorblindMode {
            return player == .X ? .black : .white
        } else {
            return player == .X ? .red : .blue
        }
    }
}

// MARK: - Move Processor
struct MoveProcessor {
    struct MoveValidation {
        let isValid: Bool
        let reason: String?
    }
    
    private let winningCombinations = [
        [0, 1, 2], [3, 4, 5], [6, 7, 8], // Rows
        [0, 3, 6], [1, 4, 7], [2, 5, 8], // Columns
        [0, 4, 8], [2, 4, 6]             // Diagonals
    ]
    
    func validateMove(index: Int, board: [PlayerType?], gameState: GameState) -> MoveValidation {
        guard gameState == .playing else {
            return MoveValidation(isValid: false, reason: "Game is finished")
        }
        
        guard index >= 0 && index < 9 else {
            return MoveValidation(isValid: false, reason: "Invalid index")
        }
        
        guard board[index] == nil else {
            return MoveValidation(isValid: false, reason: "Cell already occupied")
        }
        
        return MoveValidation(isValid: true, reason: nil)
    }
    
    func checkForWin(board: [PlayerType?]) -> [Int]? {
        for combination in winningCombinations {
            let cells = combination.compactMap { board[$0] }
            if cells.count == 3 && cells[0] == cells[1] && cells[1] == cells[2] {
                return combination
            }
        }
        return nil
    }
    
    func isBoardFull(board: [PlayerType?]) -> Bool {
        board.compactMap { $0 }.count == 9
    }
}

// MARK: - Extensions
extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Entity {
    func findEntity(named name: String) -> Entity? {
        if self.name == name {
            return self
        }
        for child in children {
            if let found = child.findEntity(named: name) {
                return found
            }
        }
        return nil
    }
}
