import AppKit
import PulseCore

protocol QuitApplication: AnyObject {
    var processIdentifier: pid_t { get }
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var isTerminated: Bool { get }
    func terminate() -> Bool
}

extension NSRunningApplication: QuitApplication {}

/// A graceful Quit request bound to the app instance shown in the confirmation dialog.
@MainActor
public struct AppQuitRequest {
    public enum Outcome: Equatable { case requested, changed, refused }

    public let id: ProcessID
    public let name: String
    private let application: any QuitApplication

    public init?(row: ProcessRow) {
        self.init(row: row, lookup: { NSRunningApplication(processIdentifier: $0) })
    }

    init?(row: ProcessRow, lookup: (pid_t) -> (any QuitApplication)?) {
        guard row.uid == getuid(), row.pid != getpid(), let app = lookup(row.pid),
              app.processIdentifier == row.pid, app.activationPolicy == .regular, !app.isTerminated
        else { return nil }
        id = row.id
        name = row.name
        application = app
    }

    public func send(using sampler: MacSampler) async -> Outcome {
        await send { id in await sampler.isCurrentUserAppProcess(id) }
    }

    func send(ifCurrentOwner: (ProcessID) async -> Bool) async -> Outcome {
        guard await ifCurrentOwner(id), application.processIdentifier == id.pid,
              application.activationPolicy == .regular, !application.isTerminated
        else { return .changed }
        // The PID can change hands even after validation. AppKit addresses this retained instance.
        return application.terminate() ? .requested : .refused
    }
}
