#!/usr/bin/env bash
#
#  make-ipa.sh — MeloNX tvOS IPA 만들기 (명령 하나)
#
#  사용법
#    ./make-ipa.sh            환경을 보고 알아서 고른다
#    ./make-ipa.sh local      이 Mac에서 직접 빌드
#    ./make-ipa.sh ci         GitHub Actions 에서 빌드해 내려받기 (Mac 불필요)
#    ./make-ipa.sh probe      MemProbe 만 (메모리 측정용, 빠름)
#
#  결과:  ./dist/MeloNX.ipa  와  ./dist/MeloNX.tipa   (내용 동일)
#
#  ─────────────────────────────────────────────────────────────────
#  local : macOS + Xcode(+tvOS 플랫폼) + .NET 10 SDK 필요.
#          첫 실행은 MoltenVK 때문에 오래 걸린다(한 시간 이상 각오).
#  ci    : Mac이 없어도 된다. gh 로그인된 상태여야 하고, 이 디렉터리를
#          GitHub 리포지토리로 푸시한 뒤 macOS 러너가 빌드한다.
#  ─────────────────────────────────────────────────────────────────
#
#  이 포팅은 컴파일 검증을 거치지 않은 1차 패치다. 첫 시도에서 컴파일
#  에러가 나는 것이 정상이고, 이 스크립트는 에러를 모아서 보여준다.
#  고쳐서 다시 돌리면 다음 에러로 넘어간다.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
DIST="$ROOT/dist"

C_OK=$'\033[1;32m'; C_IN=$'\033[1;36m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_0=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$C_IN" "$*" "$C_0"; }
ok()   { printf '%s  ok%s %s\n' "$C_OK" "$C_0" "$*"; }
warn() { printf '%s  [!]%s %s\n' "$C_WARN" "$C_0" "$*"; }
die()  { printf '\n%s[실패]%s %s\n' "$C_ERR" "$C_0" "$*" >&2; exit 1; }

need_file() { [ -e "$1" ] || die "필요한 파일이 없습니다: $1
이 스크립트는 MeloNX 소스 루트에 오버레이를 얹은 상태에서 실행해야 합니다."; }

# ══════════════════════════════════════════════════════════════════
#  공통: 소스 패치 (멱등)
# ══════════════════════════════════════════════════════════════════
apply_patches() {
  step "tvOS 패치 적용"
  need_file tvos/patches/01-swift-tvos.patch
  need_file src/MeloNX/MeloNX

  if [ -d src/MeloNX/MeloNX/Compat ]; then
    ok "Swift 패치 이미 적용됨 (Compat/ 존재)"
  else
    ( cd src/MeloNX/MeloNX && patch -p1 --forward < "$ROOT/tvos/patches/01-swift-tvos.patch" ) \
      || die "Swift 패치 적용 실패. .rej 파일을 확인하세요."
    ok "Swift 패치 적용 (30개 파일 + Compat/ 5개)"
  fi

  if grep -q AppleSdkRelPath src/Ryujinx.Library/Ryujinx.Library.csproj 2>/dev/null; then
    ok "csproj 패치 이미 적용됨"
  else
    patch -p0 src/Ryujinx.Library/Ryujinx.Library.csproj \
      < tvos/patches/02-ryujinx-library-csproj.patch \
      || die "csproj 패치 적용 실패."
    ok "csproj 패치 적용 (RID / SDK 경로)"
  fi
}

# ══════════════════════════════════════════════════════════════════
#  로컬 빌드 (macOS)
# ══════════════════════════════════════════════════════════════════
preflight_local() {
  step "환경 확인"
  [ "$(uname -s)" = "Darwin" ] || die "로컬 빌드는 macOS 에서만 됩니다.
Mac이 없으면:  ./make-ipa.sh ci"

  command -v xcodebuild >/dev/null || die "Xcode 가 필요합니다. App Store 에서 설치 후:
  sudo xcode-select -s /Applications/Xcode.app"
  ok "$(xcodebuild -version | head -1)"

  local sdk
  sdk="$(xcrun --sdk appletvos --show-sdk-path 2>/dev/null)"
  [ -n "$sdk" ] || die "appletvos SDK 가 없습니다.
Xcode > Settings > Components 에서 tvOS 플랫폼을 설치하세요."
  ok "appletvos SDK $(xcrun --sdk appletvos --show-sdk-version)"

  local missing=()
  for t in xcodegen ldid cmake pkg-config nasm; do
    command -v "$t" >/dev/null || missing+=("$t")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    warn "없는 도구: ${missing[*]}"
    command -v brew >/dev/null || die "Homebrew 가 필요합니다: https://brew.sh"
    step "brew install ${missing[*]}"
    brew install "${missing[@]}" || die "도구 설치 실패"
  fi
  ok "빌드 도구 준비됨"

  command -v dotnet >/dev/null || die ".NET 10 SDK 가 필요합니다:
  https://dotnet.microsoft.com/download/dotnet/10.0"
  ok "dotnet $(dotnet --version 2>/dev/null || echo '?')"
}

build_local() {
  preflight_local
  apply_patches

  step "SPM 패키지 tvOS 대응 포크"
  ./tvos/scripts/prepare-packages.sh || die "패키지 준비 실패"

  # ── 네이티브 의존성: 이미 있으면 건너뛴다
  local D=tvos/deps/out/tvos
  local need_deps=0
  for f in SDL3.xcframework libMoltenVK.dylib libavcodec.dylib libavutil.dylib; do
    [ -e "$D/$f" ] || need_deps=1
  done

  if [ "$need_deps" -eq 1 ]; then
    cat <<'NOTE'

  ─────────────────────────────────────────────────────────────
   네이티브 의존성을 빌드합니다. 오래 걸립니다.
   MoltenVK 의 fetchDependencies 가 glslang · SPIRV-Cross ·
   SPIRV-Tools 를 tvOS용으로 전부 빌드합니다.
   한 번 성공하면 tvos/deps/out 에 남아 다시 하지 않습니다.
  ─────────────────────────────────────────────────────────────

NOTE
    step "MoltenVK (Ryujinx 포크)"
    ./tvos/scripts/build-deps.sh moltenvk || die "MoltenVK 빌드 실패.
Vulkan 없이는 렌더링이 안 되므로 여기서 멈춥니다."
    step "SDL3"
    ./tvos/scripts/build-deps.sh sdl3 || die "SDL3 빌드 실패"
    step "FFmpeg"
    ./tvos/scripts/build-deps.sh ffmpeg || warn "FFmpeg 빌드 실패 — 영상 디코딩(컷신)만 영향받습니다"
  else
    ok "네이티브 의존성 이미 있음 (다시 만들려면 tvos/deps/out 삭제)"
  fi

  step "의존성 플랫폼 검증"
  local bad=0
  for f in "$D"/*.dylib; do
    [ -e "$f" ] || continue
    if vtool -show-build "$f" 2>/dev/null | grep -q "platform TVOS"; then
      ok "$(basename "$f")"
    else
      warn "$(basename "$f") 가 tvOS 바이너리가 아닙니다"; bad=1
    fi
  done
  [ "$bad" -eq 0 ] || die "잘못된 플랫폼의 의존성이 있습니다. tvos/deps/out 을 지우고 다시 빌드하세요."

  # ── .NET 코어
  step "Ryujinx.Library (tvos-arm64 NativeAOT)"
  dotnet publish -c Release -r tvos-arm64 \
    -p:ExtraDefineConstants=DISABLE_UPDATER \
    src/Ryujinx.Library --self-contained true 2>&1 | tee dotnet-publish.log
  local core=src/Ryujinx.Library/bin/Release/net10.0/tvos-arm64/native/Ryujinx.Library.dylib
  [ -f "$core" ] || die "코어 dylib 이 생성되지 않았습니다. dotnet-publish.log 를 보세요.
tvOS NativeAOT 런타임 팩이 없다는 에러면 .NET SDK 를 최신 피처 밴드로 올리세요."
  vtool -show-build "$core" | grep -q "platform TVOS" \
    || die "코어가 iOS SDK 로 링크되었습니다. csproj 패치가 적용되지 않았습니다."
  ok "코어 dylib (platform TVOS)"

  # ── 앱
  step "Xcode 프로젝트 생성"
  xcodegen generate --spec project-tvos.yml || die "xcodegen 실패"

  step "xcodebuild (appletvos)"
  set -o pipefail
  xcodebuild \
    -project MeloNX-tvOS.xcodeproj \
    -scheme MeloNX-tvOS \
    -configuration Release \
    -sdk appletvos -arch arm64 \
    -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build 2>&1 | tee xcodebuild.log
  local rc=${PIPESTATUS[0]}

  if [ "$rc" -ne 0 ]; then
    printf '\n%s===== 컴파일 에러 =====%s\n' "$C_ERR" "$C_0"
    grep -E "error:" xcodebuild.log | sort -u | head -60
    printf '\n전체 로그: %s/xcodebuild.log\n' "$ROOT"
    cat <<'HINT'

이 포팅은 1차 패치라 첫 시도에서 에러가 나는 것이 정상입니다.

흔한 원인
 1. Melo-Controller 패키지 — 온스크린 터치 컨트롤 코드를
    tvos/packages/Melo-Controller 안에서 #if os(iOS) 로 감싸야 합니다.
    tvOS가 실제로 필요한 것은 타입뿐입니다
    (VirtualControllerButton / VirtualControllerManager / VirtualAddressing).
 2. tvOS 에 없는 SwiftUI modifier
    (.navigationBarTitleDisplayMode, .listStyle(.insetGrouped) 등)
    → 해당 지점을 #if os(tvOS) 로 분기.

고친 뒤 ./make-ipa.sh local 을 다시 돌리면 이미 끝난 단계는 건너뜁니다.
HINT
    exit 1
  fi
  ok "빌드 성공"

  step "서명 및 IPA 포장"
  local app
  app="$(find build/Build/Products/Release-appletvos -maxdepth 1 -name '*.app' | head -1)"
  [ -n "$app" ] || die ".app 산출물을 찾지 못했습니다"
  ./tvos/scripts/package-tipa.sh "$app" "$DIST" || die "포장 실패"

  finish_local
}

finish_local() {
  printf '\n%s========================================%s\n' "$C_OK" "$C_0"
  printf '%s  IPA 생성 완료%s\n' "$C_OK" "$C_0"
  printf '%s========================================%s\n\n' "$C_OK" "$C_0"
  ls -la "$DIST"
  cat <<'NEXT'

TrollStore 로 설치하세요 (.tipa 를 쓰는 편이 다루기 쉽습니다).
엔타이틀먼트는 바이너리 서명에 들어 있어 TrollStore 가 그대로 보존합니다.

주의: Apple TV 4K 3세대는 RAM 4GB(iPhone 12/13급)입니다.
경량·2D 타이틀은 동작하고 대형 3D 타이틀은 OOM 이 예상됩니다.
NEXT
}

# ══════════════════════════════════════════════════════════════════
#  CI 빌드 (Mac 불필요)
# ══════════════════════════════════════════════════════════════════
preflight_ci() {
  step "GitHub 환경 확인"
  command -v gh >/dev/null || die "GitHub CLI 가 필요합니다:
  macOS  brew install gh
  Linux  https://github.com/cli/cli#installation
설치 후  gh auth login"
  gh auth status >/dev/null 2>&1 || die "GitHub 로그인이 필요합니다:  gh auth login"
  ok "gh 로그인됨 ($(gh api user --jq .login 2>/dev/null || echo '?'))"
  command -v git >/dev/null || die "git 이 필요합니다"
}

ensure_pushed() {
  step "리포지토리 준비"

  if [ ! -d .git ]; then
    git init -b main >/dev/null
    ok "git 초기화"
  fi

  if [ ! -f .gitignore ] || ! grep -q "tvos/deps/out" .gitignore 2>/dev/null; then
    [ -f gitignore-append ] && cat gitignore-append >> .gitignore
    ok ".gitignore 갱신"
  fi

  git add -A >/dev/null
  if ! git diff --cached --quiet 2>/dev/null; then
    git -c user.name="${GIT_AUTHOR_NAME:-melonx-tvos}" \
        -c user.email="${GIT_AUTHOR_EMAIL:-melonx-tvos@local}" \
        commit -q -m "MeloNX tvOS 포팅 ($(date +%Y-%m-%d\ %H:%M))" \
      || die "커밋 실패"
    ok "변경사항 커밋"
  else
    ok "커밋할 변경 없음"
  fi

  if ! git remote get-url origin >/dev/null 2>&1; then
    local name="${REPO_NAME:-melonx-tvos}"
    warn "origin 원격이 없습니다. 비공개 리포지토리 '$name' 를 만듭니다."
    printf '    계속할까요? [y/N] '
    read -r a
    case "$a" in y|Y) ;; *) die "중단했습니다. 직접 원격을 추가하세요:
  git remote add origin git@github.com:<본인>/<리포>.git" ;; esac
    gh repo create "$name" --private --source=. --remote=origin --push \
      || die "리포지토리 생성 실패"
    ok "생성 및 푸시 완료"
  else
    git push -u origin HEAD || die "푸시 실패"
    ok "푸시 완료 ($(git remote get-url origin))"
  fi
}

run_workflow() {
  local wf="$1" label="$2" artifact="$3"
  step "$label 워크플로 실행"
  gh workflow run "$wf" || die "워크플로 실행 실패.
Actions 탭에서 워크플로가 인식되었는지 확인하세요 (푸시 직후 잠깐 걸립니다)."

  sleep 8
  local id
  id="$(gh run list --workflow "$wf" --limit 1 --json databaseId --jq '.[0].databaseId')"
  [ -n "$id" ] || die "실행 ID 를 가져오지 못했습니다"
  ok "실행 #$id — 브라우저: $(gh browse --no-browser --repo "$(gh repo view --json nameWithOwner --jq .nameWithOwner)" 2>/dev/null || echo '')actions/runs/$id"

  step "완료 대기 (첫 실행은 매우 오래 걸립니다)"
  gh run watch "$id" --exit-status
  local rc=$?

  if [ "$rc" -ne 0 ]; then
    printf '\n%s===== 빌드 실패 =====%s\n' "$C_ERR" "$C_0"
    gh run view "$id" --log-failed 2>/dev/null | grep -E "error:" | sort -u | head -60 || true
    mkdir -p "$DIST"
    gh run download "$id" --name build-logs --dir "$DIST/logs" 2>/dev/null \
      && ok "전체 로그: $DIST/logs"
    cat <<'HINT'

워크플로를 에러 수집기로 쓰십시오. 위 에러를 고쳐 커밋한 뒤
./make-ipa.sh ci 를 다시 돌리면 다음 에러로 넘어갑니다.
네이티브 의존성은 캐시되므로 재실행이 훨씬 빠릅니다.
HINT
    exit 1
  fi

  step "산출물 내려받기"
  mkdir -p "$DIST"
  gh run download "$id" --name "$artifact" --dir "$DIST" || die "아티팩트 내려받기 실패"
  find "$DIST" -name '*.ipa' -o -name '*.tipa' | sort
}

build_ci() {
  preflight_ci
  ensure_pushed
  run_workflow "Build tvOS (.tipa)" "MeloNX tvOS" "MeloNX-tvOS"
  printf '\n%s IPA 준비 완료 %s\n' "$C_OK" "$C_0"
  ls -la "$DIST"
  cat <<'NEXT'

릴리즈로 올리려면:
  git tag tvos-v0.1 && git push origin tvos-v0.1
태그를 밀면 워크플로가 끝나고 릴리즈에 .tipa / .ipa 가 첨부됩니다.
NEXT
}

build_probe() {
  preflight_ci
  ensure_pushed
  run_workflow "Build MemProbe (.tipa)" "MemProbe" "MemProbe-full"
  local id
  id="$(gh run list --workflow "Build MemProbe (.tipa)" --limit 1 --json databaseId --jq '.[0].databaseId')"
  gh run download "$id" --name MemProbe-baseline --dir "$DIST" 2>/dev/null || true
  printf '\n%s MemProbe 준비 완료 %s\n' "$C_OK" "$C_0"
  ls -la "$DIST"
  cat <<'NEXT'

두 .tipa 를 각각 TrollStore 로 설치하세요 (번들 ID 가 달라 공존합니다).
앱에서 "jetsam active 한도" 를 비교하십시오.

  full 이 baseline 보다 유의하게 크다        → 본 포팅 진행
  둘이 같다                                  → "한도 직접 상향" 버튼 확인
  둘 다 2000 MB 미만이고 상향도 실패         → 여기서 중단

본 포팅을 빌드하기 전에 이 숫자를 먼저 보시는 것을 강력히 권합니다.
NEXT
}

# ══════════════════════════════════════════════════════════════════
main() {
  local mode="${1:-auto}"
  case "$mode" in
    local) build_local ;;
    ci)    build_ci ;;
    probe) build_probe ;;
    auto)
      if [ "$(uname -s)" = "Darwin" ] && command -v xcodebuild >/dev/null \
         && xcrun --sdk appletvos --show-sdk-path >/dev/null 2>&1; then
        warn "macOS + appletvos SDK 감지 — 로컬 빌드로 진행합니다 (ci 로 강제 가능)"
        build_local
      else
        warn "로컬에 appletvos SDK 가 없습니다 — GitHub Actions 로 빌드합니다"
        build_ci
      fi ;;
    -h|--help|help) sed -n '2,30p' "$0" | sed 's|^# \{0,1\}||' ;;
    *) die "알 수 없는 모드: $mode   (local | ci | probe)" ;;
  esac
}

main "$@"
