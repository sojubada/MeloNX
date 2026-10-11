# MeloNX tvOS 포팅 — GitHub 빌드 일체

MeloNX 2.7을 Apple TV(tvOS 16.6 + TrollStore)에서 돌리기 위한 포팅 오버레이와,
**Mac 없이 GitHub Actions에서 `.tipa` / `.ipa` 를 만들어 릴리즈하는 워크플로**입니다.

GitHub의 macOS 러너에는 Xcode와 appletvos SDK가 들어 있어서, 로컬에 Mac이
없어도 빌드와 릴리즈가 됩니다.

---

## 1. 명령 하나로 IPA 만들기

```bash
./make-ipa.sh
```

환경을 보고 알아서 고릅니다.

| 모드 | 조건 | 동작 |
|---|---|---|
| `./make-ipa.sh local` | macOS + Xcode(tvOS 플랫폼) + .NET 10 SDK | 이 Mac에서 끝까지 빌드 |
| `./make-ipa.sh ci` | `gh auth login` 만 되어 있으면 됨 | GitHub Actions 의 macOS 러너가 빌드, 결과를 내려받음 |
| `./make-ipa.sh probe` | 위와 같음 | MemProbe 만 빌드 (빠름) |

결과: `dist/MeloNX.ipa` 와 `dist/MeloNX.tipa` (내용 동일, TrollStore 로는 `.tipa` 가 편합니다)

`ci` 모드는 Mac이 없어도 됩니다. GitHub의 macOS 러너에 Xcode와 appletvos SDK가
들어 있습니다. 스크립트가 커밋·푸시·워크플로 실행·대기·아티팩트 내려받기까지
알아서 합니다. `origin` 원격이 없으면 비공개 리포지토리를 만들지 물어봅니다.

각 단계는 멱등입니다. 중간에 실패해서 고친 뒤 다시 돌리면 이미 끝난 단계
(패치, 네이티브 의존성)는 건너뜁니다.

---

## 2. 사전 준비

### 이 오버레이를 MeloNX 소스에 얹기

```bash
cd MeloNX-2_7/melonx          # 받으신 2.7 소스 루트

cp -R <오버레이>/.github .
cp -R <오버레이>/tvos .
cp    <오버레이>/project-tvos.yml <오버레이>/make-ipa.sh <오버레이>/README-tvOS.md .
cp    <오버레이>/gitignore-append .
chmod +x make-ipa.sh tvos/scripts/*.sh
```

### local 모드

```bash
# Xcode 설치 후 tvOS 플랫폼 추가: Xcode > Settings > Components > tvOS
brew install xcodegen ldid cmake pkg-config nasm
# .NET 10 SDK: https://dotnet.microsoft.com/download/dotnet/10.0
./make-ipa.sh local
```

첫 실행은 MoltenVK의 `fetchDependencies` 가 glslang · SPIRV-Cross ·
SPIRV-Tools 를 tvOS용으로 전부 빌드하느라 **한 시간 이상** 걸립니다.
`tvos/deps/out` 에 남으므로 다음부터는 건너뜁니다.

### ci 모드

```bash
brew install gh        # 또는 https://github.com/cli/cli#installation
gh auth login
./make-ipa.sh ci
```

### 릴리즈

```bash
git tag tvos-v0.1 && git push origin tvos-v0.1
```

태그를 밀면 워크플로가 릴리즈를 만들고 `.tipa` / `.ipa` 를 첨부합니다.
`--private` 리포지토리를 권합니다. ROM·키·펌웨어는 절대 커밋하지 마십시오.
공개로 올릴 경우 원본 MIT 라이선스(`LICENSE.txt`, Ryujinx Team and
Contributors)를 유지하고 비공식 포팅임을 명시하십시오.

---

## 2-1. 그래도 MemProbe 를 먼저 돌리십시오

`com.apple.developer.kernel.increased-memory-limit` 은 Apple 문서에
iOS / iPadOS / visionOS 만 기재되어 있고 **tvOS가 없습니다.** XNU 공통
코드라 동작할 가능성이 높지만 확증이 없습니다. 본 포팅은 네이티브 의존성
빌드만 한 시간이 넘는데, 이 숫자가 작으면 그 시간이 전부 무의미해집니다.

```bash
./make-ipa.sh probe     # 몇 분이면 끝납니다
```

`MemProbe-full.tipa` 와 `MemProbe-baseline.tipa` 를 각각 TrollStore 로
설치하고(번들 ID가 달라 공존합니다) **jetsam active 한도**를 비교하십시오.

| 결과 | 판단 |
|---|---|
| full이 baseline보다 유의하게 큼 (예: 1400 → 3000 MB) | **tvOS가 엔타이틀먼트를 존중함 → 진행** |
| 둘이 같음 | "한도를 3500 MB로 설정 시도" 버튼 확인 (`memorystatus_control` 경로) |
| 둘 다 2000 MB 미만이고 상향도 실패 | **여기서 중단** |

램프 테스트 중 앱이 갑자기 종료되는 것은 정상입니다(jetsam). 매 청크마다
최고치를 동기 기록하므로 재실행해서 "지난 최고치"를 보면 됩니다.

---

## 3. 첫 실행은 실패하는 것이 정상입니다

이 포팅은 **컴파일 검증을 거치지 않은 1차 패치**입니다.
리눅스에서는 Swift 툴체인과 Apple SDK를 쓸 수 없어 빌드 확인이 불가능했습니다.

워크플로를 **에러 수집기로 쓰십시오.** 실패하면

- 실행 요약(Summary)에 `error:` 줄을 최대 80개까지 모아 보여줍니다
- 전체 로그는 `build-logs` 아티팩트에 들어갑니다

남아 있을 만한 에러는 tvOS에 없는 SwiftUI modifier 종류입니다
(`.navigationBarTitleDisplayMode`, `.listStyle(.insetGrouped)`,
`TextField` 스타일 등). 각 지점을 `#if os(tvOS)` 로 분기하고 커밋하면
다음 실행에서 다음 에러로 넘어갑니다.

가장 먼저 막힐 지점은 **`Melo-Controller` 패키지**일 가능성이 높습니다.
`tvos/scripts/prepare-packages.sh` 가 `Package.swift` 의 `platforms` 에
`.tvOS(.v16)` 을 넣지만, 패키지 안에 온스크린 터치 컨트롤러 코드가 있으면
그 파일들을 `#if os(iOS)` 로 감싸야 합니다. tvOS 타겟이 실제로 필요한 것은
타입뿐입니다 — `VirtualControllerButton`(55곳), `VirtualControllerManager`(8곳),
`VirtualAddressing`(14곳).

---

## 4. 구성

```
make-ipa.sh                명령 하나로 IPA (local / ci / probe)
.github/workflows/
  build-memprobe.yml       1단계 게이트. full/baseline 두 변종 매트릭스 빌드
  build-tvos.yml           본 포팅. 패치 → 의존성 → .NET → Xcode → .tipa → 릴리즈
project-tvos.yml           XcodeGen 설정 (tvOS 타겟을 매번 생성)
tvos/
  Info-tvOS.plist          iOS 전용 키 제거, 컨트롤러 선언 유지
  MeloNX-tvOS.entitlements TrollStore 전용 엔타이틀먼트 4종
  patches/
    01-swift-tvos.patch    Swift 프런트엔드 (30개 파일)
    02-ryujinx-library-csproj.patch   RID·SDK 경로
  scripts/
    prepare-packages.sh    SPM 패키지를 tvOS 대응으로 포크
    build-deps.sh          MoltenVK / SDL3 / FFmpeg appletvos 빌드
    package-tipa.sh        ldid 서명 + .tipa/.ipa 포장 + 플랫폼 검증
  memprobe/                1단계 프로브 앱 소스
```

### 왜 기존 `MeloNX.xcodeproj` 를 고치지 않는가

Xcode 16의 **file system synchronized group** 을 쓰고 있어서
`project.pbxproj` 를 스크립트로 안전하게 편집하기가 어렵고, CI에서
재현되지 않습니다. 대신 XcodeGen으로 tvOS 전용 프로젝트를 매번
생성합니다. iOS 프로젝트는 그대로 두니 양쪽을 병행할 수 있습니다.

---

## 5. 포팅 내용 요약

### 컨트롤러 — 수정 0건

`GCDeviceHaptics` 가 tvOS 14.0+ 이고 `createEngine(withLocality:)` 가
`CHHapticEngine` 을 반환하므로 CoreHaptics 타입을 tvOS에서도 쓸 수 있습니다.
`BaseController` 의 럼블 분기를 그대로 둬도, 기기 자체 햅틱 경로는
`capabilitiesForHardware().supportsHaptics` 가 Apple TV에서 false 이므로
`RumbleController`(실패 가능 이니셜라이저)가 알아서 nil 이 됩니다.

`MenuNavigator` · `MenuFocusView` · `MenuFocusScope` 는 손대지 않았습니다 —
iOS에서 물리 컨트롤러 사용자를 위해 만든 포커스 내비게이션이 tvOS 요구사항과
그대로 겹칩니다. `contextMenu` 도 tvOS 14+ 라서 19곳 전부 유지했습니다.

### JIT — TrollStore 가 직접 해결

`JITChecker.jitEnabled()` 는 첫 줄에서 `dynamic-codesigning` 엔타이틀먼트를
확인하고 통과합니다. TrollStore 설치본에는 이게 실제로 붙으므로
`EnableJIT.swift` 의 네 가지 URL 스킴 경로(StikDebug / StosDebug /
TrollStore / LiveContainer)는 호출되지 않는 죽은 코드가 됩니다.
그 네 앱이 tvOS에 없다는 것이 원래 유일한 차단 사유였습니다.

tvOS 16.6은 SPTM/TXM 이전 세대(iOS 17 + A15 이상에서 도입)이므로
`mmap(RW)` → `mprotect(RX)` 단순 경로가 그대로 동작합니다. iOS 26 우회
장치(`JIT26Breakpoint.swift`, `BreakpointJIT.framework`)는 링크에서 뺐습니다.

### 가장 중요한 수정 — `#available` 함정

Swift availability 조건 끝의 `*` 는 "명시되지 않은 플랫폼은 전부 사용 가능"을
뜻합니다. 그래서 tvOS 타겟에서 `#available(iOS 26, *)` 가 **tvOS 16.6에서도
참**이 됩니다. 안의 API가 tvOS에도 있으면 컴파일 에러조차 나지 않습니다.

실제로 걸린 곳 — `UI/MeloNXApp.swift:52` 가 `DUAL_MAPPED_JIT=1` 을 환경변수에
넣어 C# 코어가 TXM 없는 기기에서 `DualMappedNoWxCache` 를 고르게 만들고 있었습니다.
패치가 31곳 전부에 같은 번호의 tvOS 절을 넣습니다(`iOS 19, *` → `iOS 19, tvOS 19, *`).

### 네이티브 의존성 — 9개가 아니라 4개

번들된 프리빌트 9개는 전부 ios-arm64 슬라이스뿐이지만, 런타임에 실제로
로드되는 것은 4개입니다.

| 라이브러리 | 로드 지점 | 처리 |
|---|---|---|
| SDL3.framework | `Library.cs:143` `NativeLibrary.Load("@rpath/SDL3.framework/SDL3")` | 재빌드 (필수) |
| libMoltenVK.dylib | `MVKInitialization.cs` `[LibraryImport("libMoltenVK.dylib")]` | 재빌드 (필수, **Ryujinx 포크**) |
| libavcodec.dylib | `FFmpegApi.cs` `AvCodecLibraryName = "avcodec"` | 재빌드 (영상 디코딩) |
| libavutil.dylib | `FFmpegApi.cs` `AvUtilLibraryName = "avutil"` | 재빌드 (영상 디코딩) |
| libteakra.a | 참조 없음 | **제외** (3DS Teak DSP 에뮬레이터, Switch와 무관) |
| BreakpointJIT.framework | iOS 26 TXM 전용 | **제외** |
| libSPIRV.a, libav{filter,format}, libsw{resample,scale} | 링크 전용/미사용 | 필요 시 MoltenVK 빌드 산출물에서 |

### .csproj 에 숨어 있던 함정

원본은 `-isysroot` 를 iPhoneOS SDK 로 하드코딩하고, 그 조건이
`tvos-arm64` 에서도 참입니다. RID만 바꿔 publish하면 **tvOS 타겟을 iOS SDK에
링크**해놓고 링크는 통과합니다. 패치가 SDK 경로를 RID에서 유도하고,
해당 없는 RID엔 `<Error>` 로 명시 실패하게 만듭니다. 워크플로도
`vtool -show-build` 로 `platform TVOS` 를 검증합니다.

### 기능 축소

| 항목 | tvOS에서 |
|---|---|
| ROM/키/펌웨어 반입 | 문서 피커 → 자체 파일 브라우저(`TVFileBrowser`). `/var/mobile/Media` 등을 직접 탐색 |
| RamDonor | 비활성 (`ar.viewer` 익스텐션 포인트 없음). `memorystatus_control` 로 대체 |
| 화면 회전 | 무동작 |
| 기기 햅틱 | 없음 (컨트롤러 럼블은 동작) |
| 대체 앱 아이콘 | 무동작 |
| 사진 라이브러리 아바타 | 번들 아바타 그리드로 대체 |
| 외부 디스플레이/AirPlay | 불필요 (Apple TV 자체가 디스플레이) |
| 슬라이더 | 좌/우 입력 기반 `TVSlider` |
| 앱 아이콘 | tvOS 레이어드 아이콘·Top Shelf 미제작 → 홈 화면에 빈 타일 |

---

## 6. 기대치

Apple TV 4K 3세대는 A15 / **RAM 4GB** / 128GB 입니다. MeloNX README의
기준표로는 "최저 호환(무료 계정) iPhone 12"와 같은 4GB 티어입니다.
경량·2D·인디 타이틀은 동작하고 대형 3D 타이틀은 OOM이나 심한 저하가
예상됩니다.

반대 방향으로는 배터리와 얇은 섀시가 없어 **지속 클럭이 iPhone 13보다
유리할 수 있습니다.** 에뮬레이터는 스로틀링에 민감하니 실측에서
의외의 결과가 나올 여지가 있습니다.

---

원본: MeloNX (Ryujinx 기반), MIT License, Copyright (c) Ryujinx Team and Contributors.
이 포팅은 비공식이며 원본 프로젝트와 무관합니다.
