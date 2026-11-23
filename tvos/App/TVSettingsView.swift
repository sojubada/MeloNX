//
//  TVSettingsView.swift
//  MeloNX tvOS
//
//  Settings tab, laid out like the iOS settings (Graphics / System / Input /
//  Advanced) but with tvOS controls: Pickers open a list, Toggles flip with the
//  remote's select button. tvOS has no Slider, so volumes and scale are steps.
//  Changes apply from the next game start.
//

import SwiftUI

struct TVSettingsView: View {
    @ObservedObject private var settings = TVSettings.shared
    @State private var confirmReset = false

    private var v: Binding<TVSettingsValues> { $settings.values }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("해상도 배율", selection: v.resScale) {
                        ForEach([Float(0.5), 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { scale in
                            Text(scale == 1 ? "1x (기본)" : "\(scale.formatted())x").tag(scale)
                        }
                    }
                    Toggle("TV 모드 (도킹)", isOn: v.dockedMode)
                    choice("화면 비율", AspectRatio.allCases, v.aspectRatio) { $0.displayName }
                    Toggle("수직 동기화 (60fps 제한)", isOn: v.vSyncSwitch)
                    choice("안티에일리어싱", AntiAliasing.allCases, v.antiAliasing) { $0.displayName }
                    choice("스케일링 필터", ScalingFilter.allCases, v.scalingFilter) { $0.displayName }
                    Picker("이방성 필터링", selection: v.maxAnisotropy) {
                        Text("자동").tag(Float(-1))
                        ForEach([Float(2), 4, 8, 16], id: \.self) { Text("\(Int($0))x").tag($0) }
                    }
                } header: {
                    Text("그래픽")
                } footer: {
                    Text("해상도 배율과 TV 모드는 메모리와 GPU를 더 씁니다. 4GB Apple TV에서는 1x·휴대 모드가 안정적입니다.")
                }

                Section {
                    Toggle("텍스처 재압축", isOn: v.textureRecompression)
                    Toggle("셰이더 캐시", isOn: v.shaderCache)
                    Toggle("비동기 셰이더 컴파일", isOn: v.asyncShaderCompilation)
                    choice("그래픽 백엔드 스레딩", BackendThreading.allCases, v.backendThreading) { $0.displayName }
                    Toggle("매크로 HLE", isOn: v.macroHLE)
                    Toggle("호스트 메모리 예산 추적", isOn: v.hostMemoryBudget)
                } header: {
                    Text("그래픽 고급")
                } footer: {
                    Text("텍스처 재압축과 메모리 예산 추적은 메모리 부족 종료를 줄여 줍니다. 켜 두는 것을 권장합니다.")
                }

                Section {
                    choice("시스템 언어", SystemLanguage.allCases, v.language) { $0.displayName }
                    choice("지역", NativeRegionCode.allCases, v.region) { $0.displayName }
                    Picker("게임 음량", selection: v.audioVolume) {
                        ForEach([Float(0), 0.25, 0.5, 0.75, 1.0], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                    }
                    Toggle("PPTC (번역 캐시)", isOn: v.ptc)
                    Toggle("인터넷 접속 허용", isOn: v.internetAccess)
                } header: {
                    Text("시스템")
                }

                Section {
                    choice("컨트롤러 종류", ControllerType.allCases.filter { $0 != .handheld && $0 != .pokeball },
                           v.player1Type) { $0.displayName }
                    Toggle("A/B·X/Y 위치 바꾸기 (Xbox·PS 패드)", isOn: v.swapFaceButtons)
                } header: {
                    Text("입력")
                } footer: {
                    Text("연결된 게임패드 모두에 적용됩니다. 위치 바꾸기를 켜면 Xbox·PS 패드에서도 Switch처럼 오른쪽 버튼이 A(확인)입니다. 일시정지: Siri Remote의 Menu 또는 패드 − + L R 동시 입력. 게임 중 패드 연결이 끊기면 자동으로 일시정지합니다.")
                }

                Section {
                    Toggle("메뉴 음악", isOn: v.menuMusic)
                    Picker("메뉴 음악 음량", selection: v.menuMusicVolume) {
                        ForEach([Float(0.25), 0.5, 0.75, 1.0], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                    }
                } header: {
                    Text("메뉴")
                } footer: {
                    Text("직접 고른 음악을 쓰려면 \(TVMenuMusic.shared.musicFolder.path) 에 mp3·m4a 파일을 넣으세요.")
                }

                Section {
                    choice("메모리 관리 방식", MemoryManagerMode.allCases, v.memoryManager) { $0.displayName }
                    Toggle("RAM 스왑 (저장 공간을 메모리로 사용, 앱 재시작 후 적용)", isOn: v.guestSwap)
                    Toggle("RAM 확장 (8GB 게임용)", isOn: v.expandRAM)
                    Toggle("없는 서비스 무시", isOn: v.ignoreMissingServices)
                    Toggle("디버그 로그", isOn: v.debugLogs)
                    Toggle("Metal 성능 표시 (앱 재시작 후 적용)", isOn: v.metalHUD)
                    Button("기본값으로 되돌리기", role: .destructive) { confirmReset = true }
                } header: {
                    Text("고급")
                } footer: {
                    Text("로그: \(TVPaths.logs.path)")
                }
            }
            .navigationTitle("설정")
        }
        .alert("모든 설정을 기본값으로 되돌릴까요?", isPresented: $confirmReset) {
            Button("되돌리기", role: .destructive) { settings.reset() }
            Button("취소", role: .cancel) {}
        }
    }

    /// Picker over a MeloNX option enum, stored by its Int id.
    private func choice<T: Identifiable>(_ title: String, _ cases: [T], _ selection: Binding<Int>,
                                         _ name: @escaping (T) -> String) -> some View where T.ID == Int {
        Picker(title, selection: selection) {
            ForEach(cases) { item in
                Text(name(item)).tag(item.id)
            }
        }
    }
}
