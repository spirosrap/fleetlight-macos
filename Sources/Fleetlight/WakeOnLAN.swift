import Darwin
import Foundation

enum WakeOnLAN {
    static func send(macAddress: String, broadcastAddress: String = "255.255.255.255") throws {
        let mac = try parse(macAddress)
        let packet = Array(repeating: UInt8(0xff), count: 6)
            + Array(repeating: mac, count: 16).flatMap { $0 }

        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw WakeError.socketCreation }
        defer { close(descriptor) }

        var enabled: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_BROADCAST,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw WakeError.broadcastPermission
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(9).bigEndian
        guard inet_pton(AF_INET, broadcastAddress, &address.sin_addr) == 1 else {
            throw WakeError.invalidBroadcastAddress
        }

        let sent = packet.withUnsafeBytes { packetBuffer in
            withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        descriptor,
                        packetBuffer.baseAddress,
                        packetBuffer.count,
                        0,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        guard sent == packet.count else { throw WakeError.sendFailed }
    }

    private static func parse(_ address: String) throws -> [UInt8] {
        let pieces = address.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 6 else { throw WakeError.invalidMACAddress }
        let bytes = pieces.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { throw WakeError.invalidMACAddress }
        return bytes
    }
}

private enum WakeError: LocalizedError {
    case invalidMACAddress
    case invalidBroadcastAddress
    case socketCreation
    case broadcastPermission
    case sendFailed

    var errorDescription: String? {
        switch self {
        case .invalidMACAddress: "Wake MAC address must contain six hexadecimal pairs"
        case .invalidBroadcastAddress: "Wake broadcast address is not a valid IPv4 address"
        case .socketCreation: "Could not create a UDP socket"
        case .broadcastPermission: "Could not enable UDP broadcast"
        case .sendFailed: "The Wake-on-LAN packet could not be sent"
        }
    }
}
