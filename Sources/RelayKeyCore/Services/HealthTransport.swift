import Foundation

public protocol HealthTransport: Sendable {
    func get(_ url: URL) async throws -> (Data, Int)
}

public struct URLSessionHealthTransport: HealthTransport {
    public init() {}

    public func get(_ url: URL) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(from: url)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (data, statusCode)
    }
}
