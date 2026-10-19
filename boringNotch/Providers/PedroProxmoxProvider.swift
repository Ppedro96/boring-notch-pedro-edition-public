import AppKit
import Combine
import Foundation

@MainActor
final class PedroProxmoxProvider: ObservableObject {
    static let shared = PedroProxmoxProvider()

    @Published private var fleet: PedroProxmoxFleetState
    private let defaults: UserDefaults
    private static let selectedNodeKey = "pedroProxmoxSelectedNode"

    var snapshot: PedroProxmoxSnapshot { fleet.snapshot }
    var isLoading: Bool { fleet.isLoading }
    var lastUpdated: Date? { fleet.lastUpdated }
    var selectedNode: PedroProxmoxNode { fleet.selectedNode }
    private var timer: Timer?
    private var appActiveObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let node = defaults.string(forKey: Self.selectedNodeKey).flatMap(PedroProxmoxNode.init(rawValue:)) ?? .lab
        fleet = PedroProxmoxFleetState(selectedNode: node)
    }

    func select(_ node: PedroProxmoxNode) {
        guard node != selectedNode else { return }
        fleet.select(node)
        defaults.set(node.rawValue, forKey: Self.selectedNodeKey)
        refresh()
    }

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
        let node = selectedNode
        guard fleet.beginRefresh(for: node) else { return }
        let target = node.target

        DispatchQueue.global(qos: .utility).async {
            let command = PedroOpsSSHRunner.remoteCommand(for: Self.remoteProbeScript)
            let result = PedroOpsSSHRunner().status(for: target, remoteCommand: command)
            let nextSnapshot: PedroProxmoxSnapshot
            if result.isReachable {
                nextSnapshot = PedroProxmoxSnapshotParser.parse(output: result.output, hostName: node.rawValue)
            } else {
                nextSnapshot = PedroProxmoxSnapshot(
                    host: nil,
                    guests: [],
                    errorMessage: result.errorMessage ?? "SSH indisponível"
                )
            }

            DispatchQueue.main.async {
                self.fleet.finishRefresh(for: node, snapshot: nextSnapshot, at: Date())
            }
        }
    }

    nonisolated static let remoteProbeScript = """
    node_name=$(hostname 2>/dev/null || printf lab)
    printf '__HOST__\\n'
    pvesh get /nodes/$node_name/status --output-format json 2>/dev/null
    printf '\\n__GUESTS__\\n'
    pvesh get /cluster/resources --type vm --output-format json 2>/dev/null
    printf '\\n__THERMALS__\\n'
    printf 'node_name=%s\\n' "$node_name"
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
    if [ -z "$cpu_temp" ]; then
        for sensor in /sys/class/hwmon/hwmon*; do
            sensor_name=$(cat "$sensor/name" 2>/dev/null)
            case "$sensor_name" in
                k10temp|coretemp)
                    for reading in "$sensor"/temp*_input; do
                        label=$(cat "${reading%_input}_label" 2>/dev/null)
                        case "$label" in
                            Tdie|Tctl|"Package id 0")
                                cpu_temp=$(awk '{printf "%d", $1 / 1000}' "$reading" 2>/dev/null)
                                break ;;
                        esac
                    done
                    [ -n "$cpu_temp" ] && break ;;
            esac
        done
    fi
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
    gpu_line=$(lspci -nn 2>/dev/null | awk '/VGA compatible controller|3D controller|Display controller/ { print; exit }')
    gpu_slot=$(printf '%s' "$gpu_line" | awk '{print $1}')
    gpu_address="0000:$gpu_slot"
    gpu_driver=$(basename "$(readlink /sys/bus/pci/devices/$gpu_address/driver 2>/dev/null)" 2>/dev/null)
    if [ -z "$gpu_temp" ]; then
        for reading in /sys/bus/pci/devices/$gpu_address/hwmon/hwmon*/temp1_input; do
            [ -r "$reading" ] || continue
            gpu_temp=$(awk '{printf "%d", $1 / 1000}' "$reading")
            break
        done
    fi
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
    if [ -z "$gpu_name" ]; then
        gpu_name=$(printf '%s\\n' "$gpu_line" | sed -n 's/.*AMD\\/ATI] \\([^[]*\\).*/Radeon \\1/p' | sed 's/[[:space:]]*$//')
    fi
    if [ -z "$gpu_name" ]; then
        gpu_name=$(printf '%s\\n' "$gpu_line" | sed 's/^[^:]*:..\\.[0-9] [^:]*: //; s/ \\[.*//')
    fi
    gpu_memory_gb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk 'NR == 1 { printf "%d", ($1 + 512) / 1024 }')
    if [ -z "$gpu_memory_gb" ]; then
        case "$gpu_line" in
            *"[10de:1c82]"*) gpu_memory_gb=4 ;;
        esac
    fi
    if [ -z "$gpu_memory_gb" ] && [ -r "/sys/bus/pci/devices/$gpu_address/mem_info_vram_total" ]; then
        gpu_memory_gb=$(awk '{printf "%d", ($1 + 536870912) / 1073741824}' "/sys/bus/pci/devices/$gpu_address/mem_info_vram_total")
    fi
    if [ -z "$gpu_memory_gb" ] && [ "$gpu_driver" = radeon ]; then
        gpu_memory_gb=$(journalctl -k -b --no-pager -o cat -n 1 -g "radeon $gpu_address: VRAM:" 2>/dev/null | awk '/VRAM:/ { for (i=1; i<NF; i++) if ($i == "VRAM:") { printf "%d", ($(i+1) + 512) / 1024; exit } }')
    fi
    printf 'cpu_temp=%s\\n' "$cpu_temp"
    printf 'gpu_temp=%s\\n' "$gpu_temp"
    printf 'gpu_name=%s\\n' "$gpu_name"
    printf 'gpu_memory_gb=%s\\n' "$gpu_memory_gb"
    printf 'gpu_driver=%s\\n' "$gpu_driver"
    printf 'gpu_guest=%s\\n' "$gpu_guest"
    """
}
