import SwiftUI
import Cocoa
import Foundation
import MachO
import ServiceManagement

// MARK: - Models & Metrics Sampler

struct SystemMetrics {
    var cpuUsage: Double = 0.0          // 0 - 100%
    var ramUsedBytes: Double = 0.0
    var ramTotalBytes: Double = Double(ProcessInfo.processInfo.physicalMemory)
    var swapUsedBytes: Double = 0.0
    var swapTotalBytes: Double = 0.0
    var gpuUsage: Double = 0.0          // 0 - 100%
    var netDownloadRate: Double = 0.0   // bytes / sec
    var netUploadRate: Double = 0.0     // bytes / sec
    var thermalState: ProcessInfo.ThermalState = .nominal
    var loadAverages: (Double, Double, Double) = (0.0, 0.0, 0.0)
    var uptimeString: String = ""
    
    var ramPercentage: Double {
        guard ramTotalBytes > 0 else { return 0 }
        return (ramUsedBytes / ramTotalBytes) * 100.0
    }
    
    var swapPercentage: Double {
        guard swapTotalBytes > 0 else { return 0 }
        return (swapUsedBytes / swapTotalBytes) * 100.0
    }
}

class MetricsSampler: ObservableObject {
    @Published var metrics = SystemMetrics()
    @Published var isMonitoringEnabled: Bool = true
    
    private var lastCpuLoad: host_cpu_load_info?
    private var lastNetRx: Double?
    private var lastNetTx: Double?
    private var lastNetTime: Date?
    private var timer: Timer?
    
    init() {
        sample()
        start()
    }
    
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isMonitoringEnabled else { return }
            self.sample()
        }
    }
    
    func sample() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let cpu = self.sampleCPU()
            let (ramUsed, load) = self.sampleRAMAndLoad()
            let (swapUsed, swapTotal) = self.sampleSwapUsage()
            let gpu = self.sampleGPU()
            let (rxRate, txRate) = self.sampleNetwork()
            let thermal = ProcessInfo.processInfo.thermalState
            let uptime = self.sampleUptime()
            
            DispatchQueue.main.async {
                self.metrics.cpuUsage = cpu
                self.metrics.ramUsedBytes = ramUsed
                self.metrics.loadAverages = load
                self.metrics.swapUsedBytes = swapUsed
                self.metrics.swapTotalBytes = swapTotal
                self.metrics.gpuUsage = gpu
                self.metrics.netDownloadRate = rxRate
                self.metrics.netUploadRate = txRate
                self.metrics.thermalState = thermal
                self.metrics.uptimeString = uptime
            }
        }
    }
    
    private func sampleCPU() -> Double {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var curLoad = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &curLoad) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0.0 }
        
        guard let prev = lastCpuLoad else {
            lastCpuLoad = curLoad
            return 0.0
        }
        
        lastCpuLoad = curLoad
        
        let u = Double(curLoad.cpu_ticks.0 - prev.cpu_ticks.0)
        let s = Double(curLoad.cpu_ticks.1 - prev.cpu_ticks.1)
        let i = Double(curLoad.cpu_ticks.2 - prev.cpu_ticks.2)
        let n = Double(curLoad.cpu_ticks.3 - prev.cpu_ticks.3)
        let total = u + s + i + n
        if total > 0 {
            return min(100.0, max(0.0, ((u + s + n) / total) * 100.0))
        }
        return 0.0
    }
    
    private func sampleRAMAndLoad() -> (Double, (Double, Double, Double)) {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStat = vm_statistics64()
        let ret = withUnsafeMutablePointer(to: &vmStat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        var ramUsed: Double = 0.0
        if ret == KERN_SUCCESS {
            let pageSize = Double(vm_kernel_page_size)
            let active = Double(vmStat.active_count) * pageSize
            let wired = Double(vmStat.wire_count) * pageSize
            let compressed = Double(vmStat.compressor_page_count) * pageSize
            ramUsed = active + wired + compressed
        }
        
        var loadavg = [Double](repeating: 0.0, count: 3)
        getloadavg(&loadavg, 3)
        let loads = (loadavg[0], loadavg[1], loadavg[2])
        
        return (ramUsed, loads)
    }
    
    private func sampleSwapUsage() -> (Double, Double) {
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctl(&mib, 2, &swap, &size, nil, 0) == 0 {
            return (Double(swap.xsu_used), Double(swap.xsu_total))
        }
        return (0.0, 0.0)
    }
    
    private func sampleGPU() -> Double {
        let task = Process()
        task.launchPath = "/usr/sbin/ioreg"
        task.arguments = ["-r", "-c", "IOAccelerator", "-d", "2"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let pattern = "Device Utilization %\"?=([0-9]+)"
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let range = NSRange(output.startIndex..<output.endIndex, in: output)
                    let matches = regex.matches(in: output, options: [], range: range)
                    var vals: [Double] = []
                    for match in matches {
                        if match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: output) {
                            if let val = Double(output[r]) {
                                vals.append(val)
                            }
                        }
                    }
                    if !vals.isEmpty {
                        return vals.reduce(0, +) / Double(vals.count)
                    }
                }
            }
        } catch {}
        return 0.0
    }
    
    private func sampleNetwork() -> (Double, Double) {
        let task = Process()
        task.launchPath = "/usr/bin/netstat"
        task.arguments = ["-ib"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        
        var rxTotal: Double = 0
        var txTotal: Double = 0
        
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    if line.contains("<Link#") && !line.hasPrefix("lo0") {
                        let parts = line.split(whereSeparator: { $0.isWhitespace })
                        if parts.count >= 10 {
                            if let rx = Double(parts[6]), let tx = Double(parts[9]) {
                                rxTotal += rx
                                txTotal += tx
                            }
                        }
                    }
                }
            }
        } catch {}
        
        let now = Date()
        var rxRate: Double = 0
        var txRate: Double = 0
        
        if let lastRx = lastNetRx, let lastTx = lastNetTx, let lastTime = lastNetTime {
            let dt = now.timeIntervalSince(lastTime)
            if dt > 0 {
                rxRate = max(0, (rxTotal - lastRx) / dt)
                txRate = max(0, (txTotal - lastTx) / dt)
            }
        }
        
        lastNetRx = rxTotal
        lastNetTx = txTotal
        lastNetTime = now
        
        return (rxRate, txRate)
    }
    
    private func sampleUptime() -> String {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        if sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0 {
            let uptimeSeconds = Date().timeIntervalSince1970 - Double(bootTime.tv_sec)
            let days = Int(uptimeSeconds) / 86400
            let hours = (Int(uptimeSeconds) % 86400) / 3600
            let mins = (Int(uptimeSeconds) % 3600) / 60
            if days > 0 {
                return "\(days)d \(hours)h"
            }
            return "\(hours)h \(mins)m"
        }
        return "n/a"
    }
}

// MARK: - Formatting & Apple Design Colors

func formatBytes(_ bytes: Double, perSec: Bool = false) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var val = bytes
    var unitIndex = 0
    while val >= 1024 && unitIndex < units.count - 1 {
        val /= 1024
        unitIndex += 1
    }
    let suffix = perSec ? "/s" : ""
    if val >= 100 || unitIndex == 0 {
        return String(format: "%.0f %@", val, units[unitIndex]) + suffix
    } else {
        return String(format: "%.2f %@", val, units[unitIndex]) + suffix
    }
}

func appleSemanticColor(for percent: Double) -> Color {
    switch percent {
    case ..<50:
        return Color(nsColor: .systemGreen)
    case 50..<75:
        return Color(nsColor: .systemBlue)
    case 75..<90:
        return Color(nsColor: .systemOrange)
    default:
        return Color(nsColor: .systemRed)
    }
}

// MARK: - Native Apple Aesthetic HUD Components

struct AppleMetricRow: View {
    let title: String
    let value: String
    let percent: Double
    let icon: String
    let detail: String
    let isDisabled: Bool
    
    var tintColor: Color {
        isDisabled ? Color.secondary.opacity(0.4) : appleSemanticColor(for: percent)
    }
    
    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(tintColor)
                        .frame(width: 14)
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isDisabled ? .secondary.opacity(0.6) : .secondary)
                }
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(isDisabled ? .secondary.opacity(0.6) : .primary)
            }
            
            // Apple-style subtle pill progress track
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(nsColor: .separatorColor).opacity(0.35))
                        .frame(height: 4.5)
                    
                    Capsule()
                        .fill(tintColor)
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(percent / 100.0))), height: 4.5)
                }
            }
            .frame(height: 4.5)
            
            HStack {
                Text(detail)
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.vertical, 3)
    }
}

struct MacDashPopoverView: View {
    @ObservedObject var sampler: MetricsSampler
    
    var thermalColor: Color {
        guard sampler.isMonitoringEnabled else { return Color.secondary.opacity(0.4) }
        switch sampler.metrics.thermalState {
        case .nominal: return Color(nsColor: .systemGreen)
        case .fair: return Color(nsColor: .systemBlue)
        case .serious: return Color(nsColor: .systemOrange)
        case .critical: return Color(nsColor: .systemRed)
        @unknown default: return Color(nsColor: .systemGreen)
        }
    }
    
    var thermalLabel: String {
        switch sampler.metrics.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Elevated"
        case .critical: return "Throttled"
        @unknown default: return "Nominal"
        }
    }

    var body: some View {
        VStack(spacing: 11) {
            // Header: Apple Control Center style
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.needle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(sampler.isMonitoringEnabled ? Color(nsColor: .controlAccentColor) : .secondary)
                    Text("MacDash")
                        .font(.system(size: 13, weight: .bold))
                }
                
                Spacer()
                
                // Disable / Enable Switch
                Toggle("", isOn: $sampler.isMonitoringEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .padding(.horizontal, 2)
            
            Divider()
            
            // Telemetry Sections
            VStack(spacing: 10) {
                AppleMetricRow(
                    title: "CPU",
                    value: String(format: "%.1f%%", sampler.metrics.cpuUsage),
                    percent: sampler.metrics.cpuUsage,
                    icon: "cpu",
                    detail: String(format: "Load: %.2f  %.2f  %.2f", sampler.metrics.loadAverages.0, sampler.metrics.loadAverages.1, sampler.metrics.loadAverages.2),
                    isDisabled: !sampler.isMonitoringEnabled
                )
                
                AppleMetricRow(
                    title: "Memory",
                    value: String(format: "%.1f%%", sampler.metrics.ramPercentage),
                    percent: sampler.metrics.ramPercentage,
                    icon: "memorychip",
                    detail: "\(formatBytes(sampler.metrics.ramUsedBytes)) of \(formatBytes(sampler.metrics.ramTotalBytes))",
                    isDisabled: !sampler.isMonitoringEnabled
                )
                
                AppleMetricRow(
                    title: "Swap",
                    value: String(format: "%.1f%%", sampler.metrics.swapPercentage),
                    percent: sampler.metrics.swapPercentage,
                    icon: "arrow.triangle.2.circlepath",
                    detail: "\(formatBytes(sampler.metrics.swapUsedBytes)) used / \(formatBytes(sampler.metrics.swapTotalBytes)) total",
                    isDisabled: !sampler.isMonitoringEnabled
                )
                
                AppleMetricRow(
                    title: "GPU",
                    value: String(format: "%.0f%%", sampler.metrics.gpuUsage),
                    percent: sampler.metrics.gpuUsage,
                    icon: "display",
                    detail: "Apple Silicon Metal Acceleration",
                    isDisabled: !sampler.isMonitoringEnabled
                )
            }
            .opacity(sampler.isMonitoringEnabled ? 1.0 : 0.45)
            .grayscale(sampler.isMonitoringEnabled ? 0.0 : 0.9)
            
            Divider()
            
            // Network & Thermal Card Grid
            HStack(spacing: 8) {
                // Network Box
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "network")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("NETWORK")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(sampler.isMonitoringEnabled ? Color(nsColor: .systemBlue) : .secondary)
                        Text(formatBytes(sampler.metrics.netDownloadRate, perSec: true))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    }
                    HStack {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(sampler.isMonitoringEnabled ? Color(nsColor: .systemPurple) : .secondary)
                        Text(formatBytes(sampler.metrics.netUploadRate, perSec: true))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
                
                // Thermal Box
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "thermometer.medium")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("THERMAL")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(thermalColor)
                            .frame(width: 7, height: 7)
                        Text(thermalLabel)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(thermalColor)
                    }
                    .padding(.top, 2)
                    
                    Text("Up \(sampler.metrics.uptimeString)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
            }
            .opacity(sampler.isMonitoringEnabled ? 1.0 : 0.45)
            .grayscale(sampler.isMonitoringEnabled ? 0.0 : 0.9)
            
            Divider()
            
            // Footer
            HStack {
                Button(action: {
                    let task = Process()
                    task.launchPath = "/usr/bin/open"
                    task.arguments = ["-a", "Activity Monitor"]
                    try? task.run()
                }) {
                    Text("Activity Monitor…")
                        .font(.system(size: 10.5, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Text("Quit")
                        .font(.system(size: 10.5, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .padding(12)
        .frame(width: 275)
    }
}

// MARK: - Application Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover = NSPopover()
    let sampler = MetricsSampler()
    var displayTimer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        let contentView = MacDashPopoverView(sampler: sampler)
        popover.contentSize = NSSize(width: 275, height: 380)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)
        
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            updateStatusBarButton()
        }
        
        displayTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateStatusBarButton()
        }
    }
    
    func updateStatusBarButton() {
        guard let button = statusItem.button else { return }
        
        if !sampler.isMonitoringEnabled {
            button.image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "MacDash Paused")
            let attr = NSMutableAttributedString(string: " Off", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            button.attributedTitle = attr
            return
        }
        
        let cpu = sampler.metrics.cpuUsage
        let ram = sampler.metrics.ramPercentage
        
        button.image = NSImage(systemSymbolName: "gauge.with.needle.fill", accessibilityDescription: "MacDash")
        let title = String(format: " %.0f%% · %.0f%%", cpu, ram)
        let attr = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ])
        button.attributedTitle = attr
    }
    
    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
