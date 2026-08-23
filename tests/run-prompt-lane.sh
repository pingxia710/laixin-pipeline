#!/usr/bin/env bash
# tests/run-prompt-lane.sh —— 写单窗(prompt-up 写 prompt 动线)绊线
#
# 独立成文件的原因(2026-08-23):落盘时 tests/run.sh 被 11B 归口在飞件占用,⛔ 同文件并发。
# **并入 run.sh 归合并方**,并入后删除本文件。判定纪律照 run.sh:herestring ⛔ 管道(AGENTS 第五发)。
set -uo pipefail
cd "$(dirname "$0")/.."
LANE="$PWD/bin/laixin-lane"
PASS=0; FAIL=0
t(){ local name="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok  - $name"
  else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi }
tout(){ local name="$1" want="$2"; shift 2; local out
  out="$("$@" 2>&1)" || true
  if grep -qF "$want" <<< "$out"; then PASS=$((PASS+1)); echo "ok  - $name"
  else FAIL=$((FAIL+1)); echo "FAIL - $name"; echo "----- 实际输出末 5 行:"; tail -5 <<< "$out"; fi }
sgrep(){ local name="$1" want="$2"   # 源码静态锚
  if grep -qF "$want" "$LANE"; then PASS=$((PASS+1)); echo "ok  - $name"
  else FAIL=$((FAIL+1)); echo "FAIL - $name(缺锚:$want)"; fi }

echo "== 写单窗:参数与 dry(零副作用)=="
PK="$(mktemp)"; printf '底稿占位(测试)\n' > "$PK"
SB="lxpl-test-$$"

# ① --pack 必填/不存在/未知参数
"$LANE" prompt-up t1 --dry >/dev/null 2>&1; rc=$?
t "缺 --pack ⇒ 非零退出〔rc=${rc}〕" [ "$rc" -ne 0 ]
"$LANE" prompt-up t1 --pack /no/such.md --dry >/dev/null 2>&1; rc1b=$?
t "底稿不存在 ⇒ 非零退出〔rc=${rc1b}〕" [ "$rc1b" -ne 0 ]
"$LANE" prompt-up t1 --pack "$PK" --nope --dry >/dev/null 2>&1; rc1c=$?
t "未知参数 ⇒ 非零退出〔rc=${rc1c}〕" [ "$rc1c" -ne 0 ]

# ② 配型钉死(创始人 2026-08-23 配型令):sol + 显式 xhigh;env 可换档
tout "配型钉 gpt-5.6-sol xhigh" "配型=gpt-5.6-sol xhigh(钉,创始人 2026-08-23 配型令)" \
  "$LANE" prompt-up t2 --pack "$PK" --dry
tout "起动串显式带 -m 与 effort(⛔ 吃全局默认——与 M 轨相反,写单是固定工种)" \
  "codex -m gpt-5.6-sol -c model_reasoning_effort='\"xhigh\"'" \
  "$LANE" prompt-up t2 --pack "$PK" --dry
tout "env LAIXIN_PROMPT_LANE_MODEL 可换档" "codex -m gpt-5.6-terra" \
  env LAIXIN_PROMPT_LANE_MODEL=gpt-5.6-terra "$LANE" prompt-up t2 --pack "$PK" --dry

# ③ 契约与落位
tout "交付契约=记录/写单-<片名>-报告.md 末行【写单完成】" "记录/写单-t3-报告.md 末行【写单完成】t3" \
  "$LANE" prompt-up t3 --pack "$PK" --dry
tout "停车双态契约在 dry 里可见" "停车=【写单停车】t3" \
  "$LANE" prompt-up t3 --pack "$PK" --dry
tout "prompt 落位=prompt/来信平台-<片名>开发prompt.md" "prompt/来信平台-t3开发prompt.md" \
  "$LANE" prompt-up t3 --pack "$PK" --dry

# ④ 窗名清洗(与 mwin/vwin 同款转义)
tout "片名含 : 与空格 ⇒ 窗名清洗" "窗口=prompt-a-b-c " \
  "$LANE" prompt-up "a:b c" --pack "$PK" --dry

# ⑤ prompt-down 幂等(照 m-down 语义:不存在=本就不存在,退 0)
out5="$(env LAIXIN_SESSION="$SB" "$LANE" prompt-down t5 2>&1)"; rc5=$?
t "prompt-down 无窗口 ⇒ 退 0 幂等〔rc=${rc5}〕" [ "$rc5" -eq 0 ]
tout "prompt-down 无窗口 ⇒ 报「本就不存在」" "本就不存在" printf '%s' "$out5"
tout "prompt-list 无会话 ⇒ 如实报" "不存在" env LAIXIN_SESSION="$SB" "$LANE" prompt-list

echo "== 写单窗:接线静态锚(events/一次性窗计数/帮助/红线)=="
# ⑥ events 扫描认两个新末行(⛔ 平行实现——同一套扫描/基线/spool)
sgrep "ev_scan 认【写单完成】" "|^【写单完成】"
sgrep "ev_scan 认【写单停车】" "|^【写单停车】"
# ⑦ ev_loop 分流案例在(交稿走 Gate2 ⛔ verify-from;停车转方案窗口 ⛔ 自裁)
sgrep "ev_loop 有【写单完成】分流" "【写单完成】*)"
sgrep "ev_loop 有【写单停车】分流" "【写单停车】*)"
sgrep "Gate2 文案:lint 独立复跑" "**独立复跑**(⛔ 采信报告里贴的绿)"
sgrep "停车文案:转方案窗口 ⛔ 自裁" "转方案窗口补设计/裁定(⛔ 派工方自裁"
# ⑧ 一次性窗计数三处正则均扩到 prompt-(端口撞车/board 计数/看门狗对话框巡检)。
#   写法=保留旧字面 ^(verify|relay|m)- 另加 |^prompt-:run.sh 两处既有断言钉的是旧字面,
#   功能等价的改写会无谓地红它们(本分支实撞 2 红后改回)。
n8="$(grep -c "verify|relay|m)-|\^prompt-" "$LANE" || true)"
t "一次性窗正则三处均扩到 prompt-〔实测 ${n8} 处〕" [ "$n8" -ge 3 ]
# ⑨ 帮助与分派
sgrep "无参帮助含 prompt-up" "laixin-lane prompt-up <片名> --pack"
sgrep "分派表含 prompt-up" "prompt-up)   shift; cmd_prompt_up"
# ⑩ 点名指令红线锚(codex 无工具层禁令 ⇒ 指令写死)
sgrep "红线:⛔ kb-commit(提交=派工方签收)" "**⛔ kb-commit ⛔ git 任何写操作**"
sgrep "红线:共享键先枚举全部写入方" "先枚举它的全部写入方"
sgrep "红线:ref 级实测 ⛔ 依赖主树" "git -C /Users/pingxia/来信平台 show main:"
sgrep "缺料停车 ⛔ 硬写" "**停车报缺 ⛔ 硬写**"
# ⑪ 看板来源推断认 prompt- 窗(首火实撞:窗内 laixin-lane log 落成「未标注来源」——真看板 08-23 18:41 条)
sgrep "seat_src_infer 认写单窗" 'prompt-*)  echo "写单窗"'

rm -f "$PK"
echo
echo "结果:$PASS 过 / $FAIL 败"
[ "$FAIL" -eq 0 ]
