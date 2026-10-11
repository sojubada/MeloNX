#!/usr/bin/env bash
#
# MeloNX tvOS 포팅 3단계 — 네이티브 의존성을 appletvos SDK로 재빌드한다.
#
# MeloNX 2.7이 번들한 프리빌트 9개는 전부 ios-arm64 슬라이스만 가지고 있어
# tvOS 타겟에 링크할 수 없다. 이 스크립트가 같은 이름의 tvOS 산출물을 만든다.
#
#   ./build-tvos-deps.sh moltenvk     libMoltenVK.dylib + libSPIRV.a
#   ./build-tvos-deps.sh sdl3         SDL3.xcframework
#   ./build-tvos-deps.sh ffmpeg       libav*/libsw* 6종
#   ./build-tvos-deps.sh all          전부
#
# 산출물: ./out/tvos/
#
# 사전 준비
#   xcode-select --install
#   brew install cmake pkg-config nasm
#   # Xcode에 tvOS 플랫폼 지원이 설치되어 있어야 한다:
#   #   Xcode > Settings > Components > tvOS
#
# ───────────────────────────────────────────────────────────────────
# 권장 순서: MoltenVK → SDL3 → FFmpeg
#   MoltenVK가 가장 까다롭고, 실패하면 나머지를 할 이유가 없다
#   (Vulkan 없이는 렌더링이 안 된다).
# ───────────────────────────────────────────────────────────────────

set -euo pipefail

TVOS_MIN=16.0
ARCH=arm64
# MoltenVK 버전. 러너의 Xcode 16.4 와 빌드되는 것이 우선이라 v1.3.0 을 쓴다.
# (구버전은 최신 Xcode 에서 자체 컴파일 에러가 날 수 있다)
# 교체: MOLTENVK_TAG=v1.4.2 ./build-deps.sh moltenvk
MOLTENVK_TAG="${MOLTENVK_TAG:-v1.3.0}"
# SDL 은 릴리즈 태그에 3.5.0 이 없다(최신 안정판 3.4.x). 아래 주석 참고.
SDL_REF="${SDL_REF:-main}"
FFMPEG_TAG="${FFMPEG_TAG:-n6.1.2}"

# 스크립트는 tvos/scripts/ 에 있다. 리포지토리 루트는 두 단계 위다.
# 산출물 경로는 워크플로의 캐시 키와 project-tvos.yml 의 링크 경로와
# 반드시 일치해야 한다: tvos/deps/out/tvos
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/tvos/deps/src"
OUT="$ROOT/tvos/deps/out/tvos"
mkdir -p "$SRC" "$OUT"

# 없는 리포지토리를 클론하려 할 때 자격증명 프롬프트에서 멈추지 않고
# 즉시 실패하게 한다 (CI에서 "could not read Username" 로 죽는 것 방지).
export GIT_TERMINAL_PROMPT=0

TVOS_SDK="$(xcrun --sdk appletvos --show-sdk-path)"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

check_tvos_sdk() {
  [ -d "$TVOS_SDK" ] || die "appletvos SDK를 찾지 못했습니다. Xcode에 tvOS 플랫폼을 설치하세요."
  log "appletvos SDK: $TVOS_SDK"
}

# 결과 확인용. LC_BUILD_VERSION의 platform이 tvOS(3)인지 본다.
verify_platform() {
  local f="$1"
  if vtool -show-build "$f" 2>/dev/null | grep -q "platform TVOS"; then
    log "확인: $(basename "$f") → tvOS"
  else
    warn "$(basename "$f") 의 플랫폼이 tvOS가 아닙니다. vtool -show-build 로 직접 확인하세요."
  fi
}

# ═══════════════════════════════════════════════════════════════════
# 1. MoltenVK  (Ryujinx 포크를 써야 한다 — 업스트림과 동작이 다르다)
# ═══════════════════════════════════════════════════════════════════
build_moltenvk() {
  check_tvos_sdk
  local dir="$SRC/MoltenVK"

  # 주의: 원래는 Ryujinx 포크(github.com/Ryujinx/MoltenVK)를 쓰려 했으나
  # Nintendo 합의 이후 그 GitHub 조직이 내려가서 더 이상 존재하지 않는다.
  # (확인: git ls-remote 접근 불가). 따라서 업스트림을 쓴다.
  # 업스트림도 tvOS를 공식 지원하지만, MeloNX가 번들했던 dylib과
  # 동작이 다를 수 있다. 렌더링 이상이 보이면 이 지점을 의심할 것.
  if [ ! -d "$dir" ]; then
    log "KhronosGroup/MoltenVK $MOLTENVK_TAG 클론 (업스트림)"
    git clone --depth 1 --branch "$MOLTENVK_TAG" \
      https://github.com/KhronosGroup/MoltenVK.git "$dir" \
      || die "MoltenVK 클론 실패 ($MOLTENVK_TAG)"
  fi

  cd "$dir"

  # MoltenVK는 glslang / SPIRV-Cross / SPIRV-Tools 를 External 로 가져와
  # 플랫폼별로 같이 빌드한다. --tvos 를 꼭 붙여야 tvOS 슬라이스가 생긴다.
  log "fetchDependencies --tvos (수십 분 걸린다)"
  ./fetchDependencies --tvos

  log "make tvos"
  make tvos

  # 산출물 위치와 형태는 MoltenVK 버전에 따라 다르다.
  #   구버전  Package/Release/MoltenVK/dynamic/dylib/tvOS/libMoltenVK.dylib
  #   v1.3.x  Package/Release/MoltenVK/MoltenVK.xcframework/tvos-arm64/
  #             MoltenVK.framework/MoltenVK   ← 프레임워크 안의 바이너리
  #
  # MeloNX 는 [LibraryImport("libMoltenVK.dylib")] 로 파일명으로 로드하므로
  # 어느 형태든 libMoltenVK.dylib 라는 이름의 동적 라이브러리로 만들어 둔다.
  log "MoltenVK 산출물 탐색"
  local dylib=""
  local cand
  while IFS= read -r cand; do
    [ -f "$cand" ] || continue
    # 정적 아카이브(.a)와 iOS 슬라이스를 걸러낸다
    case "$(file -b "$cand" 2>/dev/null)" in
      *"dynamically linked shared library"*|*"dynamic library"*) ;;
      *) continue ;;
    esac
    if vtool -show-build "$cand" 2>/dev/null | grep -q "platform TVOS"; then
      dylib="$cand"
      break
    fi
  done < <(
    find Package/Release -path '*tvOS*'     -name 'libMoltenVK.dylib' 2>/dev/null
    find Package/Release -path '*tvos*'     -name 'MoltenVK'          -type f 2>/dev/null
    find Package/Release -path '*tvOS*'     -name 'MoltenVK'          -type f 2>/dev/null
    find Package      -name 'libMoltenVK.dylib' 2>/dev/null
    find Package      -name 'MoltenVK' -type f 2>/dev/null
  )

  if [ -z "$dylib" ]; then
    warn "tvOS용 MoltenVK 동적 라이브러리를 찾지 못했습니다. Package 아래 목록:"
    find Package -maxdepth 6 \( -name 'MoltenVK' -o -name '*.dylib' -o -name '*.framework' \) \
      2>/dev/null | head -40 | sed 's/^/    /'
    die "위 목록에서 tvOS 슬라이스를 확인하고 스크립트의 탐색 경로를 맞추십시오."
  fi

  log "채택: ${dylib#./}"
  cp "$dylib" "$OUT/libMoltenVK.dylib"
  chmod u+w "$OUT/libMoltenVK.dylib"

  # iOS 판과 같은 @rpath 설치 이름을 맞춘다 (Xcode가 Frameworks/ 에 임베드).
  install_name_tool -id @rpath/libMoltenVK.dylib "$OUT/libMoltenVK.dylib"
  verify_platform "$OUT/libMoltenVK.dylib"

  # ── libSPIRV.a
  # MeloNX가 번들한 libSPIRV.a 는 glslang의 SPIRV 모듈 + SPIRV-Cross 를
  # 합친 정적 라이브러리다(심볼로 확인됨). MoltenVK의 External 빌드 산출물에서
  # 같은 구성을 모은다.
  log "libSPIRV.a 조립 (glslang SPIRV + SPIRV-Cross)"
  local tmp="$dir/.spirv-tvos"
  rm -rf "$tmp"; mkdir -p "$tmp"

  local parts=()
  while IFS= read -r a; do parts+=("$a"); done < <(
    find External/build -name 'libSPIRV.a'      -path '*tvOS*' 2>/dev/null
    find External/build -name 'libSPIRV-Tools*.a' -path '*tvOS*' 2>/dev/null
    find External/build -name 'libspirv-cross*.a' -path '*tvOS*' 2>/dev/null
    find External/build -name 'libglslang*.a'   -path '*tvOS*' 2>/dev/null
  )

  if [ ${#parts[@]} -eq 0 ]; then
    warn "External/build 에서 tvOS용 SPIRV 정적 라이브러리를 찾지 못했습니다."
    warn "MoltenVK 버전에 따라 경로가 다릅니다. 다음으로 직접 찾아보세요:"
    warn "  find External/build -name '*.a' -path '*tvOS*'"
    warn "libMoltenVK.dylib 는 정상 생성되었으니 libSPIRV 는 링크 단계에서"
    warn "실제로 필요한지 먼저 확인하십시오 (dylib이 자체 포함일 수 있습니다)."
    return 0
  fi

  for a in "${parts[@]}"; do
    log "  병합: $a"
    (cd "$tmp" && ar x "$a")
  done
  ( cd "$tmp" && ar crs "$OUT/libSPIRV.a" ./*.o )
  log "libSPIRV.a 생성: $(ar t "$OUT/libSPIRV.a" | wc -l) 오브젝트"
}

# ═══════════════════════════════════════════════════════════════════
# 2. SDL3  (번들된 것은 SDL-3.5.0)
# ═══════════════════════════════════════════════════════════════════
build_sdl3() {
  check_tvos_sdk
  local dir="$SRC/SDL"

  # MeloNX가 번들한 SDL3 바이너리는 버전 문자열이 "SDL-3.5.0" 이다.
  # 그런데 libsdl-org/SDL 의 릴리즈 태그는 3.4.x 까지만 있다 — 즉 3.5.0 은
  # main 브랜치의 개발 버전이다. C# 바인딩(ppy.SDL3-CS 2026.320.0)과 ABI를
  # 맞춰야 하므로 안정 태그가 아니라 main 을 쓴다.
  # 특정 커밋으로 고정하려면: SDL_REF=<커밋해시> ./build-deps.sh sdl3
  if [ ! -d "$dir" ]; then
    log "libsdl-org/SDL $SDL_REF 클론"
    if [ "$SDL_REF" = "main" ]; then
      git clone --depth 1 https://github.com/libsdl-org/SDL.git "$dir" \
        || die "SDL 클론 실패"
    else
      git clone https://github.com/libsdl-org/SDL.git "$dir" || die "SDL 클론 실패"
      ( cd "$dir" && git checkout -q "$SDL_REF" ) || die "SDL ref 체크아웃 실패: $SDL_REF"
    fi
  fi
  log "SDL 버전: $(grep -hoE 'SDL_M(AJOR|INOR|MICRO)_VERSION[[:space:]]+[0-9]+' \
      "$dir/include/SDL3/SDL_version.h" 2>/dev/null | awk '{print $2}' | paste -sd. - || echo '?')"

  cd "$dir"
  rm -rf build-tvos

  # SDL3는 tvOS를 공식 지원한다. Xcode 제너레이터를 써야 framework 번들이
  # 제대로 만들어진다.
  log "CMake 구성 (tvOS)"
  cmake -B build-tvos -G Xcode \
    -DCMAKE_SYSTEM_NAME=tvOS \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$TVOS_MIN" \
    -DCMAKE_OSX_SYSROOT=appletvos \
    -DSDL_SHARED=ON \
    -DSDL_STATIC=OFF \
    -DSDL_FRAMEWORK=ON \
    -DSDL_TESTS=OFF \
    -DSDL_EXAMPLES=OFF \
    -DSDL_INSTALL_TESTS=OFF

  log "빌드"
  cmake --build build-tvos --config Release -- -sdk appletvos

  local fw
  fw="$(find build-tvos -name 'SDL3.framework' -type d | head -1)"
  [ -n "$fw" ] || die "SDL3.framework 를 찾지 못했습니다. build-tvos 아래를 확인하세요."

  log "xcframework 패키징"
  rm -rf "$OUT/SDL3.xcframework"
  xcodebuild -create-xcframework \
    -framework "$fw" \
    -output "$OUT/SDL3.xcframework"
  verify_platform "$OUT/SDL3.xcframework/tvos-$ARCH/SDL3.framework/SDL3" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════
# 3. FFmpeg  (libavcodec/avfilter/avformat/avutil/swresample/swscale)
# ═══════════════════════════════════════════════════════════════════
build_ffmpeg() {
  check_tvos_sdk
  local dir="$SRC/FFmpeg"
  local tag="$FFMPEG_TAG"   # 번들된 것이 6.x 계열

  if [ ! -d "$dir" ]; then
    log "FFmpeg $tag 클론"
    git clone --depth 1 --branch "$tag" https://github.com/FFmpeg/FFmpeg.git "$dir"
  fi

  cd "$dir"
  local prefix="$dir/build-tvos/install"
  rm -rf build-tvos; mkdir -p build-tvos
  cd build-tvos

  # -target 트리플이 반드시 필요하다.
  # -arch 와 -isysroot 만 주면 clang 은 호스트(macOS) 트리플을 기본값으로 쓰면서
  # tvOS 시스루트를 참조해 링크가 깨진다 → configure 의
  # "clang is unable to create an executable file / C compiler test failed".
  # -fembed-bitcode-marker 는 Xcode 14+ 에서 비트코드가 제거되어 넣지 않는다.
  local triple="arm64-apple-tvos${TVOS_MIN}"
  local cflags="-target $triple -arch $ARCH -isysroot $TVOS_SDK"

  # tvOS 주의사항
  #  · fork()/system() 금지 → --disable-programs (ffmpeg/ffplay 바이너리 불필요)
  #  · 하드웨어 가속은 VideoToolbox만 (tvOS에 있음)
  #  · MeloNX는 Nvdec 디코딩에만 쓰므로 네트워크/디바이스 전부 끈다
  log "configure"
  ../configure \
    --prefix="$prefix" \
    --enable-cross-compile \
    --target-os=darwin \
    --arch="$ARCH" \
    --cc="$(xcrun --sdk appletvos -f clang)" \
    --as="$(xcrun --sdk appletvos -f clang)" \
    --ar="$(xcrun --sdk appletvos -f ar)" \
    --ranlib="$(xcrun --sdk appletvos -f ranlib)" \
    --sysroot="$TVOS_SDK" \
    --extra-cflags="$cflags" \
    --extra-ldflags="$cflags" \
    --enable-shared \
    --disable-static \
    --disable-programs \
    --disable-doc \
    --disable-everything \
    --disable-network \
    --disable-avdevice \
    --disable-postproc \
    --enable-avcodec --enable-avformat --enable-avfilter \
    --enable-swresample --enable-swscale \
    --enable-decoder=h264,vp8,vp9,mpeg4,aac \
    --enable-parser=h264,vp8,vp9,mpeg4video,aac \
    --enable-pic

  log "make (-j$(sysctl -n hw.ncpu))"
  make -j"$(sysctl -n hw.ncpu)"
  make install

  log "dylib 추출 및 @rpath 설정"
  for lib in avcodec avfilter avformat avutil swresample swscale; do
    local f
    f="$(find "$prefix/lib" -name "lib${lib}.*.dylib" | head -1)"
    [ -n "$f" ] || { warn "lib${lib} dylib 없음 — 건너뜀"; continue; }
    cp "$f" "$OUT/lib${lib}.dylib"
    install_name_tool -id "@rpath/lib${lib}.dylib" "$OUT/lib${lib}.dylib"
    verify_platform "$OUT/lib${lib}.dylib"
  done

  warn "FFmpeg dylib 들은 서로를 참조합니다. 앱에 임베드한 뒤"
  warn "otool -L 로 상호 참조 경로가 전부 @rpath/ 로 바뀌었는지 확인하세요."
  warn "필요하면 install_name_tool -change 로 보정합니다."
}

# ═══════════════════════════════════════════════════════════════════
# 참고: libteakra
#   MeloNX 2.7에 libteakra.xcframework(정적 .a)가 들어 있지만,
#   C#·Swift 소스 어디에서도 참조가 발견되지 않았습니다.
#   Teakra는 3DS의 Teak DSP 에뮬레이터로 Switch 에뮬레이션과 무관합니다.
#   tvOS 빌드에서는 **일단 링크 대상에서 빼고** 심볼 누락이 나는지 확인하는
#   편이 낫습니다. 누락이 나면:
#     git clone https://github.com/wwylele/teakra
#     cmake -B build-tvos -G Xcode -DCMAKE_SYSTEM_NAME=tvOS \
#       -DCMAKE_OSX_ARCHITECTURES=arm64 \
#       -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0
#     cmake --build build-tvos --config Release -- -sdk appletvos
#
# 참고: BreakpointJIT.framework
#   iOS 26 TXM 우회 전용입니다. tvOS 16.6은 TXM 이전 세대이므로
#   재빌드하지 말고 링크에서 제거하십시오.
# ═══════════════════════════════════════════════════════════════════

main() {
  local target="${1:-}"
  case "$target" in
    moltenvk) build_moltenvk ;;
    sdl3)     build_sdl3 ;;
    ffmpeg)   build_ffmpeg ;;
    all)      build_moltenvk; build_sdl3; build_ffmpeg ;;
    *)
      sed -n '2,30p' "$0" | sed 's|^# \{0,1\}||'
      exit 2 ;;
  esac
  echo
  log "산출물: $OUT"
  ls -la "$OUT" 2>/dev/null || true
}

main "$@"
