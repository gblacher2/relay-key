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
        await currentSnapshot().state
    }

    public func currentSnapshot() async -> RelaySnapshot {
        let cliPath = paths.cliURL.path
        guard FileManager.default.isExecutableFile(atPath: cliPath) else {
            return RelaySnapshot(state: .notInstalled, modelSelection: nil)
        }

        do {
            let (data, statusCode) = try await health.get(paths.healthURL)
            guard statusCode == 200 else {
                return RelaySnapshot(state: .unhealthy, modelSelection: nil)
            }

            struct HealthPayload: Decodable {
                let status: String
                let port: Int
                let modelSelection: ModelSelection?

                enum CodingKeys: String, CodingKey {
                    case status, port
                    case modelSelection = "model_selection"
                }
            }

            let payload = try JSONDecoder().decode(HealthPayload.self, from: data)
            guard payload.status == "ok" else {
                return RelaySnapshot(state: .unhealthy, modelSelection: nil)
            }
            return RelaySnapshot(
                state: .running(port: payload.port),
                modelSelection: payload.modelSelection
            )
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .timedOut, .networkConnectionLost, .cannotFindHost:
                return RelaySnapshot(state: .stopped, modelSelection: nil)
            default:
                return RelaySnapshot(state: .unhealthy, modelSelection: nil)
            }
        } catch {
            return RelaySnapshot(state: .unhealthy, modelSelection: nil)
        }
    }

    public func perform(_ action: RelayAction) async -> CommandOutcome {
        await commands.run(
            paths.cliURL,
            arguments: [action.rawValue],
            timeout: commandTimeout
        )
    }

    public func selectModel(_ model: String?) async -> CommandOutcome {
        await commands.run(
            paths.cliURL,
            arguments: model.map { ["model", "set", $0] } ?? ["model", "clear"],
            timeout: .seconds(10)
        )
    }
}
