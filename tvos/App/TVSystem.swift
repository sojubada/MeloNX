//
//  TVSystem.swift
//  MeloNX tvOS
//
//  JIT and memory checks for the TrollStore build.
//
//  JIT: same test as Common/JITChecker.swift (`dynamic-codesigning` entitlement,
//  then really flip a page RW → RX and read back its protection). The iOS file
//  also probes TXM through IOKit for iOS 26; tvOS 16 predates TXM and its SDK has
//  no IOKit headers, so that path is left out. With the entitlement there is no
//  debugger, StikDebug or URL-scheme step: JIT is on as soon as the app starts.
//
//  Memory: the Switch has 4 GB of RAM. tvOS gives a foreground app a jetsam
//  limit well below the Apple TV's physical RAM. `com.apple.private.memorystatus`
//  lets the process raise its own limit with memorystatus_control (this replaces
//  the iOS RamDonor, whose AR-extension trick does not exist on tvOS).
//

import Foundation
import Darwin
import os

// MARK: - JIT

enum TVJIT {
    static var hasEntitlement: Bool { checkAppEntitlement("dynamic-codesigning") }

    /// Cached: the answer cannot change while the process runs.
    static let isAvailable: Bool = hasEntitlement && pageCanBecomeExecutable()

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
    static var availableMB: Int {
        Int(os_proc_available_memory() / 1_048_576)
    }

    /// The limit we asked for at launch and whether the kernel accepted it.
    private(set) static var requestedLimitMB = 0
    private(set) static var raisedLimit = false

    /// Ask for most of physical RAM, leaving room for tvOS itself.
    /// On a 4 GB Apple TV 4K (3rd gen) that is 3,584 MB.
    static func raiseJetsamLimit() {
        let leaveForSystem = 512
        let target = max(physicalMB - leaveForSystem, 1024)
        requestedLimitMB = target
        let result = memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, getpid(), UInt32(target), nil, 0)
        raisedLimit = (result == 0)
        NSLog("[MeloNX tvOS] jetsam limit \(target) MB → \(raisedLimit ? "ok" : "refused (errno \(errno))"); physical \(physicalMB) MB, available now \(availableMB) MB")
    }
}
