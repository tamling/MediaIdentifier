import Foundation
import CMediafinTerm
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The terminal itself: raw keys in, frames out, and the promise that the
/// shell is left exactly as it was found.
///
/// That promise is the hard part. A program that puts a terminal into raw
/// mode and then dies without restoring it leaves a shell with no echo and
/// no line editing — the user types and nothing appears, and the only way
/// out is `reset`, blind. So the restore runs from `atexit`, from the
/// signal handlers, and from `deinit`, and it is written to be safe to run
/// more than once.
public final class Terminal {

    /// What a key press was.
    public enum Key: Equatable {
        case character(Character)
        case up, down, left, right, pageUp, pageDown, home, end
        case enter, escape, backspace
        /// The terminal was resized; the caller should measure and redraw.
        case resized
        /// Nothing arrived before the timeout. The caller uses these to
        /// refresh on a clock without a second thread.
        case timeout
    }

    private var original = termios()
    private var isRaw = false
    /// The last frame, so only the rows that changed are written. A full
    /// 24-row redraw twice a second flickers on a slow link; over SSH on a
    /// phone tether it is unusable.
    private var previous: [String] = []

    public init() {}

    deinit { restore() }

    // MARK: Measuring

    /// The terminal's size, or the 80×24 fallback when stdout is not a
    /// terminal — a pipe, a file, a cron job.
    public static func size() -> ScreenSize {
        var columns: Int32 = 0
        var rows: Int32 = 0
        guard mediafin_terminal_size(&columns, &rows) == 0 else {
            return .fallback
        }
        return ScreenSize(columns: Int(columns), rows: Int(rows))
    }

    /// Whether there is a terminal to draw on at all.
    public static var isInteractive: Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    // MARK: Starting and stopping

    public func start() {
        guard Terminal.isInteractive, !isRaw else { return }
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        // Not cfmakeraw: that also clears OPOST, which turns "\n" into a
        // bare line feed and leaves every line starting where the last one
        // ended. The output stays cooked; only the input changes.
        // tcflag_t and not a spelled-out width: it is UInt32 on Linux and
        // UInt on Darwin, and naming either one breaks the other.
        raw.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ICANON) | tcflag_t(ISIG))
        raw.c_iflag &= ~(tcflag_t(IXON) | tcflag_t(ICRNL))
        withUnsafeMutablePointer(to: &raw.c_cc) { cc in
            cc.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { bytes in
                bytes[Int(VMIN)] = 0     // read returns with whatever is there
                bytes[Int(VTIME)] = 1    // after at most 100 ms
            }
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        isRaw = true

        Terminal.shared = self
        atexit { Terminal.shared?.restore() }
        for signal in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            Terminal.install(signal) { code in
                Terminal.shared?.restore()
                // Re-raised with the handler removed, so the exit status is
                // the one the signal would have given. A program that exits
                // 0 after a SIGINT lies to whatever started it.
                Foundation.signal(code, SIG_DFL)
                raise(code)
            }
        }
        Terminal.install(SIGWINCH) { _ in Terminal.resized = 1 }

        write("\u{1B}[?1049h")   // the alternate screen, so the scrollback survives
        write("\u{1B}[?25l")     // hide the cursor
        write("\u{1B}[2J")
        previous = []
    }

    /// Puts the terminal back. Safe to call any number of times, from a
    /// signal handler included — which is why it writes with `write(2)` and
    /// touches nothing that allocates.
    public func restore() {
        guard isRaw else { return }
        isRaw = false
        write("\u{1B}[?25h")     // show the cursor
        write("\u{1B}[?1049l")   // leave the alternate screen
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
    }

    // MARK: Drawing

    /// Draws a frame, writing only the rows that differ from the last one.
    public func draw(_ lines: [Line], size: ScreenSize) {
        var out = ""
        for row in 0..<size.rows {
            let line = row < lines.count ? lines[row] : Line("")
            let rendered = line.ansi()
            if row < previous.count, previous[row] == rendered { continue }
            // Move, clear to end of line, write. Clearing matters: a shorter
            // line drawn over a longer one otherwise leaves the tail of the
            // old one behind.
            out += "\u{1B}[\(row + 1);1H\u{1B}[K" + rendered
        }
        if !out.isEmpty { write(out) }
        previous = (0..<size.rows).map {
            ($0 < lines.count ? lines[$0] : Line("")).ansi()
        }
    }

    /// Forgets the last frame, so the next draw writes every row. Used after
    /// a resize, where the terminal has rearranged everything itself.
    public func invalidate() { previous = [] }

    // MARK: Reading

    /// Waits for a key, for at most about `timeout` seconds.
    ///
    /// The timeout is what keeps the screen current without a second thread
    /// poking at the coordinator: the loop blocks here, wakes, redraws, and
    /// blocks again.
    public func read(timeout: TimeInterval = 0.4) -> Key {
        if Terminal.resized != 0 {
            Terminal.resized = 0
            return .resized
        }
        var deadline = timeout
        while deadline > 0 {
            var byte: UInt8 = 0
            let got = Foundation.read(STDIN_FILENO, &byte, 1)
            if got == 1 { return decode(first: byte) }
            if Terminal.resized != 0 {
                Terminal.resized = 0
                return .resized
            }
            // VTIME is a tenth of a second, so each turn of this loop has
            // already waited that long.
            deadline -= 0.1
        }
        return .timeout
    }

    private func decode(first byte: UInt8) -> Key {
        switch byte {
        case 0x0D, 0x0A: return .enter
        case 0x7F, 0x08: return .backspace
        case 0x03: return .character("q")      // Ctrl-C leaves, like q
        case 0x1B: return decodeEscape()
        default:
            guard let scalar = Unicode.Scalar(UInt32(byte)), byte >= 0x20 else {
                return .timeout
            }
            return .character(Character(scalar))
        }
    }

    /// An escape sequence, or a bare Escape when nothing follows it.
    ///
    /// The difference is only timing — Escape and the start of an arrow key
    /// are the same byte — so a key that brings nothing after it within the
    /// VTIME window is the key itself.
    private func decodeEscape() -> Key {
        var next: UInt8 = 0
        guard Foundation.read(STDIN_FILENO, &next, 1) == 1 else { return .escape }
        guard next == 0x5B || next == 0x4F else { return .escape }   // [ or O
        var third: UInt8 = 0
        guard Foundation.read(STDIN_FILENO, &third, 1) == 1 else { return .escape }
        switch third {
        case 0x41: return .up          // A
        case 0x42: return .down        // B
        // C and D were missing, so the arrow keys anybody tries first on a
        // list of choices did nothing at all.
        case 0x43: return .right       // C
        case 0x44: return .left        // D
        case 0x48: return .home        // H
        case 0x46: return .end         // F
        case 0x35, 0x36:               // 5~ / 6~, page up and page down
            var tilde: UInt8 = 0
            _ = Foundation.read(STDIN_FILENO, &tilde, 1)
            return third == 0x35 ? .pageUp : .pageDown
        default: return .escape
        }
    }

    // MARK: Writing

    private func write(_ text: String) {
        var bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer in
                Foundation.write(STDOUT_FILENO, buffer.baseAddress! + offset,
                                 bytes.count - offset)
            }
            // A short write is normal on a slow link; a failed one means the
            // terminal has gone, and there is nothing useful to do about it.
            if written <= 0 { break }
            offset += written
        }
    }

    // MARK: Signals

    /// Set from the SIGWINCH handler, so it is `sig_atomic_t` and nothing
    /// else: a handler may not allocate, lock, or call into Swift runtime.
    private nonisolated(unsafe) static var resized: sig_atomic_t = 0
    private nonisolated(unsafe) static var shared: Terminal?

    private static func install(_ code: Int32,
                                _ handler: @escaping @convention(c) (Int32) -> Void) {
        var action = sigaction()
        #if canImport(Glibc)
        action.__sigaction_handler = unsafeBitCast(
            handler, to: sigaction.__Unnamed_union___sigaction_handler.self)
        #else
        action.__sigaction_u = unsafeBitCast(
            handler, to: __sigaction_u.self)
        #endif
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(code, &action, nil)
    }
}
