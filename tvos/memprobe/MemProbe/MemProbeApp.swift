//
//  MemProbeApp.swift
//  MemProbe — tvOS 메모리/JIT 한도 실측 프로브
//
//  목적: MeloNX를 tvOS로 포팅할 가치가 있는지 결정하는 단 하나의 숫자,
//        "이 Apple TV에서 한 프로세스가 쓸 수 있는 실제 메모리 한도"를 재는 것.
//
//  읽는 법
//   · jetsam 한도(active)  : 커널이 기록한 공식 한도. 이게 3000 MB 근처면 성립.
//   · 램프 테스트 최고치     : 실제로 터치해서 도달한 값. 위 숫자의 검증.
//   · JIT 단순 경로        : ✓면 MeloNX의 allocateTest() 경로가 통한다.
//
//  엔타이틀먼트 유/무 두 빌드를 만들어 비교하는 것이 이 앱의 사용법이다.
//    ./build.sh full      → 메모리 엔타이틀먼트 포함
//    ./build.sh baseline  → 미포함 (대조군)
//

import SwiftUI
import Combine

@main
struct MemProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeView() }
    }
}

// MARK: - 화면

struct ProbeView: View {

    @StateObject private var ramp = RampTest()

    @State private var availableMB: Int = 0
    @State private var footprintMB: Int = 0
    @State private var jitSimple: String = "미실행"
    @State private var jitDual: String = "미실행"
    @State private var setLimitResult: String = "미실행"

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var limits: MemlimitProperties? { Jetsam.limits() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {

                header

                section("기기") {
                    row("모델", Hardware.machine)
                    row("tvOS", Hardware.osVersion)
                    row("물리 RAM", mb(Int(Hardware.physicalMemoryBytes / 1_048_576)))
                }

                section("엔타이틀먼트 (서명에 붙어 있는지)") {
                    ent("increased-memory-limit", Ent.increasedMemory)
                    ent("extended-virtual-addressing", Ent.extendedVA)
                    ent("dynamic-codesigning", Ent.dynamicCodesign)
                    ent("private.memorystatus", Ent.memorystatus)
                    ent("platform-application", Ent.platformApp)
                }

                section("★ jetsam 한도 — 이 프로젝트의 판가름") {
                    if let l = limits {
                        row("active 한도", l.memlimit_active < 0
                                            ? "무제한" : mb(Int(l.memlimit_active)),
                            emphasis: true)
                        row("inactive 한도", l.memlimit_inactive < 0
                                            ? "무제한" : mb(Int(l.memlimit_inactive)))
                    } else {
                        row("조회 실패", "memorystatus_control(GET) 거부 — 램프 테스트로 측정하세요")
                    }
                    row("os_proc_available_memory", mb(availableMB), emphasis: true)
                    row("현재 phys_footprint", mb(footprintMB))
                }

                section("JIT") {
                    row("단순 mprotect 경로", jitSimple, emphasis: true)
                    row("듀얼 매핑 경로", jitDual)
                    HStack(spacing: 28) {
                        Button("단순 경로 테스트") { jitSimple = JITProbe.simpleMprotect() }
                        Button("듀얼 매핑 테스트") { jitDual = JITProbe.dualMapping() }
                    }
                    .padding(.top, 8)
                }

                section("jetsam 한도 직접 상향 (RamDonor 대체 가능성)") {
                    row("결과", setLimitResult)
                    Button("한도를 3500 MB로 설정 시도") {
                        let r = Jetsam.trySet(activeMB: 3500, inactiveMB: 3500)
                        setLimitResult = r.ok
                            ? "✓ 성공 — NSExtension 트릭 없이 상향 가능"
                            : "✗ 거부 (errno \(r.errno)) — private.memorystatus 필요"
                    }
                    .padding(.top, 8)
                }

                section("램프 테스트 (실측)") {
                    row("지난 최고치", mb(ramp.highWaterMB), emphasis: true)
                    row("현재 할당", mb(ramp.allocatedMB))
                    row("footprint", mb(ramp.footprintMB))
                    row("남은 예산", mb(ramp.availableMB))
                    if let note = ramp.finishedNote { row("종료 사유", note) }

                    Text("앱이 갑자기 종료되면 jetsam에 죽은 것이고, 그게 정상 결과입니다. "
                       + "다시 실행해서 '지난 최고치'를 확인하세요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    HStack(spacing: 28) {
                        Button(ramp.running ? "중단" : "64 MB씩 할당 시작") {
                            if ramp.running { ramp.stop() } else { ramp.start(chunkMB: 64) }
                        }
                        Button("최고치 초기화") { ramp.resetHighWater() }
                    }
                    .padding(.top, 8)
                }

                verdict
            }
            .padding(60)
        }
        .background(Color.black)
        .onReceive(tick) { _ in
            availableMB = mp_os_proc_available_memory() / 1_048_576
            footprintMB = Int(VMStat.physFootprintBytes() / 1_048_576)
        }
    }

    // MARK: 판정 요약

    private var verdict: some View {
        let budget = max(ramp.highWaterMB, availableMB)
        let jitOK = jitSimple.hasPrefix("✓")

        let text: String
        if budget == 0 {
            text = "먼저 램프 테스트를 돌리거나 1초 더 기다려 주세요."
        } else if budget >= 2800 && jitOK {
            text = "성립. 약 \(budget) MB + JIT 확보 — MeloNX 포팅을 진행할 근거가 됩니다."
        } else if budget >= 2800 {
            text = "메모리는 충분(\(budget) MB)하지만 JIT이 아직 미확인입니다. "
                 + "TrollStore 설치본인지, dynamic-codesigning이 붙었는지 확인하세요."
        } else if budget >= 1800 {
            text = "경계선 (\(budget) MB). 경량 타이틀만 가능할 전망입니다."
        } else {
            text = "부족 (\(budget) MB). 엔타이틀먼트 미포함 빌드라면 full 빌드로 재측정하고, "
                 + "full에서도 같다면 tvOS가 해당 엔타이틀먼트를 무시하는 것이므로 포팅 가치가 없습니다."
        }

        return VStack(alignment: .leading, spacing: 12) {
            Text("판정").font(.title2).bold()
            Text(text).font(.title3).foregroundStyle(.white)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: 구성 요소

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MemProbe").font(.largeTitle).bold()
            Text("MeloNX tvOS 포팅 타당성 — 메모리 한도 및 JIT 실측")
                .font(.title3).foregroundStyle(.secondary)
        }
    }

    private func section<C: View>(_ title: String,
                                  @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3).bold().foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ label: String, _ value: String, emphasis: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(label)
                .frame(width: 420, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(emphasis ? .bold : .regular)
                .foregroundStyle(emphasis ? Color.white : Color.primary)
            Spacer(minLength: 0)
        }
    }

    private func ent(_ label: String, _ name: String) -> some View {
        row(label, Ent.has(name) ? "✓ 있음" : "✗ 없음")
    }

    private func mb(_ v: Int) -> String {
        v <= 0 ? "—" : "\(v) MB  (\(String(format: "%.2f", Double(v) / 1024)) GB)"
    }
}
