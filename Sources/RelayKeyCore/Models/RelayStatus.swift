import Foundation

public enum RelayAction: String, Sendable {
    case start
    case stop
    case restart
}

public enum RelayState: Equatable, Sendable {
    case checking
    case running(port: Int)
    case stopped
    case notInstalled
    case unhealthy
    case actionFailed(RelayAction, exitCode: Int32)
}

public enum RelayStatusPresentation {
    public static func statusLine(
        state: RelayState,
        activeAction: RelayAction?
    ) -> String {
        if let activeAction {
            switch activeAction {
            case .start: return "Starting…"
            case .stop: return "Stopping…"
            case .restart: return "Restarting…"
            }
        }

        switch state {
        case .checking:
            return "Checking…"
        case .running(let port):
            return "Running · Port \(port)"
        case .stopped:
            return "Stopped"
        case .notInstalled:
            return "Not Installed"
        case .unhealthy:
            return "Relay Unhealthy"
        case .actionFailed(let action, let exitCode):
            let verb: String
            switch action {
            case .start: verb = "Start"
            case .stop: verb = "Stop"
            case .restart: verb = "Restart"
            }
            return "\(verb) Failed · Exit \(exitCode)"
        }
    }

    public static func iconName(
        state: RelayState,
        activeAction: RelayAction?
    ) -> String {
        if activeAction != nil || state == .checking {
            return "arrow.triangle.2.circlepath"
        }

        switch state {
        case .running:
            return "bolt.circle.fill"
        case .stopped:
            return "bolt.slash.circle"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .notInstalled, .unhealthy, .actionFailed:
            return "exclamationmark.triangle"
        }
    }
}
