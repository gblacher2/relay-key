import Foundation

public struct RelayController: Sendable {
    private let paths: Paths
    private let health: any HealthTransport
    private let commands: any CommandRunning
    private let commandTimeout: Duration

    public init(
        paths: Paths,
        health: any HealthTransport,
        commands: any CommandRunning,
        commandTimeout: Duration = .seconds(30)
    ) {
        self.paths = paths
        self.health = health
        self.commands = commands
        self.commandTimeout = commandTimeout
    }

    public func currentState() async -> RelayState {
        let cliPath = paths.cliURL.path
        guard FileManager.default.isExecutableFile(atPath: cliPath) else {
            return .notInstalled
        }

        do {
            let (data, statusCode) = try await health.get(paths.healthURL)
            guard statusCode == 200 else {
                return .unhealthy
            }

            struct HealthPayload: Decodable {
                let status: String
                let port: Int
            }

            let payload = try JSONDecoder().decode(HealthPayload.self, from: data)
            guard payload.status == "ok" else {
                return .unhealthy
            }
            return .running(port: payload.port)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .timedOut, .networkConnectionLost, .cannotFindHost:
                return .stopped
            default:
                return .unhealthy
            }
        } catch {
            return .unhealthy
        }
    }

    public func perform(_ action: RelayAction) async -> CommandOutcome {
        await commands.run(
            paths.cliURL,
            arguments: [action.rawValue],
            timeout: commandTimeout
        )
    }
}
