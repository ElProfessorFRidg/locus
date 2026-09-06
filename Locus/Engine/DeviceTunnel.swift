import Foundation

/// Addresses for the loopback tunnel the developer service is reached over.
///
/// The device is given `deviceIP` on the tunnel interface and talks to *itself*
/// at `targetIP`; the packet provider swaps the two on the way through. These
/// defaults match LocalDevVPN's, so a tunnel raised by either app is
/// interchangeable and Locus can use whichever is already up.
enum TunnelConfig {
    static let defaultDeviceIP = "10.7.0.0"
    static let defaultTargetIP = "10.7.0.1"
    static let defaultSubnetMask = "255.255.255.0"

    private enum Keys {
        static let targetIP = "locus.targetDeviceIP"
        static let deviceIP = "locus.tunnelDeviceIP"
        static let subnetMask = "locus.tunnelSubnetMask"
    }

    /// Kept for older builds that wrote the target IP under this key.
    static let defaultsKey = Keys.targetIP

    static var targetIP: String {
        stored(Keys.targetIP) ?? defaultTargetIP
    }

    static var deviceIP: String {
        stored(Keys.deviceIP) ?? defaultDeviceIP
    }

    static var subnetMask: String {
        stored(Keys.subnetMask) ?? defaultSubnetMask
    }

    static var isDefault: Bool {
        targetIP == defaultTargetIP && deviceIP == defaultDeviceIP && subnetMask == defaultSubnetMask
    }

    static func setTargetIP(_ value: String) {
        set(Keys.targetIP, value)
    }

    static func setDeviceIP(_ value: String) {
        set(Keys.deviceIP, value)
    }

    static func setSubnetMask(_ value: String) {
        set(Keys.subnetMask, value)
    }

    static func resetToDefaults() {
        [Keys.targetIP, Keys.deviceIP, Keys.subnetMask].forEach {
            UserDefaults.standard.removeObject(forKey: $0)
        }
    }

    /// `true` when the string is four dotted decimal octets. Saving a malformed
    /// IP would fail much later, inside `inet_pton` in the location engine, with
    /// an error that points at the wrong thing.
    static func isValidIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let octet = Int(part) else { return false }
            return (0...255).contains(octet)
        }
    }

    private static func stored(_ key: String) -> String? {
        let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func set(_ key: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(trimmed, forKey: key)
        }
    }
}
