import Darwin
import Foundation

final class ClientSocket {
    let fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    func readExact(_ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0

        while offset < count {
            let readCount = buffer.withUnsafeMutableBytes { pointer in
                Darwin.read(fd, pointer.baseAddress!.advanced(by: offset), count - offset)
            }
            if readCount == 0 {
                throw RFBError.socketError("client disconnected")
            }
            if readCount < 0 {
                if errno == EINTR {
                    continue
                }
                throw RFBError.socketError(String(cString: strerror(errno)))
            }
            offset += readCount
        }

        return buffer
    }

    func writeAll(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { pointer in
                Darwin.write(fd, pointer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written < 0 {
                if errno == EINTR {
                    continue
                }
                throw RFBError.socketError(String(cString: strerror(errno)))
            }
            offset += written
        }
    }

    func writeString(_ string: String) throws {
        try writeAll(Array(string.utf8))
    }
}

final class ListeningSocket {
    let fd: Int32

    init(bindAddress: String, port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw RFBError.socketError(String(cString: strerror(errno)))
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, bindAddress, &address.sin_addr) == 1 else {
            close(fd)
            throw RFBError.socketError("invalid IPv4 bind address: \(bindAddress)")
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw RFBError.socketError("bind \(bindAddress):\(port) failed: \(message)")
        }

        guard listen(fd, 8) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw RFBError.socketError("listen failed: \(message)")
        }
    }

    deinit {
        close(fd)
    }

    func acceptClient() throws -> ClientSocket {
        while true {
            let clientFD = accept(fd, nil, nil)
            if clientFD >= 0 {
                var flag: Int32 = 1
                setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &flag, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size))
                return ClientSocket(fd: clientFD)
            }
            if errno == EINTR {
                continue
            }
            throw RFBError.socketError(String(cString: strerror(errno)))
        }
    }
}
