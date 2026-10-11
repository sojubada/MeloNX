//
//  Untitled.swift
//  MeloNX
//
//  Created by Stossy11 on 21/12/2024.
//

import SwiftUI
import Combine

@MainActor
class MemoryUsageMonitor: ObservableObject {
    @Published private(set) var memoryUsage: UInt64 = 0
    @Published private(set) var donatedMemory: UInt64 = 0
    private var task: Task<Void, Never>?
    
    init() {
        task = Task {
            await monitorMemoryUsage()
        }
    }
    
    deinit {
        task?.cancel()
    }
    
    private func monitorMemoryUsage() async {
        while !Task.isCancelled {
            updateMemoryUsage()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
    
    private func updateMemoryUsage() {
        var taskInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride) / 4
        
        let result: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            memoryUsage = taskInfo.phys_footprint
        } else {
            print("Failed to get memory usage: \(result)")
            memoryUsage = 0
        }
        
        donatedMemory = MLXRamDonor.sharedIfExists?.donatedBytes() ?? 0 // i'm just locked in :3
    }
    
    func formatMemorySize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

struct PerformanceOverlayView: View {
    @StateObject private var memorymonitor = MemoryUsageMonitor()
    @StateObject private var nativeSettings: NativeSettingsManager = .shared
    @ObservedObject var statisticsHandler: StatisticsHandler
    
    @State private var batteryLevel: Int = Int(UIDevice.current.batteryLevel * 100)
    
    
    @ViewBuilder
    var content: some View {
        if nativeSettings.horizontalorvertical(false).bool {
            HStack(spacing: 8) {
                overlayText
            }
            .padding(10)
        } else {
            VStack(alignment: .trailing, spacing: 8) {
                overlayText
            }
            .padding(10)
            .frame(minWidth: 150)
        }
    }
    
    @ViewBuilder
    var overlayText: some View {
        if nativeSettings.horizontalorvertical(false).bool {
            Text("Battery: \(batteryLevel)%")
                .foregroundStyle(.white)
        }
        
        Text(nativeSettings.performanceFrameTime(true).bool ? statisticsHandler.formatFPS() + (" (\(statisticsHandler.frameTime)ms)") : statisticsHandler.formatFPS())
            .foregroundStyle(.white)
        
        if nativeSettings.performanceRam(true).bool {
            Text("RAM: " + memorymonitor.formatMemorySize(memorymonitor.memoryUsage))
                .foregroundStyle(.white)

            if memorymonitor.donatedMemory > 0 {
                Text("Donated: " + memorymonitor.formatMemorySize(memorymonitor.donatedMemory))
                    .foregroundStyle(.white)
            }
        }

        if nativeSettings.performanceFIFO(false).bool {
            Text("FIFO: \(statisticsHandler.fifo, specifier: "%.2f")%")
                .foregroundStyle(.white)
        }
    }
    
    var body: some View {
        content
            .background(Color.black.opacity(0.7))
            .onAppear() {
                UIDevice.current.isBatteryMonitoringEnabled = true
                batteryLevel = Int(UIDevice.current.batteryLevel * 100)
                
                NotificationCenter.default.addObserver(
                    forName: UIDevice.batteryLevelDidChangeNotification,
                    object: nil,
                    queue: .main
                ) { _ in
                    batteryLevel = Int(UIDevice.current.batteryLevel * 100)
                }
            }
    }
}

