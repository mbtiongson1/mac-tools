import SwiftUI
import Cocoa
import Foundation
import ServiceManagement

// MARK: - Models & Metrics Sampler

struct SystemMetrics {
    var cpuUsage: Double = 0.0          // 0 - 100%
    var ramUsedBytes: Double = 0.0
    var ramTotalBytes: Double = 8 * 1024 * 1024 * 1024
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
    
    private var lastNetRx: Double?
    private var lastNetTx: Double?
    private var lastNetTime: Date?
    private var timer: Timer?
    
    init() {
        metrics.ramTotalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        sample()
        start()
    }
    
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }
    
    func sample() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let cpu = self.sampleCPU()
            let (ramUsed, load) = self.sampleTopSummary()
            let (swapUsed, swapTotal) = self.sampleSwap()
            let gpu = self.sampleGPU()
            let (rxRate, txRate) = self.sampleNetwork()
            let thermal = ProcessInfo.processInfo.thermalState
            let uptime = self.formattedUptime()
            
            DispatchQueue.main.async {
                self.metrics.cpuUsage = cpu
                if let ram = ramUsed { self.metrics.ramUsedBytes = ram }
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
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numProcessors: natural_t = 0
        
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numProcessors, &cpuInfo, &numCpuInfo)
        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else { return 0.0 }
        
        // Return average or fallback to sysctl / top
        // Free memory allocated by host_processor_info
        let vmSize = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vmSize)
        
        // Quick estimate from top summary
        return sampleTopCPU()
    }
    
    private func sampleTopCPU() -> Double {
        let task = Process()
        task.launchPath = "/usr/bin/top"
        task.arguments = ["-l", "1", "-n", "0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                if let match = output.range(of: "CPU usage: ") {
                    let rest = output[match.upperBound...]
                    let comp = rest.components(separatedBy: "%")
                    if comp.count >= 2 {
                        let userStr = comp[0].trimmingCharacters(in: .whitespaces)
                        let sysComp = comp[1].components(separatedBy: "user, ")
                        if sysComp.count >= 2 {
                            let sysStr = sysComp[1].trimmingCharacters(in: .whitespaces)
                            let user = Double(userStr) ?? 0.0
                            let sys = Double(sysStr) ?? 0.0
                            return min(100.0, max(0.0, user + sys))
                        }
                    }
                }
            }
        } catch {}
        return 0.0
    }
    
    private func sampleTopSummary() -> (Double?, (Double, Double, Double)) {
        var ramUsed: Double? = nil
        var loads: (Double, Double, Double) = (0.0, 0.0, 0.0)
        
        // Sample host_statistics64 for accurate real-time RAM
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStat = vm_statistics64()
        let ret = withUnsafeMutablePointer(to: &vmStat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        if ret == KERN_SUCCESS {
            let pageSize = Double(vm_kernel_page_size)
            let active = Double(vmStat.active_count) * pageSize
            let wired = Double(vmStat.wire_count) * pageSize
            let compressed = Double(vmStat.compressor_page_count) * pageSize
            ramUsed = active + wired + compressed
        }
        
        var loadavg = [Double](repeating: 0.0, count: 3)
        getloadavg(&loadavg, 3)
        loads = (loadavg[0], loadavg[1], loadavg[2])
        
        return (ramUsed, loads)
    }
    
    private func sampleSwap() -> (Double, Double) {
        var size = 0
        sysctlbyname("vm.swapusage", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("vm.swapusage", &buffer, &size, nil, 0)
        let str = String(cString: buffer)
        
        // total = 3072.00M  used = 1870.81M  free = 1201.19M
        var usedBytes: Double = 0
        var totalBytes: Double = 0
        
        func parseBytes(_ text: String, key: String) -> Double {
            if let range = text.range(of: "\(key) = ") {
                let sub = text[range.upperBound...]
                let tokens = sub.split(separator: " ")
                if let first = tokens.first {
                    let numStr = String(first.filter { "0123456789.".contains($0) })
                    let num = Double(numStr) ?? 0.0
                    if first.contains("M") { return num * 1024 * 1024 }
                    if first.contains("G") { return num * 1024 * 1024 * 1024 }
                    if first.contains("K") { return num * 1024 }
                    return num
                }
            }
            return 0
        }
        
        usedBytes = parseBytes(str, key: "used")
        totalBytes = parseBytes(str, key: "total")
        return (usedBytes, totalBytes)
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
                // Find Device Utilization %
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
                    if line.contains("<Link#") {
                        let parts = line.split(whereSeparator: { $0.isWhitespace })
                        // Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
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
    
    private func formattedUptime() -> String {
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

// MARK: - Helpers & Color Palette

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
        return String(format: "%.1f %@", val, units[unitIndex]) + suffix
    }
}

func semanticColor(for percent: Double) -> Color {
    switch percent {
    case ..<50:
        return Color(red: 0.20, green: 0.78, blue: 0.45) // emerald green
    case 50..<75:
        return Color(red: 0.23, green: 0.60, blue: 0.98) // vibrant blue
    case 75..<90:
        return Color(red: 0.98, green: 0.75, blue: 0.25) // amber
    default:
        return Color(red: 0.94, green: 0.33, blue: 0.31) // coral red
    }
}

// MARK: - Impeccable SwiftUI Dashboard View

struct MetricCard: View {
    let title: String
    let value: String
    let percent: Double
    let icon: String
    let subtitle: String?
    
    var color: Color {
        semanticColor(for: percent)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(color)
                    Text(title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
            }
            
            // Meter progress track
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 5)
                    
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.85), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(percent / 100.0))), height: 5)
                }
            }
            .frame(height: 5)
            
            if let sub = subtitle {
                Text(sub)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

struct MacDashPopoverView: View {
    @ObservedObject var sampler: MetricsSampler
    
    var thermalColor: Color {
        switch sampler.metrics.thermalState {
        case .nominal: return Color.green
        case .fair: return Color.blue
        case .serious: return Color.orange
        case .critical: return Color.red
        @unknown default: return Color.green
        }
    }
    
    var thermalLabel: String {
        switch sampler.metrics.thermalState {
        case .nominal: return "Nominal (Cool)"
        case .fair: return "Fair (Warm)"
        case .serious: return "Serious (Hot)"
        case .critical: return "Critical (Throttling)"
        @unknown default: return "Nominal"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header bar
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.badge.bolt")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.accentColor)
                    Text("MacDash")
                        .font(.system(size: 14, weight: .bold, design: .default))
                }
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("Up \(sampler.metrics.uptimeString)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 2)
            
            Divider()
                .opacity(0.6)
            
            // Grid of Metrics
            VStack(spacing: 8) {
                MetricCard(
                    title: "CPU",
                    value: String(format: "%.1f%%", sampler.metrics.cpuUsage),
                    percent: sampler.metrics.cpuUsage,
                    icon: "cpu",
                    subtitle: String(format: "Load: %.2f  %.2f  %.2f", sampler.metrics.loadAverages.0, sampler.metrics.loadAverages.1, sampler.metrics.loadAverages.2)
                )
                
                MetricCard(
                    title: "RAM",
                    value: String(format: "%.1f%%", sampler.metrics.ramPercentage),
                    percent: sampler.metrics.ramPercentage,
                    icon: "memorychip",
                    subtitle: "\(formatBytes(sampler.metrics.ramUsedBytes)) of \(formatBytes(sampler.metrics.ramTotalBytes))"
                )
                
                MetricCard(
                    title: "SWAP",
                    value: sampler.metrics.swapTotalBytes > 0 ? String(format: "%.1f%%", sampler.metrics.swapPercentage) : "0.0%",
                    percent: sampler.metrics.swapPercentage,
                    icon: "arrow.triangle.2.circlepath",
                    subtitle: "\(formatBytes(sampler.metrics.swapUsedBytes)) used / \(formatBytes(sampler.metrics.swapTotalBytes)) total"
                )
                
                MetricCard(
                    title: "GPU",
                    value: String(format: "%.0f%%", sampler.metrics.gpuUsage),
                    percent: sampler.metrics.gpuUsage,
                    icon: "sparkles.tv",
                    subtitle: "Apple Silicon Metal Acceleration"
                )
                
                // Network Bandwidth Card
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(Color.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DOWNLOAD")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(.secondary)
                            Text(formatBytes(sampler.metrics.netDownloadRate, perSec: true))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(NSColor.controlBackgroundColor).opacity(0.65))
                    )
                    
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(Color.indigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("UPLOAD")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(.secondary)
                            Text(formatBytes(sampler.metrics.netUploadRate, perSec: true))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(NSColor.controlBackgroundColor).opacity(0.65))
                    )
                }
                
                // Temperature / Thermal Status Card
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "thermometer.medium")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(thermalColor)
                        Text("THERMAL CONDITION")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        Circle()
                            .fill(thermalColor)
                            .frame(width: 7, height: 7)
                        Text(thermalLabel)
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundColor(thermalColor)
                    }
                }
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.65))
                )
            }
            
            Divider()
                .opacity(0.6)
            
            // Bottom Action Footer
            HStack {
                Button(action: {
                    let task = Process()
                    task.launchPath = "/usr/bin/open"
                    task.arguments = ["-a", "Activity Monitor"]
                    try? task.run()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar.xaxis")
                        Text("Activity Monitor")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Text("Quit")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .padding(.top, -2)
        }
        .padding(14)
        .frame(width: 290)
    }
}

// MARK: - Application Delegate & Status Bar Controller

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover = NSPopover()
    let sampler = MetricsSampler()
    var displayTimer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        let contentView = MacDashPopoverView(sampler: sampler)
        popover.contentSize = NSSize(width: 290, height: 420)
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
        let cpu = sampler.metrics.cpuUsage
        let ram = sampler.metrics.ramPercentage
        
        // Compact, clean status bar typography: [Icon] C: 12% R: 64%
        let title = String(format: " CPU %.0f%% · RAM %.0f%%", cpu, ram)
        
        let attr = NSMutableAttributedString()
        if let icon = NSImage(systemSymbolName: "gauge.badge.bolt", accessibilityDescription: "MacDash") {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            button.image = icon.withSymbolConfiguration(config)
        }
        
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        let textAttr: [NSAttributedString.Key: Any] = [
            .font: font
        ]
        attr.append(NSAttributedString(string: title, attributes: textAttr))
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
