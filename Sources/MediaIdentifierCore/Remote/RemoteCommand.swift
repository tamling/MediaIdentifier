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
        case unsafePath(String)

        public var description: String {
            switch self {
            case .toolMissing(let name):
                return "\(name) wurde nicht gefunden. Bitte installieren: sudo apt install \(name)"
            case .notConfigured(let what):
                return "Der Server ist nicht vollständig eingerichtet: \(what)"
            case .unsafePath(let what):
                return "Nicht übertragbar: \(what)"
            }
        }
    }

    // MARK: Refusing what cannot be quoted

    /// Rejects anything that would break out of the line it is written on.
    ///
    /// sftp reads its batch script a line at a time and has no escape for a
    /// newline, so a name containing one does not become a quoted name — it
    /// becomes a second command. sftp's `!` runs a shell on THIS machine, so
    /// a file called `Dark\n!curl …|sh #\nS01E01.mkv`, which any program
    /// writing into the download folder may create, would run that shell.
    /// A newline is a legal character in a Linux filename, so this is not a
    /// theoretical case; it is simply a rare one.
    ///
    /// Refused rather than escaped, because there is nothing to escape it
    /// to. The user is told which file, and can rename it.
    static func rejectingControlCharacters(_ value: String, what: String) throws -> String {
        guard !value.unicodeScalars.contains(where: {
            $0.value < 0x20 || $0.value == 0x7F
        }) else {
            throw Failure.unsafePath("\(what) enthält ein Steuerzeichen (z. B. einen "
                + "Zeilenumbruch). Bitte umbenennen.")
        }
        return value
    }

    /// The same, for a value that is spliced into rsync's `-e` string.
    ///
    /// rsync splits that string on spaces with no quoting of any kind, so a
    /// value containing one does not become an argument with a space in it —
    /// it becomes further ssh options. `-o ProxyCommand=…` is among the
    /// options that would then be honoured, and ProxyCommand runs a local
    /// shell. This is why the identity file may not contain a space.
    static func rejectingSplittableCharacters(_ value: String, what: String) throws -> String {
        _ = try rejectingControlCharacters(value, what: what)
        guard !value.contains(" "), !value.contains("\t") else {
            throw Failure.unsafePath("\(what) darf kein Leerzeichen enthalten: rsync teilt "
                + "den SSH-Befehl daran auf. Bitte an einen Pfad ohne Leerzeichen legen.")
        }
        return value
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
            // BatchMode=no is not redundant. `sftp -b` adds `-obatchmode yes`
            // of its own, and ssh keeps the *first* setting of an option it
            // sees — so without this, and without putting it ahead of `-b`,
            // ssh refuses to ask for a password at all and the login fails
            // in a tenth of a second with "Permission denied", never having
            // prompted. That is exactly what it did.
            options += ["-o", "BatchMode=no",
                        "-o", "PubkeyAuthentication=no",
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

    /// `user@host` goes into ssh's argument list as one bare word.
    ///
    /// A user name beginning with a dash is therefore read as an option,
    /// and ssh has options that run local commands. Neither field was
    /// checked anywhere: `problems()` looks at the host for spaces and
    /// slashes and at the user only for emptiness.
    static func checkDestination(_ target: RemoteTarget) throws {
        for (value, what) in [(target.user, "Der Benutzername"),
                              (target.host, "Die Serveradresse")] {
            _ = try rejectingSplittableCharacters(value, what: what)
            guard !value.hasPrefix("-") else {
                throw Failure.unsafePath("\(what) darf nicht mit einem Bindestrich "
                    + "beginnen: ssh würde das als Option lesen.")
            }
        }
    }

    /// `ssh … test -e <path>` — is that file already on the server?
    ///
    /// sftp has no "refuse an existing file" switch, so the only way to
    /// honour "skip the file" over sftp is to ask first.
    public static func exists(_ target: RemoteTarget,
                              relativePath: String,
                              sshPath: String,
                              password: String?) throws -> Invocation {
        try checkDestination(target)
        let remote = remotePath(relativePath, under: target.basePath)
        _ = try rejectingControlCharacters(remote, what: "Der Zielpfad")
        let quoted = "'" + remote.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var arguments = ["-p", String(target.port)] + sshOptions(target)
        arguments.append(target.destination)
        arguments.append("test -e \(quoted)")

        if target.authentication == .password {
            guard let password, !password.isEmpty else {
                throw Failure.notConfigured("Passwort fehlt")
            }
            return Invocation(executable: "sshpass",
                              arguments: ["-e", sshPath] + arguments,
                              environment: ["SSHPASS": password])
        }
        return Invocation(executable: sshPath, arguments: arguments)
    }

    // MARK: Checking the server

    /// `ssh … test -d <base>` — does the login work, and is the target there?
    ///
    /// Not a port check. A port that answers proves nothing useful: the
    /// three ways this actually fails in someone's house are a key the
    /// server does not know, a host key that was never confirmed, and a
    /// target path that does not exist or cannot be written. This tries all
    /// three at once and costs one connection.
    ///
    /// Writability is checked with `test -w` rather than by writing a file,
    /// because a check that leaves litter in a media library is a check
    /// people turn off.
    public static func probe(_ target: RemoteTarget,
                             sshPath: String,
                             password: String?) throws -> Invocation {
        guard !target.host.isEmpty, !target.basePath.isEmpty else {
            throw Failure.notConfigured("Adresse oder Zielpfad fehlt")
        }
        // Single-quoted for the remote shell, with embedded quotes escaped
        // the only way POSIX sh allows. The base path comes from a settings
        // field, so it is not trusted to be shell-safe.
        try checkDestination(target)
        _ = try rejectingControlCharacters(target.basePath, what: "Der Zielpfad")
        let quoted = "'" + target.basePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var arguments = ["-p", String(target.port)] + sshOptions(target)
        arguments.append(target.destination)
        arguments.append("test -d \(quoted) && test -w \(quoted)")

        if target.authentication == .password {
            guard let password, !password.isEmpty else {
                throw Failure.notConfigured("Passwort fehlt")
            }
            return Invocation(executable: "sshpass",
                              arguments: ["-e", sshPath] + arguments,
                              environment: ["SSHPASS": password])
        }
        return Invocation(executable: sshPath, arguments: arguments)
    }

    // MARK: rsync

    /// `rsync -e ssh …` for one file.
    public static func rsync(_ target: RemoteTarget,
                             localFile: URL,
                             relativePath: String,
                             rsyncPath: String,
                             sshPath: String,
                             sshpassPath: String = "sshpass",
                             password: String?,
                             keepExisting: Bool = false) throws -> Invocation {
        guard !target.host.isEmpty, !target.basePath.isEmpty else {
            throw Failure.notConfigured("Adresse oder Zielpfad fehlt")
        }
        try checkDestination(target)
        let destination = remotePath(relativePath, under: target.basePath)

        // The ssh command rsync should use. rsync splits this on spaces, so
        // it must not contain a path with one — an identity file in a folder
        // with a space would break here and nowhere else.
        // Everything that goes into the -e string is split on spaces by
        // rsync, so each piece has to survive that intact.
        _ = try rejectingSplittableCharacters(sshPath, what: "Der Pfad zu ssh")
        if target.authentication == .key, !target.identityFile.isEmpty {
            _ = try rejectingSplittableCharacters(target.identityFile,
                                                  what: "Die Schlüsseldatei")
        }
        _ = try rejectingControlCharacters(localFile.path, what: "Der Dateiname")
        _ = try rejectingControlCharacters(destination, what: "Der Zielpfad")

        var sshCommand = ([sshPath, "-p", String(target.port)] + sshOptions(target))
            .joined(separator: " ")
        if target.authentication == .password {
            // The resolved path, not the bare name: rsync runs this string
            // itself, so a bare name would be looked up in whatever PATH
            // the service inherited — which is the thing RemoteTools was
            // written to avoid, undone inside a string.
            _ = try rejectingSplittableCharacters(sshpassPath, what: "Der Pfad zu sshpass")
            sshCommand = sshpassPath + " -e " + sshCommand
        }

        var arguments = [
            "--archive",             // keep times and permissions
            // --partial-dir, not --partial. Plain --partial leaves the
            // fragment under the FINAL name, and --ignore-existing then
            // skips it on the next attempt: rsync transfers nothing, exits
            // 0, we report "sent", and with "delete the local copy" the
            // complete original is removed while the server keeps a
            // truncated file. The fragment now waits in a subdirectory and
            // is only renamed into place when it is whole.
            "--partial-dir=.mediafin-partial",
            // Creates Serien/Name/Staffel on the way. rsync 3.2.3 and
            // newer only: an older one fails with "unknown option" and says
            // nothing about paths. Nothing here can check that — this file
            // runs no processes — so two things do instead: RemoteTransfer
            // .check() reads `rsync --version` when the user tests the
            // server, and explain() turns the getopt message into a
            // sentence naming the version. The comment that used to sit
            // here claimed "the caller checks the version"; no caller did.
            "--mkpath",
            "--protect-args",        // remote paths are not re-split by a shell
            "--info=progress2",      // one machine-readable progress line
            "-e", sshCommand,
            localFile.path,
            "\(target.destination):\(destination)",
        ]
        if keepExisting {
            // "Skip the file" has to mean the server's copy survives.
            // Without this, a send silently replaced whatever was there —
            // a 700 MB web rip over a 12 GB remux, say — whatever the
            // conflict policy said.
            arguments.insert("--ignore-existing", at: 0)
        }

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
        try checkDestination(target)
        let destination = remotePath(relativePath, under: target.basePath)
        _ = try rejectingControlCharacters(localFile.path, what: "Der Dateiname")
        _ = try rejectingControlCharacters(destination, what: "Der Zielpfad")
        let directory = (destination as NSString).deletingLastPathComponent

        var script = ""
        for level in parentDirectories(of: directory) {
            script += "-mkdir \(quote(level))\n"
        }
        script += "put \(quote(localFile.path)) \(quote(destination))\n"
        script += "bye\n"

        // Our options go FIRST, ahead of `-b`. sftp appends `-obatchmode yes`
        // at the moment it parses `-b`, and ssh honours the first setting of
        // an option, so anything of ours that comes after `-b` is ignored.
        var arguments = sshOptions(target)
        arguments += ["-b", "-", "-P", String(target.port)]
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
