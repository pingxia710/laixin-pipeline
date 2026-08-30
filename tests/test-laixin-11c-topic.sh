#!/usr/bin/env bash
# laixin-11c-topic 独立绊线；不碰真实知识库、账号或窗口。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/bin/laixin-11c-topic"
TMP="$(mktemp -d /tmp/laixin-11c-topic-test.XXXXXX)"
STATE_ROOT="$TMP/state"
OUTPUT_ROOT="$TMP/output"
PASS=0
FAIL=0

cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }
check(){
  local name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}

mkdir -p "$OUTPUT_ROOT" "$TMP/input"
printf '%s\n' '# R0' 'R0_SECRET' > "$TMP/input/r0.md"
printf '%s\n' '# R1 派题包' '请独立分析。' > "$TMP/input/pack.md"
printf '%s\n' '# 允许材料' 'MATERIAL_ONLY' > "$TMP/input/material.md"
printf '%s\n' 'EXCERPT_ALLOWED' 'EXCERPT_FORBIDDEN' > "$TMP/input/section:with-colon.md"

cat > "$TMP/fake-codex" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then shift; out="$1"; fi
  shift
done
[ -n "$out" ] || exit 70
body="$(cat)"
stage="r1"
case "$body" in *'现在进行 R2'*) stage="r2" ;; esac
if [ "$stage" = "r1" ]; then
  case "$body" in *R0_SECRET*) exit 91 ;; esac
  printf '%s\n' '# R1' 'R1_RESULT' > "$out"
else
  case "$body" in *R0_SECRET*R1_RESULT*) : ;; *) exit 92 ;; esac
  [ "${FAKE_FAIL_R2:-0}" != "1" ] || exit 42
  printf '%s\n' '# R2' 'R2_RESULT' > "$out"
fi
if [ "${FAKE_TOOL_CALL:-0}" = "1" ]; then
  printf '%s\n' '{"type":"item.completed","item":{"type":"command_execution"}}'
else
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message"}}'
fi
printf '%s\n' '{"type":"turn.completed"}'
FAKE
chmod +x "$TMP/fake-codex"

cat > "$TMP/fake-claude" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
body="$(cat)"
case "$body" in
  *'现在进行 R2'*)
    case "$body" in *R0_SECRET*R1_RESULT*) printf '%s\n' 'READINESS CHATTER' '{"result":"# R2\\nR2_RESULT","is_error":false}' ;; *) exit 92 ;; esac
    ;;
  *)
    case "$body" in *R0_SECRET*) exit 91 ;; *) printf '%s\n' 'READINESS CHATTER' '{"result":"# R1\\nR1_RESULT","is_error":false}' ;; esac
    ;;
esac
FAKE
chmod +x "$TMP/fake-claude"

topic(){
  env \
    LAIXIN_11C_TOPIC_ROOT="$STATE_ROOT" \
    LAIXIN_11C_TOPIC_OUTPUT_ROOT="$OUTPUT_ROOT" \
    LAIXIN_11C_CODEX_BIN="$TMP/fake-codex" \
    LAIXIN_11C_CLAUDE_BIN="$TMP/fake-claude" \
    "$TOOL" "$@"
}

topic run codex-ok \
  --r0 "$TMP/input/r0.md" \
  --r1-pack "$TMP/input/pack.md" \
  --material "$TMP/input/material.md" \
  --excerpt "$TMP/input/section:with-colon.md:1:1" \
  --r1-out "$OUTPUT_ROOT/codex-r1.md" \
  --r2-out "$OUTPUT_ROOT/codex-r2.md" \
  --engine codex >/dev/null
check "Codex 假引擎跑到 complete" grep -q '"phase": "complete"' "$STATE_ROOT/codex-ok/state.json"
check "R1 提示不含 R0" bash -c '! grep -q R0_SECRET "$1"' _ "$STATE_ROOT/codex-ok/r1-attempt-01.prompt.md"
check "R1 只带指定摘录行" bash -c 'grep -q EXCERPT_ALLOWED "$1" && ! grep -q EXCERPT_FORBIDDEN "$1"' _ "$STATE_ROOT/codex-ok/r1-attempt-01.prompt.md"
check "R2 才追加 R0 与冻结 R1" grep -q 'R0_SECRET.*' "$STATE_ROOT/codex-ok/r2-attempt-01.prompt.md"
check "R2 含冻结 R1" grep -q R1_RESULT "$STATE_ROOT/codex-ok/r2-attempt-01.prompt.md"
check "R1/R2 由外层发布" bash -c 'grep -q R1_RESULT "$1" && grep -q R2_RESULT "$2"' _ "$OUTPUT_ROOT/codex-r1.md" "$OUTPUT_ROOT/codex-r2.md"
printf '%s\n' 'TAMPERED' >> "$OUTPUT_ROOT/codex-r2.md"
if topic status codex-ok >/dev/null 2>&1; then
  bad "complete 状态仍复核产物"
else
  ok "complete 状态仍复核产物"
fi

if topic run codex-ok \
  --r0 "$TMP/input/r0.md" \
  --r1-pack "$TMP/input/pack.md" \
  --r1-out "$OUTPUT_ROOT/unused-r1.md" \
  --r2-out "$OUTPUT_ROOT/unused-r2.md" >/dev/null 2>&1; then
  bad "同 ID 拒绝覆盖"
else
  ok "同 ID 拒绝覆盖"
fi

if FAKE_FAIL_R2=1 topic run resume-ok \
  --r0 "$TMP/input/r0.md" \
  --r1-pack "$TMP/input/pack.md" \
  --r1-out "$OUTPUT_ROOT/resume-r1.md" \
  --r2-out "$OUTPUT_ROOT/resume-r2.md" >/dev/null 2>&1; then
  bad "R2 失败显式停住"
else
  check "R2 失败记为 r2_failed" grep -q '"phase": "r2_failed"' "$STATE_ROOT/resume-ok/state.json"
fi
topic resume resume-ok >/dev/null
check "resume 复用冻结 R1 后完成" grep -q '"phase": "complete"' "$STATE_ROOT/resume-ok/state.json"

if FAKE_FAIL_R2=1 topic run frozen-bad \
  --r0 "$TMP/input/r0.md" \
  --r1-pack "$TMP/input/pack.md" \
  --r1-out "$OUTPUT_ROOT/frozen-r1.md" \
  --r2-out "$OUTPUT_ROOT/frozen-r2.md" >/dev/null 2>&1; then
  bad "冻结测试先停在 R2"
fi
printf '%s\n' 'TAMPERED' >> "$OUTPUT_ROOT/frozen-r1.md"
if topic resume frozen-bad >/dev/null 2>&1; then
  bad "R1 被改后拒绝续跑"
else
  ok "R1 被改后拒绝续跑"
fi

if FAKE_TOOL_CALL=1 topic run tool-call \
  --r0 "$TMP/input/r0.md" \
  --r1-pack "$TMP/input/pack.md" \
  --r1-out "$OUTPUT_ROOT/tool-r1.md" \
  --r2-out "$OUTPUT_ROOT/tool-r2.md" >/dev/null 2>&1; then
  bad "Codex 工具调用整卷作废"
else
  check "Codex 工具调用整卷作废" grep -q '违反零工具边界' "$STATE_ROOT/tool-call/state.json"
fi
check "作废卷未发布" bash -c '[ ! -e "$1" ] && [ ! -e "$2" ]' _ "$OUTPUT_ROOT/tool-r1.md" "$OUTPUT_ROOT/tool-r2.md"

topic run claude-ok \
  --r0 "$TMP/input/r0.md" \
  --r1-pack "$TMP/input/pack.md" \
  --r1-out "$OUTPUT_ROOT/claude-r1.md" \
  --r2-out "$OUTPUT_ROOT/claude-r2.md" \
  --engine claude >/dev/null
check "Claude 零工具路径跑到 complete" grep -q '"phase": "complete"' "$STATE_ROOT/claude-ok/state.json"

if topic run outside \
  --r0 "$TMP/input/r0.md" \
  --r1-pack "$TMP/input/pack.md" \
  --r1-out "$TMP/outside-r1.md" \
  --r2-out "$TMP/outside-r2.md" >/dev/null 2>&1; then
  bad "输出只能落 raw 根"
else
  ok "输出只能落 raw 根"
fi

printf '\n结果：%s 过 / %s 败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
