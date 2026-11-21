//
//  TVSystem.swift
//  MeloNX tvOS
//
//  JIT and memory checks for the TrollStore build.
//
//  JIT: TrollStore cannot give a tvOS/iOS 15+ A12+ app `dynamic-codesigning`
//  (banned: such apps crash on launch). Like MeloNX on iPad, JIT is turned on by
//  TrollStore attaching to the process ("Open with JIT", or the URL scheme
//  apple-magnifier://enable-jit?bundle-id=...), which sets CS_DEBUGGED. So the
//  app starts without JIT, asks TrollStore for it, and only game start is gated.
//  Check = Common/JITChecker.swift: CS_DEBUGGED via csops + a real RW -> RX flip.
//
//  Memory: the Switch has 4 GB of RAM. tvOS gives a foreground app a jetsam
//  limit well below the Apple TV's physical RAM. `com.apple.private.memorystatus`
//  lets the process raise its own limit with memorystatus_control (this replaces
//  the iOS RamDonor, whose AR-extension trick does not exist on tvOS).
//

import Foundation
import Darwin
import os
import UIKit
import Metal

// MARK: - JIT

@_silgen_name("csops")
private func tv_csops(_ pid: Int32, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

enum TVJIT {
    private static let CS_OPS_STATUS: UInt32 = 0
    private static let CS_DEBUGGED: UInt32 = 0x10000000

    /// A debugger (TrollStore) has attached at least once: code signing is relaxed.
    static var isDebugged: Bool {
        var flags: UInt32 = 0
        return tv_csops(getpid(), CS_OPS_STATUS, &flags, MemoryLayout<UInt32>.size) == 0 && flags & CS_DEBUGGED != 0
    }

    /// Re-checked every time: TrollStore can enable JIT after launch.
    static var isAvailable: Bool { isDebugged && pageCanBecomeExecutable() }

    static var enableURL: URL {
        URL(string: "apple-magnifier://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier ?? "com.sojubada.melonx.tvos")")!
    }

    /// Ask TrollStore to attach (same URL as Common/JIT/EnableJIT.swift).
    /// Automatic requests are rate limited so a TrollStore without the URL
    /// scheme, or a failed attach, cannot bounce the app back and forth.
    @MainActor
    static func request(automatic: Bool, completion: ((Bool) -> Void)? = nil) {
        guard !isAvailable else { return }
        let key = "tvJITLastRequest"
        let now = Date().timeIntervalSince1970
        if automatic, now - UserDefaults.standard.double(forKey: key) < 60 {
            TVLog.write("JIT: automatic request skipped (asked < 60 s ago)")
            return
        }
        UserDefaults.standard.set(now, forKey: key)
        TVLog.write("JIT: asking TrollStore \(enableURL.absoluteString)")
        UIApplication.shared.open(enableURL, options: [:]) { ok in
            TVLog.write("JIT: open URL \(ok ? "accepted" : "refused (no TrollStore URL scheme?)")")
            completion?(ok)
        }
    }

    private static func pageCanBecomeExecutable() -> Bool {
        let pageSize = Int(sysconf(_SC_PAGESIZE))
        // mov w0, #42 ; ret
        let code: [UInt32] = [0x52800540, 0xD65F03C0]

        guard let page = mmap(nil, pageSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              page != MAP_FAILED else {
            return false
        }
        defer { munmap(page, pageSize) }

        code.withUnsafeBytes { bytes in
            _ = memcpy(page, bytes.baseAddress!, bytes.count)
        }

        guard mprotect(page, pageSize, PROT_READ | PROT_EXEC) == 0 else { return false }

        return protection(at: page) & VM_PROT_EXECUTE != 0
    }

    private static func protection(at address: UnsafeMutableRawPointer) -> vm_prot_t {
        var region = vm_address_t(UInt(bitPattern: address))
        var size: vm_size_t = 0
        var info = vm_region_basic_info_64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_64>.size / MemoryLayout<integer_t>.size)
        var object: mach_port_t = UInt32(MACH_PORT_NULL)

        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                vm_region_64(mach_task_self_, &region, &size, VM_REGION_BASIC_INFO_64, $0, &count, &object)
            }
        }
        return kr == KERN_SUCCESS ? info.protection : 0
    }
}

// MARK: - Memory limit

@_silgen_name("memorystatus_control")
private func memorystatus_control(_ command: UInt32, _ pid: Int32, _ flags: UInt32,
                                  _ buffer: UnsafeMutableRawPointer?, _ bufferSize: Int) -> Int32

enum TVMemory {
    // xnu bsd/sys/kern_memorystatus.h
    private static let MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT: UInt32 = 6

    static var physicalMB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) }

    static var hasIncreasedLimitEntitlement: Bool {
        checkAppEntitlement("com.apple.developer.kernel.increased-memory-limit")
    }

    /// Headroom the emulator may use right now, as reported by the OS.
    private static let metalDevice = MTLCreateSystemDefaultDevice()

    /// What the kernel charges against the memory limit (TASK_VM_INFO phys_footprint).
    static var footprintMB: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    /// Metal allocations of this process (textures, buffers, pipelines via MoltenVK).
    static var metalMB: Int {
        Int((metalDevice?.currentAllocatedSize ?? 0) / 1_048_576)
    }

    static var availableMB: Int {
        Int(os_proc_available_memory() / 1_048_576)
    }

    /// Dirty + compressed memory of this process grouped by VM tag, to see what the
    /// footprint is made of (guest RAM, .NET heap, malloc, GPU, ...). Walks the
    /// whole map, so call it off the main thread. Shared objects mapped more than
    /// once (guest RAM aliases) are counted once.
    static func regionSummary() -> String {
        var address: vm_address_t = 0
        var size: vm_size_t = 0
        var depth: natural_t = 0
        let page = UInt64(vm_page_size)
        var byGroup: [String: UInt64] = [:]
        var seenShared = Set<UInt32>()
        var largest: (bytes: UInt64, tag: UInt32, shared: Bool) = (0, 0, false)
        var regions = 0

        while regions < 200_000 {
            var info = vm_region_submap_info_data_64_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                    vm_region_recurse_64(mach_task_self_, &address, &size, &depth, $0, &count)
                }
            }
            if kr != KERN_SUCCESS { break }
            regions += 1
            if info.is_submap != 0 { depth += 1; continue }
            defer { address &+= size }

            let bytes = (UInt64(info.pages_dirtied) + UInt64(info.pages_swapped_out)) * page
            if bytes == 0 { continue }
            let mode = Int32(info.share_mode)
            let shared = mode == SM_SHARED || mode == SM_TRUESHARED || mode == SM_SHARED_ALIASED
            if shared && !seenShared.insert(info.object_id).inserted { continue }

            let tag = info.user_tag
            let group: String
            switch tag {
            case 0: group = shared ? "anon-shared" : "anon"
            case 1...13: group = "malloc"
            case 21: group = "IOKit"
            case 30: group = "stack"
            case 51: group = "CoreAnimation"
            case 100: group = "GPU"          // VM_MEMORY_IOACCELERATOR
            case 88: group = "IOSurface"
            default: group = "tag\(tag)"
            }
            byGroup[group, default: 0] += bytes
            if bytes > largest.bytes { largest = (bytes, tag, shared) }
        }

        let mb: (UInt64) -> UInt64 = { $0 / 1_048_576 }
        let parts = byGroup.sorted { $0.value > $1.value }
            .filter { mb($0.value) >= 8 }
            .prefix(8)
            .map { "\($0.key) \(mb($0.value))" }
            .joined(separator: ", ")
        return "mem map (MB): \(parts); largest object \(mb(largest.bytes)) MB tag \(largest.tag)\(largest.shared ? " shared" : ""); \(regions) regions"
    }

    /// The limit we asked for at launch and whether the kernel accepted it.
    private(set) static var requestedLimitMB = 0
    private(set) static var raisedLimit = false

    private static let MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES: UInt32 = 7

    /// memorystatus_memlimit_properties_t
    private struct MemlimitProperties {
        var activeMB: Int32
        var activeAttr: UInt32
        var inactiveMB: Int32
        var inactiveAttr: UInt32
    }

    /// Ask for most of physical RAM, leaving room for tvOS itself.
    /// On a 4 GB Apple TV 4K (3rd gen) that is 3,598 MB (was 3,470).
    ///
    /// RunningBoard re-applies the app's own limit when the app changes state
    /// (launch → foreground, JIT attach, resume). Device log: 3,464 MB available
    /// right after raising at launch, but only 2,067 MB at game start and the
    /// core saw a 2,098 MiB budget; the game was then killed by jetsam with no
    /// crash report. So the limit is set as the active AND inactive properties
    /// (what RunningBoard itself sets) plus the task limit, and re-applied on
    /// activation, at game start and periodically while a game runs.
    @discardableResult
    static func raiseJetsamLimit(_ reason: String = "launch") -> Bool {
        let leaveForSystem = 384     // 3,598 MB on a 4 GB Apple TV
        let target = max(physicalMB - leaveForSystem, 1024)
        requestedLimitMB = target
        let before = availableMB

        var props = MemlimitProperties(activeMB: Int32(target), activeAttr: 1,   // 1 = FATAL (hard limit, as RunningBoard sets)
                                       inactiveMB: Int32(target), inactiveAttr: 1)
        let r1 = withUnsafeMutablePointer(to: &props) {
            memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES, getpid(), 0,
                                 UnsafeMutableRawPointer($0), MemoryLayout<MemlimitProperties>.size)
        }
        let e1 = errno
        let r2 = memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, getpid(), UInt32(target), nil, 0)
        let e2 = errno
        raisedLimit = (r1 == 0 || r2 == 0)

        let after = availableMB
        if reason != "watch" || after > before + 64 {
            TVLog.write("jetsam limit \(target) MB [\(reason)] props \(r1 == 0 ? "ok" : "errno \(e1)"), task \(r2 == 0 ? "ok" : "errno \(e2)"); available \(before) → \(after) MB")
        }
        return raisedLimit
    }
}
