import Darwin
import Foundation
import HostProtocol

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

func serve(_ fd: Int32, token: Data) throws {
    var decoder = Decoder()
    var session = try Session(token:token)
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

do {
    let args = CommandLine.arguments
    guard args.count == 5, args[1] == "--socket", args[3] == "--token-file" else { throw RunError.arguments }
    let token = try readToken(args[4])
    _ = try Session(token: token)
    print("orange-host: read-only companion; host mutations disabled")
    fflush(stdout)
    while true {
        let fd: Int32
        do { fd = try connectSocket(args[2]) }
        catch RunError.connection { Thread.sleep(forTimeInterval:0.25); continue }
        do { try serve(fd,token:token) }
        catch { fputs("orange-host: rejected session or transport failure\n",stderr) }
        close(fd)
        Thread.sleep(forTimeInterval:0.25)
    }
} catch {
    fputs("orange-host: invalid arguments or unsafe session files\n",stderr)
    exit(1)
}
