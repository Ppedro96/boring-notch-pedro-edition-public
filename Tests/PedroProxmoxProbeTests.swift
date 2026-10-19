import Foundation

@main
struct PedroProxmoxProbeTests {
    static func main() throws {
        let syntaxCheck = Process()
        syntaxCheck.executableURL = URL(fileURLWithPath: "/bin/sh")
        syntaxCheck.arguments = ["-n", "-c", PedroProxmoxProvider.remoteProbeScript]
        try syntaxCheck.run()
        syntaxCheck.waitUntilExit()
        precondition(syntaxCheck.terminationStatus == 0, "Proxmox probe must be valid POSIX shell")

        if CommandLine.arguments.contains("--live") {
            for node in PedroProxmoxNode.allCases {
                let result = PedroOpsSSHRunner().status(
                    for: node.target,
                    remoteCommand: PedroOpsSSHRunner.remoteCommand(for: PedroProxmoxProvider.remoteProbeScript)
                )
                precondition(result.isReachable, "\(node.title) SSH failed: \(result.errorMessage ?? "unknown")")
                let snapshot = PedroProxmoxSnapshotParser.parse(output: result.output, hostName: node.rawValue)
                precondition(snapshot.errorMessage == nil, snapshot.errorMessage ?? "")
                let host = snapshot.host!
                precondition(host.name == node.rawValue && host.gpuName != nil)
                if node == .pveo2 {
                    precondition(host.cpuTemperature != nil && host.gpuTemperature != nil)
                    precondition(host.gpuName == "Radeon Cedar" && host.gpuMemoryGB == 2)
                    precondition(snapshot.containers.map(\.id) == [111, 112])
                }
                print("\(node.title): \(host.cpuModel), CPU \(host.cpuUsagePercent)% / \(host.cpuTemperature.map(String.init) ?? "--") C, RAM \(host.memoryLabel), SSD \(host.storageLabel), GPU \(host.gpuName ?? "--") / \(host.gpuMemoryGB.map(String.init) ?? "--") GB / \(host.gpuTemperature.map(String.init) ?? "--") C, CTs \(snapshot.containers.map(\.id)), VMs \(snapshot.virtualMachines.map(\.id))")
            }
        }
        print("PedroProxmoxProbeTests passed")
    }
}
