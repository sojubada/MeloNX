# MeloNX for Apple TV (tvOS 16, TrollStore)

MeloNX 2.7을 Apple TV에서 돌리는 비공식 포팅입니다. 빌드는 전부 GitHub Actions에서 합니다(Mac 불필요).

## 구조

iOS SwiftUI 앱을 파일마다 고치는 대신, **에뮬레이터와 맞닿은 코어 Swift 파일은 그대로 컴파일**하고
TV용 화면만 새로 씁니다.

| 그대로 쓰는 iOS 코드 | 역할 |
|---|---|
| `Core/Ryujinx.swift` | C# 코어 브리지 (`main_ryujinx_sdl`, 게임패드, 펌웨어 …) |
| `Core/Models/**` | `Options`, `NativeOptions.h` 타입, `GameInfo`, 컨트롤러 매핑 |
| `Core/Controllers/{Base,Native}Controller.swift`, `Motion`, `Rumble` | GCController 입력·진동·컨트롤러 자이로 |
| `Core/Callbacks`, `Common/EntitlementChecker.swift`, `Common/Models/GameFileType.swift` | |

| tvOS 전용 (`tvos/App`) | |
|---|---|
| `TVAppDelegate.swift` | 시작 순서: SDL → 환경변수 → 데이터 경로 → `Ryujinx.initialize()` |
| `TVPaths.swift` | 데이터 루트 = 앱 컨테이너 `Documents/` (iOS와 같은 `roms/`, `system/`), 시작 로그·stdout 기록 |
| `TVSystem.swift` | JIT 판정(`dynamic-codesigning` + RW→RX 시험), jetsam 한도 상향 |
| `TVControllers.swift` | 확장 게임패드 목록, 플레이어 1… 연결 |
| `TVEmulator.swift` | 게임 목록, 실행 조건(JIT·게임패드·키), 에뮬레이션 스레드 |
| `TVEmulationViewController.swift` | 게임 화면(MTKView → CAMetalLayer), 일시정지 메뉴 |
| `TVLibraryView.swift` | 홈 화면 |
| `TVShims.swift` | AirPlay·MetalFX 자리 채움 |

### iOS 소스에 가한 변경
- C#: `OperatingSystem.IsIOS()` 92곳 → `IsIOS() || IsTvOS()` (.NET에서 tvOS는 IsIOS가 false)
- C#: 오디오 지원 판정과 MoltenVK 파이프라인 분기에 tvOS 버전 추가
- C#: `AppDataManager`가 `MELONX_BASE_DIR` 환경변수를 데이터 루트로 받음
- `Ryujinx.Library.csproj`: `tvos-arm64` RID, appletvos SDK 링크
- `BaseController.swift`, `BaseController+Motion.swift`: 기기 모션(CoreMotion) 부분만 `#if !os(tvOS)`
- `nuget.config`: LibHac 알파 피드를 `git.ryujinx.app/api/packages/projects/nuget`로 (기존 피드가 비었음)

### 빌드
`.github/workflows/build-tvos.yml`

```
deps  ─┐  MoltenVK 1.4.0 · SDL3 e4f75ba · FFmpeg (appletvos)   캐시
core  ─┼▶ app   NativeAOT tvos-arm64                             캐시
       ┘        XcodeGen(project-tvos.yml) → xcodebuild → ldid 서명 → MeloNX.tipa
```

`tvos-v*` 태그를 밀면 릴리즈가 만들어집니다. 사용법은 `tvos/RELEASE_NOTES.md`.
