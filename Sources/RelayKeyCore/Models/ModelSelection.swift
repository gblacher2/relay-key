import Foundation

public struct ModelSelection: Decodable, Equatable, Sendable {
    public let version: Int
    public let selected: String?
    public let models: [String]
    public let error: String?

    public var isAvailable: Bool {
        version == 1 && error == nil && !models.isEmpty
    }
}

public struct RelaySnapshot: Equatable, Sendable {
    public let state: RelayState
    public let modelSelection: ModelSelection?

    public init(state: RelayState, modelSelection: ModelSelection?) {
        self.state = state
        self.modelSelection = modelSelection
    }
}
