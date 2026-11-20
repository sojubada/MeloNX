## MeloNX 2.7 for Apple TV — 비공식 tvOS 포팅

**TrollStore 전용입니다.** tvOS 16.x(TrollStore 설치) Apple TV에서 동작하도록 만든 빌드입니다.
실기기 검증 전의 첫 빌드이므로, 문제가 생기면 아래 로그 폴더를 확인해 주세요.

### 설치
1. `MeloNX.tipa`를 TrollStore로 설치합니다.
2. 앱을 한 번 실행하면 앱 컨테이너 `Library/Caches/MeloNX` 안에 아래 폴더가 만들어집니다(원본 MeloNX와 같은 구조). tvOS는 앱이 자기 `Documents`를 쓰지 못하게 막기 때문입니다.

### 파일 넣는 곳 (`/var/mobile/Containers/Data/Application/<UUID>/Library/Caches/MeloNX/`)
| 무엇 | 위치 |
|---|---|
| 게임 `.nsp` `.xci` `.nro` | `roms/` (하위 폴더 가능) |
| `prod.keys` `title.keys` | `system/` |
| 펌웨어 `.zip` | `firmware/` → 홈 화면 "펌웨어 설치" (**필수**: 없으면 게임이 시작 직후 종료) |
| 로그 | `Logs/` — `tvos-app.log`, `stdout.log`, 직전 실행 `stdout.prev.log` |

본인 기기에서 덤프한 게임·키·펌웨어만 사용하세요.

### 동작
- **JIT**: iPad의 MeloNX와 같은 방식입니다. TrollStore가 디버거로 붙어야 켜집니다.
  - 가장 확실한 방법: TrollStore 앱 목록에서 MeloNX 선택 → **Open with JIT**
  - 아이콘으로 실행하면 앱이 TrollStore에 JIT를 자동 요청합니다(`apple-magnifier://enable-jit`). 홈 화면의 **JIT 켜기** 버튼도 같은 요청을 보냅니다.
  - JIT가 없어도 앱은 열리고, 게임 시작만 막힙니다.
  - (이전 빌드의 `dynamic-codesigning` 권한은 A12 이후 칩에서 금지된 권한이라 앱이 시작 전에 종료됐습니다. 제거했습니다.)
- **게임패드 필수**: 확장 게임패드(8BitDo, Xbox, DualSense 등)가 연결돼 있지 않으면 게임이 시작되지 않습니다. 메뉴는 Siri Remote로도 조작됩니다.
- **일시정지 / 종료**: Siri Remote의 Menu(＜) 버튼, 또는 게임패드 `−` `＋` `L` `R` 동시 입력 → 계속하기 / 게임 종료
- 기본 설정은 MeloNX 기본값(Vulkan/MoltenVK, 휴대 모드 720p, 텍스처 재압축)입니다.

### 알려진 제약
- Apple TV 4K 3세대의 RAM은 4 GB입니다. 앱이 시작할 때 메모리 한도를 올리지만(홈 화면의 "메모리" 칸에 결과 표시), 대형 3D 게임은 메모리 부족으로 종료될 수 있습니다.
- 기기 자체 모션(자이로)은 tvOS에 없습니다. 자이로가 있는 게임패드(DualSense 등)의 모션은 전달됩니다.
- MetalFX 업스케일, 온스크린 터치 패드, 게임별 설정 화면은 포함하지 않았습니다.

### 구성
- 코어: MeloNX 2.7 (Ryujinx 기반) C# 코어를 .NET NativeAOT `tvos-arm64`로 빌드
- MoltenVK 1.4.0, SDL3 (MeloNX 동봉본과 같은 커밋), FFmpeg (영상 디코딩)
- 원본 라이선스(`LICENSE.txt`)를 따릅니다.
