#!/usr/bin/env bash
# tests/run-11c-dispatch.sh —— laixin-11c-dispatch(11C 专属派工窗口通道)绊线
#
# 独立成文件的原因(2026-08-23):落盘时 tests/run.sh 被 11B 归口在飞件(#166)占用,
# ⛔ 同文件并发(AGENTS 并发红线)。**并入 run.sh 归合并方**,并入后删除本文件。
# 判定纪律照 run.sh:herestring ⛔ 管道(pipefail 下 grep -q 早退会把命中判成失败,AGENTS 第五发)。
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="$PWD/bin/laixin-11c-dispatch"
PASS=0; FAIL=0
t(){ local name="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok  - $name"
  else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi }
tout(){ local name="$1" want="$2"; shift 2; local out
  out="$("$@" 2>&1)" || true
  if grep -qF "$want" <<< "$out"; then PASS=$((PASS+1)); echo "ok  - $name"
  else FAIL=$((FAIL+1)); echo "FAIL - $name"; echo "----- 实际输出末 5 行:"; tail -5 <<< "$out"; fi }

echo "== laixin-11c-dispatch:通道解析(--dry 零副作用)=="
SW="$(mktemp -d)"   # 沙盒开关目录:⛔ 拿真 ~/.laixin-lane-switch 当靶子
SB_SES="lx11cd-test-$$"

# ① 无参 → usage 且退 64
"$BIN" >/dev/null 2>&1; rc=$?
t "无参回 usage 且退 64〔rc=${rc}〕" [ "$rc" -eq 64 ]

# ② 默认链:开关目录为空 ⇒ 通道=claude(默认),模型=claude-opus-5(与派工窗口同档)
tout "空开关 ⇒ 通道默认 claude" "claude 通道 = claude(来源=默认" \
  env LAIXIN_SWITCH_DIR="$SW" "$BIN" up --dry
tout "模型默认 claude-opus-5(与派工窗口同档)" "claude-opus-5(来源=默认" \
  env LAIXIN_SWITCH_DIR="$SW" "$BIN" up --dry

# ③ 共用开关生效(流水线切账号时 11C 跟着切)
printf 'claude-b\n' > "$SW/claude-launcher"
tout "共用开关 claude-launcher ⇒ claude-b" "claude 通道 = claude-b(来源=开关 claude-launcher(与流水线共用)" \
  env LAIXIN_SWITCH_DIR="$SW" "$BIN" up --dry

# ④ 11C 专用开关优先于共用开关(与 laixin-11c-seat 同一条链——已知双真相源,两边同步改)
printf 'claude\n' > "$SW/claude-launcher-11c"
tout "11C 专用开关优先" "claude 通道 = claude(来源=开关 claude-launcher-11c(11C 专用)" \
  env LAIXIN_SWITCH_DIR="$SW" "$BIN" up --dry

# ⑤ env 最优先
tout "env LAIXIN_11C_CLAUDE_LAUNCHER 压过一切开关" "claude 通道 = claude-b(来源=env LAIXIN_11C_CLAUDE_LAUNCHER" \
  env LAIXIN_SWITCH_DIR="$SW" LAIXIN_11C_CLAUDE_LAUNCHER=claude-b "$BIN" up --dry

# ⑥ 模型开关与 env
printf 'claude-sonnet-5\n' > "$SW/dispatch-11c-model"
tout "模型开关 dispatch-11c-model 生效" "claude-sonnet-5(来源=开关 dispatch-11c-model" \
  env LAIXIN_SWITCH_DIR="$SW" "$BIN" up --dry
tout "env LAIXIN_11C_DISPATCH_MODEL 压过开关" "claude-opus-5(来源=env LAIXIN_11C_DISPATCH_MODEL" \
  env LAIXIN_SWITCH_DIR="$SW" LAIXIN_11C_DISPATCH_MODEL=claude-opus-5 "$BIN" up --dry

# ⑦ dry 列出工具禁令:send/fresh/claim/dispatch 四条核心(它当不成第二个 lane 派工窗口的结构保证)
dry_out="$(env LAIXIN_SWITCH_DIR="$SW" "$BIN" up --dry 2>&1)"
for pat in "laixin-lane send*" "laixin-lane fresh*" "laixin-lane claim*" "laixin-lane dispatch*" "git push*"; do
  if grep -qF "$pat" <<< "$dry_out"; then PASS=$((PASS+1)); echo "ok  - 禁令含 $pat"
  else FAIL=$((FAIL+1)); echo "FAIL - 禁令缺 $pat"; fi
done
# ⑦-bis 禁令 ⛔ 笼统 relay*(会连书记员起窗 relay-once 一起禁掉——前缀可分辨纪律)
if grep -qF '"Bash(laixin-lane relay' <<< "$dry_out"; then FAIL=$((FAIL+1)); echo "FAIL - 禁令误含 relay 前缀(会禁掉书记员 relay-once)"
else PASS=$((PASS+1)); echo "ok  - 禁令未笼统禁 relay(书记员 relay-once 可用)"; fi

# ⑧ 入口不在 PATH:up 在动任何窗口之前拒绝(沙盒会话名必须始终不存在)
out8="$(env LAIXIN_SWITCH_DIR="$SW" LAIXIN_11C_SESSION="$SB_SES" LAIXIN_11C_CLAUDE_LAUNCHER=no-such-bin-xyz "$BIN" up 2>&1)"; rc8=$?
t "入口不在 PATH ⇒ 非零退出〔rc=${rc8}〕" [ "$rc8" -ne 0 ]
tout "入口不在 PATH ⇒ 报法带修法" "不在 PATH" printf '%s' "$out8"
if tmux has-session -t "$SB_SES" 2>/dev/null; then FAIL=$((FAIL+1)); echo "FAIL - 拒起后不应留下沙盒会话(副作用先于校验)"; tmux kill-session -t "$SB_SES"
else PASS=$((PASS+1)); echo "ok  - 拒起零副作用(未建 tmux 会话)"; fi

# ⑨ down/status 对不存在的窗口:如实报不存在 ⛔ 静默成功
env LAIXIN_11C_SESSION="$SB_SES" "$BIN" down >/dev/null 2>&1; rc9=$?
t "down 无窗口 ⇒ 非零退出〔rc=${rc9}〕" [ "$rc9" -ne 0 ]
tout "status 无窗口 ⇒ 报不存在" "窗口不存在" env LAIXIN_11C_SESSION="$SB_SES" "$BIN" status

# ⑩ 内置角色指令静态绊线:红线三族在(⛔ lane 编排 / ⛔ 破双盲 / 读盘核对 ⛔ 信转述)
for want in "laixin-lane send/fresh/claim/dispatch" "破双盲" "stat mtime 与内容锚对齐" "唯一的派活来源"; do
  if grep -qF "$want" "$BIN"; then PASS=$((PASS+1)); echo "ok  - 角色指令含「${want}」"
  else FAIL=$((FAIL+1)); echo "FAIL - 角色指令缺「${want}」"; fi
done

# ⑪ --brief 文件不存在 ⇒ 拒绝
env LAIXIN_SWITCH_DIR="$SW" "$BIN" up --brief /no/such/brief.md --dry >/dev/null 2>&1; rc11=$?
t "--brief 文件不存在 ⇒ 非零退出〔rc=${rc11}〕" [ "$rc11" -ne 0 ]

rm -rf "$SW"
echo
echo "结果:$PASS 过 / $FAIL 败"
[ "$FAIL" -eq 0 ]
