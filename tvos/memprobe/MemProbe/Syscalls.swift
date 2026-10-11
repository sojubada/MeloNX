//
//  Syscalls.swift
//  MemProbe — tvOS 메모리/JIT 한도 실측 프로브
//
//  MeloNX의 EntitlementChecker.swift / JITChecker.swift와 동일한 방식으로
//  시스템 심볼을 직접 바인딩한다. 결과가 MeloNX에 그대로 전이되도록
//  판정 로직을 일부러 같은 모양으로 유지했다.
//

import Foundation
import Darwin
import Security

// MARK: - 메모리 예산

/// Ryujinx.Memory/HostMemoryBudget.cs 가 쓰는 것과 같은 함수.
/// 커널이 이 프로세스에 허용하는 남은 바이트 수를 돌려준다.
@_silgen_name("os_proc_available_memory")
func mp_os_proc_available_memory() -> Int

// MARK: - 엔타이틀먼트 조회 (MeloNX EntitlementChecker와 동일)

typealias SecTaskRef = OpaquePointer

@_silgen_name("SecTaskCreateFromSelf")
func mp_SecTaskCreateFromSelf(_ allocator: CFAllocator?) -> SecTaskRef?

@_silgen_name("SecTaskCopyValueForEntitlement")
func mp_SecTaskCopyValueForEntitlement(_ task: SecTaskRef,
                                       _ entitlement: NSString,
                                       _ error: NSErrorPointer) -> CFTypeRef?

@_silgen_name("CFRelease")
func mp_CFRelease(_ cf: CFTypeRef?)

enum Ent {
    static let increasedMemory  = "com.apple.developer.kernel.increased-memory-limit"
    static let extendedVA       = "com.apple.developer.kernel.extended-virtual-addressing"
    static let dynamicCodesign  = "dynamic-codesigning"
    static let memorystatus     = "com.apple.private.memorystatus"
    static let platformApp      = "platform-application"

    /// 엔타이틀먼트가 실제로 서명에 붙어 있는지. 붙어 있어도 커널이
    /// 존중하는지는 별개이므로, 이 값과 아래 jetsam 한도를 같이 봐야 한다.
    static func has(_ name: String) -> Bool {
        guard let task = mp_SecTaskCreateFromSelf(nil) else { return false }
        defer { mp_CFRelease(unsafeBitCast(task, to: CFTypeRef.self)) }

        guard let value = mp_SecTaskCopyValueForEntitlement(task, name as NSString, nil) else {
            return false
        }
        if let n = value as? NSNumber { return n.boolValue }
        if let b = value as? Bool { return b }
        return true   // 값이 있으나 불리언이 아님 (문자열/배열 등)
    }
}

// MARK: - jetsam 한도 직접 조회

@_silgen_name("memorystatus_control")
func mp_memorystatus_control(_ command: UInt32,
                             _ pid: Int32,
                             _ flags: UInt32,
                             _ buffer: UnsafeMutableRawPointer?,
                             _ buffersize: Int) -> Int32

let MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES: UInt32 = 7
let MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES: UInt32 = 8

/// xnu: bsd/sys/kern_memorystatus.h
struct MemlimitProperties {
    var memlimit_active: Int32 = 0        // MB, -1 = 무제한
    var memlimit_active_attr: UInt32 = 0
    var memlimit_inactive: Int32 = 0      // MB
    var memlimit_inactive_attr: UInt32 = 0
}

enum Jetsam {
    /// 할당해서 죽어보지 않고도 커널이 기록한 한도를 바로 읽는다.
    /// 이게 이 프로브의 핵심 측정값이다.
    static func limits() -> MemlimitProperties? {
        var props = MemlimitProperties()
        let size = MemoryLayout<MemlimitProperties>.size
        let rc = withUnsafeMutablePointer(to: &props) { ptr -> Int32 in
            mp_memorystatus_control(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES,
                                    getpid(), 0, UnsafeMutableRawPointer(ptr), size)
        }
        return rc == 0 ? props : nil
    }

    /// RamDonor를 대체할 수 있는 경로인지 확인용.
    /// com.apple.private.memorystatus 가 필요하고, 성공하면
    /// MeloNX에서 NSExtension 트릭 없이 한도를 올릴 수 있다는 뜻이다.
    static func trySet(activeMB: Int32, inactiveMB: Int32) -> (ok: Bool, errno: Int32) {
        var props = MemlimitProperties(memlimit_active: activeMB,
                                       memlimit_active_attr: 0,
                                       memlimit_inactive: inactiveMB,
                                       memlimit_inactive_attr: 0)
        let size = MemoryLayout<MemlimitProperties>.size
        let rc = withUnsafeMutablePointer(to: &props) { ptr -> Int32 in
            mp_memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES,
                                    getpid(), 0, UnsafeMutableRawPointer(ptr), size)
        }
        return (rc == 0, errno)
    }
}

// MARK: - 현재 사용량

enum VMStat {
    /// jetsam이 실제로 보는 값은 phys_footprint다. resident size가 아니다.
    static func physFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                           / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}

// MARK: - 기기 정보

enum Hardware {
    static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buf)
    }

    static var machine: String { sysctlString("hw.machine") }      // 예: AppleTV14,1
    static var product: String { sysctlString("hw.product") }
    static var physicalMemoryBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }
    static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

}

// MARK: - JIT 프로브

@_silgen_name("sys_icache_invalidate")
func mp_sys_icache_invalidate(_ start: UnsafeMutableRawPointer, _ size: Int)

@_silgen_name("vm_remap")
func mp_vm_remap(_ target_task: mach_port_t,
                 _ target_address: UnsafeMutablePointer<mach_vm_address_t>,
                 _ size: mach_vm_size_t,
                 _ mask: mach_vm_offset_t,
                 _ flags: Int32,
                 _ src_task: mach_port_t,
                 _ src_address: mach_vm_address_t,
                 _ copy: boolean_t,
                 _ cur_protection: UnsafeMutablePointer<vm_prot_t>,
                 _ max_protection: UnsafeMutablePointer<vm_prot_t>,
                 _ inheritance: vm_inherit_t) -> kern_return_t

@_silgen_name("vm_protect")
func mp_vm_protect(_ target_task: mach_port_t,
                   _ address: mach_vm_address_t,
                   _ size: mach_vm_size_t,
                   _ set_maximum: boolean_t,
                   _ new_protection: vm_prot_t) -> kern_return_t

private typealias JitFn = @convention(c) () -> Int32

/// AArch64:  mov w0, #42  /  ret
private let answerCode: [UInt32] = [0x52800540, 0xD65F03C0]

enum JITProbe {

    /// MeloNX의 allocateTest() + 실제 실행.
    /// MeloNX는 보호비트만 확인하는데, 여기서는 한 걸음 더 가서 호출해 본다.
    static func simpleMprotect() -> String {
        let pageSize = sysconf(_SC_PAGESIZE)
        guard let mem = mmap(nil, pageSize, PROT_READ | PROT_WRITE,
                             MAP_PRIVATE | MAP_ANON, -1, 0), mem != MAP_FAILED else {
            return "✗ mmap(RW) 실패 (errno \(errno))"
        }
        defer { munmap(mem, pageSize) }

        memcpy(mem, answerCode, answerCode.count * 4)

        guard mprotect(mem, pageSize, PROT_READ | PROT_EXEC) == 0 else {
            return "✗ mprotect(RX) 거부 (errno \(errno)) — JIT 불가"
        }
        guard hasExecBit(mem) else {
            return "✗ mprotect는 통과했으나 실행비트 미설정 — JIT 불가"
        }

        mp_sys_icache_invalidate(mem, pageSize)
        let r = unsafeBitCast(mem, to: JitFn.self)()
        return r == 42 ? "✓ 실행 성공 (42) — JIT 사용 가능"
                       : "△ 실행됐으나 반환값 \(r)"
    }

    /// MeloNX의 testDualMappedExecution(). TXM 환경용 경로.
    /// tvOS 16.6에서는 위 단순 경로만 되면 충분하지만, 둘 다 되면
    /// 상위 tvOS로 올라가도 여지가 있다는 뜻이다.
    static func dualMapping() -> String {
        let pageSize = UInt(vm_page_size)
        guard let rx = mmap(nil, Int(pageSize), PROT_READ | PROT_EXEC,
                            MAP_ANONYMOUS | MAP_PRIVATE, -1, 0), rx != MAP_FAILED else {
            return "✗ mmap(RX) 실패 (errno \(errno))"
        }
        defer { munmap(rx, Int(pageSize)) }

        var rw: mach_vm_address_t = 0
        var cur: vm_prot_t = 0
        var max: vm_prot_t = 0
        let kr = mp_vm_remap(mach_task_self_, &rw, mach_vm_size_t(pageSize), 0,
                             VM_FLAGS_ANYWHERE, mach_task_self_,
                             mach_vm_address_t(UInt(bitPattern: rx)), 0,
                             &cur, &max, VM_INHERIT_NONE)
        guard kr == KERN_SUCCESS else { return "✗ vm_remap 실패 (kr \(kr))" }
        defer {
            if let p = UnsafeMutableRawPointer(bitPattern: UInt(rw)) {
                munmap(p, Int(pageSize))
            }
        }

        guard mp_vm_protect(mach_task_self_, rw, mach_vm_size_t(pageSize), 0,
                            VM_PROT_READ | VM_PROT_WRITE) == KERN_SUCCESS else {
            return "✗ vm_protect(RW) 실패"
        }
        guard let rwPtr = UnsafeMutableRawPointer(bitPattern: UInt(rw)) else {
            return "✗ RW 포인터 변환 실패"
        }

        rwPtr.copyMemory(from: answerCode, byteCount: answerCode.count * 4)
        mp_sys_icache_invalidate(rx, Int(pageSize))

        let r = unsafeBitCast(rx, to: JitFn.self)()
        return r == 42 ? "✓ 듀얼 매핑 실행 성공 (42)" : "△ 반환값 \(r)"
    }

    private static func hasExecBit(_ address: UnsafeRawPointer) -> Bool {
        var region = vm_address_t(UInt(bitPattern: address))
        var size: vm_size_t = 0
        var info = vm_region_basic_info_64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_64>.size
                                           / MemoryLayout<integer_t>.size)
        var object: mach_port_t = mach_port_t(MACH_PORT_NULL)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                vm_region_64(mach_task_self_, &region, &size,
                             VM_REGION_BASIC_INFO_64, $0, &count, &object)
            }
        }
        guard kr == KERN_SUCCESS else { return false }
        return info.protection & VM_PROT_EXECUTE != 0
    }
}
