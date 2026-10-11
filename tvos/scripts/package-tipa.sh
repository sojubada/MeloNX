#!/usr/bin/env bash
# 빌드된 .app 을 TrollStore 설치용 .tipa / .ipa 로 포장한다.
#
#   ./tvos/scripts/package-tipa.sh <경로/MeloNX.app> [출력디렉터리]
#
# .tipa 와 .ipa 는 내용이 완전히 같은 zip 이다. TrollStore 는 .tipa 확장자를
# 쓰면 tvOS 가 파일을 App Store 설치기로 넘기지 않아 다루기 편하다.
set -euo pipefail

APP="${1:?사용법: package-tipa.sh <MeloNX.app> [출력디렉터리]}"
OUT="${2:-$(pwd)/dist}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENTS="$ROOT/tvos/MeloNX-tvOS.entitlements"
NAME="MeloNX"

[ -d "$APP" ]   || { echo ".app 을 찾지 못했습니다: $APP" >&2; exit 1; }
[ -f "$ENTS" ]  || { echo "엔타이틀먼트 파일 없음: $ENTS" >&2; exit 1; }
command -v ldid >/dev/null || { echo "ldid 필요: brew install ldid" >&2; exit 1; }

mkdir -p "$OUT"
rm -rf "$OUT/Payload" "$OUT/$NAME.tipa" "$OUT/$NAME.ipa"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R "$APP" "$WORK/$NAME.app"
BIN="$WORK/$NAME.app/$NAME"
[ -f "$BIN" ] || BIN="$WORK/$NAME.app/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$WORK/$NAME.app/Info.plist")"

echo "==> 플랫폼 확인 (platform TVOS 로 나와야 합니다)"
vtool -show-build "$BIN" 2>/dev/null | grep -E "platform|minos|sdk" || true
if ! vtool -show-build "$BIN" 2>/dev/null | grep -q "platform TVOS"; then
  echo "[!] 메인 바이너리의 플랫폼이 tvOS가 아닙니다. 잘못된 SDK로 빌드되었습니다." >&2
  exit 1
fi

# 임베드된 dylib/framework 도 tvOS 인지 확인한다. 하나라도 iOS면 설치는 되지만
# 실행 시 dyld 가 거부한다.
echo "==> 임베드 바이너리 플랫폼 확인"
BAD=0
while IFS= read -r f; do
  if ! vtool -show-build "$f" 2>/dev/null | grep -q "platform TVOS"; then
    echo "    [!] tvOS 아님: ${f#$WORK/}"
    BAD=1
  else
    echo "    ok: ${f#$WORK/}"
  fi
done < <(find "$WORK/$NAME.app/Frameworks" -type f \( -name "*.dylib" -o -perm -u+x \) 2>/dev/null | grep -vE "\.(plist|nib|car|png|json)$" || true)
[ "$BAD" -eq 0 ] || { echo "[!] 위 바이너리들을 appletvos SDK로 다시 빌드하십시오." >&2; exit 1; }

# 임베드된 각 dylib/framework 에도 서명이 필요하다.
echo "==> ldid 서명"
while IFS= read -r f; do
  ldid -S "$f" 2>/dev/null || true
done < <(find "$WORK/$NAME.app/Frameworks" -type f -name "*.dylib" 2>/dev/null || true)
while IFS= read -r fw; do
  inner="$fw/$(basename "${fw%.framework}")"
  [ -f "$inner" ] && ldid -S "$inner" 2>/dev/null || true
done < <(find "$WORK/$NAME.app/Frameworks" -maxdepth 1 -name "*.framework" 2>/dev/null || true)

# 메인 바이너리에 엔타이틀먼트를 넣어 fake-sign
ldid -S"$ENTS" "$BIN"
echo "==> 서명에 들어간 엔타이틀먼트"
ldid -e "$BIN"

echo "==> 포장"
mkdir -p "$WORK/Payload"
mv "$WORK/$NAME.app" "$WORK/Payload/"
( cd "$WORK" && zip -qry "$OUT/$NAME.tipa" Payload )
cp "$OUT/$NAME.tipa" "$OUT/$NAME.ipa"

echo
echo "완료:"
ls -la "$OUT/$NAME.tipa" "$OUT/$NAME.ipa"
echo
echo "TrollStore 로 설치하세요 (.tipa 권장)."
