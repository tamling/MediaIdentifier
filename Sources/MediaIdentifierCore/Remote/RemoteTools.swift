import Foundation

/// Finds the programs that do the transferring.
///
/// Absolute paths only, never a bare name resolved through `PATH`. Mediafin
/// may run as a systemd service whose `PATH` is whatever the unit inherited,
/// and a service that executes the first `rsync` it happens to find is a
/// service that can be made to execute something else.
public struct RemoteTools: Sendable, Equatable {
    public let rsync: String?
    public let sftp: String?
    public let ssh: String?
    public let sshpass: String?

    public init(rsync: String?, sftp: String?, ssh: String?, sshpass: String?) {
        self.rsync = rsync
        self.sftp = sftp
        self.ssh = ssh
        self.sshpass = sshpass
    }

    /// The usual locations, in the order a distribution would install them.
    public static let searchPaths = ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"]

    public static func locate(
        in directories: [String] = searchPaths,
        fileManager: FileManager = .default
    ) -> RemoteTools {
        func find(_ name: String) -> String? {
            for directory in directories {
                let path = directory + "/" + name
                if fileManager.isExecutableFile(atPath: path) { return path }
            }
            return nil
        }
        return RemoteTools(rsync: find("rsync"), sftp: find("sftp"),
                           ssh: find("ssh"), sshpass: find("sshpass"))
    }

    /// What is missing for a given configuration, named so the message can
    /// tell the user what to install rather than that something failed.
    public func missing(for target: RemoteTarget) -> [String] {
        var absent: [String] = []
        switch target.transport {
        case .rsync:
            if rsync == nil { absent.append("rsync") }
            if ssh == nil { absent.append("openssh-client") }
        case .sftp:
            if sftp == nil { absent.append("openssh-client") }
        }
        if target.authentication == .password, sshpass == nil {
            absent.append("sshpass")
        }
        return absent
    }
}
