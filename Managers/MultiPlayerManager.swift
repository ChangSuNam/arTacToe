import Foundation
import MultipeerConnectivity
import Combine

// MARK: - Connection Error
enum ConnectionError: LocalizedError {
    case notConnected
    case noPeers
    case encodingFailed
    case decodingFailed
    
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to any peer"
        case .noPeers: return "No peers available"
        case .encodingFailed: return "Failed to encode data"
        case .decodingFailed: return "Failed to decode data"
        }
    }
}

// MARK: - Multiplayer Manager
@MainActor
class MultiplayerManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published private(set) var isConnected = false
    @Published private(set) var localPlayerType: PlayerType = .X
    @Published private(set) var peerDisplayName = ""
    @Published private(set) var connectionProgress: ConnectionProgress = .idle
    
    enum ConnectionProgress {
        case idle
        case searching
        case connecting(String)
        case connected(String)
        case failed(Error)
    }
    
    private let serviceType = "ar-tictactoe"
    private let myPeerId = MCPeerID(displayName: UIDevice.current.name)
    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private let connectionQueue = DispatchQueue(label: "com.tictactoe.multiplayer", qos: .userInitiated)
    
    weak var gameManager: TicTacToeManager?
    

    override init() {
        self.session = MCSession(
            peer: myPeerId,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        super.init()
        self.session.delegate = self
    }
    
    deinit {
        disconnect()
    }
    

    func startHosting() async {
        await resetConnection()
        localPlayerType = .X
        connectionProgress = .searching
        
        await withCheckedContinuation { continuation in
            connectionQueue.async { [weak self] in
                guard let self = self else { return }
                Task { @MainActor in
                    self.advertiser = MCNearbyServiceAdvertiser(
                        peer: self.myPeerId,
                        discoveryInfo: nil,
                        serviceType: self.serviceType
                    )
                    self.advertiser?.delegate = self
                    self.advertiser?.startAdvertisingPeer()
                    continuation.resume()
                }
                
            }
        }
    }
    
    func joinGame() async {
        await resetConnection()
        localPlayerType = .O
        connectionProgress = .searching
        
        await withCheckedContinuation { continuation in
            connectionQueue.async { [weak self] in
                guard let self = self else { return }
                Task { @MainActor in
                    self.browser = MCNearbyServiceBrowser(
                        peer: self.myPeerId,
                        serviceType: self.serviceType
                    )
                    self.browser?.delegate = self
                    self.browser?.startBrowsingForPeers()
                    continuation.resume()
                }
            }
        }
    }
    
    func sendMove(cellIndex: Int) async {
        guard session.connectedPeers.count > 0 else {
            print("ConnectionError: \(ConnectionError.noPeers)")
            return
        }
        
        let move = GameMove(cellIndex: cellIndex, playerType: localPlayerType)
        
        do {
            let data = try JSONEncoder().encode(move)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connectionQueue.async { [weak self] in
                    guard let self = self else { return }
                    
                    Task { @MainActor in
                        do {
                            try self.session.send(data, toPeers: self.session.connectedPeers, with: .reliable)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }

                }
            }
        } catch {
            print("Failed to send move: \(error)")
        }
    }
    
    nonisolated func disconnect() {
        connectionQueue.async { [weak self] in
            Task { @MainActor in
                self?.performDisconnection()
            }
        }
    }
    
    private func resetConnection() async {
        await withCheckedContinuation { continuation in
            
           
            connectionQueue.async { [weak self] in
                Task { @MainActor in
                    self?.performDisconnection()
                    self?.session = MCSession(
                        peer: self?.myPeerId ?? MCPeerID(displayName: UIDevice.current.name),
                        securityIdentity: nil,
                        encryptionPreference: .required
                    )
                    self?.session.delegate = self
                    continuation.resume()
                }
                
            }
        }
    }
    
    private func performDisconnection() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        session.disconnect()
        
        Task { @MainActor in
            isConnected = false
            peerDisplayName = ""
            connectionProgress = .idle
        }
    }
}

// MARK: - MCSessionDelegate
extension MultiplayerManager: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                self.handlePeerConnected(peerID)
            case .connecting:
                self.connectionProgress = .connecting(peerID.displayName)
            case .notConnected:
                self.handlePeerDisconnected()
            @unknown default:
                break
            }
        }
    }
    
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            await self.handleReceivedData(data, from: peerID)
        }
    }
    
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate
extension MultiplayerManager: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
              invitationHandler(true, session)
        }
    }
    
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            self.connectionProgress = .failed(error)
            print("Failed to start advertising: \(error)")
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension MultiplayerManager: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
               browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
        }
    }
    
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            self.connectionProgress = .failed(error)
            print("Failed to start browsing: \(error)")
        }
    }
}

// MARK: - Private Handler Extensions
@MainActor
private extension MultiplayerManager {
    func handlePeerConnected(_ peerID: MCPeerID) {
        isConnected = true
        peerDisplayName = peerID.displayName
        connectionProgress = .connected(peerID.displayName)
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        Task {
            await gameManager?.reset()
        }
    }
    
    func handlePeerDisconnected() {
        isConnected = false
        peerDisplayName = ""
        connectionProgress = .idle
    }
    
    func handleReceivedData(_ data: Data, from peerID: MCPeerID) async {
        do {
            let move = try JSONDecoder().decode(GameMove.self, from: data)
            await gameManager?.remoteMakeMove(at: move.cellIndex, playerType: move.playerType)
        } catch {
            print("Error decoding move: \(error)")
        }
    }
}
