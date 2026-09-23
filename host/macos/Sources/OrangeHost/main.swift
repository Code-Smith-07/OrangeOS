import Darwin
import Foundation
import HostProtocol
import HostHardware
import AppKit

enum RunError: Error { case arguments, unsafePath, connection, io }

func readToken(_ path: String) throws -> Data {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_uid == getuid(),
          info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
          info.st_size == 64 else { throw RunError.unsafePath }
    let fd = open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw RunError.unsafePath }
    defer { close(fd) }
    var verified = stat()
    guard fstat(fd, &verified) == 0, verified.st_ino == info.st_ino,
          verified.st_dev == info.st_dev else { throw RunError.unsafePath }
    var bytes = [UInt8](repeating: 0, count: 64)
    guard read(fd, &bytes, bytes.count) == 64 else { throw RunError.io }
    return Data(bytes)
}

func connectSocket(_ path: String) throws -> Int32 {
    var parent = stat()
    let dir = URL(fileURLWithPath:path).deletingLastPathComponent().path
    guard lstat(dir, &parent) == 0, parent.st_uid == getuid(),
          parent.st_mode & S_IFMT == S_IFDIR, parent.st_mode & 0o077 == 0 else { throw RunError.unsafePath }
    var info = stat()
    guard lstat(path, &info) == 0 else { throw RunError.connection }
    guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw RunError.unsafePath }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw RunError.connection }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let utf8 = Array(path.utf8CString)
    guard utf8.count <= MemoryLayout.size(ofValue:address.sun_path) else { close(fd); throw RunError.unsafePath }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        for (i,c) in utf8.enumerated() { raw[i] = UInt8(bitPattern:c) }
    }
    let result = withUnsafePointer(to:&address) { p in
        p.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else { close(fd); throw RunError.connection }
    var yes: Int32 = 1
    _ = setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,socklen_t(MemoryLayout.size(ofValue:yes)))
    var timeout = timeval(tv_sec:2,tv_usec:0)
    _ = setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout.size(ofValue:timeout)))
    _ = setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout.size(ofValue:timeout)))
    return fd
}

func serve(_ fd: Int32, token: Data, monitor: HardwareMonitor, consent: AudioConsent?) throws {
    var decoder = Decoder()
    var session = try Session(token:token, hardware: { monitor.current() }, audioControl: consent.map { grant in
        { device, percent in grant.apply(device: device, percent: percent) }
    })
    var input = [UInt8](repeating:0,count:4096)
    var period = ProcessInfo.processInfo.systemUptime
    var count = 0
    while true {
        let n = read(fd,&input,input.count)
        if n == 0 { return }
        if n < 0 {
            if errno == EINTR || errno == EAGAIN { continue }
            throw RunError.io
        }
        for frame in try decoder.feed(Data(input.prefix(n))) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - period >= 1 { period = now; count = 0 }
            count += 1
            guard count <= 32 else { throw RunError.io }
            let output = try session.respond(frame).encoded()
            try output.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let amount = write(fd,raw.baseAddress!.advanced(by:sent),raw.count-sent)
                    if amount < 0 && errno == EINTR { continue }
                    guard amount > 0 else { throw RunError.io }
                    sent += amount
                }
            }
            // Never log payloads, credentials or identifiers supplied by guest.
            print("orange-host: replied method=\(frame.method) request=\(frame.request)")
            fflush(stdout)
        }
    }
}

final class CompanionMenu: NSObject {
    let consent: AudioConsent
    let item: NSStatusItem
    let grantItem = NSMenuItem(title: "Allow OrangeOS to change Mac volume", action: #selector(toggleAudio), keyEquivalent: "")
    init(consent: AudioConsent) {
        self.consent = consent
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "OrangeOS Companion")
        let menu = NSMenu()
        let title = NSMenuItem(title: "OrangeOS Companion", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title)
        let scope = NSMenuItem(title: "Sound control affects this Mac", action: nil, keyEquivalent: "")
        scope.isEnabled = false; menu.addItem(scope)
        menu.addItem(.separator())
        grantItem.target = self; menu.addItem(grantItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Disconnect and quit", action: #selector(disconnect), keyEquivalent: "")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
    }
    @objc func toggleAudio() {
        consent.setAllowed(!consent.allowed)
        grantItem.state = consent.allowed ? .on : .off
    }
    @objc func disconnect() { consent.setAllowed(false); NSApplication.shared.terminate(nil) }
}

func runConnections(path: String, token: Data, monitor: HardwareMonitor, consent: AudioConsent?) throws {
    while true {
        let fd: Int32
        do { fd = try connectSocket(path) }
        catch RunError.connection { Thread.sleep(forTimeInterval:0.25); continue }
        do { try serve(fd,token:token,monitor:monitor,consent:consent) }
        catch { fputs("orange-host: rejected session or transport failure\n",stderr) }
        close(fd)
        Thread.sleep(forTimeInterval:0.25)
    }
}

do {
    let args = CommandLine.arguments
    if args.count == 2 && args[1] == "--verify-audio-write" {
        let result = AudioPower.verifyUnchangedVolumeWrite()
        print("CoreAudio unchanged-level write/readback: \(result)")
        exit(result == "applied" ? 0 : 1)
    }
    if args.count == 2 && args[1] == "--probe-hardware" {
        let monitor = HardwareMonitor()
        let deadline = Date().addingTimeInterval(5)
        while monitor.current().freshness == "unavailable" && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        print(String(decoding: try encoder.encode(monitor.current()), as: UTF8.self))
        exit(0)
    }
    let controls = args.count == 6 && args[5] == "--controls"
    guard (args.count == 5 || controls), args[1] == "--socket", args[3] == "--token-file" else { throw RunError.arguments }
    let token = try readToken(args[4])
    _ = try Session(token: token)
    let consent = AudioConsent()
    let monitor = HardwareMonitor(audioConsent: consent)
    print(controls ? "orange-host: sound control requires a live grant in the Mac menu bar" : "orange-host: read-only companion; host mutations disabled")
    fflush(stdout)
    if controls {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let menu = CompanionMenu(consent: consent)
        Thread.detachNewThread {
            do { try runConnections(path: args[2], token: token, monitor: monitor, consent: consent) }
            catch { fputs("orange-host: unsafe session path\n", stderr); exit(1) }
        }
        withExtendedLifetime(menu) { app.run() }
    } else {
        try runConnections(path: args[2], token: token, monitor: monitor, consent: nil)
    }
} catch {
    fputs("orange-host: invalid arguments or unsafe session files\n",stderr)
    exit(1)
}
