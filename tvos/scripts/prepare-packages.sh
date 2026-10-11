#!/usr/bin/env bash
# SPM 의존 패키지를 tvOS 대응으로 포크한다.
#
# MeloNX는 두 패키지를 원격 참조하는데, 둘 다 Package.swift 의 platforms 에
# tvOS 가 없어 tvOS 타겟에서 해석되지 않는다. 클론해서 platforms 에
# .tvOS(.v16) 을 넣고, project-tvos.yml 이 로컬 경로로 참조한다.
#
#   Melo-Controller          VirtualControllerButton 등 — 55곳에서 쓰이는 핵심 타입
#   navigation-stack-backport  iOS 15용 NavigationStack 백포트
#
# 멱등: 이미 .tvOS 가 있으면 건너뛴다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKG="$ROOT/tvos/packages"
mkdir -p "$PKG"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

clone_once() {
  local url="$1" dir="$2" ref="${3:-}"
  if [ -d "$dir/.git" ]; then
    log "이미 있음: $(basename "$dir")"
    return
  fi
  log "클론: $url"
  if [ -n "$ref" ]; then
    git clone --depth 1 --branch "$ref" "$url" "$dir"
  else
    git clone --depth 1 "$url" "$dir"
  fi
}

# Package.swift 의 platforms 배열에 .tvOS(.v16) 를 삽입한다.
add_tvos_platform() {
  local manifest="$1"
  [ -f "$manifest" ] || { echo "Package.swift 없음: $manifest" >&2; return 1; }

  python3 - "$manifest" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()

if ".tvOS(" in src:
    print(f"  {path}: 이미 tvOS 선언됨 — 건너뜀")
    sys.exit(0)

m = re.search(r'platforms\s*:\s*\[', src)
if m:
    # 기존 배열 맨 앞에 끼워 넣는다
    at = m.end()
    out = src[:at] + "\n        .tvOS(.v16)," + src[at:]
    print(f"  {path}: platforms 배열에 .tvOS(.v16) 추가")
else:
    # platforms 절이 아예 없으면 name 뒤에 새로 만든다
    m2 = re.search(r'(name\s*:\s*"[^"]+"\s*,)', src)
    if not m2:
        print(f"  {path}: platforms 절을 넣을 위치를 찾지 못했습니다", file=sys.stderr)
        sys.exit(1)
    at = m2.end()
    out = src[:at] + "\n    platforms: [.iOS(.v15), .tvOS(.v16)]," + src[at:]
    print(f"  {path}: platforms 절 신규 추가")

open(path, "w", encoding="utf-8").write(out)
PY
}

clone_once https://github.com/stossy11/Melo-Controller.git "$PKG/Melo-Controller"
clone_once https://github.com/lm/navigation-stack-backport.git "$PKG/navigation-stack-backport"

add_tvos_platform "$PKG/Melo-Controller/Package.swift"
add_tvos_platform "$PKG/navigation-stack-backport/Package.swift"

cat <<'NOTE'

────────────────────────────────────────────────────────────────
주의 — Melo-Controller 는 온스크린 터치 컨트롤러도 포함합니다.
platforms 선언만으로 컴파일이 통과하지 않을 수 있습니다.
UIKit 터치 관련 코드가 있으면 그 파일을 #if os(iOS) 로 감싸야 합니다.

tvOS 타겟이 실제로 필요한 것은 타입뿐입니다:
  VirtualControllerButton   (55곳)
  VirtualControllerManager  (8곳)
  VirtualAddressing         (14곳)

컴파일 에러가 나면 해당 패키지의 터치 UI 파일을 가드하십시오.
────────────────────────────────────────────────────────────────
NOTE
