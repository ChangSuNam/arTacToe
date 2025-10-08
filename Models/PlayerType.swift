enum PlayerType: String, Codable, CaseIterable {
    case X, O
    
    var opponent: PlayerType {
        self == .X ? .O : .X
    }
}
