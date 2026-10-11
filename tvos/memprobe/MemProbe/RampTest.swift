//
//  RampTest.swift
//  MemProbe
//
//  MeloNX의 MemoryLimitManager.swift와 같은 방식의 점진 할당 테스트.
//  jetsam이 프로세스를 죽이면 malloc이 nil을 돌려주는 대신 앱이 그냥
//  종료되므로, 매 청크마다 최고치를 UserDefaults에 적어 둔다.
//  앱이 꺼지면 그 값이 곧 측정 결과다. 재실행하면 지난 최고치가 보인다.
//
//  구조는 일부러 MeloNX와 동일하게 두었다(plain class + DispatchQueue.main.async).
//  actor 격리를 끌어들이면 백그라운드 스레드에서 플래그를 못 읽는다.
//

import Foundation
import Combine

private let kHighWater = "MemProbe.highWaterMB"

final class RampTest: ObservableObject {

    @Published private(set) var allocatedMB: Int = 0
    @Published private(set) var footprintMB: Int = 0
    @Published private(set) var availableMB: Int = 0
    @Published private(set) var running = false
    @Published private(set) var finishedNote: String?

    /// 지난 실행에서 도달한 최고치. jetsam에 죽었다면 이게 실질 한도다.
    @Published private(set) var highWaterMB: Int = UserDefaults.standard.integer(forKey: kHighWater)

    /// 백그라운드 스레드에서 읽는다. 단순 Bool이라 워드 단위 접근으로 충분하다.
    private var stopRequested = false

    func resetHighWater() {
        UserDefaults.standard.removeObject(forKey: kHighWater)
        UserDefaults.standard.synchronize()
        highWaterMB = 0
    }

    func stop() { stopRequested = true }

    /// chunkMB 단위로 malloc 후 memset으로 전부 터치한다.
    /// 터치하지 않으면 가상 예약에 그쳐 jetsam 집계에 들어가지 않는다.
    func start(chunkMB: Int = 64) {
        guard !running else { return }
        running = true
        stopRequested = false
        finishedNote = nil
        allocatedMB = 0

        Thread.detachNewThread { [weak self] in
            let chunkBytes = chunkMB * 1024 * 1024
            var total = 0
            var blocks: [UnsafeMutableRawPointer] = []

            while true {
                guard let self else { break }
                if self.stopRequested { break }

                guard let p = malloc(chunkBytes) else {
                    let reached = total / (1024 * 1024)
                    DispatchQueue.main.async {
                        self.finish(note: "malloc이 \(reached) MB에서 실패했습니다 "
                                        + "(jetsam에 죽지 않고 할당만 거절된 경우).",
                                    blocks: blocks)
                    }
                    return
                }

                memset(p, 0xA5, chunkBytes)
                blocks.append(p)
                total += chunkBytes

                let mb = total / (1024 * 1024)
                let foot = Int(VMStat.physFootprintBytes() / (1024 * 1024))
                let avail = mp_os_proc_available_memory() / (1024 * 1024)

                // 죽기 직전 값을 남기는 것이 목적이므로 매번 즉시 기록한다.
                let prev = UserDefaults.standard.integer(forKey: kHighWater)
                if mb > prev {
                    UserDefaults.standard.set(mb, forKey: kHighWater)
                    UserDefaults.standard.synchronize()
                }
                NSLog("[MemProbe] allocated=%d MB  footprint=%d MB  available=%d MB",
                      mb, foot, avail)

                DispatchQueue.main.async {
                    self.allocatedMB = mb
                    self.footprintMB = foot
                    self.availableMB = avail
                    if mb > self.highWaterMB { self.highWaterMB = mb }
                }

                usleep(250_000)
            }

            DispatchQueue.main.async {
                self?.finish(note: "사용자가 중단했습니다.", blocks: blocks)
            }
        }
    }

    private func finish(note: String, blocks: [UnsafeMutableRawPointer]) {
        for b in blocks { free(b) }
        running = false
        stopRequested = false
        finishedNote = note
    }
}
