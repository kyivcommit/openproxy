import Dispatch
import Foundation
import OpenProxyCore

/// The root launch daemon. It accepts one connection contract from the OpenProxy app and
/// performs exactly one privileged operation: adding or removing the managed `/etc/hosts`
/// line. Nothing caller-supplied (script, command, path) is ever executed or written.
@main
enum OpenProxyHelper {
    static func main() {
        let delegate = HelperDelegate()
        let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
        // Only a process signed as the OpenProxy app may connect.
        listener.setConnectionCodeSigningRequirement(HelperConstants.connectionRequirement)
        listener.delegate = delegate
        listener.resume()
        dispatchMain()
    }
}

private final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = HelperService()
        return true
    }
}

private final class HelperService: NSObject, HelperProtocol {
    func setHostsEntry(present: Bool, reply: @escaping (String?) -> Void) {
        do {
            try HostsFileEditor.apply(present: present, hostsPath: "/etc/hosts")
            Self.flushDNSCache()
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    private static func flushDNSCache() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        process.arguments = ["-flushcache"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Best effort: the hosts change is what matters; a failed flush only delays DNS.
        }
    }
}
