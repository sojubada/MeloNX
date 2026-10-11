//
//  ExceptionHandler.swift
//  MeloNX
//
//  Created by Stossy11 on 29/8/2026.
//

import Foundation
import Darwin

private let crashLogPathCString: UnsafeMutablePointer<Int8> = {
    let path = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("last_crash.log").path
    return strdup(path)
}()

func signalCrashHandler(_ sig: Int32, _ info: UnsafeMutablePointer<siginfo_t>?, _ ucontextRaw: UnsafeMutableRawPointer?) {
    let crashLogFD = open(crashLogPathCString, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard crashLogFD >= 0 else {
        signal(sig, SIG_DFL)
        raise(sig)
        return
    }


    let faultAddr = UInt(bitPattern: info?.pointee.si_addr)
    let siCode = info?.pointee.si_code ?? 0

    var pc: UInt64 = 0
    var lr: UInt64 = 0
    var fp: UInt64 = 0
    var sp: UInt64 = 0

    #if arch(arm64)
    if let ucontextRaw = ucontextRaw {
        let ucontext = ucontextRaw.assumingMemoryBound(to: ucontext_t.self)
        if let mcontext = ucontext.pointee.uc_mcontext {
            let state = mcontext.pointee.__ss
            pc = state.__pc
            lr = state.__lr
            fp = state.__fp
            sp = state.__sp
        }
    }
    #endif

    var buffer = [Int8](repeating: 0, count: 512)
    withUnsafeMutablePointer(to: &buffer[0]) { ptr in
        _ = snprintf(ptr: ptr, 512,
            "sig=%d code=%d addr=0x%lx pc=0x%llx lr=0x%llx fp=0x%llx sp=0x%llx\n",
            sig, siCode, faultAddr, pc, lr, fp, sp)
    }
    _ = write(crashLogFD, &buffer, strlen(&buffer))

    #if arch(arm64)
    var currentFP = UnsafeRawPointer(bitPattern: UInt(fp))
    for _ in 0..<32 {
        guard let framePtr = currentFP else { break }
        let savedLR = framePtr.advanced(by: 8).assumingMemoryBound(to: UInt64.self).pointee
        let nextFP = framePtr.assumingMemoryBound(to: UnsafeRawPointer?.self).pointee
        if savedLR == 0 { break }

        var frameBuf = [Int8](repeating: 0, count: 64)
        withUnsafeMutablePointer(to: &frameBuf[0]) { ptr in
            _ = snprintf(ptr: ptr, 64, "  0x%llx\n", savedLR)
        }
        _ = write(crashLogFD, &frameBuf, strlen(&frameBuf))

        currentFP = nextFP
    }
    #endif

    close(crashLogFD)

    signal(sig, SIG_DFL)
    raise(sig)
}

@discardableResult
func snprintf(ptr: UnsafeMutablePointer<Int8>, _ size: Int, _ format: String, _ args: CVarArg...) -> Int32 {
    return withVaList(args) { vsnprintf(ptr, size, format, $0) }
}

enum CrashHandlerInstaller {
    static let crashSignals: [Int32] = [
        SIGSEGV,
        SIGBUS,
        SIGILL,
        SIGABRT,
        SIGFPE,
        SIGSYS,
    ]

    static func install() {
        for sig in crashSignals {
            var newAction = sigaction()
            newAction.__sigaction_u.__sa_sigaction = signalCrashHandler

            newAction.sa_flags = SA_SIGINFO
            sigemptyset(&newAction.sa_mask)

            if sigaction(sig, &newAction, nil) != 0 {
                continue
            }
        }
    }
}
