import Foundation

/// Builds the command line that moves one file to the server.
///
/// Pure: it produces an executable path, an argument array and, for sftp, the
/// batch script to feed it. Nothing here runs anything, so every decision
/// below can be tested without a server — and those decisions are where the
/// bugs are. A path with a space in it, a non-standard port silently dropped,
/// a host key check quietly disabled: all of them look like working code and
/// none of them show up until someone's library is involved.
public enum RemoteCommand {

    /// Everything needed to start the process.
    public struct Invocation: Equatable, Sendable {
        public let executable: String
        public let arguments: [String]
        /// Written to the process's standard input, for sftp's batch mode.
        public let standardInput: String?
        /// Added to the environment. Carries the password, which must never
        /// be an argument: anyone on the machine can read `ps`.
        public let environment: [String: String]

        public init(executable: String, arguments: [String],
                    standardInput: String? = nil,
                    environment: [String: String] = [:]) {
            self.executable = executable
            self.arguments = arguments
            self.standardInput = standardInput
            self.environment = environment
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case toolMissing(String)
        case notConfigured(String)

        public var description: String {
            switch self {
            case .toolMissing(let name):
                return "\(name) wurde nicht gefunden. Bitte installieren: sudo apt install \(name)"
            case .notConfigured(let what):
                return "Der Server ist nicht vollständig eingerichtet: \(what)"
            }
        }
    }

    // MARK: SSH options shared by both transports

    /// Options handed to ssh, whichever tool is driving it.
    ///
    /// `StrictHostKeyChecking` is deliberately **not** turned off. Accepting
    /// any key that turns up is how a transfer ends up at whatever machine
    /// answered, and it is the one setting that makes every other precaution
    /// here pointless. An unknown host fails with a message telling the user
    /// to connect once by hand, which is a minute of work and leaves the
    /// decision with the person who can actually verify the fingerprint.
    ///
    /// `BatchMode` is only safe with a key: with a password, ssh has to be
    /// allowed to ask, and sshpass answers.
    static func sshOptions(_ target: RemoteTarget) -> [String] {
        var options = [
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=15",
            // Nothing interactive can work here: there is no terminal to
            // type into, so a prompt would simply hang the transfer.
            "-o", "NumberOfPasswordPrompts=1",
        ]
        if target.authentication == .key {
            options += ["-o", "BatchMode=yes"]
            if !target.identityFile.isEmpty {
                // IdentitiesOnly, or ssh offers every key the agent holds and
                // can be refused for too many attempts before reaching this
                // one.
                options += ["-i", target.identityFile, "-o", "IdentitiesOnly=yes"]
            }
        } else {
            options += ["-o", "PubkeyAuthentication=no",
                        "-o", "PreferredAuthentications=password,keyboard-interactive"]
        }
        return options
    }

    /// The remote path a local file should land on, below the configured base.
    ///
    /// `relativePath` is what the planner produced — `Serien/Dark/Staffel 01/
    /// Dark - S01E01.mkv`. It is joined rather than concatenated so a base
    /// with or without a trailing slash behaves the same.
    public static func remotePath(_ relativePath: String, under base: String) -> String {
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let trimmedPath = relativePath.hasPrefix("/")
            ? String(relativePath.dropFirst()) : relativePath
        return "\(trimmedBase)/\(trimmedPath)"
    }

    // MARK: rsync

    /// `rsync -e ssh …` for one file.
    public static func rsync(_ target: RemoteTarget,
                             localFile: URL,
                             relativePath: String,
                             rsyncPath: String,
                             sshPath: String,
                             password: String?) throws -> Invocation {
        guard !target.host.isEmpty, !target.basePath.isEmpty else {
            throw Failure.notConfigured("Adresse oder Zielpfad fehlt")
        }
        let destination = remotePath(relativePath, under: target.basePath)

        // The ssh command rsync should use. rsync splits this on spaces, so
        // it must not contain a path with one — an identity file in a folder
        // with a space would break here and nowhere else.
        var sshCommand = ([sshPath, "-p", String(target.port)] + sshOptions(target))
            .joined(separator: " ")
        if target.authentication == .password {
            sshCommand = "sshpass -e " + sshCommand
        }

        let arguments = [
            "--archive",             // keep times and permissions
            "--partial",             // keep a half-sent file so it can resume
            // Creates Serien/Name/Staffel on the way. rsync 3.2.3 and newer;
            // the caller checks the version, because on an older rsync this
            // fails with "unknown option" rather than anything about paths.
            "--mkpath",
            "--protect-args",        // remote paths are not re-split by a shell
            "--info=progress2",      // one machine-readable progress line
            "-e", sshCommand,
            localFile.path,
            "\(target.destination):\(destination)",
        ]

        if target.authentication == .password {
            guard let password, !password.isEmpty else {
                throw Failure.notConfigured("Passwort fehlt")
            }
            // Through the environment, never as an argument.
            return Invocation(executable: rsyncPath, arguments: arguments,
                              environment: ["SSHPASS": password])
        }
        return Invocation(executable: rsyncPath, arguments: arguments)
    }

    // MARK: sftp

    /// `sftp -b -` for one file, with the batch script on standard input.
    ///
    /// sftp has no "create the parents" switch, so the script makes each
    /// directory in turn. A `-` prefix tells sftp to carry on when a command
    /// fails, which is what should happen when a directory is already there —
    /// the alternative is asking first, which costs a round trip per level.
    public static func sftp(_ target: RemoteTarget,
                            localFile: URL,
                            relativePath: String,
                            sftpPath: String,
                            password: String?) throws -> Invocation {
        guard !target.host.isEmpty, !target.basePath.isEmpty else {
            throw Failure.notConfigured("Adresse oder Zielpfad fehlt")
        }
        let destination = remotePath(relativePath, under: target.basePath)
        let directory = (destination as NSString).deletingLastPathComponent

        var script = ""
        for level in parentDirectories(of: directory) {
            script += "-mkdir \(quote(level))\n"
        }
        script += "put \(quote(localFile.path)) \(quote(destination))\n"
        script += "bye\n"

        var arguments = ["-b", "-", "-P", String(target.port)]
        arguments += sshOptions(target)
        arguments.append(target.destination)

        if target.authentication == .password {
            guard let password, !password.isEmpty else {
                throw Failure.notConfigured("Passwort fehlt")
            }
            return Invocation(executable: "sshpass",
                              arguments: ["-e", sftpPath] + arguments,
                              standardInput: script,
                              environment: ["SSHPASS": password])
        }
        return Invocation(executable: sftpPath, arguments: arguments,
                          standardInput: script)
    }

    /// Every directory from the root down, so each can be created in turn.
    ///
    /// `/srv/media/Serien/Dark/Staffel 01` yields `/srv`, `/srv/media`, … and
    /// not just the leaf: sftp's mkdir makes one level at a time.
    static func parentDirectories(of path: String) -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        var result: [String] = []
        var current = ""
        for part in parts {
            current += "/" + part
            result.append(current)
        }
        return result
    }

    /// Quotes a path for sftp's batch parser, which splits on spaces and
    /// understands double quotes.
    ///
    /// A filename with a quote in it is rare and legal, so it is escaped
    /// rather than assumed away.
    static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
