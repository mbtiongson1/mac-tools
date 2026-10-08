import SwiftUI
import Cocoa
import Foundation
import MachO
import ServiceManagement
import Darwin

// MARK: - Models & Metrics Sampler

struct AppMemoryUsage: Identifiable {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let launchDate: Date?
    let icon: NSImage
    let memoryBytes: Double
    var id: pid_t { pid }
}

struct SystemMetrics {
    var cpuUsage: Double = 0.0          // 0 - 100%
    var ramUsedBytes: Double = 0.0
    var ramTotalBytes: Double = Double(ProcessInfo.processInfo.physicalMemory)
    var swapUsedBytes: Double = 0.0
    var swapTotalBytes: Double = 0.0
    var topApps: [AppMemoryUsage] = []
    var netDownloadRate: Double = 0.0   // bytes / sec
    var netUploadRate: Double = 0.0     // bytes / sec
    var thermalState: ProcessInfo.ThermalState = .nominal
    var loadAverages: (Double, Double, Double) = (0.0, 0.0, 0.0)
    var uptimeString: String = ""
    
    var ramPercentage: Double {
        guard ramTotalBytes > 0 else { return 0 }
        return (ramUsedBytes / ramTotalBytes) * 100.0
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
        // NSWorkspace is AppKit state; snapshot its app list on the main thread.
        let runningApps = NSWorkspace.shared.runningApplications
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let cpu = self.sampleCPU()
            let (ramUsed, load) = self.sampleRAMAndLoad()
            let (swapUsed, swapTotal) = self.sampleSwapUsage()
            let apps = self.sampleTopApps(from: runningApps)
            let (rxRate, txRate) = self.sampleNetwork()
            let thermal = ProcessInfo.processInfo.thermalState
            let uptime = self.sampleUptime()
            
            DispatchQueue.main.async {
                self.metrics.cpuUsage = cpu
                self.metrics.ramUsedBytes = ramUsed
                self.metrics.loadAverages = load
                self.metrics.swapUsedBytes = swapUsed
                self.metrics.swapTotalBytes = swapTotal
                self.metrics.topApps = apps
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
    
    private func sampleTopApps(from runningApps: [NSRunningApplication]) -> [AppMemoryUsage] {
        runningApps
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .compactMap { app in
                var usage = rusage_info_v4()
                let result = withUnsafeMutablePointer(to: &usage) { pointer in
                    pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { buffer in
                        proc_pid_rusage(app.processIdentifier, RUSAGE_INFO_V4, buffer)
                    }
                }
                guard result == 0 else { return nil }
                return AppMemoryUsage(pid: app.processIdentifier,
                                      name: app.localizedName ?? app.bundleIdentifier ?? "Unknown App",
                                      bundleIdentifier: app.bundleIdentifier,
                                      launchDate: app.launchDate,
                                      icon: app.icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage(),
                                      memoryBytes: Double(usage.ri_phys_footprint))
            }
            .sorted { $0.memoryBytes > $1.memoryBytes }
            .prefix(8)
            .map { $0 }
    }
    
    private func sampleNetwork() -> (Double, Double) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (0, 0) }
        defer { freeifaddrs(addresses) }

        var rxTotal: Double = 0
        var txTotal: Double = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let interface = entry.pointee
            if let address = interface.ifa_addr,
               let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self),
               address.pointee.sa_family == UInt8(AF_LINK),
               (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
               (interface.ifa_flags & UInt32(IFF_UP)) != 0 {
                rxTotal += Double(data.pointee.ifi_ibytes)
                txTotal += Double(data.pointee.ifi_obytes)
            }
            cursor = interface.ifa_next
        }
        
        let now = Date()
        var rxRate: Double = 0
        var txRate: Double = 0
        
        if let lastRx = lastNetRx, let lastTx = lastNetTx, let lastTime = lastNetTime {
            let dt = now.timeIntervalSince(lastTime)
            if dt > 0 {
                let counterModulus = Double(UInt32.max) + 1
                let rxDelta = rxTotal >= lastRx ? rxTotal - lastRx : rxTotal + counterModulus - lastRx
                let txDelta = txTotal >= lastTx ? txTotal - lastTx : txTotal + counterModulus - lastTx
                rxRate = max(0, rxDelta / dt)
                txRate = max(0, txDelta / dt)
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

struct GlassIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22
    var diameter: CGFloat = 50

    var body: some View {
        let glyph = Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: diameter, height: diameter)
        Group {
            if #available(macOS 26.0, *) {
                glyph.glassEffect(.regular, in: Circle())
            } else {
                glyph.background(tint.opacity(0.15), in: Circle())
            }
        }
        .accessibilityHidden(true)
    }
}

struct GlassMetricTile: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color
    var progress: Double? = nil
    var secondaryValue: String? = nil


    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                GlassIcon(symbol: icon, tint: tint, size: 22, diameter: 50)
                Spacer(minLength: 0)
                if let progress {
                    ZStack {
                        Circle().stroke(tint.opacity(0.16), lineWidth: 5)
                        Circle().trim(from: 0, to: CGFloat(min(max(progress, 0), 100) / 100))
                            .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 31, height: 31)
                    .padding(4)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(.system(size: 27, weight: .bold, design: .rounded).monospacedDigit())
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)
                    if let secondaryValue {
                        Text(secondaryValue)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 140, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

struct MacDashPopoverView: View {
    @ObservedObject var sampler: MetricsSampler
    @State private var appToForceQuit: AppMemoryUsage?
    
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

    private var metricGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            GlassMetricTile(
                title: "CPU",
                value: String(format: "%.0f%%", sampler.metrics.cpuUsage),
                detail: String(format: "Load %.2f · %.2f · %.2f", sampler.metrics.loadAverages.0, sampler.metrics.loadAverages.1, sampler.metrics.loadAverages.2),
                icon: "cpu.fill",
                tint: Color(nsColor: .systemBlue),
                progress: sampler.metrics.cpuUsage
            )
            GlassMetricTile(
                title: "Memory",
                value: String(format: "%.0f%%", sampler.metrics.ramPercentage),
                detail: "\(formatBytes(sampler.metrics.ramUsedBytes)) of \(formatBytes(sampler.metrics.ramTotalBytes))",
                icon: "memorychip.fill",
                tint: appleSemanticColor(for: sampler.metrics.ramPercentage),
                progress: sampler.metrics.ramPercentage
            )
            GlassMetricTile(
                title: "Swap Used",
                value: formatBytes(sampler.metrics.swapUsedBytes),
                detail: "of \(formatBytes(sampler.metrics.swapTotalBytes)) available",
                icon: "arrow.triangle.2.circlepath",
                tint: Color(nsColor: .systemOrange),
                progress: sampler.metrics.swapTotalBytes > 0 ? sampler.metrics.swapUsedBytes / sampler.metrics.swapTotalBytes * 100 : 0
            )
            GlassMetricTile(
                title: "Download",
                value: formatBytes(sampler.metrics.netDownloadRate, perSec: true),
                detail: "↑  \(formatBytes(sampler.metrics.netUploadRate, perSec: true)) uploaded",
                icon: "arrow.down.circle.fill",
                tint: Color(nsColor: .systemTeal)
            )
        }
    }

    var body: some View {
        VStack(spacing: 15) {
            HStack(spacing: 10) {
                GlassIcon(symbol: "gauge.with.needle.fill", tint: Color(nsColor: .controlAccentColor), size: 18, diameter: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacDash")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("SYSTEM OVERVIEW")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Monitoring", isOn: $sampler.isMonitoringEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(sampler.isMonitoringEnabled ? "Pause monitoring" : "Resume monitoring")
            }
            .padding(.horizontal, 2)

            Group {
                if #available(macOS 26.0, *) {
                    GlassEffectContainer(spacing: 12) { metricGrid }
                } else {
                    metricGrid
                }
            }
            .opacity(sampler.isMonitoringEnabled ? 1 : 0.5)
            .grayscale(sampler.isMonitoringEnabled ? 0 : 0.85)

            HStack(spacing: 9) {
                GlassIcon(symbol: "thermometer.medium", tint: thermalColor, size: 17, diameter: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Thermal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(thermalLabel)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(thermalColor)
                }
                Spacer()
                Image(systemName: "clock")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Up \(sampler.metrics.uptimeString)")
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .opacity(sampler.isMonitoringEnabled ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Apps Using Memory", systemImage: "square.stack.3d.up.fill")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("TOP 6")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                }
                ForEach(sampler.metrics.topApps.prefix(6)) { item in
                    HStack(spacing: 10) {
                        Image(nsImage: item.icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(formatBytes(item.memoryBytes))
                                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if appToForceQuit?.pid == item.pid {
                            Button("Confirm") { forceQuit(item) }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .controlSize(.small)
                            Button("Cancel") { appToForceQuit = nil }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        } else {
                            Button { appToForceQuit = item } label: {
                                Label("Force Quit", systemImage: "xmark.circle.fill")
                                    .labelStyle(.iconOnly)
                                    .font(.system(size: 17))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red.opacity(0.8))
                            .help("Force quit \(item.name)")
                            .accessibilityLabel("Force Quit \(item.name)")
                        }
                    }
                    .padding(.vertical, 1)
                    if item.id != sampler.metrics.topApps.prefix(6).last?.id {
                        Divider().padding(.leading, 40)
                    }
                }
                if sampler.metrics.topApps.isEmpty {
                    Text("No app memory data available")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                if appToForceQuit != nil {
                    Label("Unsaved changes may be lost.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Button {
                    let task = Process()
                    task.launchPath = "/usr/bin/open"
                    task.arguments = ["-a", "Activity Monitor"]
                    try? task.run()
                } label: {
                    Label("Activity Monitor", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 410)
    }

    private func forceQuit(_ item: AppMemoryUsage) {
        if let app = NSRunningApplication(processIdentifier: item.pid),
           app.bundleIdentifier == item.bundleIdentifier,
           app.launchDate == item.launchDate {
            _ = app.forceTerminate()
        }
        appToForceQuit = nil
        sampler.sample()
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
        popover.contentSize = NSSize(width: 410, height: 700)
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
