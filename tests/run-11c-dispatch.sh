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
# ⑦-bis 禁令必须整族禁 relay(🔁 同日反转:首版为书记员放行 relay-once,scribe 通道独立后
#   lane 中继族对机务窗零合法用途——relay-once 回执事件投 laixin:dispatch,再用它=交叉污染)
for pat in "Bash(laixin-lane relay*)" "Bash(laixin-lane rdown*)"; do
  if grep -qF "$pat" <<< "$dry_out"; then PASS=$((PASS+1)); echo "ok  - 禁令含 $pat(lane 中继族整族禁)"
  else FAIL=$((FAIL+1)); echo "FAIL - 禁令缺 $pat"; fi
done

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

echo "== scribe(一次性书记员/服务窗,11C 自己的通道)=="
TF="$(mktemp)"; printf '任务单占位(测试)\n' > "$TF"

# ⑫ 配型:sol 默认(创始人 2026-08-23 书记员配型)+ 开关/env 优先级(平行取值 ⛔ 共用 lane 的 relay-once 开关)
tout "scribe 默认引擎 sol 钉 gpt-5.6-sol" "gpt-5.6-sol(默认(创始人 2026-08-23 书记员配型)" \
  env LAIXIN_SWITCH_DIR="$SW" "$BIN" scribe-up t12 --file "$TF" --dry
tout "scribe effort 显式 xhigh(⛔ 依赖默认档)" "effort=xhigh" \
  env LAIXIN_SWITCH_DIR="$SW" "$BIN" scribe-up t12 --file "$TF" --dry
printf 'gpt-5.6-luna\n' > "$SW/scribe-11c-model"
tout "scribe 模型开关 scribe-11c-model 生效" "gpt-5.6-luna(开关 scribe-11c-model" \
  env LAIXIN_SWITCH_DIR="$SW" "$BIN" scribe-up t12 --file "$TF" --dry
tout "env LAIXIN_11C_SCRIBE_MODEL 压过开关" "gpt-5.6-sol(env LAIXIN_11C_SCRIBE_MODEL" \
  env LAIXIN_SWITCH_DIR="$SW" LAIXIN_11C_SCRIBE_MODEL=gpt-5.6-sol "$BIN" scribe-up t12 --file "$TF" --dry
rm -f "$SW/scribe-11c-model"

# ⑬ claude 第二路线:钉 claude-opus-5,通道走与机务窗同一条开关链
tout "scribe --engine claude 钉 claude-opus-5" "claude-opus-5" \
  env LAIXIN_SWITCH_DIR="$SW" "$BIN" scribe-up t13 --file "$TF" --engine claude --dry

# ⑭ 参数校验:--file 必填/不存在拒,引擎枚举拒
"$BIN" scribe-up t14 --dry >/dev/null 2>&1; rc14=$?
t "scribe-up 缺 --file ⇒ 非零退出〔rc=${rc14}〕" [ "$rc14" -ne 0 ]
"$BIN" scribe-up t14 --file /no/such/task.md --dry >/dev/null 2>&1; rc14b=$?
t "scribe-up 任务单不存在 ⇒ 非零退出〔rc=${rc14b}〕" [ "$rc14b" -ne 0 ]
"$BIN" scribe-up t14 --file "$TF" --engine terra --dry >/dev/null 2>&1; rc14c=$?
t "scribe-up 未知引擎 ⇒ 非零退出〔rc=${rc14c}〕" [ "$rc14c" -ne 0 ]

# ⑮ 件名清洗:tmux 目标语法字符换 -(中文保留)
tout "件名含 : 与空格 ⇒ 窗名清洗" "scribe-a-b-c(" \
  env LAIXIN_SWITCH_DIR="$SW" "$BIN" scribe-up "a:b c" --file "$TF" --dry
tout "件名中文保留" "scribe-页面-方法" \
  env LAIXIN_SWITCH_DIR="$SW" "$BIN" scribe-up "页面.方法" --file "$TF" --dry

# ⑯ scribe-down/peek-scribe 对不存在的窗口:如实报 ⛔ 静默成功
env LAIXIN_11C_SESSION="$SB_SES" "$BIN" scribe-down t16 >/dev/null 2>&1; rc16=$?
t "scribe-down 无窗口 ⇒ 非零退出〔rc=${rc16}〕" [ "$rc16" -ne 0 ]
tout "scribe-list 无会话 ⇒ 如实报" "不存在" env LAIXIN_11C_SESSION="$SB_SES" "$BIN" scribe-list

# ⑰ 点名指令静态绊线:契约反污染句 + 完成信号 + 内置 brief 的书记员对接改走 scribe-up
for want in "⛔ 让书记员把回执落 记录/" "【11C件毕】" "scribe-up <件名> --file" "旧通道(laixin-lane relay-once)" ; do
  if grep -qF "$want" "$BIN"; then PASS=$((PASS+1)); echo "ok  - 静态锚「${want}」在"
  else FAIL=$((FAIL+1)); echo "FAIL - 静态锚「${want}」缺"; fi
done
# ⑰-bis 完成信号 ⛔ 在点名指令里整串连写(首火实撞:探针先命中指令回显——「内容标记被文档自触发」同族)
if grep -qF '【11C件毕】${item}' "$BIN"; then FAIL=$((FAIL+1)); echo "FAIL - 点名指令把完成信号整串连写(会被指令回显自触发)"
else PASS=$((PASS+1)); echo "ok  - 完成信号未整串写进点名指令(防回显自触发)"; fi

rm -f "$TF"
rm -rf "$SW"
echo
echo "结果:$PASS 过 / $FAIL 败"
[ "$FAIL" -eq 0 ]
