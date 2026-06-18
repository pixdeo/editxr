import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if os(Windows)
import WinSDK
#endif

/// The single seam where terminal OS-primitives live. macOS/Linux keep their
/// exact POSIX behaviour (termios / ioctl / DispatchSource / SIGWINCH), moved
/// here verbatim; Windows uses the console API + a reader thread + size polling.
/// Call sites stay platform-agnostic — see PORTING_TO_WINDOWS.md.
enum PlatformTerminal {

#if os(Windows)
    // MARK: Windows (WinSDK console API)

    private static var savedInMode: DWORD = 0
    private static var savedOutMode: DWORD = 0
    private static var hasSaved = false

    /// Raw input (no echo/line/Ctrl-C, VT input on) + VT output processing.
    static func enableRawMode() {
        let hIn = GetStdHandle(STD_INPUT_HANDLE)
        let hOut = GetStdHandle(STD_OUTPUT_HANDLE)
        var inMode: DWORD = 0, outMode: DWORD = 0
        GetConsoleMode(hIn, &inMode)
        GetConsoleMode(hOut, &outMode)
        savedInMode = inMode
        savedOutMode = outMode
        hasSaved = true

        inMode &= ~DWORD(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT)
        inMode |= DWORD(ENABLE_VIRTUAL_TERMINAL_INPUT)
        SetConsoleMode(hIn, inMode)

        outMode |= DWORD(ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN)
        SetConsoleMode(hOut, outMode)
    }

    /// Restore the console modes captured by enableRawMode().
    static func disableRawMode() {
        guard hasSaved else { return }
        SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), savedInMode)
        SetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), savedOutMode)
    }

    static func terminalSize() -> (width: Int, height: Int) {
        var info = CONSOLE_SCREEN_BUFFER_INFO()
        if GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &info) {
            let w = Int(info.srWindow.Right - info.srWindow.Left) + 1
            let h = Int(info.srWindow.Bottom - info.srWindow.Top) + 1
            return (w, h)
        }
        return (80, 24)
    }

    /// No SIGINT/SIGTSTP on Windows; raw mode already swallows Ctrl-C/Ctrl-Z.
    static func ignoreSuspendSignals() {}

    /// Background thread blocking on the console input handle, dispatching the
    /// bytes (VT-encoded, since ENABLE_VIRTUAL_TERMINAL_INPUT is set) to .main.
    static func startInputLoop(_ onData: @escaping (Data) -> Void) -> AnyObject {
        let thread = Thread {
            let hIn = GetStdHandle(STD_INPUT_HANDLE)
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                var read: DWORD = 0
                let ok = buf.withUnsafeMutableBytes {
                    ReadFile(hIn, $0.baseAddress, DWORD($0.count), &read, nil)
                }
                if !ok || read == 0 { break }
                let data = Data(buf[0..<Int(read)])
                DispatchQueue.main.async { onData(data) }
            }
        }
        thread.start()
        return thread
    }

    /// No SIGWINCH — poll the size and fire when it changes.
    static func startResizeWatch(_ onResize: @escaping () -> Void) -> AnyObject {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        var last = terminalSize()
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler {
            let cur = terminalSize()
            if cur != last { last = cur; onResize() }
        }
        timer.resume()
        return timer as AnyObject
    }

#else
    // MARK: POSIX (macOS / Linux) — the existing code, moved verbatim.

    static func enableRawMode() {
        var tattr = termios()
        tcgetattr(STDIN_FILENO, &tattr)
        tattr.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        tattr.c_iflag &= ~tcflag_t(IXON | IXOFF | ICRNL | INLCR | IGNCR)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &tattr)
    }

    static func disableRawMode() {
        var tattr = termios()
        tcgetattr(STDIN_FILENO, &tattr)
        tattr.c_lflag |= tcflag_t(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &tattr)
    }

    static func terminalSize() -> (width: Int, height: Int) {
        var size = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0 {
            return (Int(size.ws_col), Int(size.ws_row))
        }
        return (80, 24)
    }

    static func ignoreSuspendSignals() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTSTP, SIG_IGN)
    }

    static func startInputLoop(_ onData: @escaping (Data) -> Void) -> AnyObject {
        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        source.setEventHandler {
            let data = FileHandle.standardInput.availableData
            if !data.isEmpty { onData(data) }
        }
        source.resume()
        return source as AnyObject
    }

    static func startResizeWatch(_ onResize: @escaping () -> Void) -> AnyObject {
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        source.setEventHandler { onResize() }
        source.resume()
        return source as AnyObject
    }
#endif
}
