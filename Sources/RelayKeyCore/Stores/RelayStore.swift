import Foundation
import Observation
import OSLog

@MainActor
@Observable
public final class RelayStore {
    public private(set) var state: RelayState = .checking
    public private(set) var activeAction: RelayAction?
    public private(set) var modelSelection: ModelSelection?
    public private(set) var isSelectingModel = false
    public private(set) var modelSelectionFailed = false

    public var statusLine: String {
        RelayStatusPresentation.statusLine(state: state, activeAction: activeAction)
    }

    public var iconName: String {
        RelayStatusPresentation.iconName(state: state, activeAction: activeAction)
    }

    public var showsStart: Bool {
        switch state {
        case .stopped, .notInstalled:
            return true
        default:
            return false
        }
    }

    public var showsStopAndRestart: Bool {
        switch state {
        case .running, .unhealthy, .actionFailed:
            return true
        default:
            return false
        }
    }

    public var canStart: Bool {
        activeAction == nil && !isSelectingModel && state == .stopped
    }

    public var canStopOrRestart: Bool {
        guard activeAction == nil && !isSelectingModel else { return false }
        switch state {
        case .running, .unhealthy, .actionFailed:
            return true
        default:
            return false
        }
    }

    public var canRefresh: Bool {
        activeAction == nil && !isSelectingModel
    }

    public var canSelectModel: Bool {
        guard case .running = state else { return false }
        return activeAction == nil && !isSelectingModel
            && modelSelection?.isAvailable == true
    }

    public var canCopyBaseURL: Bool { true }

    public var canOpenLog: Bool {
        FileManager.default.fileExists(atPath: paths.logURL.path)
    }

    public var paths: Paths { controllerPaths }

    private let controller: RelayController
    private let controllerPaths: Paths
    private let logger = Logger(
        subsystem: "local.gabriel.relay-key",
        category: "RelayStore"
    )
    private var refreshGeneration = 0
    private var pollingTask: Task<Void, Never>?
    private var holdFailureUntilUserAction = false

    public init(controller: RelayController, paths: Paths) {
        self.controller = controller
        self.controllerPaths = paths
    }

    public func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func refresh() async {
        guard activeAction == nil && !isSelectingModel else { return }
        if holdFailureUntilUserAction, case .actionFailed = state {
            return
        }

        refreshGeneration &+= 1
        let generation = refreshGeneration
        let previous = state
        let snapshot = await controller.currentSnapshot()
        guard generation == refreshGeneration,
              activeAction == nil, !isSelectingModel else { return }
        if holdFailureUntilUserAction, case .actionFailed = state {
            return
        }
        state = snapshot.state
        modelSelection = snapshot.modelSelection
        if previous != snapshot.state {
            logger.info("state \(String(describing: snapshot.state), privacy: .public)")
        }
    }

    public func perform(_ action: RelayAction) {
        if activeAction != nil || isSelectingModel { return }
        if case .notInstalled = state { return }
        if !FileManager.default.isExecutableFile(atPath: controllerPaths.cliURL.path) {
            state = .notInstalled
            return
        }

        holdFailureUntilUserAction = false
        activeAction = action
        logger.info("action \(action.rawValue, privacy: .public)")

        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.controller.perform(action)
            self.activeAction = nil

            if outcome.exitCode != 0 {
                self.state = .actionFailed(action, exitCode: outcome.exitCode)
                self.holdFailureUntilUserAction = true
                self.logger.info(
                    "exit \(outcome.exitCode, privacy: .public) action \(action.rawValue, privacy: .public)"
                )
                await self.refreshAfterActionPreservingFailure()
            } else {
                self.holdFailureUntilUserAction = false
                await self.refresh()
            }
        }
    }

    public func userRefresh() {
        holdFailureUntilUserAction = false
        modelSelectionFailed = false
        Task { await refresh() }
    }

    public func selectModel(_ model: String?) {
        guard canSelectModel else { return }
        if let model, modelSelection?.models.contains(model) != true { return }
        guard FileManager.default.isExecutableFile(atPath: controllerPaths.cliURL.path) else {
            state = .notInstalled
            modelSelection = nil
            return
        }

        isSelectingModel = true
        modelSelectionFailed = false
        refreshGeneration &+= 1
        logger.info("model selection started")

        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.controller.selectModel(model)
            if outcome.exitCode != 0 {
                self.isSelectingModel = false
                self.modelSelectionFailed = true
                self.logger.info("model selection exit \(outcome.exitCode, privacy: .public)")
                return
            }

            let snapshot = await self.controller.currentSnapshot()
            self.isSelectingModel = false
            self.state = snapshot.state
            self.modelSelection = snapshot.modelSelection
            self.modelSelectionFailed = snapshot.modelSelection?.isAvailable != true
                || snapshot.modelSelection?.selected != model
            if self.modelSelectionFailed {
                self.logger.info("model selection readback failed")
            }
        }
    }

    private func refreshAfterActionPreservingFailure() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        _ = await controller.currentSnapshot()
        guard generation == refreshGeneration else { return }
        // Keep actionFailed visible until Refresh or another action.
    }
}
