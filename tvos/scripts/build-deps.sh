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

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
OUT="$ROOT/out/tvos"
mkdir -p "$SRC" "$OUT"

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

  if [ ! -d "$dir" ]; then
    log "Ryujinx/MoltenVK 포크 클론"
    git clone --depth 1 https://github.com/Ryujinx/MoltenVK.git "$dir"
  fi

  cd "$dir"

  # MoltenVK는 glslang / SPIRV-Cross / SPIRV-Tools 를 External 로 가져와
  # 플랫폼별로 같이 빌드한다. --tvos 를 꼭 붙여야 tvOS 슬라이스가 생긴다.
  log "fetchDependencies --tvos (수십 분 걸린다)"
  ./fetchDependencies --tvos

  log "make tvos"
  make tvos

  # 산출물 위치는 MoltenVK 버전에 따라 조금씩 다르다. 찾아서 복사한다.
  local dylib
  dylib="$(find Package/Release/MoltenVK -name 'libMoltenVK.dylib' -path '*tvOS*' | head -1 || true)"
  [ -n "$dylib" ] || dylib="$(find . -name 'libMoltenVK.dylib' -path '*tvOS*' | head -1 || true)"
  [ -n "$dylib" ] || die "libMoltenVK.dylib(tvOS)을 찾지 못했습니다. Package/Release 아래를 직접 확인하세요."

  cp "$dylib" "$OUT/libMoltenVK.dylib"

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
  local tag="release-3.5.0"

  if [ ! -d "$dir" ]; then
    log "SDL $tag 클론"
    git clone --depth 1 --branch "$tag" https://github.com/libsdl-org/SDL.git "$dir" \
      || { warn "$tag 태그 클론 실패 — main 으로 받습니다 (버전 차이 주의)"
           git clone --depth 1 https://github.com/libsdl-org/SDL.git "$dir"; }
  fi

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
  local tag="n6.1.2"      # 번들된 것이 6.x 계열

  if [ ! -d "$dir" ]; then
    log "FFmpeg $tag 클론"
    git clone --depth 1 --branch "$tag" https://github.com/FFmpeg/FFmpeg.git "$dir"
  fi

  cd "$dir"
  local prefix="$dir/build-tvos/install"
  rm -rf build-tvos; mkdir -p build-tvos
  cd build-tvos

  local cflags="-arch $ARCH -isysroot $TVOS_SDK -mappletvos-version-min=$TVOS_MIN -fembed-bitcode-marker"

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
