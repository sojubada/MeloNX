#!/usr/bin/env bash
# project-tvos.yml 에서 **실제로 존재하지 않는** 의존성 항목을 제거한다.
#
# 왜 필요한가
#   FFmpeg(libavcodec / libavutil)는 Nvdec 영상 디코딩 — 즉 게임 내 컷신에만
#   쓰인다. 그게 빌드되지 않았다고 해서 에뮬레이터 전체를 못 만들 이유가 없다.
#   하지만 XcodeGen 은 조건부 의존성을 지원하지 않으므로, 링크 목록에서
#   빼 주지 않으면 xcodebuild 가 "파일 없음" 으로 죽는다.
#
#   SDL3 와 MoltenVK 는 필수다. 없으면 여기서 실패시킨다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SPEC="$ROOT/project-tvos.yml"
[ -f "$SPEC" ] || { echo "project-tvos.yml 없음: $SPEC" >&2; exit 1; }

python3 - "$ROOT" "$SPEC" <<'PY'
import os, re, sys
root, spec = sys.argv[1], sys.argv[2]

REQUIRED = ["SDL3.xcframework", "libMoltenVK.dylib"]
OPTIONAL = ["libavcodec.dylib", "libavutil.dylib"]

lines = open(spec, encoding="utf-8").read().splitlines(keepends=True)
out, dropped, i = [], [], 0

while i < len(lines):
    line = lines[i]
    m = re.match(r'^(\s*)-\s*framework:\s*(\S+)\s*$', line)
    if m:
        indent, path = m.group(1), m.group(2)
        abs_path = os.path.join(root, path)
        if not os.path.exists(abs_path):
            base = os.path.basename(path)
            if base in REQUIRED:
                print(f"[x] 필수 의존성 누락: {path}", file=sys.stderr)
                sys.exit(1)
            # 이 항목과 뒤따르는 더 깊은 들여쓰기 줄(embed/codeSign)을 함께 제거
            dropped.append(path)
            i += 1
            while i < len(lines):
                nxt = lines[i]
                if nxt.strip() == "" or len(nxt) - len(nxt.lstrip()) > len(indent) + 2:
                    i += 1
                    continue
                break
            continue
    out.append(line)
    i += 1

if dropped:
    open(spec, "w", encoding="utf-8").write("".join(out))
    print("다음 의존성이 존재하지 않아 링크 목록에서 제거했습니다:")
    for d in dropped:
        print(f"    - {d}")
    print()
    print("  FFmpeg 가 빠지면 Nvdec 영상 디코딩(게임 내 컷신)이 동작하지 않습니다.")
    print("  에뮬레이션 자체와 렌더링·입력·오디오는 영향받지 않습니다.")
else:
    print("모든 의존성이 존재합니다 — 제거할 항목 없음")
PY
