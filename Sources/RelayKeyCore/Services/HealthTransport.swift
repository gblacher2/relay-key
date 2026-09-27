import Foundation

public protocol HealthTransport: Sendable {
    func get(_ url: URL) async throws -> (Data, Int)
}

public struct URLSessionHealthTransport: HealthTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    public func get(_ url: URL) async throws -> (Data, Int) {
        let (data, response) = try await session.data(from: url)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (data, statusCode)
    }
}
