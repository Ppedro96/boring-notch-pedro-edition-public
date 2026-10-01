import AppKit
import Combine
import Foundation

@MainActor
final class PedroProxmoxProvider: ObservableObject {
    static let shared = PedroProxmoxProvider()

    @Published private(set) var snapshot = PedroProxmoxSnapshot.empty
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?

    private let target = PedroOpsSSHTarget(
        id: "proxmox",
        title: "Proxmox LAB",
        hostAlias: PedroLocalConfiguration.sshHost("pedro_ssh_proxmox", fallback: "root@proxmox.example.invalid"),
        iconName: "server.rack"
    )
    private var timer: Timer?
    private var appActiveObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    func start() {
        refresh()
        guard timer == nil else { return }

        let refreshTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer

        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let appActiveObserver {
            NotificationCenter.default.removeObserver(appActiveObserver)
            self.appActiveObserver = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let target = target

        DispatchQueue.global(qos: .utility).async {
            let command = PedroOpsSSHRunner.remoteCommand(for: Self.remoteProbeScript)
            let result = PedroOpsSSHRunner().status(for: target, remoteCommand: command)
            let nextSnapshot: PedroProxmoxSnapshot
            if result.isReachable {
                nextSnapshot = PedroProxmoxSnapshotParser.parse(output: result.output)
            } else {
                nextSnapshot = PedroProxmoxSnapshot(
                    host: nil,
                    guests: [],
                    errorMessage: result.errorMessage ?? "SSH indisponível"
                )
            }

            DispatchQueue.main.async {
                self.snapshot = nextSnapshot
                self.lastUpdated = nextSnapshot.errorMessage == nil ? Date() : self.lastUpdated
                self.isLoading = false
            }
        }
    }

    nonisolated private static let remoteProbeScript = """
    node_name=$(hostname 2>/dev/null || printf lab)
    printf '__HOST__\\n'
    pvesh get /nodes/$node_name/status --output-format json 2>/dev/null
    printf '\\n__GUESTS__\\n'
    pvesh get /cluster/resources --type vm --output-format json 2>/dev/null
    printf '\\n__THERMALS__\\n'
    read _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
    total1=$((u1+n1+s1+i1+w1+q1+sq1+st1))
    idle1=$((i1+w1))
    sleep 1
    read _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
    delta=$((u2+n2+s2+i2+w2+q2+sq2+st2-total1))
    if [ "$delta" -gt 0 ]; then
        printf 'cpu_percent=%s\\n' "$(( (100*(delta-i2-w2+idle1)+delta/2)/delta ))"
    fi
    cpu_temp=$(sensors 2>/dev/null | awk '
    /Package id 0:/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^\\+[0-9.]+/) {
                gsub(/^\\+/, "", $i)
                printf "%d", $i + 0
                exit
            }
        }
    }')
    gpu_temp=$(sensors 2>/dev/null | awk '
    /nouveau-pci|nvidia-pci/ { gpu_section = 1; next }
    gpu_section && /temp1:/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^\\+[0-9.]+/) {
                gsub(/^\\+/, "", $i)
                printf "%d", $i + 0
                exit
            }
        }
    }')
    gpu_line=$(lspci -nn 2>/dev/null | awk '/NVIDIA Corporation/ && (/VGA compatible controller/ || /3D controller/) { print; exit }')
    gpu_slot=$(printf '%s' "$gpu_line" | awk '{print $1}')
    gpu_driver=$(basename "$(readlink /sys/bus/pci/devices/0000:$gpu_slot/driver 2>/dev/null)" 2>/dev/null)
    gpu_guest=
    if [ "$gpu_driver" = vfio-pci ] && [ -n "$gpu_slot" ]; then
        for config in /etc/pve/qemu-server/*.conf; do
            if awk -v slot="$gpu_slot" '/^hostpci/ && index($0, slot) { found=1 } END { exit !found }' "$config"; then
                vm_id=$(basename "$config" .conf)
                vm_name=$(sed -n 's/^name: //p' "$config")
                gpu_guest="VM $vm_id · $vm_name"
                break
            fi
        done
    fi
    if [ -z "$gpu_temp" ]; then
        gpu_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | awk 'NR==1 && $1 ~ /^[0-9]+$/ {print $1}')
    fi
    gpu_name=$(printf '%s\\n' "$gpu_line" | sed -n 's/.*\\[GeForce \\([^]]*\\)\\].*/\\1/p')
    if [ -z "$gpu_name" ]; then
        gpu_name=$(printf '%s\\n' "$gpu_line" | sed -n 's/.*NVIDIA Corporation \\([^[]*\\).*/\\1/p' | sed 's/[[:space:]]*$//')
    fi
    gpu_memory_gb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk 'NR == 1 { printf "%d", ($1 + 512) / 1024 }')
    if [ -z "$gpu_memory_gb" ]; then
        case "$gpu_line" in
            *"[10de:1c82]"*) gpu_memory_gb=4 ;;
        esac
    fi
    printf 'cpu_temp=%s\\n' "$cpu_temp"
    printf 'gpu_temp=%s\\n' "$gpu_temp"
    printf 'gpu_name=%s\\n' "$gpu_name"
    printf 'gpu_memory_gb=%s\\n' "$gpu_memory_gb"
    printf 'gpu_driver=%s\\n' "$gpu_driver"
    printf 'gpu_guest=%s\\n' "$gpu_guest"
    """
}
