import Foundation

public struct Paths: Sendable {
    public let home: URL

    public var cliURL: URL {
        home.appendingPathComponent(".local/bin/oc-relay")
    }

    public var logURL: URL {
        home.appendingPathComponent("Library/Logs/oc-relay.log")
    }

    public var baseURL: URL {
        URL(string: "http://127.0.0.1:8788")!
    }

    public var healthURL: URL {
        baseURL.appendingPathComponent("health")
    }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }
}
