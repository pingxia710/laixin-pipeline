#!/bin/bash
# laixin-lane 自测套件——只测纯函数与只读命令,绝不碰 tmux 窗口/lane/派工权锁
# 用法:bash tests/run.sh   (在任何目录均可;依赖真仓库的部分只做只读操作)
set -uo pipefail
LANE="$(cd "$(dirname "$0")/.." && pwd)/bin/laixin-lane"
PASS=0; FAIL=0
t(){ # t <名字> <命令...> —— 退出码 0 即过
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "  ✅ $name";
  else FAIL=$((FAIL+1)); echo "  ❌ $name  ← $*"; fi
}
tout(){ # tout <名字> <期望子串> <命令...> —— 输出含子串即过
  local name="$1"
  local want="$2"
  shift 2
  local out; out="$("$@" 2>&1)"
  # ⛔ 判定不许用 `echo "$out" | grep -q`:本套件 set -o pipefail,grep -q 命中即早退,
  #   echo 吃 SIGPIPE(141)⇒ pipefail 把"匹配成功"判成失败——且与输出大小/机器负载相关,
  #   表现为"安静时全绿、流水线忙时稳定红"(2026-08-14 02:1x 实撞:9 项无辜测试齐红,
  #   实测 20/20 复现)。herestring 无管道即无此竞态。
  if grep -q "$want" <<< "$out"; then PASS=$((PASS+1)); echo "  ✅ $name";
  else FAIL=$((FAIL+1)); echo "  ❌ $name  (未见「${want}」,实际:$(head -1 <<< "$out"))"; fi
}
tfail(){ # tfail <名字> <期望错误子串> <命令...> —— 命令须失败且报该错
  local name="$1"
  local want="$2"
  shift 2
  local out; out="$("$@" 2>&1)"; local rc=$?
  if [ $rc -ne 0 ] && grep -q "$want" <<< "$out"; then PASS=$((PASS+1)); echo "  ✅ $name";
  else FAIL=$((FAIL+1)); echo "  ❌ $name  (rc=$rc,输出:$(head -1 <<< "$out"))"; fi
}

echo "== 1. 语法与用法 =="
t "bash -n 语法" bash -n "$LANE"
tout "用法列出全部命令" "daily-report" "$LANE"

echo "== 2. 只读命令跑通(真环境,零副作用) =="
tout "doctor 出体检结论" "体检结果" "$LANE" doctor
tout "stats 出燃料段" "队列燃料" "$LANE" stats
tout "stats 出周期段" "片级周期" "$LANE" stats
tout "whoholds 可查" "派工权" "$LANE" whoholds
tout "vlist 可查" "" "$LANE" vlist
tout "uptime 可查" "dispatch" "$LANE" uptime
tout "next-migration 给出下一号" "下一可用序号" "$LANE" next-migration
tout "next-worktree 给出下一号" "下一可用" "$LANE" next-worktree
tout "handoff 含机器/人工分界" "以下由交班窗口手工补" "$LANE" handoff
tout "daily-report 出拓扑节" "当前拓扑" "$LANE" daily-report

echo "== 3. verify-from 契约闸门 =="
TMPD="$(mktemp -d)"
printf '假报告\n【交付完成】main e9a4acc\n' > "$TMPD/来信平台-测试片验收记录.md"
tout "合法报告解析出片名" "片名=测试片" "$LANE" verify-from "$TMPD/来信平台-测试片验收记录.md" --dry
printf '没有标记\n' > "$TMPD/坏1.md"
tfail "无标记被拒" "契约不符" "$LANE" verify-from "$TMPD/坏1.md" --dry
printf '【交付完成】main deadbeef99\n' > "$TMPD/坏2.md"
tfail "假 commit 被拒" "不存在" "$LANE" verify-from "$TMPD/坏2.md" --dry
tfail "缺文件被拒" "报告不存在" "$LANE" verify-from "$TMPD/没有这个文件.md" --dry
# ⭐ 末行快照过期绊线(2026-08-13 夜加):一晚两次实撞——开发方交付后自行 rebase,报告末行没更新,
#   B 轨那次已交接才发现,验收窗口整轮改验。比对分支 ref 是机器的活。(e9a4acc 是历史 commit,恒过期)
tout "末行过期快照被识别并警告(--dry 不阻断)" "末行快照已过期" "$LANE" verify-from "$TMPD/来信平台-测试片验收记录.md" --dry
tfail "非 dry 时过期快照拒绝起窗" "拒绝按过期快照" "$LANE" verify-from "$TMPD/来信平台-测试片验收记录.md" --prompt /tmp/不存在的prompt
FRESH_TIP="$(git -C "$HOME/来信平台" rev-parse main | cut -c1-12)"
printf '【交付完成】main %s\n' "$FRESH_TIP" > "$TMPD/来信平台-新鲜片验收记录.md"
t "分支未前进时不报过期" bash -c "out=\$('$LANE' verify-from '$TMPD/来信平台-新鲜片验收记录.md' --dry 2>&1); echo \"\$out\" | grep -q '片名=新鲜片' && ! echo \"\$out\" | grep -q '已过期'"
rm -rf "$TMPD"

# ⭐ evidence 模式搜索绊线(2026-08-14 加):repro.log 含 NEL(U+0085)时裸 grep 判非文本静默
#   零命中,按"零命中=编造"的纪律差点冤枉合格验收 ⇒ 复查通道机器化并自带 -a。fixture 真造 NEL 字节。
EVD="$(mktemp -d)"; mkdir -p "$EVD/证据测试片"
printf 'line1\xc2\x85FIREWALL_CONFLICT=0\xc2\x85line3\n' > "$EVD/证据测试片/repro.log"
tout "evidence 模式搜索穿透 NEL(裸 grep 在此静默零命中)" "FIREWALL_CONFLICT=0" \
  env LAIXIN_EVID_ROOT="$EVD" "$LANE" evidence 证据测试片 FIREWALL_CONFLICT
tfail "evidence 真零命中时给防冤枉提示而非直接定罪" "先别下「编造」结论" \
  env LAIXIN_EVID_ROOT="$EVD" "$LANE" evidence 证据测试片 这个词不存在
rm -rf "$EVD"

echo "== 4. 配置外置(env 覆盖生效,默认不变) =="
tout "SESSION 可覆盖" "不存在" env LAIXIN_SESSION=lx-test-nonexist "$LANE" status
tout "ctx 分母可覆盖" "500,000" env LAIXIN_CTX_WINDOW=500000 "$LANE" ctx 3683f143

echo "== 4b. 模型钉死(起窗命令不继承全局默认) =="
tout "起窗命令引用 VERIFY_MODEL" 'model \$VERIFY_MODEL' grep -- '--model' "$LANE"
tout "起窗命令引用 DISPATCH_MODEL" 'model \$DISPATCH_MODEL' grep -- '--model' "$LANE"
# eval 单行赋值(别用 source <():bash 3.2 静默失败,见 AGENTS.md)
MV="$(env LAIXIN_VERIFY_MODEL=claude-sonnet-5 bash -c "eval \"\$(grep '^VERIFY_MODEL=' '$LANE')\"; echo \"\$VERIFY_MODEL\"")"
tout "模型可覆盖" "claude-sonnet-5" echo "$MV"

echo "== 5. 排队解析(fixture,不依赖真总表) =="
TMPT="$(mktemp -d)"
cat > "$TMPT/table.md" <<'EOF'
## 排队(测试)
| 片 | 轨 | 内容 | 发车状态 |
|---|---|---|---|
| **已飞片** | A | x | ✅ 已发车 |
| **测试可发片** | **A** | y | prompt ready |
| 前端片 | B | z | prompt 已写 |
EOF
# 抽函数体落文件再 source(bash 3.2 对 source <(...) 静默失败)
sed -n "/^ev_next_ready/,/^}/p" "$LANE" > "$TMPT/fn.sh"
source "$TMPT/fn.sh"
TABLE="$TMPT/table.md"
tout "A 轨取到 ready 片且跳过已发车" "测试可发片" ev_next_ready A
tout "B 轨认已写等价 ready" "前端片" ev_next_ready B

# ⭐ 油表虚高绊线(2026-08-13 晚加):片离开排队节有三个去向——在飞/在验/已合入,
#   少比对一个就虚高;且**同一片在不同节的括注不同**,按前缀比对会在第 7 个字符分岔。
#   实撞:stats 报"可立即发车 4 片",实际那 4 片全部已发车或已合入。
#   判据用**数字**而非"某片出现了"——修复失效时数字会变成 4,判据必然变红。
cat > "$TMPT/oil.md" <<'EOF'
## 进行中
| 片 | 轨 | 分支 | 状态 |
|---|---|---|---|
| **在飞片**(进行中节的括注) | A | x | 飞着 |

## 验收中 / 待整改
| 片 | 轨 | 分支 | 状态 |
|---|---|---|---|
| **在验片**(验收节的括注) | B | y | 验着 |

## 排队
| 片 | 轨 | 内容 | 发车状态 |
|---|---|---|---|
| **已合片**(排队节的括注) | A | a | prompt ready |
| **在飞片**(排队节写法不同) | A | b | prompt ready |
| **在验片**(排队节写法不同) | B | c | prompt ready |
| **真可发片** | A | d | prompt ready |

## 已完成(今日)
| 片 | 轨 | 合入 |
|---|---|---|
| **已合片**(已完成节的括注完全不同) | A | abc123,100 绿 |
EOF
tout "油表:已合入/在飞/在验的片都不算可发车(括注不同也能对上)" "可立即发车(prompt ready 且未发): 1" \
  env LAIXIN_TABLE="$TMPT/oil.md" bash "$LANE" stats
tout "油表:滞后行被点名(照排队节排片会重复发车)" "排队节状态滞后 2 行" \
  env LAIXIN_TABLE="$TMPT/oil.md" bash "$LANE" stats
rm -rf "$TMPT"

echo "== 6. 事件总线守活(2026-08-13 假绿灯实撞后加,静态回归绊线) =="
tout "ev-loop 循环体禁用 -e/pipefail(监视器不许被空结果带死)" "set +e" sed -n "/^ev_loop/,/^}/p" "$LANE"
tout "verify 窗口空集扫描有兜底" "done || true" sed -n "/^ev_loop/,/^}/p" "$LANE"
tout "ev_alive 判活认进程不认窗口" "pgrep -f" sed -n "/^ev_alive/,/^}/p" "$LANE"
tout "events status 有假绿灯态提示" "窗口在但循环已死" sed -n "/^cmd_events/,/^}/p" "$LANE"
tout "看门狗巡检用进程判活重启 events" "ev_alive || { board" grep "ev_alive || { board" "$LANE"
tout "ev_watch_target 的 local 已拆行(同行自引用撞 set -u)" 'local w="\$1"; local sf' grep -F 'local w="$1"; local sf' "$LANE"

echo "== 6b. 心跳截止线(2026-08-18 优化#1:防重启重扫把历史报告当新交付,08-15 实撞 10 份) =="
tout "ev-loop 每 tick 写心跳" 'date +%s > "\$EV_HB"' grep -F 'date +%s > "$EV_HB"' "$LANE"
tout "ev-loop 投递前有陈旧闸门" "跳过陈旧交付" sed -n "/^ev_loop/,/^}/p" "$LANE"
TMPH="$(mktemp -d)"
sed -n "/^ev_hb_cutoff/,/^}/p" "$LANE" > "$TMPH/fn.sh"
EV_HB="$TMPH/heartbeat"; EV_TICK=60
source "$TMPH/fn.sh"
echo 1000000 > "$EV_HB"
tout "有心跳:截止=心跳-2*tick" "999880" ev_hb_cutoff
rm -f "$EV_HB"
hb_cutoff_now_check(){  # 无心跳分支:截止应≈当前时刻(套内只有 tout/tfail,裸 if 分支不进计数——本文件 2026-08-18 实撞 pass 未定义静默失效)
  local now cut; now=$(date +%s); cut=$(ev_hb_cutoff)
  if [ "$cut" -ge "$now" ] && [ "$cut" -le $(( now + 5 )) ]; then echo CUTOFF_NOW_OK; else echo "CUTOFF_BAD got=$cut now=$now"; fi
}
tout "无心跳:截止=当前时刻(首启由基线兜底)" "CUTOFF_NOW_OK" hb_cutoff_now_check
rm -rf "$TMPH"

echo "== 6c. 台账巡检 audit-queue(2026-08-18 优化#13:陈旧行机器 diff) =="
TMPQ="$(mktemp -d)"; mkdir -p "$TMPQ/kb/4-开发层"
printf '## 排队(测试)\n\n| 片 | 轨 | 前置 | 状态 |\n|---|---|---|---|\n| 甲片测试切片 | A | 无 | ready |\n| 乙片纯净切片 | B | 无 | ready |\n\n## 下一节\n' > "$TMPQ/kb/4-开发层/来信平台-执行总表.md"
printf '| 08-18 | 派工窗口 | 合并 甲片测试切片 abc123 |\n' > "$TMPQ/kb/4-开发层/来信平台-流水线看板.md"
tout "排队节陈旧行被揪出" "甲片测试切片" env LAIXIN_KB="$TMPQ/kb" "$LANE" audit-queue
tout "干净行不误报且有嫌疑计数" "共 1 行嫌疑" env LAIXIN_KB="$TMPQ/kb" "$LANE" audit-queue
printf '| 08-18 | 派工窗口 | 无关记录 |\n' > "$TMPQ/kb/4-开发层/来信平台-流水线看板.md"
tout "零冲突时报绿" "零冲突" env LAIXIN_KB="$TMPQ/kb" "$LANE" audit-queue
rm -rf "$TMPQ"

echo "== 6d. stats 修真(2026-08-18 优化#2/#16,静态绊线) =="
tout "stats 有前置未解检测" "_blocked" sed -n "/^cmd_stats/,/^}/p" "$LANE"
tout "stats 有首过率节" "首过率" sed -n "/^cmd_stats/,/^}/p" "$LANE"
tout "stats 尾部挂台账巡检(单一实现复用)" "cmd_audit_queue" sed -n "/^cmd_stats/,/^}/p" "$LANE"
tout "ev-loop 重启保留交付基线(死亡期间落盘不丢)" '\-s "\$EV_SEEN" \] ||' grep -F -- '-s "$EV_SEEN" ] ||' "$LANE"

echo "== 7. 事件总线执行级绊线(真跑;静态 grep 抓不到展开顺序/管道返值类崩溃——2026-08-13 两次实撞后由 dispatch 建议加) =="
TMPE="$(mktemp -d)"
{ sed -n "/^pane_hash/,/^}/p" "$LANE"; sed -n "/^ev_watch_target/,/^}/p" "$LANE"; sed -n "/^ev_scan_deliveries/,/^}/p" "$LANE"; sed -n "/^ev_next_ready/,/^}/p" "$LANE"; } > "$TMPE/fns.sh"
mkdir -p "$TMPE/kb/4-开发层/记录"
printf 'x\n【交付完成】b z\n' > "$TMPE/kb/4-开发层/记录/a验收记录.md"
printf 'y\n没有标记\n' > "$TMPE/kb/4-开发层/记录/b验收记录.md"
t "ev_watch_target 在 ev-loop 同款严格模式下实跑不炸(窗口不存在)" \
  bash -uc "set -eo pipefail; SESSION=laixin测试不存在; EV_DIR='$TMPE'; EV_TICK=60; EV_STALL=360; source '$TMPE/fns.sh'; set +e; set +o pipefail; ev_watch_target 不存在窗口"
t "ev_scan_deliveries 全局严格模式下实跑不炸且识别末行标记" \
  bash -uc "set -eo pipefail; KB='$TMPE/kb'; source '$TMPE/fns.sh'; out=\$(ev_scan_deliveries); echo \"\$out\" | grep -q 'a验收记录'"

# ⭐ 三条 GONE 分类绊线(2026-08-13 加):上面那条只验"不炸",对"该不该告警"零分辨力——
#   lane-b 窗口整个消失、空转 17 分钟无人知道,而当时测试全绿。判据必须能区分成功与失败。
GD="$TMPE/gone"; mkdir -p "$GD/a" "$GD/b" "$GD/c"
t "lane 窗口整个消失必须告警(原实现在此静默,正是 17 分钟空转的根因)" \
  bash -uc "set -eo pipefail; SESSION=laixin测试不存在; EV_DIR='$GD/a'; EV_TICK=60; EV_STALL=360; source '$TMPE/fns.sh'; ev_deliver(){ printf '%s\n' \"\$2\"; }; set +e; set +o pipefail; ev_watch_target lane-b | grep -q '窗口整个消失'"
t "verify 窗口消失保持静默(vdown 正常回收,告警会变噪音)" \
  bash -uc "set -eo pipefail; SESSION=laixin测试不存在; EV_DIR='$GD/b'; EV_TICK=60; EV_STALL=360; source '$TMPE/fns.sh'; ev_deliver(){ printf '%s\n' \"\$2\"; }; set +e; set +o pipefail; out=\$(ev_watch_target verify-某片); [ -z \"\$out\" ]"
t "lane 消失告警只报一次(去重),且标记文件落盘" \
  bash -uc "set -eo pipefail; SESSION=laixin测试不存在; EV_DIR='$GD/c'; EV_TICK=60; EV_STALL=360; source '$TMPE/fns.sh'; ev_deliver(){ printf '%s\n' \"\$2\"; }; set +e; set +o pipefail; ev_watch_target lane-a >/dev/null; out=\$(ev_watch_target lane-a); [ -z \"\$out\" ] && [ -f '$GD/c/lane-a.gone' ]"
tout "窗口恢复即清除 gone 标记(否则再次消失不会再告警)" 'rm -f "\$gf"' sed -n "/^ev_watch_target/,/^}/p" "$LANE"

# ⭐ ev_next_ready 绊线(2026-08-13 夜加):空闲告警曾把创始人已裁后延的「评审-1处罚落地」
#   报成"该轨下一片"——行内 `status: design-ready` 被裸 /ready/ 子串击中,片名格自带 🅿️ 也没拦;
#   修成整行匹配后又出现反向误杀——「打标留痕」行状态格明写 prompt ready,却因行内一句
#   "R48 已交付并在验收中"被跳过 ⇒ 判定词只看状态格首个 <br> 前的片段(与 stats 分桶同口径)。
#   fixture 构造成递进:旧代码选中第 1 行、只收紧 ready 选中第 2 行(🅿️ 但状态格 prompt 已写)、
#   全修对才选中第 3 行(它同时钉死「A小片」轨形态与「后段顺带提及不误杀」)。
QT="$TMPE/queue-table.md"
cat > "$QT" <<'QEOF'
## 已完成(今日)
| 片 | 轨 | 合入 |
|---|---|---|
| **已合入片**(带括注差异) | B | abc1234 |

## 排队
| 片 | 轨 | 说明 | 状态 |
|---|---|---|---|
| 评审-1处罚落地 → 🅿️ 创始人已定放后期 | A | 设计本体 status: design-ready | ⏸️ prompt 待写 |
| 后延但prompt已写片 → 🅿️ 创始人后延 | A | 说明 | ✅ prompt 已写 |
| 真ready片 | A小片 | 一切就绪 | ⏸️ prompt ready:等座位(⛔ `?? 0` 与 `|| 0` 是禁止项)<br>别的片已交付并在验收中 |
| 假ready片 | B | 设计 status: design-ready 而 prompt 缺 | 🚧 缺设计 |
| 已合入片(排队行滞后) | B | 滞后行 | ⏸️ prompt ready |
QEOF
t "🅿️/design-ready 不作为下一片;A小片轨、后段顺带提及、格内 || 竖线均不误杀,真 prompt ready 行胜出" \
  bash -uc "set -eo pipefail; TABLE='$QT'; source '$TMPE/fns.sh'; [ \"\$(ev_next_ready A)\" = '真ready片' ]"
t "design-ready ≠ prompt ready,且已合入片的滞后排队行被已完成节事实压掉(B 轨须输出为空)" \
  bash -uc "set -eo pipefail; TABLE='$QT'; source '$TMPE/fns.sh'; [ -z \"\$(ev_next_ready B)\" ]"
rm -rf "$TMPE"

echo "== 9. 对话框签名分类(2026-08-15「Set up auto mode」一天冻 4 窗后加;自愈盲区修复) =="
dlg(){ printf '%s\n' "$1" | "$LANE" dialog-classify; }
tout "auto-mode 设置对话框 → esc(当日实测 Esc 安全)" "esc:auto-mode-setup" \
  dlg "Set up auto mode for your environment?
  1. Set it up  2. Not now  3. Don't show again
  Enter to confirm · Esc to cancel"
tout "auto-mode 向导第二屏 → esc(误入向导后的退出路)" "esc:auto-mode-wizard" \
  dlg "How you use Claude here    ◀ Mixed ▶
  Also scan shell history [ ]
  Continue"
tout "trust 对话框 → alert(⛔ Esc=杀进程,2026-08-13 实撞,绝不自动动键)" "alert:trust-dialog" \
  dlg "Do you trust the files in this folder?
  Enter to confirm · Esc to cancel"
tout "未知模态对话框 → alert(处置键未知只告警)" "alert:unknown-dialog" \
  dlg "Some brand new dialog we have never seen
  Enter to confirm · Esc to cancel"
tout "正常工作画面 → none(空提示符/工具输出不误报)" "none" \
  dlg "❯
  Opus 5 · dispatch · 28% (285k/1M)
  auto mode on (shift+tab to cycle)"
tout "含 Esc 字样但非模态(帮助文本)→ none" "none" \
  dlg "Press Esc to cancel current input, or keep typing."

echo "== 10. prompt-lint 引用可解析性(2026-08-15 生产方式层「当下可判」件①) =="
TMPP="$(mktemp -d)"
mkdir -p "$TMPP/kb/索引" "$TMPP/repo/app"
printf '| 转单-9 | x |\n| 资金3-1 | y |\n' > "$TMPP/kb/索引/wiki-裁定池总表.md"
printf '| R48 | z |\n' > "$TMPP/kb/索引/wiki-红线清单.md"
printf 'l1\nl2\nl3\nl4\nl5\n' > "$TMPP/repo/app/x.py"
printf '引用 app/x.py:3 与 转单-9 与 资金3-1 与 R48 全部真实,照转单-9无空格前缀也真实。\n' > "$TMPP/good.md"
printf '引用 app/x.py:99 越界,商会-99 查无,R999 查无,app/ghost.py:1 文件不存在。\n' > "$TMPP/bad.md"
tout "全真引用 → PASS(文件:行号+域-序号含资金3-1形态+R编号)" "0 项查无" \
  env LAIXIN_KB="$TMPP/kb" LAIXIN_REPO="$TMPP/repo" "$LANE" prompt-lint "$TMPP/good.md"
tfail "行号越界+编号查无+文件不存在 → 非零退出且逐项报错" "行号越界" \
  env LAIXIN_KB="$TMPP/kb" LAIXIN_REPO="$TMPP/repo" "$LANE" prompt-lint "$TMPP/bad.md"
tfail "查无编号在报错清单里点名" "商会-99" \
  env LAIXIN_KB="$TMPP/kb" LAIXIN_REPO="$TMPP/repo" "$LANE" prompt-lint "$TMPP/bad.md"
tfail "缺文件参数报用法" "用法" "$LANE" prompt-lint
rm -rf "$TMPP"

echo
echo "结果:$PASS 过 / $FAIL 败"
[ "$FAIL" -eq 0 ]
