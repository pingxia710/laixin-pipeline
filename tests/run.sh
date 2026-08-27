#!/bin/bash
# laixin-lane 自测套件——只测纯函数与只读命令,绝不碰 tmux 窗口/lane/派工权锁
# 用法:bash tests/run.sh   (在任何目录均可;依赖真仓库的部分只做只读操作)
set -uo pipefail
LANE="$(cd "$(dirname "$0")/.." && pwd)/bin/laixin-lane"
PASS=0; FAIL=0
# 🔴 套件判据必须只依赖被测对象,⛔ 依赖调用者所在窗口/环境(2026-08-22 实撞:dispatch 窗口里跑本套件,shell 带着
#   LAIXIN_WINDOW / TMUX_PANE ⇒ 来源推断类 3 条 + 1 条误红,而干净 shell 全绿——「同一套测试两处两种结果」)。
#   ⇒ 开跑先卸掉会改变被测行为的调用者环境;需要它们的测试各自显式 env 传入。
unset LAIXIN_WINDOW LAIXIN_BOARD_SRC TMUX_PANE TMUX 2>/dev/null || true
# 🔴 套件零副作用的机器半边(2026-08-22 实撞):真实派工权锁在套件开跑时若在,跑完必须还在——
#   当日 halt fixture 用真 HOME 的锁,把在班 dispatch 的派工权删了两遍而套件全绿;「绝不碰派工权锁」此前只是上面那行自述。
REAL_LOCK_BEFORE="$(cat "$HOME/.laixin-dispatch.lock" 2>/dev/null || true)"
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
printf '假报告\n【交付完成】main e9a4acc\n' > "$TMPD/来信平台-对照片-交付报告-kimi.md"
tout "引擎后缀交付报告(C 轨 kimi 对照份)片名派生成 X-kimi(⛔ 与对照份同名:回执会互相覆盖)" "片名=对照片-kimi" "$LANE" verify-from "$TMPD/来信平台-对照片-交付报告-kimi.md" --dry
printf '假报告\n【交付完成】main e9a4acc\n' > "$TMPD/来信平台-普通片-交付报告.md"
tout "无后缀交付报告片名派生不变" "片名=普通片" "$LANE" verify-from "$TMPD/来信平台-普通片-交付报告.md" --dry
printf '没有标记\n' > "$TMPD/坏1.md"
tfail "无标记被拒" "契约不符" "$LANE" verify-from "$TMPD/坏1.md" --dry
printf '【交付完成】main deadbeef99\n' > "$TMPD/坏2.md"
tfail "假 commit 被拒" "不存在" "$LANE" verify-from "$TMPD/坏2.md" --dry
tfail "缺文件被拒" "报告不存在" "$LANE" verify-from "$TMPD/没有这个文件.md" --dry
# ⭐ 末行快照过期绊线(2026-08-13 夜加):一晚两次实撞——开发方交付后自行 rebase,报告末行没更新,
#   B 轨那次已交接才发现,验收窗口整轮改验。比对分支 ref 是机器的活。(e9a4acc 是历史 commit,恒过期)
tout "末行过期快照被识别并警告(--dry 不阻断)" "末行快照已过期" "$LANE" verify-from "$TMPD/来信平台-测试片验收记录.md" --dry
tfail "非 dry 时过期快照拒绝起窗" "拒绝按过期快照" "$LANE" verify-from "$TMPD/来信平台-测试片验收记录.md" --prompt /tmp/不存在的prompt
FRESH_TIP="$(git -C "${LAIXIN_REPO:-$HOME/来信平台}" rev-parse main | cut -c1-12)"
printf '【交付完成】main %s\n' "$FRESH_TIP" > "$TMPD/来信平台-新鲜片验收记录.md"
t "分支未前进时不报过期" bash -c "out=\$('$LANE' verify-from '$TMPD/来信平台-新鲜片验收记录.md' --dry 2>&1); echo \"\$out\" | grep -q '片名=新鲜片' && ! echo \"\$out\" | grep -q '已过期'"
# #21 尾随空行绊线(2026-08-19 三十一任实撞):末行合规但其后一个空行,取末行得空串报契约不符,
# 把人推回手抄 40 位 hash——防线失效指向它唯一要防的风险(反向生效族)。
printf '假报告\n【交付完成】main %s\n\n\n' "$FRESH_TIP" > "$TMPD/来信平台-尾空行片验收记录.md"
tout "尾随空行不再击穿契约解析(#21)" "片名=尾空行片" "$LANE" verify-from "$TMPD/来信平台-尾空行片验收记录.md" --dry
# #23 零commit绊线(停车报告误用完成信号):祖先/等同 commit --dry 警告,真起窗拒绝
tout "零 commit 在 --dry 出警告(#23)" "疑似停车报告误用完成信号" "$LANE" verify-from "$TMPD/来信平台-测试片验收记录.md" --dry
tfail "零 commit 真起窗被拒(#23)" "零物可验" env LAIXIN_LOCK_FRESH=0 "$LANE" verify-from "$TMPD/来信平台-新鲜片验收记录.md" --prompt /tmp/任意
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

TIER_SW="$(mktemp -d)"
tout "Codex 用量档默认普通" "普通(default)" env LAIXIN_SWITCH_DIR="$TIER_SW" "$LANE" codex-tier status
tout "Codex 用量档可持久切快速" "快速(priority，1.5x)" env LAIXIN_SWITCH_DIR="$TIER_SW" "$LANE" codex-tier fast
t "Codex 快速档写入统一开关文件" test "$(cat "$TIER_SW/codex-service-tier")" = priority
tout "env 普通档覆盖持久快速档" "普通(default)" env LAIXIN_SWITCH_DIR="$TIER_SW" LAIXIN_CODEX_SERVICE_TIER=normal "$LANE" codex-tier status
tfail "Codex 用量档非法值拒绝(⛔ 静默回退普通)" "未知 Codex 用量档" env LAIXIN_SWITCH_DIR="$TIER_SW" LAIXIN_CODEX_SERVICE_TIER=bad-tier "$LANE" codex-tier status
t "Codex 用量档覆盖全部 11B/11C 起窗入口" bash -c '
  lane="$1"; seat="$2"; dispatch="$3"
  for fn in codex_launch_cmd cmd_up cmd_tool_up cmd_mup cmd_relay_once cmd_prompt_up; do
    body="$(sed -n "/^${fn}()/,/^}/p" "$lane")"
    grep -qF "codex_service_tier_flag" <<< "$body" || exit 1
  done
  [ "$(grep -cF "codex_service_tier_flag" "$seat")" -ge 4 ] || exit 1
  [ "$(grep -cF "codex_service_tier_flag" "$dispatch")" -ge 2 ]' _ "$LANE" "$(dirname "$LANE")/laixin-11c-seat" "$(dirname "$LANE")/laixin-11c-dispatch"
rm -rf "$TIER_SW"

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
# ⛔ 按字面断言探针实现:本条原写死 "pgrep -f",而 2026-08-19 探针被换掉(见下节)⇒ 那种写法
#   会在修复落地时误报红,是「判据比缺陷窄」的自撞。改测语义:认进程(枚举命令行)⛔ 认窗口。
tout "ev_alive 判活认进程(枚举命令行)" "ps -eo command" bash -c 'grep "^ev_alive()" "'"$LANE"'"'
t   "ev_alive ⛔ 认窗口(体内无 win_exists)" bash -c '! grep "^ev_alive()" "'"$LANE"'" | grep -q win_exists'
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
tout "格式合并记录 → 强嫌疑(#15 分级)" "强嫌疑:「甲片测试切片」" env LAIXIN_KB="$TMPQ/kb" "$LANE" audit-queue
tout "强嫌疑计数正确" "共 1 行强嫌疑" env LAIXIN_KB="$TMPQ/kb" "$LANE" audit-queue
# 弱嫌疑:片名只在叙述里被提及(交叉引用形态,三十任实测 6 行全假阳性的病根)
printf '| 08-18 | 派工窗口 | 合并 甲片测试切片 abc123(与乙片纯净切片相邻排期) |\n' > "$TMPQ/kb/4-开发层/来信平台-流水线看板.md"
tout "叙述提及 → 弱嫌疑一行速核(#15 ⛔ 拿误报换漏报)" "弱嫌疑 1 行" env LAIXIN_KB="$TMPQ/kb" "$LANE" audit-queue
tout "弱嫌疑仍列名不静默" "「乙片纯净切片」" env LAIXIN_KB="$TMPQ/kb" "$LANE" audit-queue
printf '| 08-18 | 派工窗口 | 合并 甲片测试切片 abc123 |\n' > "$TMPQ/kb/4-开发层/来信平台-流水线看板.md"
printf '| 08-18 | 派工窗口 | 无关记录 |\n' > "$TMPQ/kb/4-开发层/来信平台-流水线看板.md"
tout "零冲突时报绿" "零冲突" env LAIXIN_KB="$TMPQ/kb" "$LANE" audit-queue
rm -rf "$TMPQ"

echo "== 6e. 生产级 P0 件(2026-08-18,静态绊线) =="
tout "backup 只推不 commit(防互扫污染史)" "不 add 不 commit" sed -n "/^cmd_backup/,/^}/p" "$LANE"
tout "backup 失败记看板" "board \"备份\"" sed -n "/^cmd_backup/,/^}/p" "$LANE"
tout "boot-full 有重试与放弃出口" "五次未成" sed -n "/^cmd_install_boot_full/,/^}/p" "$LANE"
tout "doctor 有上游版本变化检测" "上游 CLI 版本已变化" sed -n "/^cmd_doctor/,/^cmd_[a-z_]*()/p" "$LANE"

echo "== 6f. kb-commit 守卫 + send 被吞检测(2026-08-18 P1-1/P1-2) =="
TMPV="$(mktemp -d)"; git -C "$TMPV" init -q; git -C "$TMPV" config user.email t@t; git -C "$TMPV" config user.name t
echo hi > "$TMPV/a.md"; mkdir -p "$TMPV/dir"; echo x > "$TMPV/dir/b.md"
tout "kb-commit 提交单文件成功" "已提交 1 个文件" env LAIXIN_VAULT="$TMPV" "$LANE" kb-commit "test: a" a.md
tfail "kb-commit 拒目录" "不是文件" env LAIXIN_VAULT="$TMPV" "$LANE" kb-commit "test: dir" dir
tfail "kb-commit 拒旗标" "不收旗标" env LAIXIN_VAULT="$TMPV" "$LANE" kb-commit "test: A" -A
tout "kb-commit 无变更时不报错" "无变更可提交" env LAIXIN_VAULT="$TMPV" "$LANE" kb-commit "test: again" a.md
rm -rf "$TMPV"
tfail "fresh --dir 目录不存在时先报错不杀窗" "窗口未动" "$LANE" fresh a --dir /nonexistent-dir-test-6f
TMPM="$(mktemp -d)"
sed -n "/^lane_mcp_off_flags/,/^}/p" "$LANE" > "$TMPM/fn.sh"; source "$TMPM/fn.sh"
tout "MCP 关闭清单默认含 aliyun-readonly" "aliyun-readonly" lane_mcp_off_flags ""
mcp_keep_check(){ local o; o="$(lane_mcp_off_flags "aliyun-readonly")"; case "$o" in *aliyun-readonly*) echo KEEP_FAIL ;; *node_repl*) echo KEEP_OK ;; *) echo KEEP_BAD ;; esac; }
tout "--with-mcp 放行后该服务不再被关且其余照关" "KEEP_OK" mcp_keep_check
# ⭐ 二批引号 key 实撞绊线(2026-08-18 10:5x,复盘页#11):codex -c 的 dotted path 是纯字符串切分,
#   引号包 key 会建出字面名 `"node_repl"` 的空表 ⇒ invalid transport 整份 config 拒载,lane 起不动
#   只剩 shell(与「Codex 崩了」同形)。修复=全量裸拼;连字符名裸拼实测同样生效(codex mcp list 验证)。
mcp_quote_check(){ local o; o="$(lane_mcp_off_flags "")"; case "$o" in *'"'*|*"'"*) echo QUOTE_BAD ;; *node_repl*) echo QUOTE_OK ;; *) echo QUOTE_EMPTY ;; esac; }
tout "MCP 关闭参数裸拼零引号(引号 key=codex 整份拒载根因,二批实撞)" "QUOTE_OK" mcp_quote_check
tout "连字符名裸拼在关闭清单(codex -c 纯字符串切分,无需 TOML 引号)" "mcp_servers.douyin-creator.enabled=false" lane_mcp_off_flags ""
rm -rf "$TMPM"
tout "up 有引擎启动自检(拒载秒退=脚本说成功现场没成功,回头验尸;#60② 文案随引擎)" '\${_eng} 未在跑' sed -n "/^cmd_up/,/^}/p" "$LANE"
tout "启动自检不自动重试(同因重试同死,只会刷屏)" "盲目重试" sed -n "/^cmd_up/,/^}/p" "$LANE"
# #40 起判定体抽进 send_swallow_check(cmd_send 后台块只留挂点)⇒ 这两条改盯函数本体
tout "send 有被吞检测(8s 抓屏找活动迹象)" "send 疑似被吞" sed -n "/^send_swallow_check/,/^}/p" "$LANE"
tout "send 被吞检测不自动重发" "盲目重发" sed -n "/^send_swallow_check/,/^}/p" "$LANE"

# ── #68:kimi 起窗卡在 `Trust this folder?`(创始人 2026-08-19 令「kimi 窗口需要修」)────────────
# 失败样本:`fresh c --dir ~/来信平台-c1` 后 lane-c 卡死在 kimi 信任对话框——两个选项分别是
# 「Trust this folder(启用 project MCP)」与「Don't trust(**说明逐字=Exit Kimi Code**)」,
# **默认高亮在 Don't trust**,Esc 亦是 exit ⇒ 三条路全有问题,无人值守时必然卡死。
# ⛔ 修法走签名库:trust 类对话框「只告警绝不动键」是 2026-08-13 Esc=杀进程实撞后的硬规则,
#   **守卫的现有行为是对的** ⇒ 唯一修法=让对话框根本不出现(起窗前预写信任记录)。
TMPK="$(mktemp -d)"
{ sed -n "/^kimi_wd_key/,/^}/p" "$LANE"; sed -n "/^kimi_project_mcp/,/^}/p" "$LANE";
  sed -n "/^kimi_trust_prewrite/,/^}/p" "$LANE";
  echo 'die(){ echo "laixin-lane: $*" >&2; exit 1; }'; echo 'board(){ :; }'; } > "$TMPK/fn.sh"
source "$TMPK/fn.sh"
# ⭐ 绊线①②(回退检测,本件的立身之本):判据取自 kimi 二进制里的 encodeWorkDirKey 源码,拿**两个
#   真实存在的记录**逐字对——谁把 slug 规则或 hash 算法改了(md5/sha1/带换行/不去首尾横线),本行立刻红。
#   ⚠️ 这两个期望值 ⛔ 由本实现算出来再回填(那是自证);它们是 kimi 自己写在 ~/.kimi-code 里的文件名。
tout "#68 wd key 命中真实样本一(basename 含中文 ⇒ 塌成 - 后被清除,只剩 c1)" "wd_c1_a237095d359c" \
  kimi_wd_key "/Users/pingxia/来信平台-c1"
tout "#68 wd key 命中真实样本二(纯 ASCII basename)" "wd_pingxia_013dee86007c" \
  kimi_wd_key "/Users/pingxia"
# ⭐ 绊线③:尾斜杠归一(JS 侧 replace(/\/+$/,"") 在 hash **之前**)——不归一会算出另一个 hash,
#   表现为「预写了但对话框照出」,而那与「没预写」在现场完全同形。
tout "#68 尾斜杠归一后与无尾斜杠同键" "wd_c1_a237095d359c" kimi_wd_key "/Users/pingxia/来信平台-c1/"
# ⭐ 绊线④:slug 全被清空时兜底 "workspace"(源码逐字),⛔ 产出 `wd__<hash>` 这种半截名
tout "#68 纯中文 basename ⇒ slug 兜底 workspace(⛔ 空 slug)" "wd_workspace_" kimi_wd_key "/Users/pingxia/来信平台"
# ⭐ 绊线⑤⑥⑦(安全判据本体):trust 语义逐字=「启用 project MCP servers」,而 project 级 stdio 条目
#   **会话启动即起进程** ⇒ 无条件预写=替使用者按掉一个安全决定。两处 kimi 真读的路径都要查。
mkdir -p "$TMPK/clean" "$TMPK/local/.kimi-code" "$TMPK/rootrepo/sub"
: > "$TMPK/local/.kimi-code/mcp.json"
: > "$TMPK/rootrepo/.mcp.json"; mkdir -p "$TMPK/rootrepo/.git"
t "#68 干净目录判为无 project MCP 配置" bash -c \
  '[ -z "$(kimi_project_mcp "'"$TMPK"'/clean")" ]'
tout "#68 认 project-local <dir>/.kimi-code/mcp.json" "/.kimi-code/mcp.json" kimi_project_mcp "$TMPK/local"
# ⭐ 只查 dir 自身会漏掉 project-root:worktree 的 .git 是文件、项目根常在上层,漏查=判据说「没有」
#   而 kimi 那边其实有 ⇒ 失效方向指向「悄悄替人 trust」,正是本判据要防的。
tout "#68 认上层项目根 .mcp.json(⛔ 只查 dir 自身)" "/rootrepo/.mcp.json" kimi_project_mcp "$TMPK/rootrepo/sub"
# ⭐ 绊线⑧:干净目录 ⇒ 预写成功,文件名与内容都对(内容与 kimi 自己写的逐字同构:紧凑 JSON、root 在前)
export KIMI_TRUST_DIR="$TMPK/trust"
t "#68 干净目录预写成功且文件名=wd key" bash -c \
  'source "'"$TMPK"'/fn.sh"; KIMI_TRUST_DIR="'"$TMPK"'/trust" kimi_trust_prewrite "'"$TMPK"'/clean" &&
   [ -f "'"$TMPK"'/trust/$(kimi_wd_key "'"$TMPK"'/clean")" ]'
t "#68 预写内容含 root 且是紧凑 JSON(与 kimi 自写同构)" bash -c \
  'source "'"$TMPK"'/fn.sh";
   grep -q "^{\"root\":\"'"$TMPK"'/clean\",\"trustedAt\":[0-9]\{1,\}}$" \
     "'"$TMPK"'/trust/$(kimi_wd_key "'"$TMPK"'/clean")"'
# ⭐ 绊线⑨(安全侧正向):有 project MCP 配置 ⇒ **拒绝并退非零** ⛔ 自动 trust
tfail "#68 目录有 project MCP 配置 ⇒ 拒绝预写并退非零" "拒绝自动信任" \
  bash -c 'source "'"$TMPK"'/fn.sh"; KIMI_TRUST_DIR="'"$TMPK"'/trust" kimi_trust_prewrite "'"$TMPK"'/local"'
t "#68 被拒时确实零写盘(⛔ 先写再报)" bash -c \
  'source "'"$TMPK"'/fn.sh"; ! [ -f "'"$TMPK"'/trust/$(kimi_wd_key "'"$TMPK"'/local")" ]'
# ⭐ 绊线⑩:幂等——已有记录不重写(重写只刷新 trustedAt,是无谓写盘且抹掉「何时被信任的」这条事实)
t "#68 已有记录时幂等不重写(trustedAt 不变)" bash -c \
  'source "'"$TMPK"'/fn.sh";
   f="'"$TMPK"'/trust/$(kimi_wd_key "'"$TMPK"'/clean")"; before="$(cat "$f")";
   KIMI_TRUST_DIR="'"$TMPK"'/trust" kimi_trust_prewrite "'"$TMPK"'/clean";
   [ "$before" = "$(cat "$f")" ]'
# ⭐ 绊线⑪(判据 ⛔ 一次性):每次起窗都重跑——仓将来可能新增 MCP 配置,而已有信任记录会让它无声生效。
t "#68 已有信任记录但目录新增了 MCP 配置 ⇒ 仍然拒绝(判据 ⛔ 一次性)" bash -c \
  'mkdir -p "'"$TMPK"'/clean/.kimi-code"; : > "'"$TMPK"'/clean/.kimi-code/mcp.json";
   ! ( source "'"$TMPK"'/fn.sh"; KIMI_TRUST_DIR="'"$TMPK"'/trust" kimi_trust_prewrite "'"$TMPK"'/clean" ) 2>/dev/null;
   rm -rf "'"$TMPK"'/clean/.kimi-code"'
# ⭐ 绊线⑫(位置,源码级):预写必须在 **ensure_session/new-window 之前** —— 拒绝时 ⛔ 留下半个死窗口
#   (#60① 引擎校验前置那一课);判据取「kimi_trust_prewrite 行号 < ensure_session 行号」。
t "#68 预写调用在动窗口之前(拒绝时 ⛔ 留下半个死窗口)" bash -c \
  'b="$(sed -n "/^cmd_up/,/^}/p" "'"$LANE"'")";
   p="$(grep -n "kimi_trust_prewrite" <<< "$b" | head -1 | cut -d: -f1)";
   e="$(grep -n "^  ensure_session" <<< "$b" | head -1 | cut -d: -f1)";
   [ -n "$p" ] && [ -n "$e" ] && [ "$p" -lt "$e" ]'
unset KIMI_TRUST_DIR
rm -rf "$TMPK"

echo "== 6g. kb-commit 台账钩+facts-fresh(2026-08-18 复盘页#13/#14:挂在人一定会做的动作上的机器检查) =="
TMPG="$(mktemp -d)"
# vault=git 仓库兼 fixture 知识库(总表/看板都在里面,KB/TABLE/BOARD 全指进来)
mkdir -p "$TMPG/v/4-开发层"
git -C "$TMPG/v" init -q; git -C "$TMPG/v" config user.email t@t; git -C "$TMPG/v" config user.name t
printf '## 排队\n| 片 | 轨 | 前置 | 状态 |\n|---|---|---|---|\n| 钩测试切片 | A | 无 | ⏸️ prompt ready |\n' > "$TMPG/v/4-开发层/来信平台-执行总表.md"
printf '| 08-18 10:00 | 派工窗口 | 无关记录一 |\n| 08-18 10:05 | 派工窗口 | 无关记录二 |\n' > "$TMPG/v/4-开发层/来信平台-流水线看板.md"
# 事实表 fixture repo(有 main)+新鲜表头
mkdir -p "$TMPG/r" "$TMPG/facts"
git -C "$TMPG/r" init -q; git -C "$TMPG/r" config user.email t@t; git -C "$TMPG/r" config user.name t
echo x > "$TMPG/r/f"; git -C "$TMPG/r" add f; git -C "$TMPG/r" commit -qm init
git -C "$TMPG/r" branch -M main
CURH="$(git -C "$TMPG/r" rev-parse main | cut -c1-7)"
printf '> 生成物。源=测试 `main@%s` · 生成于 测试\n' "$CURH" > "$TMPG/facts/生成-测试表.md"
GENV=(env LAIXIN_VAULT="$TMPG/v" LAIXIN_KB="$TMPG/v" LAIXIN_TABLE="$TMPG/v/4-开发层/来信平台-执行总表.md" LAIXIN_BOARD="$TMPG/v/4-开发层/来信平台-流水线看板.md" LAIXIN_REPO="$TMPG/r" LAIXIN_FACTS_DIR="$TMPG/facts")
HOOK_OUT="$("${GENV[@]}" "$LANE" kb-commit "test: 总表编辑" 4-开发层/来信平台-执行总表.md 2>&1)"
tout "提交涉总表⇒自动跑分桶自检(第 4 律机器化)" "台账分桶自检" echo "$HOOK_OUT"
tout "自检真跑出分桶数(查结果不查形态,第 N 变体也接得住)" "可立即发车(prompt ready 且未发): 1" echo "$HOOK_OUT"
tout "同挂载点跑事实表新鲜度且新鲜路径报绿" "事实表 1 张全部新鲜" echo "$HOOK_OUT"
printf 'x\n' > "$TMPG/v/其他笔记.md"
NOHOOK_OUT="$("${GENV[@]}" "$LANE" kb-commit "test: 非总表" 其他笔记.md 2>&1)"
no_hook_check(){ case "$1" in *分桶自检*) echo HOOK_LEAK ;; *已提交*) echo NO_HOOK_OK ;; *) echo COMMIT_BAD ;; esac; }
tout "非总表提交不触发自检钩(钩挂在台账动作上,别处零噪音)" "NO_HOOK_OK" no_hook_check "$NOHOOK_OUT"
# facts-fresh 单跑:过期表+无源行表+主树被占(checkout side 分支)——⛔ 硬 checkout,跳过+告警
git -C "$TMPG/r" checkout -qb side
printf '> 生成物。源=测试 `main@deadbee` · 生成于 测试\n' > "$TMPG/facts/生成-测试表.md"
printf '没有源行的表\n' > "$TMPG/facts/生成-无源表.md"
FF_OUT="$("${GENV[@]}" "$LANE" facts-fresh 2>&1)"
tout "过期表被点名(表头 commit ≠ 当前 main)" "已过期" echo "$FF_OUT"
tout "缺源行的表判不可判并告警(生成器契约)" "不可判" echo "$FF_OUT"
tout "主树被占⇒codegraph sync 跳过+告警且绝不硬 checkout" "硬 checkout" echo "$FF_OUT"
tout "过期时给出 ref 级导出器刷新命令(随时可跑)" "laixin_facts_export.py" echo "$FF_OUT"
rm -rf "$TMPG"

echo "== 6d. stats 修真(2026-08-18 优化#2/#16,静态绊线) =="
tout "stats 有前置未解检测" "_blocked" sed -n "/^cmd_stats/,/^}/p" "$LANE"
tout "stats 有首过率节" "首过率" sed -n "/^cmd_stats/,/^}/p" "$LANE"
tout "stats 尾部挂台账巡检(单一实现复用)" "cmd_audit_queue" sed -n "/^cmd_stats/,/^}/p" "$LANE"
tout "ev-loop 重启保留交付基线(死亡期间落盘不丢)" '\-s "\$EV_SEEN" \] ||' grep -F -- '-s "$EV_SEEN" ] ||' "$LANE"

echo "== 7. 事件总线执行级绊线(真跑;静态 grep 抓不到展开顺序/管道返值类崩溃——2026-08-13 两次实撞后由 dispatch 建议加) =="
TMPE="$(mktemp -d)"
# ⚠️ #171 起 ev_scan_deliveries 依赖 last_contract_line(契约行取法单点源)⇒ 夹具抽取必须带上它,否则「函数不存在」
#   的症状与「扫描逻辑写错」完全同形(本轮 5 条既有测试同时红,红因是依赖缺失不是被测行为)。
{ sed -n "/^last_contract_line/,/^}/p" "$LANE"; sed -n "/^pane_hash/,/^}/p" "$LANE"; sed -n "/^ev_watch_target/,/^}/p" "$LANE"; sed -n "/^ev_scan_deliveries/,/^}/p" "$LANE"; sed -n "/^ev_next_ready/,/^}/p" "$LANE"; sed -n "/^ev_lane_assigned/,/^}/p" "$LANE"; sed -n "/^ev_verify_receipt_ready/,/^}/p" "$LANE"; } > "$TMPE/fns.sh"
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

# 当前在飞表才是空闲告警的任务事实源:有分配才告警;无分配且无 ready 是有意空闲。
AT="$TMPE/active-table.md"
cat > "$AT" <<'AEOF'
## 进行中(= 轨道占用,发车位只看这一节)
| 片 | 轨道 | 分支 / worktree | 状态 | 发车契约 |
|---|---|---|---|---|
| **片甲** | A | branch-a | 🚀 已发车 | x |

## 排队
AEOF
t "空闲判据:当前在飞表 A 有分配、B 无分配;表头缺失按未知退 2(失效朝告警侧)" bash -c '
  source "'$TMPE'/fns.sh"; TABLE="'$AT'"
  ev_lane_assigned A >/dev/null && ! ev_lane_assigned B >/dev/null || exit 1
  TABLE="'$TMPE'/missing.md"; : > "$TABLE"; ev_lane_assigned A >/dev/null; [ "$?" -eq 2 ]'
t "有意空闲:lane-b 无在飞分配且无 ready ⇒ 静默;lane-a 有分配 ⇒ 保留卡住告警" bash -c '
  source "'$TMPE'/fns.sh"; TABLE="'$AT'"; SESSION=x; EV_TICK=60; EV_STALL=360
  pane_hash(){ echo fixed; }; ev_next_ready(){ :; }; lane_engine(){ echo codex; }; ev_log(){ :; }
  ev_deliver(){ printf "%s\n" "$2"; }
  EV_DIR="'$TMPE'/idle-b"; mkdir -p "$EV_DIR"; printf "fixed 360 0 1\n" > "$EV_DIR/lane-b.state"
  [ -z "$(ev_watch_target lane-b)" ] || exit 1
  EV_DIR="'$TMPE'/active-a"; mkdir -p "$EV_DIR"; printf "fixed 360 0 1\n" > "$EV_DIR/lane-a.state"
  ev_watch_target lane-a | grep -q "lane-a 已"' _

# 已有本轮落盘回执时,verify 静默不是故障;旧轮回执(mtime 早于本窗起点)不能误抑制。
RKB="$TMPE/rkb"; mkdir -p "$RKB/4-开发层/记录"
printf '正文\n【验收回执】通过 v-branch abcdef1 1234567\n' > "$RKB/4-开发层/记录/片甲-验收回执.md"
t "验收静默判据:本轮回执命中;早于本窗起点的旧回执不命中" bash -c '
  source "'$TMPE'/fns.sh"; KB="'$RKB'"; vwin(){ echo "verify-$1"; }
  now=$(date +%s); ev_verify_receipt_ready verify-片甲 $((now-1)) | grep -q "片甲-验收回执.md" || exit 1
  ! ev_verify_receipt_ready verify-片甲 $((now+10)) >/dev/null' _
tout "verify 卡住分支先查本轮回执(已有则不投告警)" "ev_verify_receipt_ready" sed -n "/^ev_watch_target/,/^}/p" "$LANE"
t "验收起窗登记本轮起点与 prompt;一次性中继不误引用验收 prompt" bash -c '
  v="$(sed -n "/^cmd_verify()/,/^}/p" "$1")"; r="$(sed -n "/^cmd_relay_once()/,/^}/p" "$1")"
  grep -q "INIT 0 0" <<< "$v" && grep -q "ev_prompt_set.*prompt" <<< "$v" && ! grep -q "ev_prompt_set.*prompt" <<< "$r"' _ "$LANE"
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
# ⭐ 上游三选菜单(2026-08-18 dispatch 二十四任报形态,复盘页#12):默认高亮项=Retry with a faster
#   model,盲按 Enter 静默把该轨降档(模型钉死失效),症状与「Codex 忽然变笨」事后不可分辨
#   ⇒ alert 族与 trust 同级,⛔ 自动动键。菜单文本取当日看板逐字记录。
tout "Retry with a faster model 三选菜单 → alert(默认项=降档模型,⛔ 动键,等自关)" "alert:retry-faster-model" \
  dlg "Our systems are thinking a bit more about this request before responding. Hang tight or retry with a faster model
  1. Retry with a faster model  2. Dismiss and keep waiting  3. Learn more
  No action is required, Codex will keep waiting, and this menu will close when the response is ready"
tout "纯文本等待提示(小写 retry,无菜单,08-15 实见)→ none(告警会变噪音)" "none" \
  dlg "Our systems are thinking a bit more about this request before responding. Hang tight or retry with a faster model. No action is required."
tout "签名库硬规则在册:安全键永不得是 Enter/不得选中默认项(复盘页#12-②)" "永远不得是 Enter" grep "永远不得是 Enter" "$LANE"
tout "看门狗对 retry-faster-model 用专文案(自关菜单,不误导为需人工)" "任何人不得按 Enter" sed -n "/^dialog_sweep_win/,/^}/p" "$LANE"
# 复盘页#20a:wd-loop 08-17 18:54 起 60s 即崩一天半的真凶——同一条 local 里「w="$1" … ${w}」,
# builtin 参数先全部展开再赋值,${w} 展开时未定义,set -u 击杀(本机 bash 3.2 实测复现)。
# 绊线是**模式级**的:全文件任何一行同型(local 赋自参数+同行再引用该变量)即红,防第三次引入
# (第一次 ev_watch_win 修过并留注,第二次 dialog_sweep_win 08-15 又写了一遍——注释挡不住,绊线才挡得住)。
t "无「local 同行赋参并自引用」杀手模式(#20a 绊线,机理=builtin 参数先展开后赋值)" \
  bash -c '! grep -qE "local [a-z_]+=\"\\\$[0-9]+\"[^;]*\\\$\{?[a-z_]+" "$0"' "$LANE"
tout "杀手模式在本机 bash 确实致死(机理自证——若此测变红=bash 行为已变,重估上一条)" "unbound" \
  bash -c 'set -u; f(){ local w="$1" m="x${w}"; :; }; f hi 2>&1 || true'
# 复盘页#20⑤:窗口存在是进程存活的不可靠代理——ev 08-13 修过自己,wd 判活漏了同款,
# 08-17 崩后 doctor/status 报「运行中」一天半。绊线:wd_alive 必须存在且 status/doctor/start 都不再拿裸 win_exists 判看门狗。
tout "wd_alive 进程判活已定义(#20⑤)" "wd-loop" grep -m1 "^wd_alive" "$LANE"
t "watchdog status/doctor/start 无裸 win_exists 判活(#20⑤ 绊线)" \
  bash -c '[ "$(grep -c "win_exists \"\$WATCHDOG_WIN\" && ok\|if win_exists \"\$WATCHDOG_WIN\"; then echo \"看门狗:运行中\"" "$0")" = 0 ]' "$LANE"
# 复盘页#20b/c:08-19 05:07 起窗撞 claude.exe 替换瞬间留空 shell,报错落在退场窗口无人见。
tout "dispatch 起窗对 CLI not found 有定向重试(#20c,瞬时因不属同因同死)" "定向重试" sed -n "/^cmd_dispatch/,/^}/p" "$LANE"
tout "dispatch 起窗有 15s 验尸(#20b,lanes #11-③ 同款)" "起窗验尸失败" sed -n "/^cmd_dispatch/,/^}/p" "$LANE"
tout "验尸判据=pane_current_command 掉回 shell" "pane_current_command" sed -n "/^cmd_dispatch/,/^}/p" "$LANE"
# 复盘页#20⑥破案:ev-loop 自 08-18 09:15 跑旧代码一天半,之后全部修复(含#1心跳)未生效——
# 常驻循环体驻内存不随文件更新,#1 注明「下次重启起效」而重启从未发生。代龄检查让它可见。
tout "loop_stale 已定义且用 etime 换算(lstart 中文 locale 不可解析)" "etime" sed -n "/^loop_stale/,/^}/p" "$LANE"
tout "loop_stale 的 stat 带 -L(经软链调用时不带-L取链自身mtime永判不出新)" "stat -L" sed -n "/^loop_stale/,/^}/p" "$LANE"
tout "events status 有代龄提示路径" "循环代龄落后" sed -n "/^cmd_events/,/^}/p" "$LANE"
# 复盘页#19:心跳只挂send,有意不发车70分钟被判无人持有——锁的过期会让看门狗重起新dispatch(双派工)。
# 三层修:a)duty命令续期(仅调用者==持有者:log/peek非dispatch专属,中继实测反例)b)whoholds两态 c)wd每拍代续。
tout "lock_renew_if_holder 有身份校验(#19-a)" "调用者==当前持有者" sed -n "/^lock_renew_if_holder/,/^}/p" "$LANE"
tout "duty 白名单含 stats/evidence/handoff(#19-a 不止 send)" "stats|ctx|evidence" grep "lock_renew_if_holder ;;" "$LANE"
tout "whoholds 区分在班过期与真无人(#19-b)" "非可接管" sed -n "/^cmd_whoholds/,/^}/p" "$LANE"
tout "看门狗每拍代续且仅当持有者=dispatch(#19-c)" "lock_renew \"\$DISPATCH_WIN\"" sed -n "/^wd_loop/,/^}/p" "$LANE"
tout "持有者是别人时看门狗不碰只告警矛盾态(#19-c)" "矛盾态" sed -n "/^wd_loop/,/^}/p" "$LANE"

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
printf '| 满员话术 | 预计X日内原路到账 |\n| 好话术 | 预计 N 天内答复(N=时效配置渲染) |\n' > "$TMPP/kb/索引/wiki-消费者词汇表.md"
printf '引用 索引/wiki-消费者词汇表.md:1 与 转单-9。\n' > "$TMPP/ph-bad.md"
printf '引用 索引/wiki-消费者词汇表.md:2「好话术」 与 转单-9。\n' > "$TMPP/ph-good.md"   # 2026-08-23 起词表引用无指纹即红,夹具补指纹(本组测占位符,与指纹无关)
tfail "词表占位符未注取值来源 → 红(优化#11)" "占位符" \
  env LAIXIN_KB="$TMPP/kb" LAIXIN_REPO="$TMPP/repo" "$LANE" prompt-lint "$TMPP/ph-bad.md"
tout "占位符带取值注 → 过" "0 项查无" \
  env LAIXIN_KB="$TMPP/kb" LAIXIN_REPO="$TMPP/repo" "$LANE" prompt-lint "$TMPP/ph-good.md"
# #22a(2026-08-19):占位符只扫词格——第三格备注引用被替换旧句(含 N)不再算到新句头上。
# 定稿句零占位而备注引旧句 ⇒ 修复前报红(结构性误报),修复后过。
printf '| 付款指引 | 收款方式会短信发给你 | 替换「请按线下收款指令支付 N 元」旧句 |\n' >> "$TMPP/kb/索引/wiki-消费者词汇表.md"
printf '引用 索引/wiki-消费者词汇表.md:3「付款指引」 与 转单-9。\n' > "$TMPP/ph-note.md"
tout "备注格引旧句含占位不误伤新句(#22a 只扫词格)" "0 项查无" \
  env LAIXIN_KB="$TMPP/kb" LAIXIN_REPO="$TMPP/repo" "$LANE" prompt-lint "$TMPP/ph-note.md"
printf '| 坏例 | 预计 X 日内原路到账 | 备注 |\n' >> "$TMPP/kb/索引/wiki-消费者词汇表.md"
printf '引用 索引/wiki-消费者词汇表.md:4 与 转单-9。\n' > "$TMPP/ph-cell.md"
tfail "词格本身含占位仍红(#22a 不放松词格)" "占位符" \
  env LAIXIN_KB="$TMPP/kb" LAIXIN_REPO="$TMPP/repo" "$LANE" prompt-lint "$TMPP/ph-cell.md"
# #22b:供给侧半面提示(提示级不拦,退出码仍 0)
printf 'admin 工作台改造。引用 索引/wiki-消费者词汇表.md:2「好话术」 与 转单-9。\n' > "$TMPP/ph-side.md"
tout "提及供给侧界面只引消费者词表 → ⚠️ 提示(#22b)" "供给侧词汇表逐角色" \
  env LAIXIN_KB="$TMPP/kb" LAIXIN_REPO="$TMPP/repo" "$LANE" prompt-lint "$TMPP/ph-side.md"
t "#22b 提示不改变退出码(纯提示级)" \
  env LAIXIN_KB="$TMPP/kb" LAIXIN_REPO="$TMPP/repo" "$LANE" prompt-lint "$TMPP/ph-side.md"
# #18a:改读法片缺消费点清单 → 提示级
printf '收敛 payload 序列化面。引用 索引/wiki-消费者词汇表.md:2「好话术」 与 转单-9。\n' > "$TMPP/ph-read.md"
tout "改读法片缺消费点清单 → ⚠️ 提示(#18a)" "消费点清单" \
  env LAIXIN_KB="$TMPP/kb" LAIXIN_REPO="$TMPP/repo" "$LANE" prompt-lint "$TMPP/ph-read.md"
printf '收敛 payload 序列化面,消费点清单如下。引用 索引/wiki-消费者词汇表.md:2「好话术」 与 转单-9。\n' > "$TMPP/ph-read2.md"
t "带消费点清单不提示(#18a)" bash -c 'out="$(env LAIXIN_KB="'"$TMPP"'/kb" LAIXIN_REPO="'"$TMPP"'/repo" "'"$LANE"'" prompt-lint "'"$TMPP"'/ph-read2.md" 2>&1)"; ! grep -q "消费点清单——" <<< "$out"' 
printf '| 聚单-9 | x |\n| 商会-10 | x |\n' >> "$TMPP/kb/索引/wiki-裁定池总表.md"
printf '规格单-真人实测环境最小集-20260823.md; 照聚单-9; 转单-9; 资金3-1; 商会-10。\n' > "$TMPP/date-seg.md"
t "prompt-lint: 日期段不作裁定号，四种真编号仍可解析" bash -c 'out="$(env LAIXIN_KB="'"$TMPP"'/kb" LAIXIN_REPO="'"$TMPP"'/repo" "'"$LANE"'" prompt-lint "'"$TMPP"'/date-seg.md" 2>&1)"; grep -q "4 项引用可解析,0 项查无" <<< "$out" && ! grep -q "最小集-202" <<< "$out"'
# #18b report-lint:举证形态半边机器化(实质归验收)
RPT="$(mktemp -d)"
printf '报告\n```\n输出\n```\ncommit 数 1,任务数 1,达标\n【交付完成】b test123\n' > "$RPT/好报告.md"
tout "合规报告过 report-lint(#18b)" "0 项缺陷" "$LANE" report-lint "$RPT/好报告.md"
printf '报告全是声明式已验证\n【交付完成】b test123\n' > "$RPT/坏报告.md"
tfail "零输出块+缺达标行被拒(#18b)" "零命令输出块" "$LANE" report-lint "$RPT/坏报告.md"
printf '停车报告:词表查无\n理由如下停车\n' > "$RPT/停车.md"
t "停车报告不报末行契约错(#18b 停车是合法末态)" \
  bash -c 'out="$("$0" report-lint "$1" 2>&1)"; ! grep -q "末行既非" <<< "$out"' "$LANE" "$RPT/停车.md"
rm -rf "$RPT"
# #14c 绊线:vdown 挂了 facts-fresh 与总表脏提醒(静态,vdown 本体碰 tmux 不在套内实跑)
tout "vdown 挂 facts-fresh(#14c 合并邻接挂载点)" "cmd_facts_fresh" sed -n "/^cmd_vdown/,/^}/p" "$LANE"
tout "vdown 有总表未提交提醒且不代交(#14c)" "未提交改动" sed -n "/^cmd_vdown/,/^}/p" "$LANE"
# M1 升级提醒族(复盘页#8,方案 log:29:投而未接与没投不得同形;绊线测试须含「投而未接」路径)
TMPM="$(mktemp -d)"
sed -n "/^ev_ack_overdue/,/^}/p" "$LANE" > "$TMPM/fn.sh"; EV_ACK=2700; source "$TMPM/fn.sh"
printf '1000|老片|P\n5000|新片|P\n800|已升级片|E\n' > "$TMPM/pending"
tout "投而未接超阈值被判升级(M1 绊线)" "老片" bash -c 'source "'"$TMPM"'/fn.sh"; EV_ACK=2700 ev_ack_overdue 4000 < "'"$TMPM"'/pending"'
t "未超阈值与已升级的不重报(M1)" bash -c 'source "'"$TMPM"'/fn.sh"; out="$(EV_ACK=2700 ev_ack_overdue 4000 < "'"$TMPM"'/pending")"; ! grep -qE "新片|已升级片" <<< "$out"'
tout "ev_deliver 投交付即登记待认领(M1)" "EV_PENDING" sed -n "/^ev_deliver/,/^}/p" "$LANE"
tout "巡检见 verify 窗口即销账(M1)" "认领销账" sed -n "/^ev_loop/,/^}/p" "$LANE"
tout "升级提醒⛔自动拉起(M1 方案红线)" "不自动拉起" sed -n "/^ev_loop/,/^}/p" "$LANE"
rm -rf "$TMPM"
rm -rf "$TMPP"

echo "== copy-audit 词表覆盖率审计(#28,fixture 全封闭:临时 git 仓+临时词表) =="
CAD="$(mktemp -d)"
t "copy_audit.py 语法" python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$(dirname "$LANE")/copy_audit.py"
git init -q -b main "$CAD/repo" && mkdir -p "$CAD/repo/frontend/src/lib" "$CAD/kb/索引"
cat > "$CAD/repo/frontend/src/lib/consumer-copy.ts" <<'EOF'
// 事实源是「wiki-消费者词汇表」
export const testLabels: Record<string, string> = {
  good: "已收到测试句",
  missing: "这句词表没有登记",
  dead: "已废弃测试句",
};
EOF
git -C "$CAD/repo" add frontend/src/lib/consumer-copy.ts && git -C "$CAD/repo" -c user.name=t -c user.email=t@t commit -qm fixture
cat > "$CAD/kb/索引/wiki-消费者词汇表.md" <<'EOF'
| draft | 已收到测试句 | |
| old | ~~已废弃测试句~~ 替换后的新句 | |
EOF
printf '# 供给侧词汇表(测试,空)\n' > "$CAD/kb/索引/wiki-供给侧词汇表.md"
tout "已知命中样例给出 表:行(#28)" "消费者词汇表:L1" env LAIXIN_REPO="$CAD/repo" LAIXIN_KB="$CAD/kb" "$LANE" copy-audit
tout "已知零命中样例标 ⚠️(#28)" "⚠️零命中" env LAIXIN_REPO="$CAD/repo" LAIXIN_KB="$CAD/kb" "$LANE" copy-audit
# 三约束①绊线:删除线内命中 ⛔ 算正常命中——标废词还在用要单独看得见
tout "删线行样例归「仅删线行命中」⛔ 混入正常命中(#28 三约束①)" "仅删线行命中 消费者词汇表:L2" \
  env LAIXIN_REPO="$CAD/repo" LAIXIN_KB="$CAD/kb" "$LANE" copy-audit
# 三约束②绊线两条:报告非闸门(有零命中仍退出 0——改成非零退出即红);数据源失效必须自曝退非零(⛔ 空报告冒充达标)
t "有零命中仍退出 0——报告非闸门(#28 三约束②)" env LAIXIN_REPO="$CAD/repo" LAIXIN_KB="$CAD/kb" "$LANE" copy-audit
tfail "数据源失效自曝退非零(#28 三约束②)" "失效自曝" env LAIXIN_REPO="$CAD/nonexist" LAIXIN_KB="$CAD/kb" "$LANE" copy-audit
rm -rf "$CAD"

echo "== 6h. 中继窗口托管 relay(#32;fixture 全封闭=假 tmux 会话+临时标记/看板,零真实副作用) =="
R32="$(mktemp -d)"
R32S="bogus-relay-$$"
# ⭐ 绊线①(半成品实撞):用法注释、RELAY_* 配置、cmd_relay/cmd_relay_down/cmd_peekr 三个函数全都写好了,
#   **唯独没接进 case 分派** ⇒ `laixin-lane relay` 静默落进 `*)` 打印用法退 1,与「参数敲错了」完全同形,
#   人会去查自己的命令行而不是查接线。判据取 cmd_relay 自己的参数报错(它的 while 解析在 ensure_session
#   之前,未知参数即 die,零副作用)——接线被回退时这里立刻变红。
tfail "relay 已接线(进得了 cmd_relay 参数解析)" "未知参数" \
  env LAIXIN_SESSION="$R32S" LAIXIN_RELAY_ENABLED="$R32/m" LAIXIN_BOARD="$R32/b.md" "$LANE" relay --nope
t "peek-r 已接线(不落进用法兜底)" bash -c \
  '! grep -q "信使脚本" <<< "$(env LAIXIN_SESSION="'"$R32S"'" "'"$LANE"'" peek-r 2>&1)"'
# ⭐ 绊线②:relay-down = 收窗 **且关闭托管**(清标记)。标记是本族全部保活行为的总闸门。
printf 'seed\n' > "$R32/m"
tout "relay-down 已接线并清托管标记" "托管标记已清除" \
  env LAIXIN_SESSION="$R32S" LAIXIN_RELAY_ENABLED="$R32/m" LAIXIN_BOARD="$R32/b.md" "$LANE" relay-down
t "relay-down 后标记确已不在(总闸门真的关了)" bash -c '[ ! -f "'"$R32"'/m" ]'
# ⭐ 绊线③(方向性,最容易被"顺手优化"掉):halt 收 relay 窗口但 **⛔ 清标记**——
#   halt 是暂停、relay-down 才是关托管。若谁在 halt 里顺手 rm 标记,halt→resurrect --full 会
#   **静默少起一个中继**(拓扑缺一角且零告警),正是三约束②「失效必须降级 ⛔ 反向」要防的形态。
printf 'seed\n' > "$R32/m"
# 🔴 LAIXIN_DISPATCH_LOCK 必带(2026-08-22 实撞):本条此前用真 HOME 的锁 ⇒ cmd_halt 末尾「持有者==dispatch 则 rm」
#   把**在班 dispatch 的派工权删了**(套件跑两遍、锁消失两遍、套件自报全绿)。套件头两行「绝不碰派工权锁」
#   只是自述,机器半边见文末「套件零副作用」断言。
printf 'dispatch %s\n' "$(date +%s)" > "$R32/lock"
env LAIXIN_SESSION="$R32S" LAIXIN_RELAY_ENABLED="$R32/m" LAIXIN_BOARD="$R32/b.md" LAIXIN_DISPATCH_LOCK="$R32/lock" "$LANE" halt >/dev/null 2>&1 || true
t "halt 清的是 fixture 锁(持有者==dispatch ⇒ rm 路径真被走到,⛔ 只是没碰到真锁)" bash -c '[ ! -f "'"$R32"'/lock" ]'
t "halt 保留托管标记(halt=暂停 ⛔ 关托管)" bash -c '[ -f "'"$R32"'/m" ]'
t "halt 确会收 relay 窗口" bash -c \
  'awk "/^cmd_halt\(\)/,/^}/" "'"$LANE"'" | grep -q "RELAY_WIN"'
# ⭐ 绊线④:9230 双真相源收敛——起窗与回收必须共用常量;字面 9230 再现即红
t "cmd_halt 不再硬编码 9230(与起窗共用 DISPATCH_CDP_PORT)" bash -c \
  '! grep -q "cdp_sweep 9230" "'"$LANE"'"'
# ⭐ 绊线⑤:看门狗里 relay 段必须**排在派工分支之前**——下面每个 dispatch 分支都 continue,
#   挂在后面 = 「派工窗口一出事中继就没人管」,而这两件最可能同时发生(整机重启)。行号序即判据。
t "wd_loop:relay 保活段排在 dispatch 分支之前" bash -c \
  'b="$(awk "/^wd_loop\(\)/,/^}/" "'"$LANE"'" | grep -n "relay_enabled" | head -1 | cut -d: -f1)";
   d="$(awk "/^wd_loop\(\)/,/^}/" "'"$LANE"'" | grep -n "dispatch_alive" | head -1 | cut -d: -f1)";
   [ -n "$b" ] && [ -n "$d" ] && [ "$b" -lt "$d" ]'
# ⭐ 绊线⑥(中继裁定):看门狗对 relay ⛔ 静默戳——中继是反应式角色,没有裁定缺口时静默就是健康态,
#   照搬 dispatch 的静默戳会让误报随「流水线健康」增长(三约束③ 噪声必须与目标行为同向)。
t "看门狗 ⛔ 对 relay 发静默戳(nudge 只投 dispatch)" bash -c \
  '! grep -q "laixin-nudge.*RELAY_WIN" "'"$LANE"'"'
# ⭐ 绊线⑦:resurrect --full 覆盖中继席位(boot 链 launchd 调的就是它 ⇒ 改这一处即覆盖开机恢复),
#   且必须以托管标记为闸门(标记不在 = 完全惰性,⛔ 当场变出第二个中继)。
t "resurrect --full 起 relay 且以托管标记为闸门" bash -c \
  'body="$(awk "/^cmd_resurrect\(\)/,/^}/" "'"$LANE"'")";
   grep -q "relay_enabled" <<< "$body" && grep -q "cmd_relay" <<< "$body"'
# ⭐ 绊线⑧:CDP 端口不撞段。**判据是值域不是占用**——lsof 只证明「此刻没进程监听」,而 CDP 端口
#   起 Chrome 才监听,任何安静时刻都返回全空闲 ⇒ 它区分不了安全与危险,是与结论无关的绿灯。
#   这里从源码常量重算值域:lane 兜底 = base..base+mod-1,verify = base..base+mod-1,
#   relay 端口必须落在两段之外。谁把 %60 改宽(如 %80 → 9233-9312)吞掉 9299,这条立刻变红。
t "RELAY_CDP_PORT 落在全部派生值域之外(值域判据 ⛔ 占用判据)" bash -c '
  L="'"$LANE"'"
  lb=$(grep -o "9233 + \$(printf" "$L" >/dev/null 2>&1; grep "cdp_port_lane()" "$L" | grep -oE "echo \\\$\(\( [0-9]+" | grep -oE "[0-9]+")
  lm=$(grep "cdp_port_lane()" "$L" | grep -oE "% [0-9]+" | grep -oE "[0-9]+")
  vb=$(grep "cdp_port_verify()" "$L" | grep -oE "\(\( [0-9]+" | grep -oE "[0-9]+")
  vm=$(grep "cdp_port_verify()" "$L" | grep -oE "% [0-9]+" | grep -oE "[0-9]+")
  rp=$(grep -oE "LAIXIN_RELAY_CDP_PORT:-[0-9]+" "$L" | grep -oE "[0-9]+")
  dp=$(grep -oE "LAIXIN_DISPATCH_CDP_PORT:-[0-9]+" "$L" | grep -oE "[0-9]+")
  for v in "$lb" "$lm" "$vb" "$vm" "$rp" "$dp"; do [ -n "$v" ] || exit 1; done
  [ "$rp" -ne "$dp" ] || exit 1
  [ "$rp" -gt $((lb+lm-1)) ] || exit 1
  [ "$rp" -lt "$vb" ] || exit 1'
rm -rf "$R32"

echo "== 6m. merge-guard ref级合并主树同步闸(#24;fixture 仓真造失配态) =="
# fixture **真复现**三十一任那个失配态:主树 checkout 在 main 上时用 update-ref 移 main 指针
# ⇒ HEAD 走了、index/工作树留在原地。⛔ 只做静态 grep:这条的价值全在「判得对不对」。
M24="$(mktemp -d)"; R24="$M24/repo"
git init -q -b main "$R24"; git -C "$R24" config user.email t@t; git -C "$R24" config user.name t
printf 'A\n' > "$R24/f.txt"; git -C "$R24" add f.txt; git -C "$R24" commit -qm A
A24="$(git -C "$R24" rev-parse HEAD)"
git -C "$R24" checkout -q -b feat; printf 'B\n' > "$R24/f.txt"; git -C "$R24" commit -qam B
B24="$(git -C "$R24" rev-parse HEAD)"
git -C "$R24" checkout -q main                      # 主树停在 main(纪律要求的「释放主树回 main」)
G24=(env LAIXIN_REPO="$R24")
# ⭐ 绊线①:主树不在被移动的分支上 ⇒ 不命中(此前从不暴露,正因为条件从不成立)
git -C "$R24" checkout -q feat
tout "主树不在被移动分支 ⇒ 不命中(#24)" "✅ 不命中" "${G24[@]}" "$LANE" merge-guard "$B24" --ref main
git -C "$R24" checkout -q main
# —— 造失配态:ref 级移动 main 指针,主树正 checkout 在 main 上 ——
git -C "$R24" update-ref refs/heads/main "$B24"
# ⭐ 绊线②:命中 + 三件齐 ⇒ 给出 reset --hard 建议
tout "命中并识别为主树被甩下(#24)" "主树正 checkout 在 main 上" "${G24[@]}" "$LANE" merge-guard "$B24" --ref main --old "$A24"
tout "三件齐给出 reset --hard 建议(#24)" "三件齐" "${G24[@]}" "$LANE" merge-guard "$B24" --ref main --old "$A24"
tout "① 反向差异方向核过(index 树==合并前旧树)" "① 反向差异方向 …… ✅" \
  "${G24[@]}" "$LANE" merge-guard "$B24" --ref main --old "$A24"
t "三件齐时退 0(#24)" "${G24[@]}" "$LANE" merge-guard "$B24" --ref main --old "$A24"
# ⭐ 绊线③(本条最要紧的一条):**工具 ⛔ 自己跑 reset --hard**——有真实工作被丢的风险,
#   它只做判断与提示。跑完之后失配态必须**原样还在**(工作树内容仍是旧的 A)。
t "⛔ 自动跑 reset --hard(跑完失配态原样还在,#24)" bash -c \
  '[ "$(cat "'"$R24"'/f.txt")" = "A" ]'
# ⭐ 绊线④:③ 无未跟踪 不成立 ⇒ 停手排查 + ⛔ 给 reset 建议(未跟踪文件会被 reset --hard 留着,
#   但它是「归属未认领」的信号,本闸要求先认领)
printf 'x\n' > "$R24/未跟踪.txt"
tfail "有未跟踪文件 ⇒ 停手排查(#24)" "停手排查" "${G24[@]}" "$LANE" merge-guard "$B24" --ref main --old "$A24"
t "停手时 ⛔ 给出 reset --hard 建议(#24)" bash -c \
  '! grep -q "reset --hard '"$B24"'" <<< "$(env LAIXIN_REPO="'"$R24"'" "'"$LANE"'" merge-guard "'"$B24"'" --ref main --old "'"$A24"'" 2>&1)"'
rm -f "$R24/未跟踪.txt"
# ⭐ 绊线⑤:② 工作区与 index 一致 不成立(有人正在改)⇒ 停手,reset --hard 会直接丢掉它
printf 'A-被人改了\n' > "$R24/f.txt"
tfail "有未暂存改动 ⇒ 停手排查(#24)" "停手排查" "${G24[@]}" "$LANE" merge-guard "$B24" --ref main --old "$A24"
git -C "$R24" checkout -q -- f.txt 2>/dev/null || printf 'A\n' > "$R24/f.txt"
# ⭐ 绊线⑥(三约束②:判不了要停手,⛔ 降级成放行):拿不到合并前旧值 ⇒ ① 判不了 ⇒ 停手,
#   ⛔ 因为「没核出问题」就当成核过了
rm -rf "$R24/.git/logs"
tfail "拿不到旧值时判不了并停手 ⛔ 放行(#24)" "判不了" "${G24[@]}" "$LANE" merge-guard "$B24" --ref main
# ⭐ 绊线⑦(冒烟当场撞出的误报):**本来就同步**的干净主树不许被判「停手排查」——
#   失配态的定义是 HEAD 新而 index 旧;index==HEAD 就是没被甩下。误报会随「合并后老实来跑一次」
#   这个想鼓励的行为增长(三约束③)。
git -C "$R24" reset -q --hard "$B24"
tout "已同步的主树报零动作 ⛔ 误报停手(#24)" "没有被甩下" "${G24[@]}" "$LANE" merge-guard "$B24" --ref main
t "已同步时退 0(#24)" "${G24[@]}" "$LANE" merge-guard "$B24" --ref main
rm -rf "$M24"

echo "== 6l. kb-commit 追加条目撞号自检(#9;fixture 仓,零真实副作用) =="
D9="$(mktemp -d)"; mkdir -p "$D9/v/wiki"
git init -q -b main "$D9/v"; git -C "$D9/v" config user.email t@t; git -C "$D9/v" config user.name t
Q9="$D9/v/wiki/运行复盘与优化推动-20260818.md"
printf '# 队列页\n\n## 三、优化推动清单\n\n23. 廿三条\n24. 廿四条(甲窗口先登的)\n' > "$Q9"
git -C "$D9/v" add wiki && git -C "$D9/v" commit -qm base
# 每个用例都回到**基线 commit**(⛔ reset 到 HEAD:上一个用例已把撞号提交进去,
#   回到 HEAD 等于把撞号当基线,后续用例就再也造不出「新增行」了——实撞一次)
BASE9="$(git -C "$D9/v" rev-parse HEAD)"
KB9=(env LAIXIN_VAULT="$D9/v" LAIXIN_BOARD="$D9/board.md")
# ⭐ 绊线①(实撞形态):乙窗口也按「读最大号+1」取 24 并追加 ⇒ 与甲窗口已登的 24 撞号。
#   今晨真事:24-26 三条各撞一次,靠人工重排 28-30 才消歧。
printf '# 队列页\n\n## 三、优化推动清单\n\n23. 廿三条\n24. 廿四条(甲窗口先登的)\n24. 廿四条(乙窗口并发登的)\n' > "$Q9"
tout "追加撞号被抓出并点名编号(#9)" "编号 #24 在 运行复盘与优化推动-20260818.md 里出现 2 次" \
  "${KB9[@]}" "$LANE" kb-commit "撞号测试" "wiki/运行复盘与优化推动-20260818.md"
git -C "$D9/v" reset -q --hard "$BASE9"
# ⭐ 绊线②:要给**建议号**(当前最大号+1),⛔ 只报「撞了」不给出路
printf '# 队列页\n\n## 三、优化推动清单\n\n23. 廿三条\n24. 廿四条(甲窗口先登的)\n24. 廿四条(乙窗口并发登的)\n' > "$Q9"
tout "撞号给出建议号=当前最大号+1(#9)" "建议改用 #25" \
  "${KB9[@]}" "$LANE" kb-commit "撞号测试2" "wiki/运行复盘与优化推动-20260818.md"
git -C "$D9/v" reset -q --hard "$BASE9"
# ⭐ 绊线③(方向性):⛔ 阻断提交——命中≠定罪,同 kb-commit 既有分桶钩的哲学
printf '# 队列页\n\n## 三、优化推动清单\n\n23. 廿三条\n24. 廿四条(甲窗口先登的)\n24. 廿四条(乙窗口并发登的)\n' > "$Q9"
t "撞号 ⛔ 阻断提交(命中≠定罪,#9)" "${KB9[@]}" "$LANE" kb-commit "撞号测试3" "wiki/运行复盘与优化推动-20260818.md"
t "撞号时提交确实落库了(告警不代替提交)" bash -c \
  'git -C "'"$D9"'/v" log --oneline -1 | grep -q "撞号测试3"'
git -C "$D9/v" reset -q --hard "$BASE9"
# ⭐ 绊线④(零误报,决定这个检查器能不能长期活着):**改既有条目**不许报——
#   改一条同时产生 +N. 与 -N.,文件里该号仍只有一行 ⇒ 不该报。误报若随「正常编辑」增长,
#   这个检查器很快就会被所有人忽略(三约束③ 噪声必须与目标行为同向)。
printf '# 队列页\n\n## 三、优化推动清单\n\n23. 廿三条\n24. 廿四条(甲窗口先登的,今天改了措辞)\n' > "$Q9"
# #50 后判据收窄到误报形态本身(⚠️ 编号 告警):通过态一行「零撞号」是新增的合法输出,
# 原「输出含'撞号'即败」的宽判据会把「查过了且没撞」误当误报——意图(零误报)不变
t "改既有条目零误报(#9 三约束③)" bash -c \
  '! grep -q "⚠️ 编号" <<< "$(env LAIXIN_VAULT="'"$D9"'/v" LAIXIN_BOARD="'"$D9"'/board.md" "'"$LANE"'" kb-commit "改措辞" "wiki/运行复盘与优化推动-20260818.md" 2>&1)"'
printf '# 队列页\n\n## 三、优化推动清单\n\n23. 廿三条\n24. 廿四条(甲窗口先登的,再改一次)\n' > "$Q9"
tout "改既有条目仍报「查过了」(#50:零告警≠零检查)" "零撞号" \
  "${KB9[@]}" "$LANE" kb-commit "改措辞2" "wiki/运行复盘与优化推动-20260818.md"
git -C "$D9/v" reset -q --hard "$BASE9"
# ⭐ 绊线⑤(射程,⛔ 扩到全库):非队列文件零噪音——撞号只发生在有自增编号的队列里
printf '# 普通笔记\n\n1. 甲\n1. 乙\n' > "$D9/v/wiki/普通笔记.md"
t "非队列文件不跑撞号自检(#9 射程 ⛔ 全库)" bash -c \
  '! grep -q "撞号" <<< "$(env LAIXIN_VAULT="'"$D9"'/v" LAIXIN_BOARD="'"$D9"'/board.md" "'"$LANE"'" kb-commit "普通笔记" "wiki/普通笔记.md" 2>&1)"'
rm -rf "$D9"

echo "== 6k. opt-status 按节独立统计(#33;fixture 复盘页,⛔ 依赖真页) =="
# fixture 刻意复用**真页的节名**:白/黑名单是本工具的判据本体,拿假节名测等于没测判据
# (谁把 WHITE 里的节名改错,这些用例立刻红)。内容则是最小可判样本,每条对一个已知陷阱。
O33="$(mktemp -d)"
cat > "$O33/page.md" <<'EOF'
# 测试复盘页

## 三、优化推动清单(测试)

1. ~~甲条~~ ✅ **已实施**
2. **乙条**——未销的
3. **丙条**——转述别的条目状态:#1 甲条 ✅ 已实施(叙述里的 ✅,标题没划线)

## 三之二、「进度变慢」诊断(测试)

**数据先行**:根因三条

1. **根因一**——不是优化项
2. **根因二**——不是优化项

**对策(并入推动清单,编号续三节)**:

11. ~~对策甲~~ ✅ **已实施**
12. **对策乙**——未销

## 四、经验原则(测试)

1. **原则一**——不是优化项
2. **原则二**——不是优化项

## 五、新拓扑首日复盘(测试)

**待提升(测试)**:

17. **待提升甲**——未销

### 五之二、成色校准与下一期跟踪数(测试)

1. **跟踪数一**——不是优化项

## 六、方案窗口第十任收班盘点(测试)

**未消化摩擦 → 候选(测试)**:

28. ~~廿八~~ ✅ **已实施**
30-bis(登记位次序号 31 之实). **卅一条**——未销
EOF
# ⭐ 绊线①(立项根因):同号不同事必须按节各算各的。全文按行首数字合并会把 §三 的 1-3 与
#   §三之二 的根因 1-2、§四 的 1-2、§五之二 的 1 混成一套账,同时高估未决数与低估完成数。
tout "§三 按节独立计数(#33)" "三、优化推动清单  共 3 / 销号 1 / 半销 1 / 未销 1" \
  env LAIXIN_OPT_PAGE="$O33/page.md" "$LANE" opt-status
# ⭐ 绊线②:节内起算锚——§三之二 前半的「根因 1-2」不是优化项,必须从 `**对策(` 之后起算。
#   没有锚就会算成 共 4(把根因混进优化队列)。
tout "§三之二 从对策锚起算 ⛔ 混入根因(#33)" "三之二、「进度变慢」诊断  共 2 / 销号 1 / 半销 0 / 未销 1" \
  env LAIXIN_OPT_PAGE="$O33/page.md" "$LANE" opt-status
# ⭐ 绊线③:### 也要切节——§五之二 是 ### 挂在 §五 之下,不切就会把它的「跟踪数 1」并进 §五
tout "### 五之二 独立切节 ⛔ 并进 §五(#33)" "五、新拓扑首日复盘  共 1 / 销号 0 / 半销 0 / 未销 1" \
  env LAIXIN_OPT_PAGE="$O33/page.md" "$LANE" opt-status
# ⭐ 绊线④:非优化队列节必须被排除,且是**显式黑名单**排除
t "§四 经验原则 / §五之二 跟踪数 不进统计(#33)" bash -c \
  'out="$(env LAIXIN_OPT_PAGE="'"$O33"'/page.md" "'"$LANE"'" opt-status 2>&1)";
   ! grep -q "四、经验原则" <<< "$out" && ! grep -q "五之二" <<< "$out"'
# ⭐ 绊线⑤:`30-bis(…)` 不是标准有序列表项——认不出就被悄悄丢掉,而丢掉的恰是「未销」那条
tout "30-bis 形态条目认得出且列名(#33)" "#30-bis  卅一条" \
  env LAIXIN_OPT_PAGE="$O33/page.md" "$LANE" opt-status
# ⭐ 绊线⑥(最容易写错的一条):销号判据取「标题划线」⛔ 取「行内含 ✅」——
#   ✅ 会出现在**转述别的条目状态**的叙述里(#33 自己那行就有三个),裸数 ✅ 会把未销读成已销号。
tout "叙述里的 ✅ 归 ⚖️半销 ⛔ 判成销号(#33)" "⚖️ #3  丙条" \
  env LAIXIN_OPT_PAGE="$O33/page.md" "$LANE" opt-status
# ⭐ 绊线⑦:报告非闸门——有未销不改退出码(与 #28 同规矩)
t "有未销仍退出 0——报告非闸门(#33)" env LAIXIN_OPT_PAGE="$O33/page.md" "$LANE" opt-status
# ⭐ 绊线⑧:未知节要大声报 + 退非零。**⛔ 默默跳过**:漏掉的节越多报告越像「优化都做完了」,
#   失效方向恰好指向它要防的风险(三约束②)。
printf '# t\n\n## 九、还没登记的新节(测试)\n\n1. **新条**——未销\n' > "$O33/unknown.md"
tfail "未知节自曝退非零并点名(#33 三约束②)" "未知节" \
  env LAIXIN_OPT_PAGE="$O33/unknown.md" "$LANE" opt-status
# ⭐ 绊线⑨:白名单节解析出 0 条 ⇒ 显 ? 不显 0(「一条都没有」与「没解析出来」外观相同,
#   把后者读成前者就是空报告冒充达标)
printf '# t\n\n## 七、中继窗口入流水线托管(测试)\n\n正文没有任何条目。\n' > "$O33/empty.md"
tfail "白名单节 0 条显 ? 不显 0 并退非零(#33)" "共 ? / 销号 ?" \
  env LAIXIN_OPT_PAGE="$O33/empty.md" "$LANE" opt-status
# ⭐ 绊线⑩:数据源失效自曝退非零 ⛔ 空报告冒充达标
tfail "复盘页读不到时自曝退非零(#33)" "数据源失效自曝" \
  env LAIXIN_OPT_PAGE="$O33/根本没有这个文件.md" "$LANE" opt-status

# ── #41:节登记「开新节即欠账」——白名单逐节枚举 ⇒ 欠账频率=换班频率,结构性必复发 ──
# 修法=行首锚自动登记(算不算 + 从哪算起,一次匹配)+ 未知节降级为「计入并标记」+ 警示上合计行。
cat > "$O33/anchor.md" <<'EOF'
# 测试复盘页

## 五、中继窗口 pingxia-79 收班盘点(测试)

**摩擦 Top3(测试)**:

1. **摩擦一**——经验条,不是优化项
2. **摩擦二**——经验条,不是优化项

## 十、中继窗口 pingxia-zz 收班盘点(测试;白名单里**没有**它)

**未消化摩擦 → 候选(测试)**:

42. ~~收班甲~~ ✅ **已实施**
43. **收班乙**——子件 ✅ 已定稿,标题没划线
44. **收班丙**——未销
EOF
# ⭐ 绊线⑪(#41 主修):没人登记过的新收班盘点节,靠**行首锚**自动进统计,且销号/半销/未销三档
#   判据与白名单节完全一致。⛔ 期望串里不留「⚠️ 未登记」位 ⇒ 锚规则被回退时该节改由推断计入、
#   行里插进标记,本行立刻变红(回退检测)。
tout "锚自动登记新收班盘点节(#41 A)" "十、中继窗口 pingxia-zz 收班盘点  共 3 / 销号 1 / 半销 1 / 未销 1" \
  env LAIXIN_OPT_PAGE="$O33/anchor.md" "$LANE" opt-status
# ⭐ 绊线⑫:自动登记就是**真登记**——零人工登记的价值全在这里:不再报未知节、退出码回 0。
t "锚登记后不再报未知节且退 0(#41 A)" bash -c \
  'out="$(env LAIXIN_OPT_PAGE="'"$O33"'/anchor.md" "'"$LANE"'" opt-status 2>&1)"; rc=$?;
   [ $rc -eq 0 ] && ! grep -q "未知节" <<< "$out" && ! grep -q "未登记" <<< "$out"'
# ⭐ 绊线⑬(⚠️ 本次改动**唯一会静默出错的方向**):§五 pingxia-79 的编号列表是「摩擦 Top3」经验条
#   不是优化项,已显式拉黑。**BLACK 必须一票否决**,压过锚推断与未知节推断——否则 3 条非优化项被
#   灌进统计且全是未销形态 ⇒ 未销虚增、销号率虚降,**失效方向恰好指向它要防的风险**(三约束②),
#   比不修还糟。fixture 里它带 2 条编号行 ⇒ 谁把 BLACK 降到锚/推断之后,它就会现身,本行变红。
t "BLACK 一票否决压过推断(#41,§五 摩擦 Top3 ⛔ 进统计)" bash -c \
  '! grep -q "五、中继窗口 pingxia-79" <<< "$(env LAIXIN_OPT_PAGE="'"$O33"'/anchor.md" "'"$LANE"'" opt-status 2>&1)"'
printf '# t\n\n## 五、中继窗口 pingxia-79 收班盘点(测试;假设它某天也长出了锚句)\n\n**未消化摩擦 → 候选(测试)**:\n\n1. **摩擦一**——经验条,不是优化项\n' > "$O33/blk.md"
t "BLACK 压过锚匹配本身(#41,黑名单节即使有锚也不进统计)" bash -c \
  '! grep -q "五、中继窗口 pingxia-79" <<< "$(env LAIXIN_OPT_PAGE="'"$O33"'/blk.md" "'"$LANE"'" opt-status 2>&1)"'
# ⭐ 绊线⑭:锚**必须行首匹配 ⛔ 行内包含**——真页实测「未消化摩擦 → 候选(」3 处命中而真锚只有 2 处,
#   第 3 处是 #41 条目正文在**引用锚句本身**。「节内含锚句」会被讨论判据的文本污染,而那种文本随
#   「把规则写进知识库」增长(三约束③ 噪声与被鼓励的行为同向)。同台账八律第 8 律,同一天第二次咬人。
#   fixture:非优化节、零条目、正文引用锚句字面 ⇒ 用包含匹配就会把它当白名单节并打出「共 ?」行。
printf '# t\n\n## 十二、判据讨论节(测试;非优化节)\n\n本节讨论判据本身:收班盘点节的起算锚是 **未消化摩擦 → 候选(准入=有失败样本)**: 这一句,但它不在行首。\n' > "$O33/quote.md"
t "锚只认行首 ⛔ 行内包含(#41 三约束③)" bash -c \
  'out="$(env LAIXIN_OPT_PAGE="'"$O33"'/quote.md" "'"$LANE"'" opt-status 2>&1)"; rc=$?;
   [ $rc -ne 0 ] && grep -q "零条目" <<< "$out" && ! grep -q "十二、判据讨论节  共" <<< "$out"'
# ⭐ 绊线⑮(#41 B):未知节里**解析得出条目**就按推断计入并在节名后标 ⚠️ 未登记——
#   把「漏一整队」降级成「多算并标出来」,失效方向仍朝安全侧。(unknown.md 含 1 条未销)
tfail "未知节含条目 ⇒ 计入并标 ⚠️ 未登记(#41 B)" "九、还没登记的新节  ⚠️ 未登记  共 1 / 销号 0 / 半销 0 / 未销 1" \
  env LAIXIN_OPT_PAGE="$O33/unknown.md" "$LANE" opt-status
# ⭐ 绊线⑯(掩蔽性,与 #20⑤ doctor 假绿同族):跑本工具的人正是来看「优化做完了吗」的——
#   数字在上面、警告在下面,读数的人不必读到末尾警告就能拿走偏乐观的结论。⇒ 警示必须长在**合计行本身**。
tfail "合计行本身带未登记警示 ⛔ 只在末尾说(#41)" "合计  共 1 / 销号 0 / 半销 0 / 未销 1   ⚠️ 含 1 个未登记节" \
  env LAIXIN_OPT_PAGE="$O33/unknown.md" "$LANE" opt-status
# ⭐ 绊线⑰:降级 ⛔ 消音——计入了也仍要在末尾点名 + 退非零(三约束② 要的是「大声报」,不是「不统计」)
t "计入后仍点名未知节且退非零(#41 B ⛔ 消音)" bash -c \
  'out="$(env LAIXIN_OPT_PAGE="'"$O33"'/unknown.md" "'"$LANE"'" opt-status 2>&1)"; rc=$?;
   [ $rc -ne 0 ] && grep -q "九、还没登记的新节   ⚠️ 未登记,节内解析出条目" <<< "$out"'
rm -rf "$O33"

echo "== 6n. #61 盘点节锚句双闸(a=opt-status 预扫指病灶 / b=kb-commit 写盘闸拦在落笔) =="
# 立项样本:#53「盘点节 ⛔ 三级标题」落卡后,**下一个人照样踩**(方案窗口第十二任)——锚句写进 `###`,
# 按既有「### 也切节」规则锚被切离主节 ⇒ 主节零条目整节不进统计,而页面格式合法、写的人零报错。
# ⇒ 纪律型防线失效实证,机器闸双装。⛔ (c) 卡上再加粗(已失败过的路径)。
D61="$(mktemp -d)"
# ── (a) opt-status 侧:症状升病灶 ──────────────────────────────────────────────
cat > "$D61/cut.md" <<'EOF'
# 测试复盘页

## 十三、方案窗口第十三任收班盘点(测试)

**账目一句**:本任散文若干,主节自身零条目。

### 十三之一、候选清单(测试;⛔ 三级标题——这正是要抓的写法)

**未消化摩擦 → 候选(测试)**:

70. **摩擦甲**——未销
EOF
# ⭐ 绊线①(正向命中):主节零条目 + 其 ### 子节含行首锚 ⇒ 报病灶并退非零。
#   ⛔ 只报既有症状(「未知节零条目」)——收班卡明写「指症状不指病灶」正是 #61 的失败面。
tfail "锚句被 ### 切走时报病灶并退非零(#61 a)" "锚句被三级标题切走" \
  env LAIXIN_OPT_PAGE="$D61/cut.md" "$LANE" opt-status
# ⭐ 绊线②:必须给出**改哪一行**(## 节行号 + ### 行号 + 锚句行号)——裁定原文要的是「并指行号」;
#   只报节名等于把人推回全页手找,而本闸存在的意义就是把症状变成可执行的病灶。
tfail "病灶指到 ## 节/### 子节/锚句三个行号(#61 a)" "第 3 行)自身零条目;锚句落在 ### 十三之一、候选清单(第 7 行)之下的第 9 行" \
  env LAIXIN_OPT_PAGE="$D61/cut.md" "$LANE" opt-status
# ⭐ 绊线③(零误伤,决定这闸能不能长期活着):合规盘点节——锚句在 `##` 自身正文里 ⇒ 绝不能报。
#   这是真页上 §六/§八/§九/§十/§十一 的通用写法,误伤它等于每次收班提交都变红。
cat > "$D61/ok.md" <<'EOF'
# 测试复盘页

## 十、中继窗口 pingxia-zz 收班盘点(测试;合规写法)

**未消化摩擦 → 候选(测试)**:

42. ~~收班甲~~ ✅ **已实施**
44. **收班丙**——未销
EOF
t "合规盘点节(锚在 ## 自身正文)零误伤(#61 a)" bash -c \
  '! grep -q "锚句被三级标题切走" <<< "$(env LAIXIN_OPT_PAGE="'"$D61"'/ok.md" "'"$LANE"'" opt-status 2>&1)"'
# ⭐ 绊线④(射程,裁定原文逐字:⛔ 动 §五之二 的故意 `###` 设计):§五之二 是 `## 五、新拓扑首日复盘`
#   下的 ###,**无锚句**且主节自身有条目 ⇒ 本闸两个条件都不中。判据若退化成「### 出现即报」,本行变红。
cat > "$D61/wu2.md" <<'EOF'
# 测试复盘页

## 五、新拓扑首日复盘(测试)

**待提升(测试)**:

17. **待提升甲**——未销

### 五之二、成色校准与下一期跟踪数(测试;故意的 ###,无锚句)

1. **跟踪数一**——不是优化项
EOF
t "§五之二 形态(有 ### 无锚句)零误伤(#61 a 射程)" bash -c \
  'out="$(env LAIXIN_OPT_PAGE="'"$D61"'/wu2.md" "'"$LANE"'" opt-status 2>&1)"; rc=$?;
   [ $rc -eq 0 ] && ! grep -q "锚句被三级标题切走" <<< "$out"'
# ── (a2) #61 闸的射程补丁:**形态 B**(锚句自己就是三级标题)────────────────────────
# ⛔ 复述本段前先看证据:`git show 2bfa98b -- <复盘页>` 逐字表明 #61 立项时的原始失败样本是
#   `### 未消化摩擦 → 候选(准入=…)` —— 锚句**本身**被写成三级标题,子节 body 里一个锚字都没有。
#   而上面(a)的判据是「### 子节 body 含行首锚」(=形态 A)⇒ **闸对着自己的立项样本不响**,
#   本组绊线钉的就是这个缺口(裁定把判据写窄了,不是实现写错了)。
# ⚠️ 形态 B 比 A 更需要闸:它不静默,它**指错方向** —— ### 一切节,`未消化摩擦 → 候选` 就成了
#   独立未知节,条目照样计入,报的却是「⚠️ 未登记 … 请显式登记进 WHITE 或 BLACK」;照做即把违规
#   写法固化成合法节(委派方 2026-08-19 给 §十二 补 WHITE 时差点这么做)。
cat > "$D61/cutb.md" <<'EOF'
# 测试复盘页

## 十四、方案窗口第十四任收班盘点(测试)

**账目一句**:本任散文若干,主节自身零条目。

### 未消化摩擦 → 候选(测试;⛔ 锚句本身被写成三级标题——这就是 #61 的原始样本)

70. **摩擦甲**——未销
EOF
# ⭐ 绊线④之一(正向命中,本补丁的立身之本):锚句自己是 ### ⇒ 与形态 A 同样报病灶并退非零。
tfail "形态 B(锚句自己就是 ###)照样报病灶并退非零(#61 a 射程)" "锚句被三级标题切走" \
  env LAIXIN_OPT_PAGE="$D61/cutb.md" "$LANE" opt-status
# ⭐ 绊线④之二:**行号必须指到真正违规的那一行** —— 形态 B 的子节 body 里没有锚,行号若沿用
#   形态 A 的「子节内锚句行」就会指向一段不存在的文本,而本闸的全部交付物就是「改哪一行」。
tfail "形态 B 行号指到 ### 标题行本身(⛔ 指进子节 body)" "违规行=第 7 行" \
  env LAIXIN_OPT_PAGE="$D61/cutb.md" "$LANE" opt-status
# ⭐ 绊线④之三(自相矛盾消解,数据行侧):节行标「⛔ #61 违规节」⛔ 标「⚠️ 未登记」——
#   「未登记」在本工具里的动作含义是**去 WHITE/BLACK 补一笔**,对它正确动作恰恰相反。
tfail "形态 B 节行标违规节 ⛔ 标未登记(自相矛盾消解)" "未消化摩擦 → 候选  ⛔ #61 违规节  共 1 / 销号 0 / 半销 0 / 未销 1" \
  env LAIXIN_OPT_PAGE="$D61/cutb.md" "$LANE" opt-status
# ⭐ 绊线④之四(自相矛盾消解,指引侧):未知节清单里**就地翻转指引** ⛔ 消音(三约束② 要「大声报」)。
#   ⛔ 一边报违规一边劝人登记进 WHITE —— 那正是委派方差点踩的那一步。
tfail "形态 B 在未知节清单里给相反指引(⛔ 劝登记进 WHITE)" "违规节(形态 B):它不是新开的节" \
  env LAIXIN_OPT_PAGE="$D61/cutb.md" "$LANE" opt-status
tfail "通用「请登记」指引下方带例外说明(⛔ 让读者自己在两条冲突提示间取舍)" "下面标「⛔ #61 违规节」的" \
  env LAIXIN_OPT_PAGE="$D61/cutb.md" "$LANE" opt-status
# ⭐ 绊线④之五(掩蔽性,#41 那一课):合计行是读数的人**一定会读到**的位置 ⇒ 违规节必须与「未登记节」
#   分列计数,混进去等于在最显眼的地方仍旧劝人登记。
t "合计行把违规节与未登记节分列 ⛔ 合并计数(#61 a2)" bash -c \
  'ln="$(env LAIXIN_OPT_PAGE="'"$D61"'/cutb.md" "'"$LANE"'" opt-status 2>&1 | grep "^合计")";
   grep -q "个 #61 违规节" <<< "$ln" && ! grep -q "个未登记节" <<< "$ln"'
# ⭐ 绊线④之六:标题里带粗体记号是同一件事的另一种写法 ⇒ 同判(粗体只是记号,不改变「锚被写成标题」)。
printf '# t\n\n## 十五、某收班盘点(测试)\n\n散文一句,主节零条目。\n\n### **未消化摩擦 → 候选(测试)**\n\n71. **甲**——未销\n' > "$D61/cutb2.md"
tfail "形态 B 变体:### 标题里带粗体记号同判(#61 a2)" "锚句被三级标题切走" \
  env LAIXIN_OPT_PAGE="$D61/cutb2.md" "$LANE" opt-status
# ⭐ 绊线④之七(零误伤 · 射程上界):**主节自身有条目**时子节另起一队是合法写法 ⇒ 形态 B 也不报,
#   与形态 A 的射程逐字一致(条件① 主节零条目仍是必要条件,⛔ 因为补 B 就把它悄悄拆掉)。
printf '# t\n\n## 十六、某节(测试;主节自身有条目)\n\n**未消化摩擦 → 候选(测试)**:\n\n80. **主节条目**——未销\n\n### 未消化摩擦 → 候选(另一队)\n\n81. **子节条目**——未销\n' > "$D61/cutb3.md"
t "主节自身有条目 ⇒ 形态 B 也不报(射程上界,与形态 A 同口径)" bash -c \
  '! grep -q "锚句被三级标题切走" <<< "$(env LAIXIN_OPT_PAGE="'"$D61"'/cutb3.md" "'"$LANE"'" opt-status 2>&1)"'
# ⭐ 绊线④之八(判据不许各写各的):形态 B 的锚文本**由 AUTO_ANCHOR 派生**,⛔ 另抄一份字面量
#   (两份会各改各的,#59「自述与判据不同宽」同族)。⇒ 缺尾括号的标题不在 AUTO_ANCHOR 射程内,
#   同样不该在形态 B 射程内;谁把它改成另写的宽判据,本行立刻变红。
printf '# t\n\n## 十七、某收班盘点(测试)\n\n散文一句,主节零条目。\n\n### 未消化摩擦 → 候选\n\n90. **甲**——未销\n' > "$D61/cutb4.md"
t "形态 B 射程=AUTO_ANCHOR 派生(缺尾括号不命中,⛔ 另写一份宽判据)" bash -c \
  '! grep -q "锚句被三级标题切走" <<< "$(env LAIXIN_OPT_PAGE="'"$D61"'/cutb4.md" "'"$LANE"'" opt-status 2>&1)"'
# ── (b) kb-commit 侧:写盘闸 ───────────────────────────────────────────────────
git init -q -b main "$D61/v"; git -C "$D61/v" config user.email t@t; git -C "$D61/v" config user.name t
mkdir -p "$D61/v/wiki"; P61="$D61/v/wiki/运行复盘与优化推动-测试.md"
KB61=(env LAIXIN_VAULT="$D61/v" LAIXIN_BOARD="$D61/board.md")
printf '# 页\n\n## 十三、某某收班盘点(测试)\n\n散文一句。\n\n### 十三之一、候选(测试)\n\n**未消化摩擦 → 候选(测试)**:\n\n70. **甲**——未销\n' > "$P61"
# ⭐ 绊线⑤(正向,写盘闸的全部意义):**拦在 add 之前** ⛔ 学 table-lint 事后告警——错误页一旦落库,
#   引用它的窗口就已经拿到偏乐观的数了。判据零歧义(收班盘点节内出现 `### ` 没有第二种读法)故 die。
tfail "收班盘点节内 ### ⇒ 拒绝提交(#61 b)" "拒绝提交:收班盘点节内出现三级标题" \
  "${KB61[@]}" "$LANE" kb-commit "违规测试" wiki/运行复盘与优化推动-测试.md
tfail "拒绝时给规则出处+违规行号(#61 b)" "7: ### 十三之一、候选" \
  "${KB61[@]}" "$LANE" kb-commit "违规测试2" wiki/运行复盘与优化推动-测试.md
t "被拒时确实零落库(写盘闸 ⛔ 事后告警)" bash -c \
  '[ -z "$(git -C "'"$D61"'/v" log --oneline 2>/dev/null)" ]'
# ⭐ 绊线⑥(零误伤①):同一个复盘页,收班盘点节内无 ### ⇒ 照常提交。
printf '# 页\n\n## 十三、某某收班盘点(测试)\n\n**未消化摩擦 → 候选(测试)**:\n\n70. **甲**——未销\n' > "$P61"
tout "收班盘点节无 ### ⇒ 照常提交(#61 b 零误伤)" "已提交 1 个文件" \
  "${KB61[@]}" "$LANE" kb-commit "合规提交" wiki/运行复盘与优化推动-测试.md
# ⭐ 绊线⑦(零误伤②,射程):**非收班盘点节**里的 ### 是合法设计(§五之二)⇒ 照常提交。
#   判据若退化成「复盘页里有 ### 就拒」,§五之二 那种页面从此再也提交不了,本行变红。
printf '# 页\n\n## 五、新拓扑首日复盘(测试)\n\n17. **甲**——未销\n\n### 五之二、成色校准(测试)\n\n1. **跟踪数一**\n' > "$P61"
tout "别节(非收班盘点)有 ### ⇒ 照常提交(#61 b 射程)" "已提交 1 个文件" \
  "${KB61[@]}" "$LANE" kb-commit "五之二合规" wiki/运行复盘与优化推动-测试.md
# ⭐ 绊线⑧(射程 ⛔ 全库):非复盘页即使长成违规形态也不管——噪声必须与被鼓励的行为同向(三约束③)。
printf '# 笔记\n\n## 某某收班盘点\n\n### 子标题\n' > "$D61/v/wiki/普通笔记.md"
tout "非复盘页不受本闸约束(#61 b 射程 ⛔ 全库)" "已提交 1 个文件" \
  "${KB61[@]}" "$LANE" kb-commit "普通笔记" wiki/普通笔记.md
rm -rf "$D61"

echo "== 6o. #65 半销判据「认形态 ⛔ 认符号」(叙述性 ✅ ⛔ 稀释半销桶) =="
# 立项样本:#41 附注明写「有再犯样本再单立」,再犯样本已到——真页实测半销 5 条里 #62(正文
# 「我的 ✅ 判据案」)与 #65(讨论该缺陷本身,标题里就必须写 ✅)两条是假半销,**占四成**。
# 改的不是失效方向(裸 ✅ 是**有意的保守档**),是**信噪比**:桶再稀释下去就没人看了。
D65="$(mktemp -d)"
cat > "$D65/half.md" <<'EOF'
# 测试复盘页

## 十、中继窗口 pingxia-zz 收班盘点(测试)

**未消化摩擦 → 候选(测试)**:

70. ~~销号甲~~ ✅ **已实施**
71. **半销甲**——子件 ✅ 已定稿,标题没划线
72. **半销乙**——子件 ✅ **已实施**,粗体记号夹在 ✅ 与「已」之间
73. **半销丙**——某项 ✅ 完成,标题没划线
74. **叙述甲**——正文提到「我的 ✅ 判据案」,叙述性符号 ⛔ 销号性标记
75. **自引甲**——本条在讨论判据本身,逐字引用形态样本 `✅ 已定稿` 与 `✅ **已实施`
76. **未销甲**——既没划线也没 ✅
77. **边缘甲**——✅ 取值表已定稿(✅ 之后先跟了别的词,已知射程外形态)
EOF
# ⭐ 绊线①(总账):三档计数一次钉死。销号判据(标题划线)本次**零改动**,它在这行里同时被回归。
tout "半销认形态后三档计数(#65)" "十、中继窗口 pingxia-zz 收班盘点  共 8 / 销号 1 / 半销 3 / 未销 4" \
  env LAIXIN_OPT_PAGE="$D65/half.md" "$LANE" opt-status
# ⭐ 绊线②(🔴 最重要的一条:⛔ 让真半销掉成未销):`✅ 已定稿` / `✅ **已实施`(粗体记号夹在中间)
#   / `✅ 完成` 三种真半销写法必须**全部**仍判半销。真页实测 #6/#7/#17 正是这三型
#   (`✅ **已定稿`、`✅ 已裁**`、`✅ 已实施`)⇒ 判据若收得太紧,完成度会凭空少一截。
t "三型真半销全部仍判半销(#65 ⛔ 真半销掉成未销)" bash -c \
  'out="$(env LAIXIN_OPT_PAGE="'"$D65"'/half.md" "'"$LANE"'" opt-status 2>&1)";
   grep -q "⚖️ #71" <<< "$out" && grep -q "⚖️ #72" <<< "$out" && grep -q "⚖️ #73" <<< "$out"'
# ⭐ 绊线③(修法本体):叙述性 ✅(后面跟的不是「已/完成」)判**未销** ⛔ 半销——这就是 #62 的形态。
t "叙述性 ✅ 判未销 ⛔ 半销(#65,#62 形态)" bash -c \
  'out="$(env LAIXIN_OPT_PAGE="'"$D65"'/half.md" "'"$LANE"'" opt-status 2>&1)";
   ! grep -q "⚖️ #74" <<< "$out" && grep -q "    #74  叙述甲" <<< "$out"'
# ⭐ 绊线④(🔴 元文本污染,#65 自己的形态):条目正文**逐字引用形态样本**时带反引号 ⇒ 行内代码格
#   必须先剥掉再判。不剥就仍然命中,本次修改对 #65 自己零效——「讨论判据的文本会随规则被写进
#   知识库而增长」在本文件上的**第三次**咬人(#33 销号判据一次、#41 锚一次)。⛔ 删 CODE_SPAN。
t "行内码格里的 ✅ 是被引用的样本 ⛔ 算半销(#65 自指,第 8 律第三次)" bash -c \
  'out="$(env LAIXIN_OPT_PAGE="'"$D65"'/half.md" "'"$LANE"'" opt-status 2>&1)";
   ! grep -q "⚖️ #75" <<< "$out" && grep -q "    #75  自引甲" <<< "$out"'
# ⭐ 绊线⑤(失效方向,**故意钉住已知缺口**):`✅ 取值表已定稿` 这类「✅ 之后先跟了别的词」的写法
#   会被漏判成**未销**。未销比半销保守(少一分完成度虚高)⇒ **方向朝安全**,本行把这个缺口钉成
#   有意的设计而非疏忽:谁哪天要够到它,得先来改这一行,⛔ 顺手把判据放宽成「行内含已/完成」
#   (那等于退回包含匹配,把刚清掉的叙述性污染重新灌回来)。
t "射程外形态漏判成未销=可接受的失效方向(#65,有意钉住)" bash -c \
  'out="$(env LAIXIN_OPT_PAGE="'"$D65"'/half.md" "'"$LANE"'" opt-status 2>&1)";
   ! grep -q "⚖️ #77" <<< "$out" && grep -q "    #77  边缘甲" <<< "$out"'
# ⭐ 绊线⑥:工具**自述必须与判据同宽**(#59:判据比规则窄,而两者在通过时长得一模一样)——
#   图例还写「有 ✅ 就算半销」而判据已收紧 ⇒ 读的人会按一个并不存在的判据去理解这份数。
tout "图例随判据同步收紧(#65,自述 ⛔ 比判据宽)" "半销=✅ 紧跟「已/完成」但标题没划线" \
  env LAIXIN_OPT_PAGE="$D65/half.md" "$LANE" opt-status
# ⭐ 绊线⑦:报告非闸门——半销判据变了也不改退出码(与 #28/#33 同规矩)
t "半销判据收紧后仍退 0——报告非闸门(#65)" env LAIXIN_OPT_PAGE="$D65/half.md" "$LANE" opt-status
rm -rf "$D65"

echo "== 6p. #67 派工引擎化(默认 claude)+ 出站中转 relay-msg(单向,零扩权) =="
# 背景:Claude 周额度实测 weekly_all 91%,dispatch 是单窗口消耗最大的一个;#60① 已换验收窗,本批换派工窗。
# codex 没有 SendMessage ⇒ 出站走中继代发;**回程 ⛔ 反向注入**——对方落盘、events 投**路径指针**,
# dispatch 自读全文(events 的载荷从来不是结构化内容,这正是「讨论也能走落盘」的机关)。
# ⭐ 绊线①(2026-08-22 创始人定案,当日三改一锤:早切 codex → 16:34 换回 claude → 17:3x「claude 默认 / kimi 可选顶班 / codex 废除」):
#   - 默认 claude ⛔ 改默认(#66:dispatch 起窗被 resurrect/boot 链无人值守自动调用,默认值变更在无人在场时生效);
#   - kimi 是**可选顶班**(claude 额度耗尽时),必须真能起——此前 C 分支只是占位:dispatch_alive 不认 kimi 进程、
#     confirm_briefed 无 kimi 词表、pane_claude_age 不认 kimi(看门狗会把活着的 kimi 派工席判死、重起、再判死);
#   - codex 已废除:请求 codex ⇒ 按 claude 起 + 点名 + doctor 告警(⛔ die——过期开关不该有权停掉自愈;⛔ 静默——同形);
#   - 🔴 起窗时**实时解析** ⛔ 进程启动时读一次(当日实撞:看门狗循环内存攥着切换前的值,切回后仍会按旧引擎重起)。
#   ⚠️ ⛔ 用 `LAIXIN_DISPATCH_ENGINE=xxx dispatch` 当反例测「拒绝」:无效值不再被拒,会真起一个 claude 派工窗口到
#     fixture 会话(与当年 kimi 成合法引擎后那次同形)——一律用只读的 doctor 测三态。
t "#67 派工引擎默认 claude(dispatch_engine_resolve 兜底 echo claude,⛔ 兜底 codex/kimi)" bash -c \
  'b="$(sed -n "/^dispatch_engine_resolve()/,/^}/p" "$1")"; grep -q "LAIXIN_DISPATCH_ENGINE:-.*echo claude" <<< "$b" && ! grep -qE "echo (codex|kimi)\)" <<< "$b"' _ "$LANE"
t "#67 合法集只有 claude|kimi(codex 已废除,⛔ 再出现在 resolve 里)" bash -c \
  'b="$(sed -n "/^dispatch_engine_resolve()/,/^}/p" "$1")"; grep -q "claude|kimi) eff=" <<< "$b" && ! grep -q "codex" <<< "$b"' _ "$LANE"
t "#67 cmd_dispatch 起窗时实时解析引擎(⛔ 只用进程启动时读的值;看门狗重生路径靠这一行)" bash -c \
  'b="$(sed -n "/^cmd_dispatch()/,/^}/p" "$1")"; c="$(grep -n "dispatch_engine_resolve" <<< "$b" | head -1 | cut -d: -f1)"; e="$(grep -n "^  ensure_session" <<< "$b" | head -1 | cut -d: -f1)"; [ -n "$c" ] && [ -n "$e" ] && [ "$c" -lt "$e" ]' _ "$LANE"
tout "#67 doctor 三态①claude(默认):报派工引擎行" "派工引擎:claude" env LAIXIN_DISPATCH_ENGINE=claude "$LANE" doctor
tout "#67 doctor 三态②kimi 合法可选:报 派工引擎:kimi" "派工引擎:kimi" env LAIXIN_DISPATCH_ENGINE=kimi "$LANE" doctor
tout "#67 doctor 三态③codex 已废除:请求被点名无效" "派工引擎请求「codex」无效" env LAIXIN_DISPATCH_ENGINE=codex "$LANE" doctor
tout "#67 codex 请求下 doctor 仍报 claude 钉模型行(按 claude 处理,⛔ 只告警不落实)" "派工窗口钉:" env LAIXIN_DISPATCH_ENGINE=codex "$LANE" doctor
tout "#67 拼错值同样点名(⛔ 静默回落)" "派工引擎请求「bogus」无效" env LAIXIN_DISPATCH_ENGINE=bogus "$LANE" doctor
tout "#67 doctor 在 kimi 引擎下点名工具层 push 锁失效(kimi 无 disallowedTools 等价物)" "push 锁不生效" env LAIXIN_DISPATCH_ENGINE=kimi "$LANE" doctor
t "#67 起窗无效值点名在 ensure_session 之前且 ⛔ die(无人值守重生不许被过期开关拦停)" bash -c \
  'b="$(sed -n "/^cmd_dispatch()/,/^}/p" "$1")";
   c="$(grep -n "派工引擎请求「" <<< "$b" | head -1 | cut -d: -f1)";
   e="$(grep -n "^  ensure_session" <<< "$b" | head -1 | cut -d: -f1)";
   [ -n "$c" ] && [ -n "$e" ] && [ "$c" -lt "$e" ] && seg="$(sed -n "${c},$((c+2))p" <<< "$b")" && ! grep -q "die " <<< "$seg"' _ "$LANE"
t "#67 引擎校验在 ensure_session/kill-window 之前" bash -c \
  'b="$(sed -n "/^cmd_dispatch()/,/^}/p" "'"$LANE"'")";
   c="$(grep -n "未知派工引擎" <<< "$b" | head -1 | cut -d: -f1)";
   e="$(grep -n "^  ensure_session" <<< "$b" | head -1 | cut -d: -f1)";
   [ -n "$c" ] && [ -n "$e" ] && [ "$c" -lt "$e" ]'
# ⭐ 绊线③:claude 路径**零行为变化**——起窗命令行四件(--model/--permission-mode/--settings/
#   --disallowedTools)与 #20c 定向重试都必须原样在;这是"回切随时可用"的全部保障。
tout "#67 claude 起窗命令行原样保留(--disallowedTools)" "disallowedTools \$deny" \
  sed -n "/^cmd_dispatch()/,/^}/p" "$LANE"
tout "#67 claude 路径保留 #20c 自更新定向重试(codex 无此因 ⛔ 照抄)" "Claude Code CLI not found" \
  sed -n "/^cmd_dispatch()/,/^}/p" "$LANE"
# ⭐ 绊线④:kimi 顶班形态必须**真能起**(此前 C 分支从未真跑过;2026-08-22 隔离 tmux 会话实起一次:4s 就绪、pane=kimi、
#   就绪签名在 kimi 0.38.0 下仍成立、K3 窗口 1M)。以下钉的是起窗链路各环节对 kimi 的认知,缺一环看门狗就会误判。
tout "#67 kimi 起窗走 kimi_launch_cmd(与 lane C 轨同一份,⛔ 另拼)" "kimi_launch_cmd \"dispatch\"" \
  sed -n "/^cmd_dispatch()/,/^}/p" "$LANE"
tout "#67 kimi 就绪判据复用 vwait_ready_kimi(⛔ 拿 claude/codex 画面判据量 kimi)" "vwait_ready_kimi \"\$DISPATCH_WIN\"" \
  sed -n "/^cmd_dispatch()/,/^}/p" "$LANE"
t "#67 kimi 起窗前预写信任记录(#68,在起窗命令之前)" bash -c \
  'b="$(sed -n "/^cmd_dispatch()/,/^}/p" "$1")"; p="$(grep -n "^  kimi_trust_prewrite " <<< "$b" | head -1 | cut -d: -f1)"; w="$(grep -n "\$(kimi_launch_cmd \"dispatch\"" <<< "$b" | head -1 | cut -d: -f1)"; [ -n "$p" ] && [ -n "$w" ] && [ "$p" -lt "$w" ]' _ "$LANE"
t "#67 cmd_dispatch 已无 codex 分支,DISPATCH_BRIEF_CODEX 已删(codex 派工废除)" bash -c \
  'b="$(sed -n "/^cmd_dispatch()/,/^}/p" "$1")"; ! grep -q "codex_launch_cmd" <<< "$b" && ! grep -q "DISPATCH_BRIEF_CODEX" <<< "$b" && ! grep -q "^DISPATCH_BRIEF_CODEX=" "$1"' _ "$LANE"
t "#67 看门狗判活认 kimi 进程(dispatch_alive;此前只认 node|claude ⇒ 活着的 kimi 派工席会被判死重起)" bash -c \
  'b="$(sed -n "/^dispatch_alive()/,/^}/p" "$1")"; grep -qE "node\|claude\|claude\.exe\|kimi\)" <<< "$b"' _ "$LANE"
t "#67 接管回读复核有 kimi 活动词表(confirm_briefed;⛔ 拿 claude 词表量 kimi 而盲补 Enter)" bash -c \
  'b="$(sed -n "/^confirm_briefed()/,/^}/p" "$1")"; grep -q "\"kimi\" \] && pat=" <<< "$b"' _ "$LANE"
t "#67 冷启动宽限探针认 kimi(pane_claude_age;否则 kimi 冷启动静止被当 Enter 丢失盲补)" bash -c \
  'b="$(sed -n "/^pane_claude_age()/,/^}/p" "$1")"; grep -q "claude\.exe|kimi)" <<< "$b"' _ "$LANE"
t "#67 ctx-all 对非 codex 席位不认领 codex rollout(kimi/claude 派工席 ⛔ 被安上别人的数)" bash -c \
  'b="$(sed -n "/^cmd_ctx_all()/,/^}/p" "$1")"; grep -q "非codex引擎" <<< "$b"' _ "$LANE"
# ⭐ 绊线⑤:工具层锁失效必须**明写进派单指令**——DISPATCH_DENY 实测只有 git push 一条,
#   kimi 无 disallowedTools 等价物 ⇒ 锁静默失效,而「锁在」与「锁没了」在体检输出里原本同形。
tout "#67 kimi 派单指令明写 git push 禁令(工具层锁失效的补位)" "⛔ git push" \
  sed -n "/^DISPATCH_BRIEF_KIMI=/,/窗口记忆不算数/p" "$LANE"
tout "#67 kimi 派单指令写明出站走 relay-msg(本引擎无 SendMessage)" "relay-msg --to" \
  sed -n "/^DISPATCH_BRIEF_KIMI=/,/窗口记忆不算数/p" "$LANE"
# 措辞随 #67④(2026-08-22 自述改实测)变过一次:原为「工具层锁**不生效**」,现为
# 「工具层 push 锁不生效」+ git 层兜底实测结论。**断言意图不变**——doctor 必须当面点名
# 工具层锁失效这件事,⛔ 只写在提交信息里;字面串跟着措辞走,⛔ 因为串对不上就删掉这条。
# (2026-08-22)原「doctor 在 codex 引擎下点名 push 锁失效」随 codex 派工废除改为 kimi 版(见绊线①末条)。
tout "#67 doctor 在 claude 引擎下旧文案逐字保留" "派工窗口钉:" \
  env LAIXIN_DISPATCH_ENGINE=claude "$LANE" doctor
# * 绊线⑦(2026-08-22 实撞,创始人窗口修):`else` 写在 die 那一行的**行尾** ⇒ bash 把它当成 die 的
#   参数字符串吃掉,if/elif/else 塌成两支:引擎=codex 先起 codex **再接着起一遍 kimi**(同一函数内
#   两次 new-window ⇒ 两个同名 dispatch 窗口 ⇒ tmux 按名寻址歧义,报 `can't find window: dispatch`
#   —— 错误信息指向「窗口不存在」而真相是「窗口有两个」,**方向相反**,检查器三约束②的实例);
#   引擎=kimi 则 if/elif 都不成立而 else 已不存在 ⇒ **一个窗口都不建**。claude 路径不受影响 ⇒
#   581 项测试全绿、doctor 全绿、`bash -n` 也过(语法合法)⇒ 潜伏两天:08-20 04:38「切 codex 失败」
#   当时归因为 codex 自更新,实为本 bug。两条递进:①本处结构;②全文件同族 lint(bash -n 查不出)。
#   (2026-08-22 17:3x codex 派工分支废除后,结构变为 if claude … else kimi … fi;本条改钉新结构的两个关键字独立成行)
tout "#67-fix 派工起窗 if/else/fi 结构:claude 分支 done 后独立一行 else、kimi 分支 die 后独立一行 fi(关键字挂在 die 行尾=被吞成参数)" "OK" \
  bash -c 'b="$(sed -n "/^cmd_dispatch()/,/^}/p" "$1")"; n=$(grep -n "启动超时。查看:laixin-lane peek-d 40" <<< "$b" | head -1 | cut -d: -f1); k=$(grep -n "vwait_ready_kimi .* || die" <<< "$b" | head -1 | cut -d: -f1); [ -n "$n" ] && [ -n "$k" ] && [ "$(sed -n "$((n+1))p" <<< "$b" | tr -d "[:space:]")" = "done" ] && [ "$(sed -n "$((n+2))p" <<< "$b" | tr -d "[:space:]")" = "else" ] && [ "$(sed -n "$((k+1))p" <<< "$b" | tr -d "[:space:]")" = "fi" ] && echo OK' _ "$LANE"
tout "#67-fix 全文件禁「引号行尾挂 else/fi/then/do」(同族一律被当参数吞掉)" "ZERO" \
  bash -c 'grep -nE "\"[[:space:]]+(else|fi|then|do|done)[[:space:]]*\$" "'"$LANE"'" || echo ZERO'
# ⭐ 通道额度到线提醒(2026-08-22 立,创始人「先问机器化」):CC 双账号按额度轮换,而「该切了」
#   此前只存在于人去开仪表盘看一眼 —— 没有机器面,漏看的代价是账号跑干后流水线停摆。
#   三条绊线全压在**失效方向**上(三约束②:失效必须降级 ⛔ 反向)——一个读不到额度却显示
#   「未到轮换线」的检查器,比没有这个检查器更糟:它会让人以为已经核过了。
# 🔴 **两种失效必须可分辨**(2026-08-22 实撞):首版超时 3s,而该 API 同步拉两个账号的官方额度、
#   走代理,实测 7.16s ⇒ 稳定超时、输出恒为「读不到」——与「仪表盘根本没起」同一句话,
#   于是「服务好好的只是慢」被读成「服务没了」。⇒ 探活与拉数分开判,措辞必须不同。
tfail "通道额度:仪表盘未监听时说「未在监听」(⛔ 与「拉取超时」同一句话)" "未在监听" \
  bash -c 'env LAIXIN_USAGE_PROBE=http://127.0.0.1:1/ LAIXIN_USAGE_API=http://127.0.0.1:1/nope "'"$LANE"'" doctor | grep "通道额度"; exit 1'
# ⚠️ 探活靶子 ⛔ 用外网(首版用 example.com,当轮网络一慢就返 000 ⇒ 断言红而代码是对的)——
#   **会因环境忽红忽绿的测试比没有测试更糟**,这条本仓写过。改起一个本地极简 HTTP 服务当靶子。
UPORT=18763; python3 -m http.server "$UPORT" --bind 127.0.0.1 >/dev/null 2>&1 & UPID=$!
for _i in 1 2 3 4 5 6 7 8 9 10; do curl -s -m 1 -o /dev/null "http://127.0.0.1:$UPORT/" && break; sleep 0.3; done
tfail "通道额度:在跑但拉取超时说「在跑但额度拉取超时」(⛔ 读成服务没了)" "在跑但额度拉取超时" \
  bash -c 'env LAIXIN_USAGE_PROBE=http://127.0.0.1:'"$UPORT"'/ LAIXIN_USAGE_API=http://10.255.255.1:9/ LAIXIN_USAGE_TIMEOUT=1 "'"$LANE"'" doctor | grep "通道额度"; exit 1'
# ⚠️ 靶子必须**真的超时**:首版用 example.com/slow,它 1s 内就返 404 ⇒ 落进「不是 JSON」分支,
#   断言红。改用**不可路由地址**(10.255.255.1:9)——它只会挂到超时,不会提前给出任何响应。
tfail "通道额度:响应不是 JSON 时降级 ⛔ 当成额度充裕" "不是 JSON" \
  bash -c 'env LAIXIN_USAGE_PROBE=http://127.0.0.1:'"$UPORT"'/ LAIXIN_USAGE_API=http://127.0.0.1:'"$UPORT"'/ "'"$LANE"'" doctor | grep "通道额度"; exit 1'
kill "$UPID" 2>/dev/null || true
# 5h 窗口(session)与周额度**处置完全不同**:前者几小时自愈=等重置或临时换,后者=按剧本轮换 ⇒ ⛔ 混成一条
tout "通道额度:5h 窗口纳入判据(⛔ 只看周额度——5h 打满同样当场停摆且更容易撞)" "5h窗口" \
  bash -c 'sed -n "/^channel_quota_verdict()/,/^}/p" "'"$LANE"'"'
tout "通道额度:5h 到线的措辞点明「几小时后自愈」(⛔ 与周额度同一句处置)" "自愈" \
  bash -c 'sed -n "/^channel_quota_verdict()/,/^}/p" "'"$LANE"'"'
tout "通道额度:通道→账号取 .claude.json 的 oauthAccount(⛔ Keychain——要授权,无人值守会挂)" "oauthAccount" \
  sed -n "/^channel_quota_verdict()/,/^}/p" "$LANE"
# ⭐ #67④ 自述同步(2026-08-22):doctor 原写「待 git pre-push hook 把锁挪到 git 层」,而钩子
#   2026-08-19 就已在两仓落地 ⇒ 把**已经在位的防线说成还没有**(#27 自述同步族)。改成每次实测,
#   并借此补上一个此前无人看的真风险:**git hooks 不随 clone 传播**,换机/重克隆后会静默消失,
#   而「锁在」与「锁没了」在任何输出里原本长得一模一样。
tout "#67④ push 锁自述改实测:⛔ 再写「待挪到 git 层」(钩子早已在位=把已有防线说成没有)" "ZERO" \
  bash -c 'grep -n "待 git pre-push hook" "'"$LANE"'" || echo ZERO'
tout "#67④ push 锁判据=文件可执行且含 BU_NAME(⛔ 只看文件在:空壳钩子拦不住任何东西)" "BU_NAME" \
  bash -c 'sed -n "/工具层 push 锁不生效/,+2p" "'"$LANE"'"; sed -n "/_hookmiss=\"\" _hr/,+5p" "'"$LANE"'"'
# ⭐ 绊线⑥:派单指令必须告诉非 claude 派工席「回程不会弹进你的输入框」——否则它会干等一个永远不来的消息
#   (原 codex 版两条随 codex 派工废除改钉 kimi 版,断言意图不变)
tout "#67 kimi 派单指令写明回程走落盘+路径指针(⛔ 等它直接注入)" "那条路不存在" \
  sed -n "/^DISPATCH_BRIEF_KIMI=/,/窗口记忆不算数/p" "$LANE"
tout "#67 kimi 派单指令写明 laixin-lane ctx 对本引擎无效(看自身 TUI 底栏 context%,⛔ 读到别人的数)" "对本引擎无效" \
  sed -n "/^DISPATCH_BRIEF_KIMI=/,/窗口记忆不算数/p" "$LANE"

# ── relay-msg:注入面自述可被逐条核(举证责任在实现方 ⛔ 在验收方)────────────────────
# ⭐ 绊线⑦🔴(创始人明裁的边界,中继会亲自复核这一条):本命令只能向**一个**窗格注入=RELAY_WIN,
#   且窗口名**硬编码 ⛔ 参数化** —— 没有"目标窗口"这个入参,就不存在被指去投 lane-*/dispatch 的形态。
t "#67② relay-msg 的 tmux 目标只有 RELAY_WIN(⛔ 参数化 ⛔ 出现 dispatch/lane-)" bash -c \
  'b="$(sed -n "/^cmd_relay_msg()/,/^}/p" "'"$LANE"'")";
   n="$(grep -c "SESSION:" <<< "$b")"; r="$(grep -c "SESSION:\$RELAY_WIN" <<< "$b")";
   [ "$n" -gt 0 ] && [ "$n" = "$r" ] && ! grep -q "SESSION:\$DISPATCH_WIN" <<< "$b" &&
   ! grep -q "SESSION:lane-" <<< "$b"'
# ⭐ 绊线⑧🔴:中继的 deny 列表**一字未改**——本批不靠放宽它换功能(换个名字不改变它是同一个动作)
# ⚠️ 提取时必须滤掉注释行:本列表的注释里要说明「relay-msg 有意 ⛔ 入列」,而末句断言正是 grep relay-msg
#    ⇒ 判据串同时是机器判据与人会书写讨论的对象 ⇒ 包含匹配必被讨论它的文本污染(第 8 律扩展;
#    2026-08-19 b7 补 RELAY_DENY 时当轮实撞,而它当轮刚把该律的射程从「台账行」扩到「一切被归档的文本」)。
t "#67 RELAY_DENY 一字未放宽(原八条 + 创始人明令补的破坏性五族,且 relay-msg 未被塞进去当例外)" bash -c \
  'b="$(sed -n "/^RELAY_DENY=(/,/^)/p" "'"$LANE"'" | grep -v "^[[:space:]]*#")";
   for k in "git push" "git merge" "git reset --hard" "laixin-lane send" "laixin-lane fresh" \
            "laixin-lane up" "laixin-lane down" "laixin-lane claim" \
            "laixin-lane dispatch" "laixin-lane halt" "laixin-lane resurrect" "laixin-lane release" \
            "laixin-lane watchdog" "laixin-lane events" "laixin-lane verify" "laixin-lane vdown" \
            "laixin-lane relay-down" "laixin-lane install-" "laixin-lane evid-gc"; do
     grep -q "$k" <<< "$b" || exit 1; done;
   ! grep -q "relay-msg" <<< "$b"'
# ⭐ 绊线⑨:调用方机器校验(⛔ 靠约定)——本命令是一条向窗格注入文本的路径,谁能用必须可被逐条核
tfail "#67② relay-msg 只允许派工窗口调用(⛔ 靠约定)" "只允许派工窗口" \
  env LAIXIN_SESSION=bogus-r67 "$LANE" relay-msg --to 方案窗口 "试"
# ⭐ 绊线⑩:必须显式 --to —— 收方要据它判「这是 dispatch 的请求,不是中继的裁定」;
#   ⛔ 让收方按内容猜:猜对和猜错在收方眼里长得一模一样。
tfail "#67② relay-msg 必须显式 --to(⛔ 让收方按内容猜)" "必须显式 --to" \
  env LAIXIN_SESSION=bogus-r67 "$LANE" relay-msg "没有目标"
t "#67② 被拒时零 tmux 副作用" bash -c '! tmux has-session -t bogus-r67 2>/dev/null'
# ⭐ 绊线⑪:relay 不在/已死 ⇒ **响亮失败 ⛔ 静默丢消息**
tout "#67② relay 不在时响亮失败(⛔ 静默丢消息)" "⛔ 静默丢消息" \
  sed -n "/^cmd_relay_msg()/,/^}/p" "$LANE"
# ⭐ 绊线⑫:**先落盘再注入**——倒过来写,"注入成功但进程随即被杀"会让消息既没转出也没留痕
t "#67② 全文落盘在注入之前(⛔ 注入成功但随即被杀 ⇒ 既没转出也没留痕)" bash -c \
  'b="$(sed -n "/^cmd_relay_msg()/,/^}/p" "'"$LANE"'")";
   w="$(grep -n "RELAY_OUTBOX_D/\$id\"$" <<< "$b" | head -1 | cut -d: -f1)";
   i="$(grep -n "load-buffer -b laixin-relaymsg" <<< "$b" | head -1 | cut -d: -f1)";
   [ -n "$w" ] && [ -n "$i" ] && [ "$w" -lt "$i" ]'
# ⭐ 绊线⑬:信封三件(两个机器可辨字段 + 两类前缀 + 收方拒收半边)
tout "#67② 信封带「原发方」字段" "原发方:" sed -n "/^cmd_relay_msg()/,/^}/p" "$LANE"
tout "#67② 信封带「回执给谁」字段(⛔ 让收方猜)" "回执给谁:" sed -n "/^cmd_relay_msg()/,/^}/p" "$LANE"
t "#67② 两类前缀分开(转办件 vs 请中继自己裁,自然语言里长得很像)" bash -c \
  'b="$(sed -n "/^cmd_relay_msg()/,/^}/p" "'"$LANE"'")";
   grep -q "【转:给" <<< "$b" && grep -q "【给relay自己】" <<< "$b"'
tout "#67② 信封要求逐字透传(⛔ 要求中继加工/总结/判断)" "逐字透传" \
  sed -n "/^cmd_relay_msg()/,/^}/p" "$LANE"
tout "#67② 收方半边:信封不全即拒收(⛔ 据内容像谁就当谁)" "拒收并回一句" \
  sed -n "/^cmd_relay_msg()/,/^}/p" "$LANE"

# ── 回程与销账:复用既有扫描/投递/spool ⛔ 平行实现 ──────────────────────────────
TMPR="$(mktemp -d)"; mkdir -p "$TMPR/kb/4-开发层/记录"
{ sed -n "/^last_contract_line/,/^}/p" "$LANE"; sed -n "/^ev_scan_deliveries/,/^}/p" "$LANE"; sed -n "/^relay_outbox_overdue/,/^}/p" "$LANE"; } > "$TMPR/fn.sh"
KB="$TMPR/kb"; source "$TMPR/fn.sh"
printf '正文\n【交付完成】main abc1234\n' > "$TMPR/kb/4-开发层/记录/甲-交付报告.md"
printf '正文\n【验收回执】通过 v-x abc1234 def5678\n' > "$TMPR/kb/4-开发层/记录/乙-验收回执.md"
printf '正文\n【中转回执】rm-1-2 已转出 方案窗口\n' > "$TMPR/kb/4-开发层/记录/丙-中转回执.md"
printf '自由文本很长很长……\n【中转回复】rm-1-2 来自 方案窗口\n' > "$TMPR/kb/4-开发层/记录/丁-中转回复.md"
# ⭐ 绊线⑭:两个新末行标记走**同一个** ev_scan_deliveries(⛔ 另起一套扫描)
t "#67③ 扫描同时认交付/验收回执/中转回执/中转回复四种末行(单一实现)" bash -c \
  'out="$(KB="'"$TMPR"'/kb" bash -c "source \"'"$TMPR"'/fn.sh\"; ev_scan_deliveries")";
   [ "$(grep -c . <<< "$out")" = 4 ]'
# ⭐ 绊线⑮:ev_loop 对【中转回复】的下一步是**读全文**——投的是路径指针不是内容,
#   ⛔ 对它 verify-from(那是交付报告的下一步,两者末行不同、动作完全不同)
tout "#67③ ev_loop 对中转回复投「读全文」⛔ verify-from" "events 投的是指针不是内容" \
  sed -n "/^ev_loop/,/^}/p" "$LANE"
tout "#67③ ev_loop 收到中转回执即销 outbox 那条账(⛔ 只报不销 ⇒ 永久告警)" "#67 转办销账" \
  sed -n "/^ev_loop/,/^}/p" "$LANE"
# ⭐ 绊线⑯:超时纯判定——「投出去多久还没等到回执」⛔ 判 relay 死没死(两件事正确动作不同)
t "#67② outbox 超时判定:超阈值命中、未超阈值不命中" bash -c \
  'source "'"$TMPR"'/fn.sh"; now=1000000; export RELAY_ACK_SECS=600;
   in="$(printf "%s|rm-old|方案窗口|摘要一\n%s|rm-new|方案窗口|摘要二\n" $((now-900)) $((now-60)))";
   out="$(RELAY_ACK_SECS=600 relay_outbox_overdue "$now" <<< "$in")";
   grep -q "rm-old" <<< "$out" && ! grep -q "rm-new" <<< "$out"'
t "#67② 超时判定忽略非法行(⛔ 被半写的行带出假告警)" bash -c \
  'source "'"$TMPR"'/fn.sh";
   out="$(RELAY_ACK_SECS=600 relay_outbox_overdue 1000000 <<< "半行没有时间戳")"; [ -z "$out" ]'
rm -rf "$TMPR"
# ⭐ 绊线⑰:ctx 分引擎——取不到读数**报不可用退非零** ⛔ 返 0/旧值(0 和旧值都会让交班闸门看着「还早」)
tfail "#67③ ctx 未知引擎被拒" "只接受 claude|codex" "$LANE" ctx --engine kimi
tfail "#67③ codex ctx 取不到读数 ⇒ 报不可用并退非零(⛔ 返 0/返旧值)" "ctx 不可用" \
  env LAIXIN_CODEX_SESSIONS=/nonexistent-codex-sessions-67 "$LANE" ctx --engine codex
tout "#67③ ctx 默认引擎仍是 claude(claude 路径零行为变化)" 'local eng="claude"' \
  sed -n "/^cmd_ctx() {/,/^}/p" "$LANE"
# ── ctx 多配置目录枚举(2026-08-19 夜,11B pingxia-37 实撞)──────────────────────────────────
# 原写死 $HOME/.claude-official/projects/-Users-pingxia;双账号软切换(#75 族)后 transcript 按配置目录分家
# ⇒ 新通道(.claude-b)全部窗口 `ctx <id>`「没有匹配」,≥70% 交班硬闸门整条通道失明;不带参的列表分支
# 更糟——把旧通道别人的会话列给你认领(失效反向)。修=枚举 ~/.claude*/projects/-Users-pingxia,输出带通道名。
VCX="$(mktemp -d)"
mkdir -p "$VCX/.claude-official/projects/-Users-pingxia" "$VCX/.claude-b/projects/-Users-pingxia"
printf '%s\n' '{"message":{"usage":{"input_tokens":100000,"cache_read_input_tokens":200000,"cache_creation_input_tokens":0}}}' \
  > "$VCX/.claude-official/projects/-Users-pingxia/aaaa1111-old.jsonl"
printf '%s\n' '{"message":{"usage":{"input_tokens":50000,"cache_read_input_tokens":350000,"cache_creation_input_tokens":0}}}' \
  > "$VCX/.claude-b/projects/-Users-pingxia/bbbb2222-new.jsonl"
tout "ctx:新通道(.claude-b)会话按 id 能找到并标通道名(⛔ 只认 .claude-official)" "bbbb2222… \[.claude-b\]" \
  env HOME="$VCX" LAIXIN_CTX_PROJ= "$LANE" ctx bbbb2222
tout "ctx:旧通道会话仍可读(两线并存,⛔ 只认开关那条)" "aaaa1111… \[.claude-official\]" \
  env HOME="$VCX" LAIXIN_CTX_PROJ= "$LANE" ctx aaaa1111
tout "ctx:不带参列表跨两通道并标通道名" "\[.claude-official\]" env HOME="$VCX" LAIXIN_CTX_PROJ= "$LANE" ctx
tout "ctx:不带参列表含新通道会话" "bbbb2222" env HOME="$VCX" LAIXIN_CTX_PROJ= "$LANE" ctx
VCX0="$(mktemp -d)"
tfail "ctx:零 transcript 目录 ⇒ 报不可用退非零(⛔ 返 0/返空让闸门看着「还早」)" "ctx 不可用" \
  env HOME="$VCX0" LAIXIN_CTX_PROJ= "$LANE" ctx
t "ctx:⛔ 代码行写死 .claude-official/projects(换账号即失明)" bash -c '! grep -vE "^[[:space:]]*#" "'"$LANE"'" | grep -q "claude-official/projects"'
rm -rf "$VCX" "$VCX0"
tout "#67③ codex ctx 分母取会话自带 model_context_window(⛔ 复用 claude 那份手改分母)" \
  "model_context_window" sed -n "/^cmd_ctx_codex/,/^}/p" "$LANE"
# ⭐ 绊线⑱:confirm_briefed 词表分引擎,第三参缺省=claude ⇒ 既有调用方零行为变化
tout "#67 confirm_briefed 词表分引擎(照 #60② lane-c 取词表)" 'eng="${3:-claude}"' \
  sed -n "/^confirm_briefed/,/^}/p" "$LANE"
t "#67 relay 起窗仍按 claude 词表(缺省参数,零行为变化)" bash -c \
  'grep -q "confirm_briefed \"\$RELAY_WIN\" \"relay\" )" "'"$LANE"'" ||
   grep -q "confirm_briefed \"\$RELAY_WIN\" \"relay\"" "'"$LANE"'"'
# ⭐ 绊线⑲:SKILL.md 五处**分引擎二选一 ⛔ 删掉 claude 的写法**(回切时卡还得能用)
t "#67 SKILL.md 保留 SendMessage 写法且补齐 relay-msg 分支(⛔ 二选一写成一选一)" bash -c \
  'f="$(cd "$(dirname "'"$LANE"'")/.." && pwd)/skills/laixin-pipeline/SKILL.md";
   [ "$(grep -c "SendMessage" "$f")" -ge 5 ] && [ "$(grep -c "relay-msg" "$f")" -ge 5 ]'
tout "#67 SKILL.md 写明分流原则(事实类 ⛔ 占用中继那一跳)" "只让「需要对方判断」的消息走中继" \
  cat "$(cd "$(dirname "$LANE")/.." && pwd)/skills/laixin-pipeline/SKILL.md"
tout "#67 SKILL.md 写明中继无反向注入能力(换个名字不改变它是同一个动作)" "换个名字不改变它是同一个动作" \
  cat "$(cd "$(dirname "$LANE")/.." && pwd)/skills/laixin-pipeline/SKILL.md"

# ── #75 换账号:起窗入口可覆盖(创始人 2026-08-19 令「流水线全部切到另一个账号」)─────────
# 换账号走「换配置目录」⛔ 走 /login;路径=复制包装器只改 CLAUDE_OFFICIAL_CONFIG_DIR 一行。
# ⚠️ 本组最要紧的是第 3 条「三处零遗漏」:改了两处漏一处,那一处会**静默用旧账号**,
#    而它与改对了在任何回显里都长得一模一样(今日主线:失败态与正常态同形)。
t "#75 起窗入口默认仍是 claude(⛔ 默认换新,切换要显式;理由同 #66)" bash -c \
  'grep -qE "LAIXIN_CLAUDE_LAUNCHER:-.*echo claude" "'"$LANE"'"'
t "#75 起窗入口可被 LAIXIN_CLAUDE_LAUNCHER 覆盖" bash -c \
  'grep -q "LAIXIN_CLAUDE_LAUNCHER" "'"$LANE"'"'
# 🔁 沿革:2026-08-23 #165-2 调用点由 4→5；本片 Claude print 新增第 6 个真实执行点。
#   断言随之更新 **⛔ 删**(它钉的是「零硬编码 claude」,不是数字本身；dry 展示串不计执行点)。
t "#75 六处起窗调用点全部走变量,零硬编码 claude(print 为第 6 处；dry 展示串不计执行点)" bash -c \
  'n="$(grep -E '\''\$CLAUDE_LAUNCHER"? -n '\'' "'"$LANE"'" | grep -v "<同一件点名prompt-argv>" | wc -l | tr -d " ")"; [ "$n" = 6 ] || { echo "变量调用点=$n,应为6"; exit 1; };
   h="$(grep -c "\" claude -n " "'"$LANE"'" || true)"; [ "$h" = 0 ] || { echo "仍有 $h 处硬编码 claude -n"; exit 1; }'


echo "== 6j. verify-from 自述列全防线(#27) =="
# 原自述只说「契约与 commit 存在性已校验」,而实际已有四道 ⇒ 三十一任据它反推「闸门会放行」并当盲区上报。
T27="$(mktemp -d)"
printf '假报告\n【交付完成】main e9a4acc\n' > "$T27/来信平台-廿七片验收记录.md"
# ⭐ 绊线①:四道逐一在自述里点名(少一道即红)
tout "自述点名末行契约(#27)" "①末行契约" "$LANE" verify-from "$T27/来信平台-廿七片验收记录.md" --dry
tout "自述点名 commit 存在性(#27)" "②commit 在仓库存在" "$LANE" verify-from "$T27/来信平台-廿七片验收记录.md" --dry
tout "自述点名零 commit 拒接(#27)" "③相对 main 非零 commit" "$LANE" verify-from "$T27/来信平台-廿七片验收记录.md" --dry
tout "自述点名末行快照过期(#27)" "④末行快照未过期" "$LANE" verify-from "$T27/来信平台-廿七片验收记录.md" --dry
tout "自述交代 dry 与真起窗的分层(#27)" "只警告、真起窗才拒" "$LANE" verify-from "$T27/来信平台-廿七片验收记录.md" --dry
tout "自述不影响既有解析行(片名仍可读)" "片名=廿七片" "$LANE" verify-from "$T27/来信平台-廿七片验收记录.md" --dry
# ⭐ 绊线②(本条真正要防的是「漂移」,而不只是「这一次写对了」):
#   自述道数必须等于代码里实际防线数 = 2 道常驻(契约/commit 存在)+ **语句位** die 拒绝的条数。
#   将来谁加第五道防线却忘了回改自述,这条立刻变红——把「回改自述」从靠自觉变成机器强制。
#   ⚠️ 只数语句位(`^\s*die "`)⛔ 数注释:首版数了含该词的注释,把解释这条判据的注释自己算了进去
#   (自指污染,实撞一次)——判据的射程必须排除判据自身的说明文字。
t "自述道数 = 代码实际防线数(#27 防自述再漂)" bash -c '
  body="$(awk "/^cmd_verify_from\(\)/,/^}/" "'"$LANE"'")"
  refuse="$(grep -cE "^[[:space:]]*die \"⛔ 拒绝" <<< "$body" || true)"
  want=$((2 + refuse))
  [ "$refuse" -ge 1 ] && grep -q "已校验 $want 道" <<< "$body"'
rm -rf "$T27"

echo "== 6i. log 未标来源要有反馈(#26;fixture 看板,零真实副作用) =="
L26="$(mktemp -d)"; printf '# 看板\n' > "$L26/b.md"
# ⭐ 绊线①:未设 LAIXIN_WINDOW 必须**明确提示且告诉你该设什么**——原缺陷是零反馈,连错 18 条
tout "未设 LAIXIN_WINDOW 时提示该设什么(#26)" "LAIXIN_WINDOW=派工窗口" \
  env -u LAIXIN_WINDOW LAIXIN_BOARD="$L26/b.md" "$LANE" log "测试事件甲"
tout "提示里点名验收窗口有专用 vlog(#26)" "vlog" \
  env -u LAIXIN_WINDOW LAIXIN_BOARD="$L26/b.md" "$LANE" log "测试事件乙"
# ⭐ 绊线②(方向性,本条的立项要害):提示 ⛔ 升级成拒绝执行——打断记录比来源字段错更贵,
#   提示不得惩罚「记看板」这个想鼓励的行为(三约束③)。退出码必须仍是 0,且记录必须真落盘。
t "未设来源仍退出 0(提示 ⛔ 拒绝执行,#26)" \
  env -u LAIXIN_WINDOW LAIXIN_BOARD="$L26/b.md" "$LANE" log "测试事件丙"
t "未设来源时记录照常落盘(不打断记看板)" bash -c 'grep -q "测试事件丙" "'"$L26"'/b.md"'
# ⭐ 绊线③:兜底来源 ⛔ 叫「窗口」——那是个看着像正常来源的名字,把缺陷伪装成合法记录
#   (三约束② 失效必须降级 ⛔ 反向)。必须是自曝的「未标注来源」,stats 来源统计里一眼可见。
t "兜底来源自曝为「未标注来源」⛔ 伪装成「窗口」" bash -c \
  'grep -q "| 未标注来源 | 测试事件丙 |" "'"$L26"'/b.md" && ! grep -q "| 窗口 | 测试事件丙 |" "'"$L26"'/b.md"'
# ⭐ 绊线③-bis(2026-08-22 监测中实撞):log 要认 LAIXIN_BOARD_SRC(起窗/重生路径的来源变量),与 caller_src 同一优先级族——
#   否则同一调用方 `log` 落「未标注来源」而 `dispatch`/`relay` 起窗条目落「11B归口」,两条路各认一个变量。
t "log 认 LAIXIN_BOARD_SRC 做来源(LAIXIN_WINDOW 未设时)" bash -c \
  'env -u LAIXIN_WINDOW LAIXIN_BOARD_SRC=11B归口 LAIXIN_BOARD="'"$L26"'/b.md" "'"$LANE"'" log "测试事件丁" >/dev/null 2>&1; grep -q "| 11B归口 | 测试事件丁 |" "'"$L26"'/b.md"'
t "log 来源优先级:LAIXIN_WINDOW 仍高于 LAIXIN_BOARD_SRC(在班窗口自报身份优先)" bash -c \
  'env LAIXIN_WINDOW=派工窗口 LAIXIN_BOARD_SRC=11B归口 LAIXIN_BOARD="'"$L26"'/b.md" "'"$LANE"'" log "测试事件戊" >/dev/null 2>&1; grep -q "| 派工窗口 | 测试事件戊 |" "'"$L26"'/b.md"'
# ⭐ 绊线④:设了来源就**零提示**——噪音不得随正确用法增长
t "设了 LAIXIN_WINDOW 则零提示(不制造噪音)" bash -c \
  '! grep -q "未设 LAIXIN_WINDOW" <<< "$(env LAIXIN_WINDOW=派工窗口 LAIXIN_BOARD="'"$L26"'/b.md" "'"$LANE"'" log "测试事件丁" 2>&1)"'
t "设了来源时来源字段照原样写入" bash -c 'grep -q "| 派工窗口 | 测试事件丁 |" "'"$L26"'/b.md"'
rm -rf "$L26"

echo "== 7a. #44 保命循环禁裸调用(wd_loop 执行重生时宿主无声死亡;隔离 fixture,零真实 tmux) =="
# 08-19 10:56 实撞:杀 relay → 看门狗记「自动重起」→ cmd_relay 内双中继守卫 die(:die=echo+exit)
# 在**同进程函数调用**形态下 exit 直接终止宿主 wd_loop,`|| board` 兜底接不住 exit,stderr 被吞
# ⇒ 无声死亡,全线失去看门狗且零告警。绊线驱动 tests/wd44-driver.sh 在沙盒里跑**真实** wd_loop/cmd_relay。
WDD="$(cd "$(dirname "$0")" && pwd)/wd44-driver.sh"
# ⭐ 机理自证(照 #20a 例):若此测变红=bash 行为已变,重估本组
tout "#44 机理自证:函数内 die(exit)穿透 >/dev/null ||兜底 直接杀宿主" "MECH=host-dead-and-fallback-skipped" \
  bash "$WDD" mech "$LANE"
# ⭐ 主绊线(执行级,修复回退即红):relay 死+常态拓扑 outside=2,跑真 wd_loop ≥2 拍——
#   宿主必须存活(回退子 shell 隔离 ⇒ HOST=dead)+ 失败必须大声上看板并附死因末行(回退大声报 ⇒ 缺条)
#   + 死因不得是「起窗中止」(回退 --resurrect 豁免 ⇒ 常态拓扑被自家守卫拦死,恰好报它)
t "#44 绊线:relay 死跑 wd_loop 一拍——宿主存活+重生失败大声报+非守卫拦死" bash -c \
  'out="$(bash "$0" beat "$1")"; grep -q "HOST=alive" <<< "$out" && grep -q "中继重生失败" <<< "$out" && ! grep -q "起窗中止" <<< "$out"' \
  "$WDD" "$LANE"
# ⭐ 豁免不泄漏:首起路径(人手跑 relay,无豁免旗)守卫必须照旧拦
t "#44 绊线:首起路径双中继守卫照旧(无豁免旗;2026-08-23 起判据=tmux 外有会话名 relay* 即真双中继,必拦且 rc 非零)" bash -c \
  'out="$(bash "$0" guard "$1")"; grep -q "GUARD_RC=1" <<< "$out" && grep -q "起窗中止" <<< "$out"' \
  "$WDD" "$LANE"
# 模式级:wd_loop 里不许再出现裸的 cmd_relay/cmd_dispatch 调用(重生一律命令替换子 shell 收码)
t "#44 模式绊线:wd_loop 内无裸 cmd_relay/cmd_dispatch 调用" bash -c \
  'body="$(sed -n "/^wd_loop()/,/^}/p" "$0")"; ! grep -qE "^[[:space:]]*cmd_(relay|dispatch) " <<< "$body"' "$LANE"
# dispatch 两分支同族加固在位(死窗重起 + 静默换窗,失败都大声报不再静默/带死宿主)
tout "#44:dispatch 死窗重起分支子 shell 隔离并大声报" "派工窗口重起失败" sed -n "/^wd_loop()/,/^}/p" "$LANE"
tout "#44:静默换窗分支失败不再静默吞错(原 || true)" "静默换窗失败" sed -n "/^wd_loop()/,/^}/p" "$LANE"
# boot 链(resurrect --full)同族:relay 拉起带席位恢复豁免,且 || board 兜底因子 shell 隔离而真正可达
tout "#44:resurrect --full 的 relay 拉起=恢复既有席位(--resurrect)" "cmd_relay --resurrect" \
  sed -n "/^cmd_resurrect()/,/^}/p" "$LANE"
t "#44:resurrect --full 内无裸 cmd_relay/cmd_dispatch/cmd_watchdog 调用" bash -c \
  'body="$(sed -n "/^cmd_resurrect()/,/^}/p" "$0")"; ! grep -qE "^[[:space:]]*(cmd_relay|cmd_dispatch|cmd_watchdog)[ )]" <<< "$body" && ! grep -qE "\|\| (cmd_relay|cmd_dispatch|cmd_watchdog) " <<< "$body"' "$LANE"
# #44 后续:wd_loop 改命令替换收输出后,起窗函数里的后台块若握着继承的 stdout fd,
# $( ) 会一直读到后台块退出(验尸块=15s)⇒ 后台块必须显式脱离 stdout/stderr
t "#44:起窗函数内后台块显式脱离 stdout(防拖住 wd_loop 的命令替换读 15s)" bash -c \
  'for f in cmd_relay cmd_dispatch; do sed -n "/^${f}()/,/^}/p" "$0" | grep -qE "^[[:space:]]*\) &$" && exit 1; done; :' "$LANE"

echo "== 7b. #45 起窗看板来源=真实调用上下文(⛔ 硬编码「看门狗」) =="
# 实撞(08-19 11:0x):创始人**手工**拉起 relay,看板记「看门狗 起中继窗口」,relay 第二任据此
# 误判「看门狗保活有效」并正式推翻 #44 的失效判定(三层全错)——来源写「通常是谁」=为每一次
# 非常规调用制造伪证,而演练/事故排查恰恰全是非常规调用。
# ⭐ 主绊线(执行级,修复回退即红):手工调用路径的起窗 board 来源**不得**是「看门狗」
t "#45 绊线:起窗 board 来源随真实调用方(手工/LAIXIN_WINDOW),⛔ 硬编码看门狗" bash -c \
  'out="$(bash "$0" manual-src "$1")"; grep -q "| 手工 | 起中继窗口" <<< "$out" && grep -q "| 方案窗口 | 起中继窗口" <<< "$out" && ! grep -q "| 看门狗 | 起中继窗口" <<< "$out"' \
  "$WDD" "$LANE"
# 看门狗重生路径的来源仍是「看门狗」(它这回是真的)——borrow beat 模式的看板复核
t "#45:看门狗重生路径来源=看门狗(真实时照记,⛔ 因噎废食)" bash -c \
  'grep -q "| 看门狗 | ⚠️ 中继窗口不在" <<< "$(bash "$0" beat "$1")"' "$WDD" "$LANE"
# 模式绊线:起窗族函数体内零硬编码 board "看门狗"(回退任一处即红)
t "#45 模式绊线:cmd_relay/cmd_dispatch 函数体零硬编码 board \"看门狗\"" bash -c \
  'for f in cmd_relay cmd_dispatch; do sed -n "/^${f}()/,/^}/p" "$0" | grep -q "board \"看门狗\"" && exit 1; done; :' "$LANE"
tout "#45:wd_loop 重生调用显式声明来源=看门狗" 'LAIXIN_BOARD_SRC="看门狗" cmd_relay' sed -n "/^wd_loop()/,/^}/p" "$LANE"
tout "#45:boot 链重生显式声明来源=resurrect" 'LAIXIN_BOARD_SRC="resurrect" cmd_relay' sed -n "/^cmd_resurrect()/,/^}/p" "$LANE"
# caller_src 取值优先级(单测):显式声明 > 在班窗口自报 > 手工;与 #26 的 log 提示逻辑互不相扰
t "#45:caller_src 优先级=LAIXIN_BOARD_SRC>LAIXIN_WINDOW>手工" bash -c '
  T="$(mktemp -d)"; sed -n "/^caller_src()/,/^}/p" "$0" > "$T/f.sh"
  a="$(env -u LAIXIN_WINDOW -u LAIXIN_BOARD_SRC bash -c "source \"$T/f.sh\"; caller_src")"
  b="$(env -u LAIXIN_BOARD_SRC LAIXIN_WINDOW=派工窗口 bash -c "source \"$T/f.sh\"; caller_src")"
  c="$(env LAIXIN_BOARD_SRC=看门狗 LAIXIN_WINDOW=派工窗口 bash -c "source \"$T/f.sh\"; caller_src")"
  rm -rf "$T"
  [ "$a" = 手工 ] && [ "$b" = 派工窗口 ] && [ "$c" = 看门狗 ]' "$LANE"

echo "== 7c. #37 派接管指令后回读复核(Enter 竞态实撞:指令停在输入框,dispatch 空转 5 分钟) =="
# fixture:抽真实 confirm_briefed+dialog_classify,tmux/sleep/board 为桩,三情景全覆盖
T37="$(mktemp -d)"
sed -n "/^confirm_briefed()/,/^}/p" "$LANE" > "$T37/f.sh"
sed -n "/^dialog_classify()/,/^}/p" "$LANE" >> "$T37/f.sh"
cat > "$T37/stub.sh" <<'S37'
sleep(){ :; }
board(){ printf '%s\n' "$2" >> "$B37"; }
caller_src(){ echo 测试; }
SESSION=s
tmux(){ case "$1" in
  capture-pane) cat "$PANE37" ;;
  send-keys)    echo KEY >> "$K37" ;;
esac; }
S37
# 情景 A:已见活动迹象 ⇒ 成功返回,零补 Enter 零告警
t "#37:已提交(见 Working)⇒ 静默通过,零补 Enter" bash -c '
  export B37="$1/bA" K37="$1/kA" PANE37="$1/pA"
  printf "● Working on the takeover\n" > "$PANE37"; : > "$K37"; : > "$B37"
  bash -c "source \"$1/f.sh\"; source \"$1/stub.sh\"; confirm_briefed dispatch dispatch" \
    && [ ! -s "$K37" ] && [ ! -s "$B37" ]' 37 "$T37"
# 情景 B:卡在输入框且无对话框 ⇒ 补 3 次 Enter 后大声报,rc 非零
t "#37 绊线:未提交且无对话框 ⇒ 补 3 次 Enter+大声上看板+rc 非零" bash -c '
  export B37="$1/bB" K37="$1/kB" PANE37="$1/pB"
  printf "> 你是 laixin 开发流水线的派工窗口(指令停在输入框)\n" > "$PANE37"; : > "$K37"; : > "$B37"
  bash -c "source \"$1/f.sh\"; source \"$1/stub.sh\"; confirm_briefed dispatch dispatch" && exit 1
  [ "$(grep -c KEY "$K37")" = 3 ] && grep -q "疑似未提交" "$B37"' 37 "$T37"
# 情景 C:画面有对话框 ⇒ ⛔ 补 Enter(签名库硬规则:安全键永不得是 Enter/选中默认项),只告警
t "#37 绊线:有对话框 ⇒ 零 Enter(防替弹窗选默认项)+告警点名对话框" bash -c '
  export B37="$1/bC" K37="$1/kC" PANE37="$1/pC"
  printf "Esc to cancel\nEnter to confirm\n" > "$PANE37"; : > "$K37"; : > "$B37"
  bash -c "source \"$1/f.sh\"; source \"$1/stub.sh\"; confirm_briefed dispatch dispatch" && exit 1
  [ ! -s "$K37" ] && grep -q "对话框" "$B37"' 37 "$T37"
rm -rf "$T37"
# 结构绊线:dispatch 与 relay 起窗共用此竞态 ⇒ 两处都必须挂回读(回退任一处即红)
tout "#37:cmd_dispatch 起窗挂了回读复核" "confirm_briefed \"\$DISPATCH_WIN\"" sed -n "/^cmd_dispatch()/,/^}/p" "$LANE"
tout "#37:cmd_relay 起窗挂了回读复核(共用路径同修)" "confirm_briefed \"\$RELAY_WIN\"" sed -n "/^cmd_relay()/,/^}/p" "$LANE"

echo "== 7d. #34 wip-save 丢弃前先固化(fixture 仓库,零真实副作用) =="
W34="$(mktemp -d)"; mkdir -p "$W34/repo" "$W34/wip"
git -C "$W34/repo" init -q
printf 'a\nb\n' > "$W34/repo/f.txt"
git -C "$W34/repo" add f.txt
git -C "$W34/repo" -c user.email=t@t -c user.name=t commit -qm init
printf 'a\nCHANGED\n' > "$W34/repo/f.txt"      # 未暂存改动(checkout -- 会毁掉的那部分)
printf 'new\n' > "$W34/repo/untracked.txt"      # 未跟踪文件(diff 拍不到,须射程自曝)
tout "#34:固化成功回显「已固化并通过反向校验」+补丁路径" "已固化并通过反向校验" \
  env LAIXIN_WIP_DIR="$W34/wip" "$LANE" wip-save --dir "$W34/repo"
# ⭐ 保真非声称:补丁真落盘、真含改动、真能反向干净应用(⛔ 只信回显)
t "#34 绊线:补丁落在指定持久目录且 git apply --check -R 实测可还原" bash -c '
  p="$(ls "$1/wip"/wip-*.patch 2>/dev/null | head -1)"; [ -n "$p" ] || exit 1
  grep -q "CHANGED" "$p" && git -C "$1/repo" apply --check -R "$p"' 34 "$W34"
tout "#34:射程自曝——未跟踪文件不在补丁里要点名" "未跟踪文件" \
  env LAIXIN_WIP_DIR="$W34/wip" "$LANE" wip-save --dir "$W34/repo"
# 空 diff:不造空补丁;且 staged 改动 diff 拍不到也要点名(「无未暂存改动」≠「无可失去」)
git -C "$W34/repo" checkout -- f.txt
printf 'a\nb\nstaged\n' > "$W34/repo/f.txt"; git -C "$W34/repo" add f.txt
t "#34:空 diff 不造空补丁且点名 staged 改动拍不到" bash -c '
  out="$(env LAIXIN_WIP_DIR="$1/wip" "$2" wip-save --dir "$1/repo")"
  grep -q "没有要固化的内容" <<< "$out" && grep -q "已暂存" <<< "$out"' 34 "$W34" "$LANE"
rm -rf "$W34"
# ⭐ 目录绊线(实撞的次生风险):默认目录必须在 HOME,⛔ /private/tmp(重启清空=固化了也蒸发)
t "#34 绊线:补丁目录默认挂 HOME ⛔ /tmp 族" bash -c \
  'grep -q "LAIXIN_WIP_DIR:-\$HOME/" "$0" && ! grep -qE "LAIXIN_WIP_DIR:-/(private/)?tmp" "$0"' "$LANE"
tout "#34:保真校验在位(⛔ 只看文件生成了)" "apply --check -R" sed -n "/^cmd_wip_save()/,/^}/p" "$LANE"

echo "== 7e. #39 kb-commit 回显列实际路径+说明位路径守卫(fixture vault) =="
V39="$(mktemp -d)"
git -C "$V39" init -q
printf 'x\n' > "$V39/总表.md"; printf 'y\n' > "$V39/注册表.md"
git -C "$V39" add 总表.md 注册表.md
git -C "$V39" -c user.email=t@t -c user.name=t commit -qm init
printf 'y2\n' > "$V39/注册表.md"
# ⭐ 主绊线(实撞:误信总表已提交):回显必须列**实际 add 的路径**,msg 带「说明:」标注不再像文件名
t "#39 绊线:回显列实际 add 的路径且 msg 标注为说明" bash -c '
  out="$(env LAIXIN_VAULT="$1" "$2" kb-commit "更新注册表" 注册表.md 2>&1)"
  grep -q "已提交 1 个文件(说明:更新注册表)" <<< "$out" && grep -q "^   .*注册表.md" <<< "$out"' 39 "$V39" "$LANE"
# ⭐ 强形态:单参且是存在的文件 ⇒ 拒绝并提示签名(把路径当 msg 的形态)
tfail "#39 绊线:单参调用且参数是存在的文件 ⇒ 拒绝并提示签名" "落在「说明」位" \
  env LAIXIN_VAULT="$V39" "$LANE" kb-commit 总表.md
tfail "#39:单参非文件仍走通用用法提示(不误伤)" "用法:" \
  env LAIXIN_VAULT="$V39" "$LANE" kb-commit 只有说明没有文件
# 弱形态(实撞原型 kb-commit <总表路径> <注册表路径>):不阻断,stderr 提醒说明位是存在文件
t "#39:多参但说明位是存在文件 ⇒ 提醒不阻断,提交照常" bash -c '
  printf "y3\n" > "$1/注册表.md"
  out="$(env LAIXIN_VAULT="$1" "$2" kb-commit 总表.md 注册表.md 2>&1)"; rc=$?
  [ $rc -eq 0 ] && grep -q "存在的文件路径" <<< "$out" && grep -q "已提交 1 个文件" <<< "$out"' 39 "$V39" "$LANE"
rm -rf "$V39"

echo "== 7f. #40 send 送达检测附状态(⚖️ 裁定:⛔ 放宽判据 ⛔ 提高阈值,只加状态说明) =="
T40="$(mktemp -d)"
{ sed -n "/^lane_engine()/,/^}/p" "$LANE"; sed -n "/^kimi_act_pat()/,/^}/p" "$LANE"; sed -n "/^send_swallow_check()/,/^}/p" "$LANE"; } > "$T40/f.sh"   # #60②:检测分引擎,lane_engine 一并抽出
cat > "$T40/stub.sh" <<'S40'
win(){ echo "lane-$1"; }
target(){ echo "s:lane-$1"; }
board(){ printf '%s\n' "$2" >> "$B40"; }
tmux(){ cat "$P40"; }
S40
# ⭐ 主绊线(实撞形态):lane 跑后台长任务时界面静止 ⇒ 警告**照发**(拦截不变)且点名状态与看处
t "#40 绊线:后台任务静止 ⇒ 警告照发+点名 Waiting for background terminal 属预期" bash -c '
  export B40="$1/bA" P40="$1/pA"
  printf "Waiting for background terminal (1m 42s)\n" > "$P40"; : > "$B40"
  out="$(bash -c "source \"$1/f.sh\"; source \"$1/stub.sh\"; send_swallow_check a" 2>&1)"
  grep -q "疑似被吞" <<< "$out" && grep -q "Waiting for background terminal" <<< "$out" \
    && grep -q "界面静止属预期" "$B40"' 40 "$T40"
# 普通静止:警告原样,零状态注(状态注只在有据时出现,不制造无据文案)
t "#40:普通静止 ⇒ 警告原样零状态注" bash -c '
  export B40="$1/bB" P40="$1/pB"
  printf "安静的画面\n" > "$P40"; : > "$B40"
  out="$(bash -c "source \"$1/f.sh\"; source \"$1/stub.sh\"; send_swallow_check a" 2>&1)"
  grep -q "疑似被吞" <<< "$out" && ! grep -q "界面静止属预期" <<< "$out"' 40 "$T40"
# 有活动迹象:零警告——判据未放宽也未收紧
t "#40:有活动迹象 ⇒ 零警告(判据未动)" bash -c '
  export B40="$1/bC" P40="$1/pC"
  printf "● Working on it\n" > "$P40"; : > "$B40"
  out="$(bash -c "source \"$1/f.sh\"; source \"$1/stub.sh\"; send_swallow_check a" 2>&1)"
  [ -z "$out" ] && [ ! -s "$B40" ]' 40 "$T40"
rm -rf "$T40"
# 结构:8 秒阈值未动(裁定 ⛔ 提高阈值),检测挂点仍在 cmd_send 后台块
tout "#40:8s 阈值未动且检测挂在 send 后台块" "sleep 8; send_swallow_check" sed -n "/^cmd_send()/,/^}/p" "$LANE"

echo "== 7g. #38 backup 瞬时失败重试(git 桩按调用次数控成败,零真实 push) =="
T38="$(mktemp -d)"
sed -n "/^cmd_backup()/,/^}/p" "$LANE" > "$T38/f.sh"
cat > "$T38/stub.sh" <<'S38'
board(){ printf '%s\n' "$2" >> "$B38"; }
git(){  # git -C <repo> <子命令>…;push 的成败由计数与 FAILN 控制
  shift 2
  case "$1" in
    remote) if [ -f "$NOREMOTE" ]; then return 1; fi; return 0 ;;
    push)   local n; n="$(cat "$CNT" 2>/dev/null || echo 0)"; n=$((n+1)); printf '%s' "$n" > "$CNT"
            if [ "$n" -le "$FAILN" ]; then return 1; fi; return 0 ;;
  esac
  return 0
}
S38
# ⭐ 主绊线(实撞形态):首轮三仓全败、重试全成 ⇒ 退出码 0 且**零告警**(误报被洗掉)
t "#38 绊线:瞬时失败(首轮败重试成)⇒ 重试洗掉误报,零告警 rc=0" bash -c '
  export B38="$1/bA" CNT="$1/cA" NOREMOTE="$1/没有这个文件" FAILN=3 LAIXIN_BACKUP_RETRY_DELAY=0
  : > "$B38"
  out="$(bash -c "set -uo pipefail; source \"$1/f.sh\"; source \"$1/stub.sh\"; cmd_backup")" || exit 1
  grep -q "自动重试一次" <<< "$out" && [ ! -s "$B38" ]' 38 "$T38"
# 持续失败:重试后仍败才告警,rc 非零(告警没有被重试机制吞掉)
t "#38 绊线:持续失败 ⇒ 重试后仍告警且 rc 非零" bash -c '
  export B38="$1/bB" CNT="$1/cB" NOREMOTE="$1/没有这个文件" FAILN=99 LAIXIN_BACKUP_RETRY_DELAY=0
  : > "$B38"
  bash -c "set -uo pipefail; source \"$1/f.sh\"; source \"$1/stub.sh\"; cmd_backup" >/dev/null && exit 1
  grep -q "重试后仍有失败项" "$B38"' 38 "$T38"
# 全成:零重试零告警(重试不随健康态出现)
t "#38:全成 ⇒ 零重试零告警" bash -c '
  export B38="$1/bC" CNT="$1/cC" NOREMOTE="$1/没有这个文件" FAILN=0 LAIXIN_BACKUP_RETRY_DELAY=0
  : > "$B38"
  out="$(bash -c "set -uo pipefail; source \"$1/f.sh\"; source \"$1/stub.sh\"; cmd_backup")" || exit 1
  ! grep -q "自动重试" <<< "$out" && [ ! -s "$B38" ]' 38 "$T38"
# ⭔ 配置缺口 ⛔ 被重试掩蔽:缺 origin 首轮即告警(重试救不了的失败不进重试洗白通道)
t "#38 绊线:缺 origin=配置缺口,首轮即告警不被重试掩蔽" bash -c '
  export B38="$1/bD" CNT="$1/cD" NOREMOTE="$1/cD-noremote" FAILN=0 LAIXIN_BACKUP_RETRY_DELAY=0
  : > "$B38"; : > "$NOREMOTE"
  bash -c "set -uo pipefail; source \"$1/f.sh\"; source \"$1/stub.sh\"; cmd_backup" >/dev/null && exit 1
  grep -q "缺 origin 远端(配置缺口" "$B38"' 38 "$T38"
rm -rf "$T38"

echo "== 8. #25 部署原子化(release:已提交版+版本化路径+原子换链;fixture 仓零真实副作用) =="
# ⚠️ 全部走 LAIXIN_RELEASE_* env 覆盖:本批 ⛔ 碰真实 ~/.local/bin/laixin-lane(切换留复工试火)
R25="$(mktemp -d)"
mkdir -p "$R25/repo/bin" "$R25/bin" "$R25/rel"
git -C "$R25/repo" init -q
printf '#!/bin/bash\necho v1\n' > "$R25/repo/bin/laixin-lane"
git -C "$R25/repo" add bin/laixin-lane
git -C "$R25/repo" -c user.email=t@t -c user.name=t commit -qm v1
RENV=(env LAIXIN_RELEASE_REPO="$R25/repo" LAIXIN_RELEASE_BIN="$R25/bin/laixin-lane" LAIXIN_RELEASE_DIR="$R25/rel")
tout "#25:release 发布已提交版并回显新旧软链去向" "已发布" "${RENV[@]}" "$LANE" release
t "#25:软链指向发布目录内版本化文件,内容=已提交版且可执行" bash -c '
  tgt="$(readlink "$1/bin/laixin-lane")"
  case "$tgt" in "$1/rel"/*) ;; *) exit 1 ;; esac
  [ -x "$tgt" ] && grep -q "echo v1" "$tgt"' 25 "$R25"
# ⭐ 绊线③:工作树脏 ⇒ 拒绝发布,软链纹丝不动(发布=已提交态,与 backup 只推已提交同哲学)
printf '#!/bin/bash\necho v2\n' > "$R25/repo/bin/laixin-lane"
TGT25_OLD="$(readlink "$R25/bin/laixin-lane")"
tfail "#25 绊线:工作树脏 ⇒ 拒绝发布" "拒绝发布" "${RENV[@]}" "$LANE" release
t "#25 绊线:拒绝发布时软链未被碰" bash -c '[ "$(readlink "$1/bin/laixin-lane")" = "$2" ]' 25 "$R25" "$TGT25_OLD"
# 提交 v2 再发布:链切到新版,旧发布文件保留(运行中的旧进程握旧 inode/可回滚)
git -C "$R25/repo" add bin/laixin-lane
git -C "$R25/repo" -c user.email=t@t -c user.name=t commit -qm v2
tout "#25:换代发布成功" "已发布" "${RENV[@]}" "$LANE" release
t "#25 绊线:链已指新版且旧发布文件仍保留(旧 inode 不销毁)" bash -c '
  tgt="$(readlink "$1/bin/laixin-lane")"
  grep -q "echo v2" "$tgt" || exit 1
  [ "$(ls "$1/rel" | wc -l | tr -d " ")" -ge 2 ]' 25 "$R25"
# ⭐ 绊线:已提交版语法坏 ⇒ 拒绝发布(半坏版换上=每次调用都死,比旧版继续跑危害大)
printf '#!/bin/bash\nif [ x ; then\n' > "$R25/repo/bin/laixin-lane"
git -C "$R25/repo" add bin/laixin-lane
git -C "$R25/repo" -c user.email=t@t -c user.name=t commit -qm v3-bad
tfail "#25 绊线:已提交版 bash -n 不过 ⇒ 拒绝发布" "语法检查未过" "${RENV[@]}" "$LANE" release
t "#25:语法拒发后链仍指 v2(不换上半坏版)" bash -c 'grep -q "echo v2" "$(readlink "$1/bin/laixin-lane")"' 25 "$R25"
# ② doctor 判据函数 release_stale:落后报 0 / 一致报 1 / 未切发布=不适用报 1(失效⛔指向「落后」)
sed -n "/^release_stale()/,/^}/p" "$LANE" > "$R25/fn.sh"
t "#25:release_stale——HEAD 前进(v3)而链仍 v2 ⇒ 报落后" bash -c '
  source "$1/fn.sh"
  export LAIXIN_RELEASE_REPO="$1/repo" LAIXIN_RELEASE_BIN="$1/bin/laixin-lane" LAIXIN_RELEASE_DIR="$1/rel"
  release_stale' 25 "$R25"
t "#25:release_stale——回到 v2 后内容一致 ⇒ 不报落后" bash -c '
  git -C "$1/repo" reset -q --hard HEAD~1
  source "$1/fn.sh"
  export LAIXIN_RELEASE_REPO="$1/repo" LAIXIN_RELEASE_BIN="$1/bin/laixin-lane" LAIXIN_RELEASE_DIR="$1/rel"
  ! release_stale' 25 "$R25"
t "#25:release_stale——软链指向仓库工作树(开发直连态)⇒ 不适用不报落后" bash -c '
  ln -sf "$1/repo/bin/laixin-lane" "$1/bin/laixin-lane"
  source "$1/fn.sh"
  export LAIXIN_RELEASE_REPO="$1/repo" LAIXIN_RELEASE_BIN="$1/bin/laixin-lane" LAIXIN_RELEASE_DIR="$1/rel"
  ! release_stale' 25 "$R25"

# ⭐ #59:发布单元=运行单元——helper(bin/*.py)全集随行,差集自检,版本目录隔离
printf '#!/bin/bash\necho v4-good\n' > "$R25/repo/bin/laixin-lane"   # 前序 HEAD 是坏语法版,先提交好版
git -C "$R25/repo" add bin/laixin-lane
git -C "$R25/repo" -c user.email=t@t -c user.name=t commit -qm v4good
printf 'print("h1")
' > "$R25/repo/bin/opt_status.py"
printf 'print("h2")
' > "$R25/repo/bin/copy_audit.py"
git -C "$R25/repo" add bin/opt_status.py bin/copy_audit.py
git -C "$R25/repo" -c user.email=t@t -c user.name=t commit -qm helpers
tout "#59:发布回显 helper 全集随行" "helper 全集随行" "${RENV[@]}" "$LANE" release
t "#59 绊线:发布目录 git 内 bin/*.py 差集为空,且与主脚本同目录(dirname 可解)" bash -c '
  tgt="$(readlink "$1/bin/laixin-lane")"; d="$(dirname "$tgt")"
  [ -f "$d/opt_status.py" ] && [ -f "$d/copy_audit.py" ] && grep -q h1 "$d/opt_status.py"' 59 "$R25"
t "#59 绊线:两次发布版本目录隔离(旧版本目录的 helper 不被新发布覆盖)" bash -c '
  old_d="$(dirname "$(readlink "$1/bin/laixin-lane")")"
  printf "print(\"h1v2\")\n" > "$1/repo/bin/opt_status.py"
  git -C "$1/repo" add bin/opt_status.py
  git -C "$1/repo" -c user.email=t@t -c user.name=t commit -qm h1v2
  env LAIXIN_RELEASE_REPO="$1/repo" LAIXIN_RELEASE_BIN="$1/bin/laixin-lane" LAIXIN_RELEASE_DIR="$1/rel" "$2" release >/dev/null 2>&1
  new_d="$(dirname "$(readlink "$1/bin/laixin-lane")")"
  [ "$old_d" != "$new_d" ] && grep -q "h1\"" "$old_d/opt_status.py" && grep -q h1v2 "$new_d/opt_status.py"' 59 "$R25" "$LANE"

rm -rf "$R25"
# 结构绊线:doctor 挂了发布代龄提示(提示级 wrn ⛔ 强制);原子换链走「临时链+mv」⛔ ln -sfn 直写
tout "#25:doctor 挂发布代龄检查" "发布版落后仓库已提交版" sed -n "/^cmd_doctor/,/^cmd_[a-z_]*()/p" "$LANE"
t "#25 绊线:换链=临时链+mv 原子替换,⛔ ln -sfn 直写正式链(macOS 两步有空窗)" bash -c '
  # 只判可执行行:cmd_release 注释里就有「ln -sfn ⛔ 用」的选型理由,含注释的包含匹配
  # 会被自己的元文本命中(台账八律第 8 律,本测试首跑即实撞一次)
  body="$(sed -n "/^cmd_release()/,/^}/p" "$0" | grep -v "^[[:space:]]*#")"
  grep -q "ln -s \"\$rel\" \"\$ltmp\"" <<< "$body" || exit 1
  grep -q "mv -f \"\$ltmp\" \"\$lbin\"" <<< "$body" || exit 1
  ! grep -q "ln -sfn" <<< "$body"' "$LANE"


echo "== 8b. #58 盲补 Enter 改正向信号(冷启动≠消息被吞;fixture 桩,零真实按键) =="
# 机理:#37 的补偿(补 Enter)只看「画面有无变化」,claude 冷启动「只思考不产字」与「Enter 真丢」
# 在该探针眼里同形 ⇒ 12:46 假阳性实撞,3 次盲 Enter 落进正在工作的窗口。修=补键前取正向存活信号
# (进程在+etime 短 ⇒ 宽限等待);⛔ 修 A 破 B:真丢失(无进程/etime 长)仍必须补。
T58="$(mktemp -d)"
sed -n "/^confirm_briefed()/,/^}/p" "$LANE" > "$T58/f.sh"
sed -n "/^dialog_classify()/,/^}/p" "$LANE" >> "$T58/f.sh"
cat > "$T58/stub.sh" <<'S58'
board(){ printf '%s\n' "$2" >> "$B58"; }
caller_src(){ echo 测试; }
SESSION=s
tmux(){ case "$1" in
  capture-pane) cat "$PANE58" ;;
  send-keys)    echo KEY >> "$K58" ;;
esac; }
S58
# 情景桩:冷启动(age 恒短;第 4 次 sleep 后 claude 结束思考开始产字——正是 12:46 实撞里的真相)
cat > "$T58/age_cold.sh" <<'S58A'
pane_claude_age(){ echo 10; }
sleep(){ local n; n=$(cat "$TICK58"); n=$((n+1)); echo "$n" > "$TICK58"
  [ "$n" -ge 4 ] && printf '● Working on takeover\n' > "$PANE58"; return 0; }
S58A
# 情景桩:真丢失·无进程形态(claude 没起来/已死)
cat > "$T58/age_dead.sh" <<'S58B'
pane_claude_age(){ return 1; }
sleep(){ :; }
S58B
# 情景桩:进程在但 age 持续增长越过阈值(画面永远静止=真丢失·etime 长形态)
cat > "$T58/age_grow.sh" <<'S58G'
pane_claude_age(){ cat "$AGE58"; }
sleep(){ local n; n=$(cat "$AGE58"); echo $((n+40)) > "$AGE58"; }
S58G
# ⭐ 绊线方向一(#58 主修):冷启动 fixture(进程在+etime 短+画面静止)⇒ ⛔ 补 Enter,零告警,产字后静默放行
t "#58 绊线:冷启动(进程在 etime 短)画面静止 ⇒ 宽限等待零补 Enter 零告警,产字后放行" bash -c '
  export B58="$1/b1" K58="$1/k1" PANE58="$1/p1" TICK58="$1/t1"
  printf "> 接管指令停在画面(claude 冷启动思考中)\n" > "$PANE58"; : > "$K58"; : > "$B58"; echo 0 > "$TICK58"
  bash -c "source \"$1/f.sh\"; source \"$1/stub.sh\"; source \"$1/age_cold.sh\"; confirm_briefed dispatch dispatch" \
    && [ ! -s "$K58" ] && [ ! -s "$B58" ]' 58 "$T58"
# ⭐ 绊线方向二(⛔ 修 A 破 B):真丢失·无进程 ⇒ 仍补 3 次 Enter+大声报+rc 非零(#37 原防线不减)
t "#58 绊线:真丢失(无进程)⇒ 仍补 3 次 Enter+疑似未提交告警+rc 非零" bash -c '
  export B58="$1/b2" K58="$1/k2" PANE58="$1/p2"
  printf "> 指令停在输入框(claude 没起来)\n" > "$PANE58"; : > "$K58"; : > "$B58"
  bash -c "source \"$1/f.sh\"; source \"$1/stub.sh\"; source \"$1/age_dead.sh\"; confirm_briefed dispatch dispatch" && exit 1
  [ "$(grep -c KEY "$K58")" = 3 ] && grep -q "疑似未提交" "$B58"' 58 "$T58"
# ⭐ 绊线方向二之二:进程在但画面持续静止、age 越过阈值 ⇒ 宽限到期后仍补(宽限不是免死金牌)
t "#58 绊线:宽限到期(age 越过 180s 阈值)画面仍静止 ⇒ 回到补 Enter 路径+告警" bash -c '
  export B58="$1/b3" K58="$1/k3" PANE58="$1/p3" AGE58="$1/a3"
  printf "> 指令停在输入框(进程活着但真的没提交)\n" > "$PANE58"; : > "$K58"; : > "$B58"; echo 100 > "$AGE58"
  bash -c "source \"$1/f.sh\"; source \"$1/stub.sh\"; source \"$1/age_grow.sh\"; confirm_briefed dispatch dispatch" && exit 1
  [ "$(grep -c KEY "$K58")" = 3 ] && grep -q "疑似未提交" "$B58"' 58 "$T58"
# etime_secs 单测(抽自 loop_stale,#58 与 #20⑥ 共用;10# 防 08/09 八进制)
sed -n "/^etime_secs()/,/^}/p" "$LANE" > "$T58/et.sh"
t "#58:etime_secs 四形换算(mm:ss/前导零/hh:mm:ss/dd-hh:mm:ss)" bash -c '
  source "$1/et.sh"
  [ "$(etime_secs 1:23)" = 83 ] && [ "$(etime_secs 08:09)" = 489 ] \
    && [ "$(etime_secs 01:02:03)" = 3723 ] && [ "$(etime_secs 2-01:00:00)" = 176400 ]' 58 "$T58"
rm -rf "$T58"
# 结构绊线:正向信号判据在 confirm_briefed 本体(回退即红);对话框安检仍在补键之前
tout "#58:confirm_briefed 补键前挂正向存活信号(pane_claude_age)" "pane_claude_age" \
  sed -n "/^confirm_briefed()/,/^}/p" "$LANE"
tout "#58:pane_claude_age 用 etime(lstart 中文 locale 不可解析)" "etime" \
  sed -n "/^pane_claude_age()/,/^}/p" "$LANE"

echo "== 8c. #45-bis 来源残留(board 来源=真实调用上下文,⛔ 硬编码;批二收尾裁定归停工 B 段) =="
# 判可执行行(剔注释)——注释里保留了旧写法案底,含注释的包含匹配会被元文本命中(八律第 8 律)
t "#45-bis:vwait_ready 两处 board 改走 caller_src,零硬编码「事件总线」" bash -c '
  body="$(sed -n "/^vwait_ready()/,/^}/p" "$0" | grep -v "^[[:space:]]*#")"
  [ "$(grep -c "board \"\$(caller_src)\"" <<< "$body")" = 2 ] || exit 1
  ! grep -q "board \"事件总线\"" <<< "$body"' "$LANE"
t "#45-bis:watchdog stop 来源=执行方(caller_src),主语挪进消息" bash -c '
  body="$(sed -n "/^cmd_watchdog()/,/^}/p" "$0" | grep -v "^[[:space:]]*#")"
  grep -q "board \"\$(caller_src)\" \"看门狗已停止\"" <<< "$body" || exit 1
  ! grep -q "board \"看门狗\" \"已停止\"" <<< "$body"' "$LANE"
# ev_loop 内两处 board「事件总线」是真自述(循环体自己在说话),⛔ 被本修波及
t "#45-bis 射程:ev_loop 循环体内的「事件总线」自述保留(来源即事实)" bash -c '
  body="$(sed -n "/^ev_loop()/,/^}/p" "$0" | grep -v "^[[:space:]]*#")"
  grep -q "board \"事件总线\"" <<< "$body"' "$LANE"

echo "== 8d. kb-commit 相对路径错误信息指真因(#27 同形:工具自述把人往错方向引;落卡级) =="
# 实撞形态:在别的 cwd 用相对路径,文件明明「在」(相对 cwd),错误信息却只说「不是文件」——
# 排查被引向「文件在不在」,真因是相对路径按 vault 解析不按 cwd
KRP="$(mktemp -d)"; mkdir -p "$KRP/vault" "$KRP/cwd"
git -C "$KRP/vault" init -q
echo x > "$KRP/cwd/真在cwd的文件.md"
t "kb-commit 被拒时点明「按 vault 解析」+回显解析后路径+给绝对路径出路" bash -c '
  cd "$1/cwd" || exit 1
  out="$(env LAIXIN_VAULT="$1/vault" "$2" kb-commit "说明" 真在cwd的文件.md 2>&1)"; rc=$?
  [ $rc -ne 0 ] || exit 1
  grep -q "不是文件" <<< "$out" || exit 1
  grep -q "相对路径按 vault 解析" <<< "$out" || exit 1
  grep -q "解析为 $1/vault/真在cwd的文件.md" <<< "$out" || exit 1
  grep -q "绝对路径" <<< "$out"' kb "$KRP" "$LANE"
rm -rf "$KRP"

echo "== 8e. #五-18 review-env 评审环境一键化(fixture 全封闭:假仓+桩服务;起过的服务测完必须杀净) =="
RVD="$(mktemp -d)"
# 假主仓库:main 分支 + 实操卡要求的全部落点(scripts/init_db.py、seed.py、frontend、.venv 桩)
git init -q -b main "$RVD/repo"; git -C "$RVD/repo" config user.email t@t; git -C "$RVD/repo" config user.name t
mkdir -p "$RVD/repo/scripts" "$RVD/repo/frontend" "$RVD/repo/app"
printf '# fixture init_db\n' > "$RVD/repo/scripts/init_db.py"
printf 'def seed(): pass\n' > "$RVD/repo/seed.py"
printf 'x\n' > "$RVD/repo/frontend/package.json"
git -C "$RVD/repo" add -A; git -C "$RVD/repo" commit -qm fixture
mkdir -p "$RVD/repo/frontend/node_modules" "$RVD/repo/.venv/bin" "$RVD/bin"
# python 桩:init/seed 退 0;`-m uvicorn ... --port N` 起真实 HTTP 监听(就绪判定与杀净验尸都要真端口)
cat > "$RVD/repo/.venv/bin/python" <<'EOF'
#!/bin/bash
port=""; prev=""
for a in "$@"; do [ "$prev" = "--port" ] && port="$a"; prev="$a"; done
case "${1:-}" in
  -m) exec /usr/bin/env python3 -m http.server "$port" --bind 127.0.0.1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$RVD/repo/.venv/bin/python"
# npx 桩:`next dev -p N --webpack` 同样起真实监听
cat > "$RVD/bin/npx" <<'EOF'
#!/bin/bash
port=""; prev=""
for a in "$@"; do [ "$prev" = "-p" ] && port="$a"; prev="$a"; done
exec /usr/bin/env python3 -m http.server "$port" --bind 127.0.0.1
EOF
chmod +x "$RVD/bin/npx"
RV_WT="$HOME/.laixin-review-test-$$"   # 评审树必须在 /Users 下(命令自己的硬闸门),⛔ 用 mktemp(/var 下)
RVE=(env PATH="$RVD/bin:$PATH" LAIXIN_REPO="$RVD/repo" LAIXIN_REVIEW_DIR="$RV_WT" LAIXIN_REVIEW_STATE="$RVD/state" LAIXIN_REVIEW_API_PORT=8977 LAIXIN_REVIEW_WEB_PORT=3977 LAIXIN_BOARD="$RVD/b.md")
# ⭐ 闸门先测(零副作用路径):/Users 外拒起(Turbopack panic 实撞)、重复 up 拒起
tfail "review-env:worktree 在 /Users 外被拒(Turbopack symlink 坑)" "必须放 /Users 下" \
  env LAIXIN_REPO="$RVD/repo" LAIXIN_REVIEW_DIR="/tmp/lx-review-bad" "$LANE" review-env up
RV_OUT="$("${RVE[@]}" "$LANE" review-env up 2>&1)"; RV_RC=$?
tout "up 五步全过并自报每步实测(#50 通过态可见)" "5/5 前端" echo "$RV_OUT"
t "up 退出码 0" test "$RV_RC" -eq 0
t "后端端口真在应答(HTTP 判活,非声明)" curl -s -o /dev/null --max-time 2 http://127.0.0.1:8977/
t "前端端口真在应答" curl -s -o /dev/null --max-time 2 http://127.0.0.1:3977/
t "worktree 真建在指定路径" test -d "$RV_WT"
t "前端 node_modules 已 symlink 主仓库" test -L "$RV_WT/frontend/node_modules"
tfail "重复 up 被拒(目录已存在,先 down)" "已存在" "${RVE[@]}" "$LANE" review-env up
tout "status 报端口有监听" "有监听" "${RVE[@]}" "$LANE" review-env status
# ⭐ 端口占用预检:8977 正被上面的环境占着,换 API 端口=8977 的第二环境必须被拦并指认占用者
tfail "端口被占时拒起并指认占用者(⛔ 盲起=伪环境)" "已被占用" \
  env PATH="$RVD/bin:$PATH" LAIXIN_REPO="$RVD/repo" LAIXIN_REVIEW_DIR="$HOME/.laixin-review-test2-$$" LAIXIN_REVIEW_STATE="$RVD/state2" LAIXIN_REVIEW_API_PORT=8977 LAIXIN_REVIEW_WEB_PORT=3978 "$LANE" review-env up
# ⭐ down=杀净+验尸+回收(⛔ 留孤儿进程——本批最硬的纪律)
RV_DOWN="$("${RVE[@]}" "$LANE" review-env down 2>&1)"
tout "down 验尸端口零监听" "验尸:零监听者" echo "$RV_DOWN"
tout "down 回收 worktree" "worktree 已回收" echo "$RV_DOWN"
t "down 后后端端口确已静默(lsof 实测)" bash -c '[ -z "$(lsof -ti tcp:8977 2>/dev/null)" ]'
t "down 后前端端口确已静默" bash -c '[ -z "$(lsof -ti tcp:3977 2>/dev/null)" ]'
t "down 后 worktree 目录确已不在" bash -c '[ ! -e "$1" ]' rv "$RV_WT"
t "down 后 git 无残留注册(worktree list 干净)" bash -c '! git -C "$1/repo" worktree list --porcelain | grep -qx "worktree $2"' rv "$RVD" "$RV_WT"
rm -rf "$RVD"; rm -rf "$RV_WT" 2>/dev/null || true

echo "== 8f. #五-19 audit-pages 底册复查提醒(fixture 底册+看板;audit-queue 同族,命中≠定罪) =="
APD="$(mktemp -d)"; mkdir -p "$APD/kb/索引" "$APD/kb/4-开发层"
cat > "$APD/kb/索引/wiki-页面走查底册.md" <<'EOF'
| 页面 | 路由 | 状态 | 最近走查 | 裁定指针 | 截图 | 下轮关注 |
|---|---|---|---|---|---|---|
| 付款页 | /pay | ✅ 🔁 | 08-18 | §12 | shot | **付款指引机制片**后复查 |
| 聚单页 | /agg | ✅ 🔁 | 08-18 | §12 | shot | 标题基座片合入后复查 |
| 名片页 | /m | ✅ 🔁 | 08-18 | §12 | shot | 履约区撤除片;「在线」真实性观察 |
| 首页 | / | ✅ | 08-18 | §12 | shot | 标题基座片合入后复查 |
EOF
printf '| 08-19 10:00 | 派工窗口 | 合并 付款指引机制 abc123,100 绿 |\n| 08-19 11:00 | 派工窗口 | 合并 别的片(prompt 里顺带提及标题基座词) |\n' > "$APD/kb/4-开发层/来信平台-流水线看板.md"
APE=(env LAIXIN_KB="$APD/kb" LAIXIN_BOARD="$APD/kb/4-开发层/来信平台-流水线看板.md")
AP_OUT="$("${APE[@]}" "$LANE" audit-pages 2>&1)"
tout "触发片有格式合并记录 → 🔴 复查提醒点名页与片" "「付款页」的复查触发片「付款指引机制」" echo "$AP_OUT"
tout "触发名仅在叙述里 → 弱嫌疑一行速核(⛔ 拿误报换漏报)" "弱嫌疑 1 项" echo "$AP_OUT"
tout "弱嫌疑点名页←片" "「聚单页←标题基座」" echo "$AP_OUT"
ap_scope_check(){ case "$1" in *首页*) echo SCOPE_LEAK ;; *) echo SCOPE_OK ;; esac; }
tout "非 🔁 页不报(✅ 页的触发点已复查过,报了=噪声随做对的行为涨)" "SCOPE_OK" ap_scope_check "$AP_OUT"
ap_miss_check(){ case "$1" in *履约区撤除*) echo MISS_LEAK ;; *) echo MISS_OK ;; esac; }
tout "未合并的触发片零输出(零命中≠零检查——总结行会报查了几个)" "MISS_OK" ap_miss_check "$AP_OUT"
printf '| 08-19 10:00 | 派工窗口 | 无关记录 |\n' > "$APD/kb/4-开发层/来信平台-流水线看板.md"
tout "零命中时报绿且自报射程(🔁 页数/触发点数,#50 通过态可见)" "🔁 页 3 个 / 带「片」触发点 3 个 × 看板合并记录零命中" \
  "${APE[@]}" "$LANE" audit-pages
tfail "底册读不到时自曝 ⛔ 静默当零命中(三约束②)" "底册/看板读不到" env LAIXIN_KB="$APD/nokb" LAIXIN_BOARD="$APD/kb/4-开发层/来信平台-流水线看板.md" "$LANE" audit-pages
tout "stats 尾部挂接班可选项提示(⛔ 常驻,只是可发现)" "audit-pages" sed -n "/^cmd_stats/,/^}/p" "$LANE"
rm -rf "$APD"

echo "== 8g. #五-29 词表引用行号指纹(prompt-lint「可解析」升「行号+内容指纹」;#22 状态感知) =="
FPD="$(mktemp -d)"; mkdir -p "$FPD/kb/索引" "$FPD/repo/app"
printf '| 转单-9 | x |\n' > "$FPD/kb/索引/wiki-裁定池总表.md"
printf '| R48 | z |\n' > "$FPD/kb/索引/wiki-红线清单.md"
printf 'l1\nl2\nl3\n' > "$FPD/repo/app/x.py"
cat > "$FPD/kb/索引/wiki-消费者词汇表.md" <<'EOF'
| 场景A | 已收到 | 备注 |
| 场景B | ~~旧句已废弃~~ 新句上屏 | 替换「旧句已废弃」 |
| 场景C | ~~彻底废句~~ 现行句 | 无 |
EOF
FPE=(env LAIXIN_KB="$FPD/kb" LAIXIN_REPO="$FPD/repo")
printf '引用 索引/wiki-消费者词汇表.md:1「已收到」 与 转单-9。\n' > "$FPD/fp-ok.md"
tout "指纹匹配 → 过且零指纹提示" "0 项查无" "${FPE[@]}" "$LANE" prompt-lint "$FPD/fp-ok.md"
t "带指纹的词表引用不再触发「未带指纹」提示" bash -c \
  '! grep -q "未带内容指纹" <<< "$(env LAIXIN_KB="'"$FPD"'/kb" LAIXIN_REPO="'"$FPD"'/repo" "'"$LANE"'" prompt-lint "'"$FPD"'/fp-ok.md" 2>&1)"'
printf '引用 索引/wiki-消费者词汇表.md:1「等你确认」 与 转单-9。\n' > "$FPD/fp-miss.md"
tfail "指纹不匹配 → 红并点名行号漂移形态(#五-29 本体)" "内容指纹不匹配" "${FPE[@]}" "$LANE" prompt-lint "$FPD/fp-miss.md"
# ⭐ #22 状态感知三形态:删除线剥掉后现行句匹配 / 只命中备注格旧句 / 只命中删除线废句
printf '引用 索引/wiki-消费者词汇表.md:2「新句上屏」 与 转单-9。\n' > "$FPD/fp-live.md"
tout "现行句匹配(删除线内容不挡道)→ 过" "0 项查无" "${FPE[@]}" "$LANE" prompt-lint "$FPD/fp-live.md"
printf '引用 索引/wiki-消费者词汇表.md:2「旧句已废弃」 与 转单-9。\n' > "$FPD/fp-note.md"
tfail "指纹只命中备注引文旧句 → 红并点名(旧句=最像的伪锚;⛔ 按格位判——真表列布局不一)" "只命中引号内引文" "${FPE[@]}" "$LANE" prompt-lint "$FPD/fp-note.md"
printf '引用 索引/wiki-消费者词汇表.md:3「彻底废句」 与 转单-9。\n' > "$FPD/fp-struck.md"
tfail "指纹只命中删除线 → 红并点名已废弃" "只命中删除线" "${FPE[@]}" "$LANE" prompt-lint "$FPD/fp-struck.md"
# 词表引用未带指纹 → 提示级(迁移推手,⛔ 拦)
printf '引用 索引/wiki-消费者词汇表.md:1 与 转单-9。\n' > "$FPD/fp-none.md"
tout "词表引用未带指纹 → ❌ 并给写法(2026-08-23 由提示升红:漂移是静默的,无指纹=静默错锚)" "未带内容指纹" "${FPE[@]}" "$LANE" prompt-lint "$FPD/fp-none.md"
t "未带指纹 ⇒ 非零退出(2026-08-23 升红;原「提示级不改退出码」口径作废)" bash -c '! "$@" >/dev/null 2>&1' _ "${FPE[@]}" "$LANE" prompt-lint "$FPD/fp-none.md"
# 非词表文件带指纹同样核(通用同一性;不带则不提示——提示射程只在词表)
printf '引用 app/x.py:3「l3」 与 转单-9。\n' > "$FPD/fp-code-ok.md"
tout "非词表文件指纹匹配 → 过" "0 项查无" "${FPE[@]}" "$LANE" prompt-lint "$FPD/fp-code-ok.md"
printf '引用 app/x.py:3「l9」 与 转单-9。\n' > "$FPD/fp-code-bad.md"
tfail "非词表文件指纹不匹配 → 红" "内容指纹不匹配" "${FPE[@]}" "$LANE" prompt-lint "$FPD/fp-code-bad.md"
t "非词表文件不带指纹零提示(提示射程=词表)" bash -c \
  '! grep -q "未带内容指纹" <<< "$(env LAIXIN_KB="'"$FPD"'/kb" LAIXIN_REPO="'"$FPD"'/repo" "'"$LANE"'" prompt-lint "'"$FPD"'/fp-code-ok.md" 2>&1)"'
rm -rf "$FPD"

echo "== 8h. #49 移节漏检机器化(进行中节片名 × 轨道占用;fixture 表+一次性 tmux 会话,测完杀净) =="
MQ="$(mktemp -d)"; mkdir -p "$MQ/kb/4-开发层"
MQS="lx49test-$$"
# 方向二:行在轨不在(bogus 会话=零窗口)——「进行中」挂着行而 lane 窗口整个没了
cat > "$MQ/kb/4-开发层/来信平台-执行总表.md" <<'EOF'
## 进行中(= 轨道占用)
> 引注块要被跳过,⛔ 当表行
| 片 | 轨 | 分支 | 状态 |
|---|---|---|---|
| **在飞甲片**(括注) | **A** | x | 整改中 |

## 排队
| 片 | 轨 | 前置 | 状态 |
|---|---|---|---|
EOF
printf '| 08-19 10:00 | 派工窗口 | 无关记录 |\n' > "$MQ/kb/4-开发层/来信平台-流水线看板.md"
tout "行在而轨不在 → ⚠️ 移节嫌疑点名片与轨" "「进行中」节挂着 「在飞甲片」" \
  env LAIXIN_SESSION="bogus-$MQS" LAIXIN_KB="$MQ/kb" "$LANE" audit-queue
# 方向一:轨在干活而节空(一次性 tmux 会话造「lane-a 屏上有活动迹象」;⛔ 碰真 laixin 会话)
tmux new-session -d -s "$MQS" -n hub 2>/dev/null
tmux new-window -d -t "$MQS" -n lane-a "bash -c 'echo Working on it; sleep 30'"
# 条件等待而非盲 sleep:抓屏早于窗口首行输出=竞态假红(等到 Working 上屏才继续,上限 5s)
for _i in 1 2 3 4 5 6 7 8 9 10; do
  tmux capture-pane -p -t "$MQS:lane-a" 2>/dev/null | grep -q "Working" && break
  sleep 0.5
done
cat > "$MQ/kb/4-开发层/来信平台-执行总表.md" <<'EOF'
## 进行中(= 轨道占用)
| 片 | 轨 | 分支 | 状态 |
|---|---|---|---|

## 排队
| 片 | 轨 | 前置 | 状态 |
|---|---|---|---|
EOF
MV_OUT="$(env LAIXIN_SESSION="$MQS" LAIXIN_KB="$MQ/kb" "$LANE" audit-queue 2>&1)"
tout "轨在干活而节空 → 🔴 移节漏检嫌疑(撞车形态,三十四任实撞)" "移节漏检嫌疑(#49):lane-a 正在干活" echo "$MV_OUT"
# 一致态:行在且窗口在(嫌疑双向都不触发;lane-a busy + A 行 1 = 方向一不触发)
cat > "$MQ/kb/4-开发层/来信平台-执行总表.md" <<'EOF'
## 进行中(= 轨道占用)
| 片 | 轨 | 分支 | 状态 |
|---|---|---|---|
| **在飞甲片** | **A** | x | 整改中 |
EOF
tout "行在且轨在 → ✅ 移节核报绿并自报两向射程(#50 通过态可见)" "✅ 移节核(#49):进行中节片名 × 轨道占用一致(A 行 1 / B 行 0" \
  env LAIXIN_SESSION="$MQS" LAIXIN_KB="$MQ/kb" "$LANE" audit-queue
tmux kill-session -t "$MQS" 2>/dev/null || true
# 空表+零窗口=一致(空比空的相等在这里是真相等:两边都是「无」的事实,零冲突报绿)
cat > "$MQ/kb/4-开发层/来信平台-执行总表.md" <<'EOF'
## 进行中
| 片 | 轨 | 分支 | 状态 |
|---|---|---|---|
EOF
tout "节空且轨闲 → 报绿(空轨等派是常态,报了=噪声随做对的行为涨)" "✅ 移节核(#49)" \
  env LAIXIN_SESSION="bogus-$MQS" LAIXIN_KB="$MQ/kb" "$LANE" audit-queue
t "fixture tmux 会话确已杀净(测试自己不留孤儿)" bash -c '! tmux has-session -t "$1" 2>/dev/null' mv "$MQS"
rm -rf "$MQ"

echo "== 8i. #50 检查器「通过」态必须可见(「没有报警」与「没有这项检查」不得同形;样本=代龄 grep 零命中被读成没这项检查) =="
# —— 功能级:真跑两遍 doctor,第二遍版本未变必须报 ok(⛔ 只在变化时说话) ——
"$LANE" doctor >/dev/null 2>&1 || true
tout "doctor:上游版本未变化时也留一行" "上游 CLI 版本未变化" "$LANE" doctor
# —— 静态:分支在停工期不可达(wd/ev 未跑),grep 判 else 分支存在 ——
tout "doctor:看门狗代龄一致有通过行" "看门狗循环代龄一致" sed -n "/^cmd_doctor/,/^cmd_stats/p" "$LANE"
tout "doctor:事件总线代龄一致有通过行" "事件总线循环代龄一致" sed -n "/^cmd_doctor/,/^cmd_stats/p" "$LANE"
tout "doctor:模型档位无冲突有通过行(§6 此前非 haiku 整段零输出)" "ctx 分母与模型档位无冲突" sed -n "/^cmd_doctor/,/^cmd_stats/p" "$LANE"
tout "doctor:工程债不适用有通过行(§7 此前文件不在整段零输出)" "债项不适用" sed -n "/^cmd_doctor/,/^cmd_stats/p" "$LANE"
tout "events status:代龄一致有通过行" "循环代龄一致" sed -n "/^cmd_events/,/^}/p" "$LANE"
tout "watchdog status:补上代龄比对+通过行(此前该 status 连这项检查都没有)" "循环代龄一致" sed -n "/^cmd_watchdog/,/^}/p" "$LANE"
# —— lint 类:总结行报「已核清单」,零报警≠零检查 ——
P50="$(mktemp -d)"; mkdir -p "$P50/kb/索引"
printf '| 转单-9 | x |\n' > "$P50/kb/索引/wiki-裁定池总表.md"
printf '| R48 | z |\n' > "$P50/kb/索引/wiki-红线清单.md"
printf '引用 转单-9。\n' > "$P50/p.md"
tout "prompt-lint 报已核清单" "①文件:行号 ②裁定编号" env LAIXIN_KB="$P50/kb" "$LANE" prompt-lint "$P50/p.md"
printf '报告\n```\n输出\n```\ncommit 数 1,任务数 1,达标\n【交付完成】b t\n' > "$P50/r.md"
tout "report-lint 总结行报已核四项" "已核:末行契约" "$LANE" report-lint "$P50/r.md"
rm -rf "$P50"
# —— kb-commit 撞号自检:真扫过且零撞号要说一声(未涉队列文件仍静默=不适用是实话) ——
D50="$(mktemp -d)"; mkdir -p "$D50/v/wiki"
git init -q -b main "$D50/v"; git -C "$D50/v" config user.email t@t; git -C "$D50/v" config user.name t
printf '## 清单\n\n23. 廿三条\n' > "$D50/v/wiki/运行复盘与优化推动-测试.md"
git -C "$D50/v" add -A; git -C "$D50/v" commit -qm seed
printf '24. 新条不撞号\n' >> "$D50/v/wiki/运行复盘与优化推动-测试.md"
tout "撞号自检真扫过且零撞号 → ✅ 一行" "撞号自检(#9):本次新增的编号条目与既有条目零撞号" \
  env LAIXIN_VAULT="$D50/v" "$LANE" kb-commit "test: 追加" wiki/运行复盘与优化推动-测试.md
NQ_OUT="$(env LAIXIN_VAULT="$D50/v" bash -c 'printf "x\n" > "'"$D50"'/v/普通笔记.md"; "'"$LANE"'" kb-commit "test: 非队列" 普通笔记.md' 2>&1)"
nq_check(){ case "$1" in *撞号自检*) echo NQ_LEAK ;; *已提交*) echo NQ_OK ;; *) echo NQ_BAD ;; esac; }
tout "非队列文件不打撞号行(不适用≠通过,静默是实话)" "NQ_OK" nq_check "$NQ_OUT"
rm -rf "$D50"
# —— 后台检查的存在要在前台说一声(send 8s 复核/up 10s 验尸/起窗守卫状态) ——
tout "send 回显预告 8s 送达复核" "8s 送达复核已挂后台" sed -n "/^cmd_send/,/^}/p" "$LANE"
tout "up 回显预告 10s 启动验尸" "10s 启动验尸已挂后台" sed -n "/^cmd_up/,/^}/p" "$LANE"
tout "dispatch 回显守卫已核态" "双派工守卫已核:无对手" sed -n "/^cmd_dispatch/,/^}/p" "$LANE"
tout "dispatch 回显在 --force-rival 下如实说「跳过未核」⛔ 装作核过" "跳过(未核,风险自担)" sed -n "/^cmd_dispatch/,/^}/p" "$LANE"
tout "relay 回显区分 --resurrect 豁免与 --force-rival 跳过(两种非常规调用语义不同)" "按 --resurrect 豁免" sed -n "/^cmd_relay()/,/^}/p" "$LANE"
tout "release 成功回显已核清单" "已核:工作树干净" sed -n "/^cmd_release/,/^}/p" "$LANE"

echo "== 8j. #51 table-lint 台账写盘断言库(列数+残留竖线+行首唯一;从「各窗口自带」升「库提供」) =="
TL="$(mktemp -d)"
cat > "$TL/好表.md" <<'EOF'
# 注册表
| 角色 | 地址 | 备注 |
|---|---|---|
| 派工窗口 | dispatch | `?? 0` 与 `|| 0` 是禁止项 |
| **中继窗口** | relay | 正常行 |
整行叙述可以出现在表外只要不带竖线
EOF
tout "合法表过(内联代码带竖线不算分隔——实撞:裸分列被 \`|| 0\` 切碎)" "✅ table-lint:1 个表 4 行列数齐" "$LANE" table-lint "$TL/好表.md"
t "合法表退 0" "$LANE" table-lint "$TL/好表.md"
cat > "$TL/劈行.md" <<'EOF'
| 角色 | 地址 | 备注 |
|---|---|---|
| 中继 | relay | 布尔或 || 就是那次把行劈成 10 列的形态 |
EOF
tfail "裸竖线劈行被列数断言拦(#51 本体:注册表 10 列实撞)" "列数断言:3 行有 5 格" "$LANE" table-lint "$TL/劈行.md"
tfail "劈行报错给出路(符号进表格包反引号)" "包反引号" "$LANE" table-lint "$TL/劈行.md"
cat > "$TL/残留.md" <<'EOF'
| 角色 | 地址 |
|---|---|
| 甲 | a |
移行没删干净的碎片 | b |
| 尾巴不闭合
EOF
tfail "表外残留竖线被扫出(移行碎片形态)" "表外残留竖线" "$LANE" table-lint "$TL/残留.md"
tfail "行不闭合被扫出" "行不闭合" "$LANE" table-lint "$TL/残留.md"
cat > "$TL/叙述行.md" <<'EOF'
| 片 | 轨 | 分支 | 状态 |
|---|---|---|---|
| **正常片** | A | x | ok |
| **整行叙述的单格行(执行总表在用的形态,不许误伤)** |
EOF
tout "单格叙述行不算列数异常(状态感知,真总表 4 连例)" "单格叙述行 1 行不参与" "$LANE" table-lint "$TL/叙述行.md"
cat > "$TL/围栏.md" <<'EOF'
| 甲 | 乙 |
|---|---|
| a | b |
```
代码块里的 | 竖线 | 不算 | 表 |
```
EOF
t "代码围栏内竖线不扫(fence 状态感知)" "$LANE" table-lint "$TL/围栏.md"
# 行首匹配唯一性:写盘脚本定位目标行的三态
tout "行首唯一命中报行号" "行首「派工窗口」唯一命中" "$LANE" table-lint "$TL/好表.md" --match "派工窗口"
tfail "行首零命中报「sed 会静默空替换」" "零命中" "$LANE" table-lint "$TL/好表.md" --match "不存在的行"
cat > "$TL/歧义.md" <<'EOF'
| 片 | 轨 |
|---|---|
| 付款指引机制 | A |
| 付款指引机制补丁 | B |
EOF
tfail "行首多命中报歧义并列行号" "命中 2 行" "$LANE" table-lint "$TL/歧义.md" --match "付款指引机制"
# --lines 射程:存量坏行不在指定行 ⇒ 不扰(kb-commit 钩=只核新增行的机制半边)
cat > "$TL/存量.md" <<'EOF'
| 甲 | 乙 | 丙 |
|---|---|---|
| 老坏行 | 只有两格 |
| 新好行 | a | b |
EOF
t "--lines 限射程:存量坏行不在指定行 ⇒ 过(历史形态不扰正常提交)" "$LANE" table-lint "$TL/存量.md" --lines 4
tfail "--lines 含坏行 ⇒ 照拦" "列数断言" "$LANE" table-lint "$TL/存量.md" --lines 3,4
# kb-commit 挂点:提交涉注册表 ⇒ 自动只核新增行;非台账族零噪音
TLV="$(mktemp -d)"; git init -q -b main "$TLV"; git -C "$TLV" config user.email t@t; git -C "$TLV" config user.name t
printf '| 角色 | 地址 |\n|---|---|\n| 甲 | a |\n' > "$TLV/来信平台-窗口角色注册表.md"
git -C "$TLV" add -A; git -C "$TLV" commit -qm seed
printf '| 乙 | 劈行 || 形态 |\n' >> "$TLV/来信平台-窗口角色注册表.md"
tout "kb-commit 涉注册表 ⇒ 自动断言并拦下新增劈行(⛔ 阻断,报警由人核)" "列数断言" \
  env LAIXIN_VAULT="$TLV" "$LANE" kb-commit "test: 注册表劈行" 来信平台-窗口角色注册表.md
t "断言未过但提交已落库(⛔ 阻断=分桶钩同哲学)" bash -c \
  'git -C "$1" log --oneline -1 | grep -q "注册表劈行"' tl "$TLV"
printf '| 丙 | c |\n' >> "$TLV/来信平台-窗口角色注册表.md"
tout "kb-commit 新增好行 ⇒ 断言过报绿(#50)" "✅ table-lint" \
  env LAIXIN_VAULT="$TLV" "$LANE" kb-commit "test: 注册表好行" 来信平台-窗口角色注册表.md
printf 'x | y 普通笔记里的竖线\n' > "$TLV/随笔.md"
tl_nohook(){ case "$1" in *table-lint*|*表结构断言*) echo TL_LEAK ;; *已提交*) echo TL_OK ;; *) echo TL_BAD ;; esac; }
tout "非台账族提交零断言噪音(钩挂在台账动作上)" "TL_OK" tl_nohook "$(env LAIXIN_VAULT="$TLV" "$LANE" kb-commit "test: 随笔" 随笔.md 2>&1)"
rm -rf "$TL" "$TLV"

echo "== 8k. #57 观察者审计——修复组(逐处小修的绊线;结构级见交付报告清单) =="
# ① #45 族收尾:五处硬编码 board 来源(halt/claim/relay-down/verify/vdown)改走 caller_src。
#   判可执行行剔注释(八律第 8 律:注释保留旧写法案底,含注释的包含匹配会被元文本命中)
t "#57a:全脚本可执行行零硬编码「派工窗口/方案窗口/中继窗口」board 来源" bash -c '
  body="$(grep -v "^[[:space:]]*#" "$0")"
  ! grep -qE "board \"(派工窗口|方案窗口|中继窗口)\"" <<< "$body"' "$LANE"
t "#57a:halt/claim/relay_down/verify/vdown 五处都走 caller_src" bash -c '
  for fn in cmd_halt cmd_claim cmd_relay_down cmd_verify cmd_vdown; do
    sed -n "/^${fn}()/,/^}/p" "$0" | grep -v "^[[:space:]]*#" | grep -q "board \"\$(caller_src)\"" || exit 1
  done' "$LANE"

# ② 版本探针修真:包装器横幅在首行、真版本在末行——head -1 抓横幅=版本变化检测全盲
tout "#57b:版本探针取末行(⛔ head -1 抓包装器横幅=检测全盲)" 'claude --version 2>/dev/null | tail -1' \
  sed -n "/^cmd_doctor/,/^cmd_stats/p" "$LANE"
t "#57b:doctor 里不再有 head -1 取版本" bash -c \
  '! sed -n "/^cmd_doctor/,/^cmd_stats/p" "$0" | grep -v "^[[:space:]]*#" | grep -q -- "--version 2>/dev/null | head -1"' "$LANE"
# ③ uptime 判活口径与 doctor/status 对齐(窗口存在=假绿形态,#20⑤)
tout "#57c:uptime watchdog 用进程判活并区分假绿" "窗口在但循环已死" sed -n "/^cmd_uptime/,/^}/p" "$LANE"
t "#57c:uptime 不再拿窗口存在当 watchdog 活着" bash -c \
  'sed -n "/^cmd_uptime/,/^}/p" "$0" | grep -v "^[[:space:]]*#" | grep -q "! wd_alive" ' "$LANE"

# ④ uptime 零命中计数畸形(grep -c 零命中先打 0 再退 1,|| echo 0 叠打成断行;审计真机实测抓出)
t "#57d:uptime 今日事件行是完整一行(零命中 ⛔ 断行成两行)" bash -c '
  out="$("$0" uptime 2>&1 | grep "今日事件")"
  [ "$(wc -l <<< "$out" | tr -d " ")" = 1 ] || exit 1
  grep -q "投递 [0-9]* · 暂存 [0-9]* · 看门狗动作 [0-9]*$" <<< "$out"' "$LANE"

# ⑤ start 类命令的启动断言(「脚本说了启动」≠「现场起来了」,#20b 同族;静态——真起会碰常驻)
tout "#57e:events start 有启动验证两态" "启动验证:ev-loop 进程已在跑" sed -n "/^cmd_events/,/^}/p" "$LANE"
tout "#57e:watchdog start 有启动验证两态" "启动验证:wd-loop 进程已在跑" sed -n "/^cmd_watchdog/,/^}/p" "$LANE"
tout "#57e:resurrect --infra 按实测宣布 ⛔ 起完就宣布" "⛔ 当作基础设施已恢复" sed -n "/^cmd_resurrect/,/^}/p" "$LANE"
# ⑥ 新增输出自审:review-env status 三态(目录在≠worktree 在);prompt-lint 已核行防过度声明
tout "#57f:review-env status 区分「已注册/目录在未注册/不在」三态" "未注册为本仓库 worktree" \
  sed -n "/^cmd_review_env/,/^}/p" "$LANE"
tout "#57f:prompt-lint 已核行自标「适用即核」⛔ 过度声明" "各项适用即核" sed -n "/^cmd_prompt_lint/,/^}/p" "$LANE"

echo "== 6y. #60② C 轨(Kimi Code CLI / K3;可选轨,每片独立 worktree) =="
C60="$(mktemp -d)"
# win 收 c;非法轨仍拒(函数抽出真跑,⛔ 经 cmd_up 触 ensure_session)
C60W="$C60/win.sh"; { sed -n "/^win()/,/^}/p" "$LANE"; sed -n "/^lane_engine()/,/^}/p" "$LANE"; } > "$C60W"
t "#60②:win 收 c → lane-c,非法轨照拒" bash -c '
  source "'"$C60W"'"; die(){ echo "die: $*" >&2; exit 1; }
  [ "$(win c)" = "lane-c" ] || exit 1
  ! (win d) 2>/dev/null'
t "#60②:引擎分派 a/b=codex c=kimi" bash -c '
  source "'"$C60W"'"; [ "$(lane_engine a)" = codex ] && [ "$(lane_engine b)" = codex ] && [ "$(lane_engine c)" = kimi ]'
# 🔴 2026-08-27:以下 C 轨用例内显式钉 LAIXIN_LANE_TRANSPORT=tui ⛔ 依赖机器默认——
#   全局开关切 print 后,:542 的守卫会让 fresh c 先以「非 Codex 轨」被拒,本组断言的拒绝理由随之改变,
#   同一份代码因机器上一个开关文件而给出 1054/0 与 1053/1 两种结果 ⇒ 基线数字不可比。钉死后恢复可比。
# ⭐ fresh c 必须 --dir(机器执法):不带即拒且**窗口未动**(破坏性动作前置校验);--dir 不存在同拒
tfail "#60②:fresh c 不带 --dir 被拒(每片独立 worktree,同 B 轨形态)" "fresh c 必须带 --dir" \
  env LAIXIN_SESSION=lx60c-nonexist LAIXIN_LANE_TRANSPORT=tui "$LANE" fresh c
tfail "#60②:fresh c --dir 目录不存在照拒(窗口未动)" "目录不存在" \
  env LAIXIN_SESSION=lx60c-nonexist LAIXIN_LANE_TRANSPORT=tui "$LANE" fresh c --dir "$C60/没有这个worktree"
t "#60②:fresh c 被拒时零 tmux 副作用" bash -c '! tmux has-session -t lx60c-nonexist 2>/dev/null'
# ⭐ --with-mcp 是 codex 专属语法:C 轨拒收(静默吞掉=调用者以为生效了),且动窗口之前拒
tfail "#60②:up c --with-mcp 被拒(codex 专属参数 ⛔ 静默吞)" "codex 专属参数" \
  env LAIXIN_SESSION=lx60c-nonexist "$LANE" up c --with-mcp aliyun-readonly
t "#60②:up c --with-mcp 被拒时零 tmux 副作用" bash -c '! tmux has-session -t lx60c-nonexist 2>/dev/null'
# ⭐ 起动命令按引擎分派:kimi --auto + -m 显式钉死(防配置漂移);codex 路径原样(MCP 关闭参数仍在)
t "#60②:cmd_up 起动命令分引擎(kimi --auto -m 钉死 / codex MCP 关闭原样)" bash -c '
  body="$(sed -n "/^cmd_up()/,/^}/p" "$0")"
  grep -q -- "\$KIMI_BIN\\\\\" --auto -m \$KIMI_MODEL" <<< "$body" || grep -q -- "--auto -m \$KIMI_MODEL" <<< "$body" || exit 1
  grep -qF "codex\$(codex_service_tier_flag) \$_mcp_off" <<< "$body"' "$LANE"
KM="$(bash -c "eval \"\$(grep '^KIMI_MODEL=' '$LANE')\"; echo \"\$KIMI_MODEL\"")"
tout "#60②:kimi 模型默认钉 kimi-code/k3" "kimi-code/k3" echo "$KM"
KM2="$(env LAIXIN_KIMI_MODEL=kimi-code/k4 bash -c "eval \"\$(grep '^KIMI_MODEL=' '$LANE')\"; echo \"\$KIMI_MODEL\"")"
tout "#60②:kimi 模型可覆盖(LAIXIN_KIMI_MODEL)" "kimi-code/k4" echo "$KM2"
# ⭐ codex 验收窗模型档显式钉死(2026-08-22 创始人发起、方案窗口第二十二任裁,dispatch 54 落):
#    与 kimi 位同哲学——起窗命令行显式带,⛔ 吃 config.toml 全局默认(配置漂移在看板上与从前同形)。
t "#配档:codex_launch_cmd 显式带模型与推理档(⛔ 吃 config.toml)" bash -c '
  body="$(sed -n "/^codex_launch_cmd()/,/^}/p" "$0")"
  grep -qF -- "-m \$CODEX_MODEL" <<< "$body" || exit 1
  grep -q -- "model_reasoning_effort" <<< "$body"' "$LANE"
CXM="$(bash -c "eval \"\$(grep '^CODEX_MODEL=' '$LANE')\"; echo \"\$CODEX_MODEL\"")"
tout "#配档:codex 模型默认钉 gpt-5.6-luna" "gpt-5.6-luna" echo "$CXM"
CXE="$(bash -c "eval \"\$(grep '^CODEX_EFFORT=' '$LANE')\"; echo \"\$CODEX_EFFORT\"")"
tout "#配档:codex 推理档默认钉 max(创始人既有直令 ⛔ 降档)" "max" echo "$CXE"
CXM2="$(env LAIXIN_CODEX_MODEL=gpt-5.6-terra bash -c "eval \"\$(grep '^CODEX_MODEL=' '$LANE')\"; echo \"\$CODEX_MODEL\"")"
tout "#配档:可回切 terra(luna 跑不动 CDP 时的逃生口,⛔ 改 config.toml)" "gpt-5.6-terra" echo "$CXM2"
# 🔴 病灶级反向断言:射程只到验收窗——开发轨 lane-a/b 走 cmd_up 的独立 _launch,⛔ 被本改动带走。
#    (若有人把模型参数误加进 cmd_up,在飞开发轨会静默换模型,而看板上与从前逐字相同。)
t "#配档:开发轨 cmd_up ⛔ 沾模型参数(射程不越界)" bash -c '
  body="$(sed -n "/^cmd_up()/,/^}/p" "$0")"
  ! grep -q "CODEX_MODEL" <<< "$body" && ! grep -q "model_reasoning_effort" <<< "$body"' "$LANE"
# ⭐ kimi 画面判据(2026-08-19 临时会话实测):在飞=月相转轮/Running;codex 词表(Explored)⛔ 量 kimi
C60B="$C60/busy.sh"; { sed -n "/^lane_engine()/,/^}/p" "$LANE"; sed -n "/^kimi_act_pat()/,/^}/p" "$LANE"; sed -n "/^lane_busy()/,/^}/p" "$LANE"; } > "$C60B"
t "#60②:lane_busy 分引擎——kimi 月相=在飞,codex 词表不误判 kimi" bash -c '
  source "'"$C60B"'"; SESSION=s; win_exists(){ return 0; }
  tmux(){ echo " 🌔 · Tip: /sessions to browse"; }
  lane_busy c || exit 1
  tmux(){ echo "  Explored codebase"; }
  lane_busy a || exit 1
  ! lane_busy c'
C60S="$C60/swallow.sh"; { sed -n "/^lane_engine()/,/^}/p" "$LANE"; sed -n "/^kimi_act_pat()/,/^}/p" "$LANE"; sed -n "/^win()/,/^}/p" "$LANE"; sed -n "/^target()/,/^}/p" "$LANE"; sed -n "/^send_swallow_check()/,/^}/p" "$LANE"; } > "$C60S"
t "#60②:send 被吞检测分引擎——kimi 工作画面不误报,空屏照报" bash -c '
  source "'"$C60S"'"; SESSION=s; die(){ echo "die: $*" >&2; exit 1; }; board(){ :; }
  tmux(){ echo "● Running a command"; echo " 🌕 ·"; }
  out="$(send_swallow_check c 2>&1)"; [ -z "$out" ] || exit 1
  tmux(){ echo "只有提示符没有活动迹象"; }
  out="$(send_swallow_check c 2>&1)"; grep -q "疑似被吞" <<< "$out"'
# ⭐ ev_watch_target lane-c 可选轨语义:从未起过=静默;起过又消失=与 a/b 同级事故(告警带 kimi+--dir 处置)
C60G="$C60/gone"; mkdir -p "$C60G/n" "$C60G/y"
C60E="$C60/ev.sh"; { sed -n "/^pane_hash/,/^}/p" "$LANE"; sed -n "/^lane_engine()/,/^}/p" "$LANE"; sed -n "/^ev_watch_target/,/^}/p" "$LANE"; } > "$C60E"
t "#60②:lane-c 从未起过 → GONE 静默(可选轨 ⛔ 告警)" bash -c '
  set -eo pipefail; SESSION=laixin测试不存在; EV_DIR="'"$C60G"'/n"; EV_TICK=60; EV_STALL=360
  source "'"$C60E"'"; ev_deliver(){ printf "%s\n" "$2"; }; set +e; set +o pipefail
  out="$(ev_watch_target lane-c)"; [ -z "$out" ] && [ ! -f "'"$C60G"'/n/lane-c.gone" ]'
t "#60②:lane-c 起过又消失 → 告警一次(kimi 已死+fresh c --dir 处置),去重生效" bash -c '
  set -eo pipefail; SESSION=laixin测试不存在; EV_DIR="'"$C60G"'/y"; EV_TICK=60; EV_STALL=360
  source "'"$C60E"'"; ev_deliver(){ printf "%s\n" "$2"; }; set +e; set +o pipefail
  echo "hash 0 0" > "'"$C60G"'/y/lane-c.state"
  out="$(ev_watch_target lane-c)"
  grep -q "窗口整个消失" <<< "$out" && grep -q "kimi 已死" <<< "$out" && grep -q "fresh c --dir" <<< "$out" || exit 1
  out2="$(ev_watch_target lane-c)"; [ -z "$out2" ]'
tout "#60②:ev-loop 监视含 lane-c" 'ev_watch_target "lane-c"' sed -n "/^ev_loop()/,/^}/p" "$LANE"
# ⭐ 空闲告警的下一片提示对 C 轨可解析(排队节 轨=C 行;awk 参数化本就该通吃,谁写死 A|B 这条变红)
C60T="$C60/table.md"
cat > "$C60T" <<'EOF'
## 排队(测试)
| 片 | 轨 | 内容 | 发车状态 |
|---|---|---|---|
| **C轨前端片** | **C** | y | prompt ready |
EOF
C60N="$C60/nr.sh"; sed -n "/^ev_next_ready/,/^}/p" "$LANE" > "$C60N"
t "#60②:ev_next_ready 解析 C 轨 ready 片" bash -c '
  source "'"$C60N"'"; TABLE="'"$C60T"'"; [ "$(ev_next_ready C)" = "C轨前端片" ]'
# ⭐ 移节核(#49)扩 C:行在轨没报嫌疑;无 C 行且 lane-c 未起=合规不误伤(可选轨)
C60Q="$C60/kb/4-开发层"; mkdir -p "$C60Q"
printf '| 08-19 10:00 | 派工窗口 | 无关记录 |\n' > "$C60Q/来信平台-流水线看板.md"
cat > "$C60Q/来信平台-执行总表.md" <<'EOF'
## 进行中(= 轨道占用)
| 片 | 轨 | 分支 | 状态 |
|---|---|---|---|
| **C轨在飞片** | **C** | x | 开发中 |

## 排队
| 片 | 轨 | 前置 | 状态 |
|---|---|---|---|
EOF
tout "#60②:C 行在而 lane-c 不在 → 移节嫌疑点名轨 C" "「进行中」节挂着 「C轨在飞片」(轨 C)" \
  env LAIXIN_SESSION=bogus-c60 LAIXIN_KB="$C60/kb" "$LANE" audit-queue
cat > "$C60Q/来信平台-执行总表.md" <<'EOF'
## 进行中(= 轨道占用)
| 片 | 轨 | 分支 | 状态 |
|---|---|---|---|
EOF
tout "#60②:无 C 行且 lane-c 未起 → 报绿含三轨读数(可选轨不误伤)" "A 行 0 / B 行 0 / C 行 0" \
  env LAIXIN_SESSION=bogus-c60 LAIXIN_KB="$C60/kb" "$LANE" audit-queue
# ⭐ doctor 拓扑/watchdog status:lane-c 存在性=可选,不起是 ℹ️/未起 ⛔ wrn
tout "#60②:doctor 拓扑节报 lane-c 可选轨(两态都含「可选轨」)" "可选轨" "$LANE" doctor
tout "#60②:watchdog status 报 lane-c 未起=可选 ⛔ 与 a/b 同文案" "lane-c:未起(可选轨" \
  env LAIXIN_SESSION=bogus-c60 "$LANE" watchdog status
t "#60②:doctor lane-c 未起 ⛔ 计入 warn(a/b 缺席才是 wrn)" bash -c '
  body="$(sed -n "/^cmd_doctor()/,/^cmd_stats/p" "$0")"
  grep -q "ℹ️ lane-c 未起" <<< "$body"' "$LANE"
# ⭐ 看门狗「正常等待」判定:C 轨起了才算数(在跑且空闲要被过问,没起不挡)
t "#60②:wd_loop 正常等待判定含 lane-c 条件(起了才算数),催办正文按行动燃料 ⛔ 空闲轨名" bash -c '
  body="$(sed -n "/^wd_loop()/,/^}/p" "$0")"
  grep -q "win_exists \"lane-c\" || lane_busy c" <<< "$body" || exit 1
  grep -q "行动燃料" <<< "$body" && ! grep -q "local idle=" <<< "$body"' "$LANE"
# ⭐ next-worktree 扩 C(零命中管道击穿绊线:B 有存量掩蔽,C 首用必然零命中——修前函数中途死,C 行根本打不出)
tout "#60②:next-worktree 给出 C 轨下一号(零命中 ⛔ 经 pipefail 击穿函数)" "C 轨下一可用" "$LANE" next-worktree
tout "#60②:next-worktree B 轨行照旧" "B 轨下一可用" "$LANE" next-worktree
# ⭐ cdp_port_lane c 落兜底段(9233 起),不撞 a/b/dispatch,低于 verify 段
C60P="$C60/port.sh"; sed -n "/^cdp_port_lane/,/^}/p" "$LANE" > "$C60P"
t "#60②:cdp_port_lane c 落 9233-9292 兜底段(不撞 9230/9231/9232,低于 9300)" bash -c '
  source "'"$C60P"'"; p="$(cdp_port_lane c)"
  [ "$p" -ge 9233 ] && [ "$p" -lt 9293 ]'
rm -rf "$C60"

echo "== 6z. #60① verify 引擎化(默认 codex;claude 路径原样保留) =="
# 引擎默认与回切(与 4b VERIFY_MODEL 同款 eval 单行赋值)
E60="$(bash -c "eval \"\$(grep '^VERIFY_ENGINE=' '$LANE')\"; echo \"\$VERIFY_ENGINE\"")"
tout "#60①:验收引擎默认 codex(创始人令:验收烧 GPT 额度不烧 Claude)" "codex" echo "$E60"
E60C="$(env LAIXIN_VERIFY_ENGINE=claude bash -c "eval \"\$(grep '^VERIFY_ENGINE=' '$LANE')\"; echo \"\$VERIFY_ENGINE\"")"
tout "#60①:引擎可回切 claude(备用路径保留)" "claude" echo "$E60C"
# ⭐ 未知引擎在**动窗口之前**被拒(破坏性动作前置校验,同 fresh --dir 一课)——拒后零 tmux 副作用
V60="$(mktemp -d)"; touch "$V60/r.md" "$V60/p.md"
tfail "#60①:未知引擎被拒且指明合法值" "只接受 codex|claude" \
  env LAIXIN_VERIFY_ENGINE=gpt5 LAIXIN_SESSION=lx60-nonexist "$LANE" verify 某片 --branch b --commit c --report "$V60/r.md" --prompt "$V60/p.md"
t "#60①:未知引擎被拒时零 tmux 副作用(⛔ 留下半个死会话)" bash -c '! tmux has-session -t lx60-nonexist 2>/dev/null'
# ⭐ claude 路径**原样保留**:起窗命令与 SendMessage 回执语仍在(谁把 claude 路径顺手删了,这条变红)
t "#60①:claude 起窗命令与 SendMessage 回执语原样保留" bash -c '
  body="$(sed -n "/^cmd_verify()/,/^}/p" "$0")"
  grep -q -- "--model \$VERIFY_MODEL --permission-mode auto" <<< "$body" || exit 1
  grep -q "SendMessage 回派工窗口" <<< "$body"' "$LANE"
# ⭐ codex 派单契约四要素:①开场第一句读验收卡单点源全文;②回执落盘路径+末行【验收回执】双分支;
#   ③红线明写(codex 无 disallowedTools 等价物);④合并侧校验兜底点名 merge-guard+evidence
t "#60①:codex 派单含验收卡单点源+回执落盘契约双分支" bash -c '
  body="$(sed -n "/^cmd_verify()/,/^}/p" "$0")"
  grep -q "/Users/pingxia/.codex/skills/laixin-acceptance/SKILL.md" <<< "$body" || exit 1
  grep -q -- "-验收回执.md" <<< "$body" || exit 1
  grep -q "【验收回执】通过" <<< "$body" && grep -q "【验收回执】打回" <<< "$body"' "$LANE"
t "#60①:codex 派单红线明写且点名合并侧兜底(⛔ 依赖不存在的工具层禁令)" bash -c '
  body="$(sed -n "/^cmd_verify()/,/^}/p" "$0")"
  grep -q "⛔ git push ⛔ git merge ⛔ git reset --hard ⛔ 动 lane" <<< "$body" || exit 1
  grep -q "merge-guard" <<< "$body" && grep -q "disallowedTools" <<< "$body"' "$LANE"
# ⭐ vwait_ready_codex 行为绊线(stub tmux+sleep,真跑判定逻辑;sleep 置空免 90s 真等)
V60F="$V60/fns.sh"
{ sed -n "/^pane_cmd()/,/^}/p" "$LANE"; sed -n "/^vwait_ready_codex()/,/^}/p" "$LANE"; } > "$V60F"
t "#60①:codex 就绪判据=OpenAI Codex 横幅(实测 0.147.0 画面)" bash -c '
  source "'"$V60F"'"; SESSION=s; sleep(){ :; }
  tmux(){ case "$1" in capture-pane) echo "│ >_ OpenAI Codex (v0.147.0) │";; display-message) echo node;; esac; }
  board(){ :; }; caller_src(){ echo t; }; die(){ echo "die: $*" >&2; exit 1; }
  vwait_ready_codex w'
t "#60①:Update 菜单安全键=Esc ⛔ Enter(默认项=全局升级,签名库硬规则)" bash -c '
  source "'"$V60F"'"; SESSION=s; sleep(){ :; }; LOG="'"$V60"'/keys.log"
  tmux(){ case "$1" in
    capture-pane) if [ -f "$LOG.esc" ]; then echo "OpenAI Codex"; else printf "✨ Update available! 0.147.0 -> 0.148.0\nPress enter to continue\n"; fi ;;
    send-keys) echo "$*" >> "$LOG"; case "$*" in *Escape*) : > "$LOG.esc" ;; esac ;;
    display-message) echo node ;; esac; }
  board(){ :; }; caller_src(){ echo t; }; die(){ echo "die: $*" >&2; exit 1; }
  vwait_ready_codex w || exit 1
  grep -q Escape "$LOG" && ! grep -q "C-m" "$LOG"'
t "#60①:pane 掉回 shell=秒退即死带现场(lane 验尸判据惯例,⛔ 哑等 90s)" bash -c '
  source "'"$V60F"'"; SESSION=s; SHELL=/bin/zsh; sleep(){ :; }
  tmux(){ case "$1" in capture-pane) echo "zsh: command not found: codex";; display-message) echo zsh;; list-windows) echo "w zsh";; esac; }
  board(){ :; }; caller_src(){ echo t; }; die(){ echo "die: $*" >&2; exit 1; }
  out="$(vwait_ready_codex w 2>&1)"; rc=$?
  [ $rc -ne 0 ] && grep -q "启动即退" <<< "$out" && grep -q "command not found" <<< "$out"'
t "#60①:始终未就绪走超时返 1(⛔ 假绿)" bash -c '
  source "'"$V60F"'"; SESSION=s; sleep(){ :; }
  tmux(){ case "$1" in capture-pane) echo "还在转圈";; display-message) echo node;; list-windows) echo "w node";; esac; }
  board(){ echo "board: $*"; }; caller_src(){ echo t; }; die(){ echo "die: $*" >&2; exit 1; }
  out="$(vwait_ready_codex w 2>&1)"; rc=$?
  [ $rc -eq 1 ] && grep -q "启动超时" <<< "$out"'
# ⭐ 回执监听=交付监听同机制(#60①):末行行首【验收回执】进扫描集合;无标记文件不进
V60K="$V60/kb/4-开发层/记录"; mkdir -p "$V60K"
printf 'x\n【交付完成】b z\n' > "$V60K/甲片-交付报告.md"
printf 'y\n【验收回执】通过 verify/b abc1234 def5678\n' > "$V60K/甲片-验收回执.md"
printf 'z\n没有标记\n' > "$V60K/乙片笔记.md"
V60S="$V60/scan.sh"; { sed -n "/^last_contract_line()/,/^}/p" "$LANE"; sed -n "/^ev_scan_deliveries()/,/^}/p" "$LANE"; } > "$V60S"
t "#60①:ev 扫描认【验收回执】末行(与【交付完成】同机制,⛔ 另起一套)" bash -c '
  set -eo pipefail; KB="'"$V60"'/kb"; source "'"$V60S"'"; out="$(ev_scan_deliveries)"
  grep -q "甲片-验收回执" <<< "$out" && grep -q "甲片-交付报告" <<< "$out" && ! grep -q "乙片笔记" <<< "$out"'
# ⭐ ev_loop 按末行分流文案:回执的下一步=核数字+合并 ⛔ 再 verify-from 一遍
t "#60①:ev_loop 对回执投「核数字+合并」⛔ 对它 verify-from" bash -c '
  body="$(sed -n "/^ev_loop()/,/^}/p" "$0")"
  grep -q "【验收回执】\*)" <<< "$body" || exit 1
  grep -q "验收回执落盘" <<< "$body" && grep -q "verify-from" <<< "$body"' "$LANE"
# ⭐ 回执是事实:dispatch 不在时走 spool 暂存 ⛔ 丢弃;瞬时告警仍丢
V60D="$V60/dead"; mkdir -p "$V60D"
V60E="$V60/ev.sh"; sed -n "/^ev_deliver()/,/^}/p" "$LANE" > "$V60E"
t "#60①:dispatch 不在时回执 spool 暂存(事实 ⛔ 丢),告警仍丢" bash -c '
  source "'"$V60E"'"; EV_SPOOL="'"$V60D"'/spool"; EV_PENDING="'"$V60D"'/pending"
  dispatch_alive(){ return 1; }; ev_log(){ :; }
  ev_deliver 回执 "【事件】验收回执落盘:x"
  ev_deliver 告警 "【告警】某轨卡住"
  grep -q "验收回执落盘" "$EV_SPOOL" && ! grep -q "某轨卡住" "$EV_SPOOL"'
# ⭐ 回执 ⛔ 进 M1 认领台账——M1 销账判据=verify 窗口存在,而回执落盘时窗口恰好还在,一登记即误销账
t "#60①:M1 登记仍只收交付(回执进台账=立即被误销账)" bash -c \
  'sed -n "/^ev_deliver()/,/^}/p" "$0" | grep -q "if \[ \"\$kind\" = \"交付\" \]"' "$LANE"
# ⭐ doctor §6 引擎适配:codex 报引擎行(VERIFY_MODEL 不适用),claude 旧文案逐字保留(#27 自述同步族)
# 🔴 引擎类断言必须**把两个引擎变量都钉死**(2026-08-22 实撞,创始人窗口修):这两条原先只钉
#   VERIFY_ENGINE,DISPATCH_ENGINE 落回读 ~/.laixin-lane-switch/dispatch-engine ⇒ **本机开关一改,
#   测试就红**,而红的原因与被测行为无关。当日派工席切 codex 后立即复现:doctor 输出正确、断言却红。
#   这与「一套会因机器忙而变红的测试比没有测试更糟」同族——判据必须只依赖被测对象,⛔ 依赖本机可变状态。
tout "#60①:doctor 引擎=codex 报引擎行 ⛔ 旧文案误导" "验收引擎:codex" \
  env LAIXIN_VERIFY_ENGINE=codex LAIXIN_DISPATCH_ENGINE=claude "$LANE" doctor
tout "#60①:doctor 引擎=claude 旧文案逐字保留" "验收窗口钉:claude-opus-5  派工窗口钉" \
  env LAIXIN_VERIFY_ENGINE=claude LAIXIN_DISPATCH_ENGINE=claude "$LANE" doctor
# ⭐ outside_sessions 改 tty 精确配对:codex 验收窗 pane 同为 node 但不产 cc-sock,按窗口数减会把
#   计数减成负、且恰在真有第二个手开 claude 时把它减没(失效指向要防的风险,三约束②)
OS60="$V60/socks-empty"; mkdir -p "$OS60"
V60O="$V60/os.sh"; { grep '^CC_SOCKS_DIR=' "$LANE"; sed -n "/^outside_sessions()/,/^}/p" "$LANE"; } > "$V60O"
t "#60①:outside_sessions 空 sock 报 0 ⛔ 负数(tty 配对 ⛔ 按窗口数减)" bash -c '
  LAIXIN_CC_SOCKS="'"$OS60"'"; SESSION=laixin; source "'"$V60O"'"
  [ "$(outside_sessions)" = "0" ]'
rm -rf "$V60"

# ── 循环判活探针(2026-08-19 换:pgrep -f → ps 认解释器行)──────────────────────────────
# 🔴 换因:#71 把 RELAY_DENY 由 8 扩到 21 项,写进 relay 命令行的 `Bash(laixin-lane wd-loop*)`
#   成了别处探针的被搜对象 ⇒ 原 pgrep 在 relay 活着时**恒真**。后果两层:①看门狗死了
#   doctor/status 照样报绿(复盘页 #20⑤ 假绿原样重现,走全新路径);②`cmd_watchdog start`
#   首行 `wd_alive && die` ⇒ **看门狗一停就再也起不来**。三方独立读数判死(11B/dispatch 命中
#   relay pid;relay 自测"没复现"系假阴性——它看不见自己)。
VLA="$(mktemp -d)"; VLAF="$VLA/fn.sh"
sed -n "/^loop_alive_filter()/,/^}/p" "$LANE" > "$VLAF"
t "判活:真循环行必中(/bin/bash …/laixin-lane wd-loop)" bash -c '
  source "'"$VLAF"'"; printf "/bin/bash /Users/x/.local/bin/laixin-lane wd-loop\n" | loop_alive_filter wd-loop'
t "判活:relay 的 deny 形态 Bash(laixin-lane wd-loop*) 必不中(#71 污染)" bash -c '
  source "'"$VLAF"'"; ! printf "/x/claude-raw --disallowedTools Bash(laixin-lane wd-loop*) Bash(git push*)\n" | loop_alive_filter wd-loop'
t "判活:ev 与 wd 不串味" bash -c '
  source "'"$VLAF"'"; ! printf "/bin/bash /x/laixin-lane ev-loop\n" | loop_alive_filter wd-loop'
t "判活:grep 自身命令行不自匹配(前缀 (^|/)bash 即防线)" bash -c '
  source "'"$VLAF"'"; ! printf "grep -qE (^|/)bash[^:]*laixin-lane wd-loop( |$)\n" | loop_alive_filter wd-loop'
# loop_alive_filter 的小输入断言覆盖不了 pipefail × grep -q 的 SIGPIPE 病灶：真实 ps 输出足够大时，
# 匹配越早，上游越会在 grep 提前退出后继续写并以 141 结束。用大流 ps 桩固定复现，且正反向都测。
t "判活:大流上游下 ev/wd 各连续 10 次认活(pipefail)" bash -c '
  set -o pipefail
  source "'"$VLAF"'"
  ps(){
    awk "BEGIN {
      print \"/bin/bash /Users/x/.local/bin/laixin-lane ev-loop\"
      print \"/bin/bash /Users/x/.local/bin/laixin-lane wd-loop\"
      for (i=0; i<20000; i++) print \"python filler-process-\" i
    }"
  }
  i=0
  while [ "$i" -lt 10 ]; do
    ev_alive || exit 1
    wd_alive || exit 1
    i=$((i+1))
  done'
t "判活:大流上游无循环时 ev/wd 都判死(防恒真)" bash -c '
  set -o pipefail
  source "'"$VLAF"'"
  ps(){ awk "BEGIN { for (i=0; i<20000; i++) print \"python filler-process-\" i }"; }
  ! ev_alive && ! wd_alive'
t "pipefail:merged 大串不经管道喂 grep -q(探针先过阳性)" bash -c '
  pat="printf .*[$]merged.*[|][[:space:]]*grep -q"
  known="printf x \"\$merged\" | grep -q x"
  [ "$(grep -Ec "$pat" <<< "$known")" -eq 1 ] || exit 2
  ! grep -E "$pat" "$1" >/dev/null' _ "$LANE"
tout "判活:文案⛔ 写死探针实现(实现换了文案会骗人)" "ps 认解释器行" bash -c '
  grep "事件总线已在跑" "'"$LANE"'"'
rm -rf "$VLA"
# 🔴 杀进程半边与判活半边必须同判据(2026-08-19 晚,方案窗口第十四任):判活换了解释器行,events stop 仍
#   pkill -f 宽模式 ⇒ relay(deny 形态含该串)被当作 ev-loop 杀掉 ⇒ 看门狗再把它重生——中继 10 次重生真凶。
t "停事件总线:⛔ pkill -f 宽模式(会杀 relay;只核代码行,注释里留案底)" bash -c '! grep -vE "^[[:space:]]*#" "'"$LANE"'" | grep -q "pkill -f \"laixin-lane ev-loop\""'
t "停事件总线:改走 loop_pids ev-loop(与判活同判据)" bash -c 'grep -q "loop_pids ev-loop" "'"$LANE"'"'
VLP="$(mktemp -d)"; VLPF="$VLP/fn.sh"
sed -n "/^loop_alive_filter()/,/^}/p" "$LANE" > "$VLPF"; sed -n "/^loop_pids()/,/^}/p" "$LANE" >> "$VLPF"
t "loop_pids:真循环出 pid、deny 形态不出(ps 桩)" bash -c '
  source "'"$VLPF"'"; ps(){ printf "%s\n" "101 /bin/bash /x/laixin-lane ev-loop" "202 /x/claude-raw --disallowedTools Bash(laixin-lane ev-loop*)" "303 /bin/bash /x/laixin-lane wd-loop"; }
  [ "$(loop_pids ev-loop | tr "\n" " ")" = "101 " ]'
rm -rf "$VLP"

# ── #105-#108(复盘页 §十六,2026-08-20 创始人直令实现):四条判据函数纯化直测 ──
V16="$(mktemp -d)"; V16F="$V16/fn.sh"
grep -E '^PH_TIME_RE=' "$LANE" > "$V16F"
for fn in ph_time_hits ev_directive_filter ev_material_filter ev_prompt_mentions_materials ev_same_contract_mode handover_unpaired; do
  sed -n "/^${fn}()/,/^}/p" "$LANE" >> "$V16F"; done
t "#107 占位时刻:22:4x 命中" bash -c 'source "'"$V16F"'"; printf "%s" "创始人确认复工(22:4x,方案窗口问得)" | ph_time_hits | grep -q "22:4x"'
t "#107 占位时刻:23:xx 命中" bash -c 'source "'"$V16F"'"; printf "%s" "大约 23:xx 起" | ph_time_hits >/dev/null'
t "#107 占位时刻:真时刻 22:45 不命中" bash -c 'source "'"$V16F"'"; ! printf "%s" "22:45:03 实测" | ph_time_hits >/dev/null'
t "#107 占位时刻:十六进制 0x1f 不命中(无冒号)" bash -c 'source "'"$V16F"'"; ! printf "%s" "地址 0x1f 与 hex" | ph_time_hits >/dev/null'
# ── #160 两形态(2026-08-23 方案窗口第二十三任裁「升条」;转录带来源锚 ⇒ 提示级放行,自编占位照旧警)──
# 🔴 病灶级绊线:本组必须能区分「判定真的生效」与「python 侧炸了走 fallback」——**两者对自编样本输出完全同形**
#   (实撞:首版 try 缺 except 语法错,自编样本照样出 SELF,只有 QUOTED 样本露馅)⇒ 至少一条断言必须要求 QUOTED 出现。
V160="$(mktemp -d)"; V160F="$V160/fn.sh"
grep -E '^PH_TIME_RE=|^PH_SRC_ANCHOR_RE=|^PH_SRC_WHERE_RE=' "$LANE" > "$V160F"
for fn in ph_time_hits ph_time_two_forms; do sed -n "/^${fn}()/,/^}/p" "$LANE" >> "$V160F"; done
t "#160 自编占位 ⇒ SELF" bash -c 'source "'"$V160F"'"; out="$(printf "%s" "创始人确认复工(22:4x)" | ph_time_two_forms)"; grep -q "^SELF	22:4x" <<< "$out"'
t "#160 转录带锚(锚词+出处同行)⇒ QUOTED〔判定生效的唯一证据,⛔ 删〕" bash -c 'source "'"$V160F"'"; out="$(printf "%s" "创始人 00:4x 授权(此处系转录记忆档 [[11b-monitoring-recipe]] 原文)" | ph_time_two_forms)"; grep -q "^QUOTED	00:4x" <<< "$out"'
t "#160 只有锚词无出处 ⇒ 仍 SELF" bash -c 'source "'"$V160F"'"; out="$(printf "%s" "转录一下 22:4x 的事" | ph_time_two_forms)"; grep -q "^SELF" <<< "$out"'
t "#160 只有出处无锚词 ⇒ 仍 SELF" bash -c 'source "'"$V160F"'"; out="$(printf "%s" "看板 22:4x 那条" | ph_time_two_forms)"; grep -q "^SELF" <<< "$out"'
t "#160 跨行 ⛔ 免死金牌:他行有锚不救本行自编" bash -c 'source "'"$V160F"'"; out="$(printf "%s\n%s" "本节逐字转录自 [[某档]] 原文" "另一行自编 23:1x" | ph_time_two_forms)"; grep -q "^SELF	23:1x" <<< "$out" && ! grep -q "^QUOTED" <<< "$out"'
t "#160 单行内两态(真环境首火病灶:log 正文永远单行)⇒ 锚只救同小句 ⛔ 救整行" bash -c 'source "'"$V160F"'"; out="$(printf "%s" "据复盘页原文 00:4x;我这轮 23:1x 起" | ph_time_two_forms)"; grep -q "^SELF	23:1x" <<< "$out" && grep -q "^QUOTED	00:4x" <<< "$out"'
t "#160 小句级:锚与占位跨逗号分离 ⇒ 从严记 SELF" bash -c 'source "'"$V160F"'"; out="$(printf "%s" "本条逐字转录自 [[某档]],时刻 22:4x" | ph_time_two_forms)"; grep -q "^SELF" <<< "$out" && ! grep -q "^QUOTED" <<< "$out"'
t "#160 两态同现 ⇒ 两行各报" bash -c 'source "'"$V160F"'"; out="$(printf "%s\n%s" "据复盘页原文 00:4x" "我这里 23:1x" | ph_time_two_forms)"; grep -q "^SELF	23:1x" <<< "$out" && grep -q "^QUOTED	00:4x" <<< "$out"'
t "#160 零命中退 1(与 ph_time_hits 同约定)" bash -c 'source "'"$V160F"'"; ! printf "%s" "22:45:03 实测" | ph_time_two_forms >/dev/null'
t "#160 失效降级 ⛔ 反向:python3 不可用 ⇒ 转录样本也记 SELF(严格态)" bash -c 'source "'"$V160F"'"; python3(){ return 127; }; out="$(printf "%s" "转录 [[档]] 原文 00:4x" | ph_time_two_forms)"; grep -q "^SELF	00:4x" <<< "$out"'
t "#160三 样本:占位在行内代码内 ⇒ SAMPLE(元文本 ⛔ 被判据本身罚)" bash -c 'source "'"$V160F"'"; out="$(printf "%s" "我又撞了两次(看板 \`12:2x\` 与注册表 \`12:1x\`)" | ph_time_two_forms)"; grep -q "^SAMPLE	12:2x 12:1x" <<< "$out" && ! grep -q "^SELF" <<< "$out"'
t "#160三 裸占位不因同行有别的代码块而豁免" bash -c 'source "'"$V160F"'"; out="$(printf "%s" "样本 \`12:2x\`;我这轮 23:1x 起" | ph_time_two_forms)"; grep -q "^SELF	23:1x" <<< "$out" && grep -q "^SAMPLE	12:2x" <<< "$out"'
t "#160三 反引号 ⛔ 豁免真登记:提示语当场声明" bash -c 'grep -q "反引号 ⛔ 豁免真登记时刻" "'"$LANE"'"'
t "#160 接线:cmd_log 与 kb-commit 各挂一处 ph_time_two_forms" bash -c '[ "$(grep -c "ph_time_two_forms 2>/dev/null" "'"$LANE"'")" -ge 4 ]'
rm -rf "$V160"

# ── #161 --dry 射程缺口(2026-08-23 dispatch 59 实撞 relay-once + 11C 主持判「值得成规」;11B 归口枚举全族)──
# 病灶:dry 在同件硬拦截**之前** return ⇒ 对「这次会不会被拦」零分辨力,且默认叙述偏向「会起窗」=与真实行为相反。
# 🔴 双向自证按主持规格:**对已存在件跑 dry 应报拦截而非「会起窗」**;对不存在件仍报会起。
V161="$(mktemp -d)"; V161F="$V161/fn.sh"
sed -n "/^dry_win_clash()/,/^}/p" "$LANE" > "$V161F"
t "#161 dry_win_clash:窗已存在 ⇒ 报「会被 die 拦下」" bash -c 'source "'"$V161F"'"; SESSION=x; tmux(){ printf "%s\n" "relay-已存在件" "dispatch"; }; out="$(dry_win_clash "relay-已存在件")"; grep -q "会被 die 拦下" <<< "$out"'
t "#161 dry_win_clash:窗不存在 ⇒ 报「会新起」" bash -c 'source "'"$V161F"'"; SESSION=x; tmux(){ printf "%s\n" "dispatch"; }; out="$(dry_win_clash "relay-新件")"; grep -q "会新起" <<< "$out"'
# ⚠️ 本断言必须**剥掉注释行**再扫:首版直扫全段,被函数自己那句「⛔ ensure_session:dry 不许有副作用」的注释命中而假红
#   ——即八律第 8 律「讨论判据的文本会被判据本身命中」(同日 dispatch 59 在 #107 钩子上撞同族)。
#   二版又红:命中的是**函数首行的行尾注释**,`grep -v "^#"` 只剥整行注释 ⇒ 判据改为 `sed "s/#.*//"` 剥到行尾。
#   ⭐ 方向选择:本仓惯例**鼓励**注释里写出互指的函数名(双真相源互指注释),所以该适配的是判据 ⛔ 让人改措辞。
t "#161 dry_win_clash 只读:代码里 ⛔ 调 ensure_session(dry 不许有副作用;断言剥注释行)" bash -c '! sed -n "/^dry_win_clash()/,/^}/p" "'"$LANE"'" | sed "s/#.*//" | grep -q "ensure_session"'
t "#161 relay-once dry 段含同件拦截与覆盖范围声明" bash -c 'seg="$(sed -n "/^cmd_relay_once()/,/^}/p" "'"$LANE"'")"; grep -q "dry_win_clash" <<< "$seg" && grep -q "\[dry\] 覆盖范围" <<< "$seg"'
t "#161 m-up dry 段含同件拦截+端口撞车+覆盖范围" bash -c 'seg="$(sed -n "/^cmd_mup()/,/^}/p" "'"$LANE"'")"; grep -q "dry_win_clash" <<< "$seg" && grep -q "oneshot_port_clash" <<< "$seg" && grep -q "\[dry\] 覆盖范围" <<< "$seg"'
t "#161 chrome-up dry 段报端口是否已在听" bash -c 'seg="$(sed -n "/^cmd_chrome_up()/,/^}/p" "'"$LANE"'")"; grep -q "已有 CDP 在听" <<< "$seg" && grep -q "\[dry\] 覆盖范围" <<< "$seg"'
t "#161 verify-from 的 dry〔有意只警告 ⛔ 当缺口修〕:行为不动,只加声明" bash -c 'seg="$(sed -n "/^cmd_verify_from()/,/^}/p" "'"$LANE"'")"; grep -q "有意设计" <<< "$seg" && ! grep -q "dry_win_clash" <<< "$seg"'
t "#161 全族覆盖:五个带 --dry 的子命令段各有一行「[dry] 覆盖范围」" bash -c '
  n=0; for fn in cmd_relay_once cmd_mup cmd_chrome_up cmd_account_switch cmd_verify_from; do
    seg="$(sed -n "/^${fn}()/,/^}/p" "'"$LANE"'")"; grep -q "\[dry\] 覆盖范围" <<< "$seg" && n=$((n+1)); done
  [ "$n" -eq 5 ]'
rm -rf "$V161"
t "#106 直令过滤:方案窗口+创始人直令 命中" bash -c 'source "'"$V16F"'"; printf "%s\n" "| 08-20 07:00 | 方案窗口 | 创始人直令两条(date):原话逐字… |" | ev_directive_filter | grep -q 直令'
t "#106 直令过滤:在飞口径变更 命中" bash -c 'source "'"$V16F"'"; printf "%s\n" "| 08-20 07:01 | 方案窗口 | ⚠️ 在飞口径变更:推翻 X |" | ev_directive_filter >/dev/null'
t "#106 直令过滤:派工窗口来源不搬运" bash -c 'source "'"$V16F"'"; ! printf "%s\n" "| 08-20 07:02 | 派工窗口 | 转述创始人直令… |" | ev_directive_filter >/dev/null'
t "#106 直令过滤:句中的真口径变更必须搬运(⛔ 按位置收窄——漏真直令贵于多送指针)" bash -c 'source "'"$V16F"'"; printf "%s\\n" "| 08-20 07:15 | 方案窗口 | 裁(授权-2)b86 验收窗处置,并 ⚠️ 在飞口径变更:推翻 X |" | ev_directive_filter >/dev/null'
t "#106 直令过滤:方案窗口普通裁定不搬运" bash -c 'source "'"$V16F"'"; ! printf "%s\n" "| 08-20 07:03 | 方案窗口 | 裁(授权-2)普通一件 |" | ev_directive_filter >/dev/null'
t "#105 材料过滤:词汇表命中" bash -c 'source "'"$V16F"'"; printf "%s\n" "项目入口/来信平台/知识库/索引/wiki-供给侧词汇表.md" | ev_material_filter >/dev/null'
t "#105 材料过滤:设计要点命中" bash -c 'source "'"$V16F"'"; printf "%s\n" "项目入口/来信平台/知识库/4-开发层/来信平台-首页门户改版-设计要点.md" | ev_material_filter >/dev/null'
t "#105-fix2 材料过滤:新目录(3-方案层/前端设计)的设计要点命中——按文件名特征 ⛔ 绑目录前缀" bash -c 'source "'"$V16F"'"; printf "%s\n" "项目入口/来信平台/知识库/3-方案层/前端设计/来信平台-首页信息推演与重做-设计要点.md" | ev_material_filter >/dev/null'
t "#105-fix2 反向:同目录非材料文件不命中(特征匹配 ⛔ 目录放行)" bash -c 'source "'"$V16F"'"; ! printf "%s\n" "项目入口/来信平台/知识库/3-方案层/前端设计/来信平台-前端开源参照调研.md" | ev_material_filter >/dev/null'
t "#105 材料过滤:看板与执行总表不命中(⛔ 全 vault 广播)" bash -c 'source "'"$V16F"'"; ! printf "%s\n%s\n" "项目入口/来信平台/知识库/4-开发层/来信平台-流水线看板.md" "项目入口/来信平台/知识库/4-开发层/来信平台-执行总表.md" | ev_material_filter >/dev/null'
printf '本片依赖 [[wiki-供给侧词汇表]]。\n' > "$V16/prompt.md"
t "#105 降噪:只给真正引用材料的 prompt 命中(按文件名/去后缀锚)" bash -c 'source "'"$V16F"'"; printf "%s\n" "项目入口/来信平台/知识库/索引/wiki-供给侧词汇表.md" | ev_prompt_mentions_materials "'"$V16"'/prompt.md"'
t "#105 降噪:无引用的材料不命中" bash -c 'source "'"$V16F"'"; ! printf "%s\n" "项目入口/来信平台/知识库/索引/wiki-消费者词汇表.md" | ev_prompt_mentions_materials "'"$V16"'/prompt.md"'
t "#105 降噪接线:材料先合批,再按在飞 prompt 算目标;⛔ 每个 vault commit 立即全广播" bash -c '
  e="$(sed -n "/^ev_loop()/,/^}$/p" "'"$LANE"'")"
  grep -q "EV_MATERIAL_DEBOUNCE" <<< "$e" && grep -q "ev_material_targets" <<< "$e" && grep -q "材料合批" <<< "$e"'
t "同契约正文更新:交付报告静默;验收回执仍通知(回执正文可能改结论)" bash -c '
  source "'"$V16F"'"
  [ "$(ev_same_contract_mode "【交付完成】片 abc1234")" = quiet ] && [ "$(ev_same_contract_mode "【验收回执】通过 x")" = notify ]'
cat > "$V16/board" <<'BEOF'
| 08-20 03:27 | 方案窗口 | 方案窗口第十四任 pingxia-fb 交班(六步…) |
| 08-19 19:17 | 中继窗口 | 收班完成 中继窗口 relay 第五任(…) |
| 08-20 05:22 | 派工窗口 | 交班 dispatch 第三十九任 → 第四十任 |
BEOF
cat > "$V16/page" <<'PEOF'
## 十四、中继窗口 relay 第五任收班盘点(2026-08-19)
## 十六、方案窗口第十四任 pingxia-fb 收班盘点(2026-08-20)
## 十七、派工窗口 dispatch 第三十九任收班盘点(2026-08-20)
PEOF
t "#108 配对:两窗口盘点齐全零输出" bash -c 'source "'"$V16F"'"; [ -z "$(handover_unpaired "'"$V16"'/board" "'"$V16"'/page")" ]'
t "#108 配对:删掉方案窗口盘点节即报其名" bash -c 'source "'"$V16F"'"; grep -v 方案窗口 "'"$V16"'/page" > "'"$V16"'/page2"; handover_unpaired "'"$V16"'/board" "'"$V16"'/page2" | grep -q "方案窗口第十四任"'
# ⚖️ 射程反转(2026-08-22,创始人直令「每班遇到的问题都要对 11B、11C 做生产级优化」;三个常驻窗口
#   =dispatch/relay/方案窗口,都要做第 6 步)。原断言是「dispatch 不在射程」,理由=其交接包在执行总表;
#   那是**判据错误**:交接包(受众=继任,载体=执行总表)≠ 收班盘点(受众=11B/11C,载体=复盘页),
#   「写在别处」推不出「不需要」。且实践早已越界——复盘页 §十九 就是 dispatch 第四十二任的盘点节。
t "#108 配对:dispatch 在射程(删掉其盘点节即报其任次)" bash -c 'source "'"$V16F"'"; grep -v dispatch "'"$V16"'/page" > "'"$V16"'/page3"; handover_unpaired "'"$V16"'/board" "'"$V16"'/page3" | grep -q "dispatch 第三十九任"'
# 🔴 本函数对输入**读两遍**(方案/中继一遍、dispatch 一遍)⇒ 传 /dev/stdin 时第二遍读空,
#   而症状=「dispatch 一条都不报」,**与射程里根本没有 dispatch 的旧行为一模一样**,肉眼查不出。
#   2026-08-22 实撞:同一份看板,传文件 27 条、经管道只剩 7 条。
t "#108-fix2 经管道传 /dev/stdin 结果必须与传文件一致(⛔ 第二遍读空)" bash -c 'source "'"$V16F"'"; a="$(handover_unpaired "'"$V16"'/board" "'"$V16"'/page3" | wc -l)"; b="$(cat "'"$V16"'/board" | handover_unpaired /dev/stdin "'"$V16"'/page3" | wc -l)"; [ "$a" = "$b" ] && [ "$a" != "0" ]'
t "#106 接线:ev_loop 含直令搬运游标" bash -c 'grep -q "EV_BOARD_POS" "'"$LANE"'" && grep -q "ev_directive_filter | while" "'"$LANE"'"'
t "#105 接线:ev_loop 含 vault HEAD 基线" bash -c 'grep -q "EV_VAULT_HEAD" "'"$LANE"'" && grep -q "ev_material_filter | sort -u" "'"$LANE"'"'
t "#107 接线:cmd_log 与 kb-commit 各挂一处 ph_time_hits" bash -c '[ "$(grep -c "ph_time_hits 2>/dev/null" "'"$LANE"'")" -ge 2 ]'
t "#108 接线:doctor 第 8 节存在" bash -c 'grep -q "== 8. 交班配对" "'"$LANE"'"'
# 🔴 doctor 必须**跑到最后一行**:`[ ... ] && printf` 这种独立语句在 set -e 下条件为假即返回 1,
#   会把 doctor 杀在半途,而症状是「某节整节空输出、后续节消失」——看起来像那节没检查项,
#   不像崩了(2026-08-22 第 8 节实撞)。⇒ 钉住结尾行必现,这条能防整族「doctor 半途退出」。
tout "doctor 必须跑完(set -e 半途退出=末节与体检结果行一起消失,看着像没检查项)" "体检结果" \
  env LAIXIN_USAGE_API=http://127.0.0.1:1/nope "$LANE" doctor
V16F2="$(mktemp)"; cp "$V16F" "$V16F2"
# #105 端到端:真 git 仓 + 中文路径 + 默认 quotePath——跑生产同款管道,防「fixture 全绿真环境必不命中」重演
V105="$(mktemp -d)"; ( cd "$V105" && git init -q . && mkdir -p 索引 && echo a > 索引/wiki-测试词汇表.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm base && echo b >> 索引/wiki-测试词汇表.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm change )
t "#105 E2E:中文路径经 quotePath=false 管道命中" bash -c 'source "'"$V16F2"'"; git -C "'"$V105"'" -c core.quotePath=false log --name-only --format= HEAD~1..HEAD | ev_material_filter | grep -q 词汇表'
t "#130 席位活性:在班无会话=报(受控真火形态)" bash -c 'awk "/^seat_liveness\\(\\)\\{/,/^}/" "'"$LANE"'" > /tmp/lx-sl-fn.sh; source /tmp/lx-sl-fn.sh; printf "%s\n" "| **测试席位甲** | **\`pingxia-zz\`**(**第一任在班**) | — | 任 | 时 | 人 |" > /tmp/lx-sl-reg.md; seat_liveness /tmp/lx-sl-reg.md | grep -q "pingxia-zz"'
t "#130 席位活性:待接/看门狗托管不报(⛔ 交接期与 tmux 内误报)" bash -c 'source /tmp/lx-sl-fn.sh; printf "%s\n%s\n" "| **席位丙** | **待接**(\`pingxia-yy\` 已交班) | — | 任 | 时 | 人 |" "| **席位丁** | \`dwin\`(tmux 内,看门狗托管;**在班**) | — | 任 | 时 | 人 |" > /tmp/lx-sl-reg.md; [ -z "$(seat_liveness /tmp/lx-sl-reg.md)" ]'
t "#130 席位活性:首版 awk 分列假阴性已钉死(cell 必须取到第 3 竖列)" bash -c 'grep -q "cut -d.|. -f3" "'"$LANE"'" && ! grep -qE "awk -F. \\\\\| . .\{print .2\}" "'"$LANE"'"'
# ── #130-tmux 直测半边(2026-08-23 监测实撞:dispatch-11c 两局之间合法待命 >45 分钟,心跳启发式 19:16 假阳性)──
t "#130 tmux 内活窗(pane 非 shell)⇒ 直测判活不报〔应召机务窗形态〕" bash -c '
  awk "/^seat_liveness\\(\\)\\{/,/^}/" "'"$LANE"'" > /tmp/lx-sl2-fn.sh; source /tmp/lx-sl2-fn.sh
  tmux kill-session -t lxslt-$$ 2>/dev/null
  tmux new-session -d -s lxslt-$$ -n live-seat-zz -x 40 -y 8 "sleep 25"   # -n 显式命名=tmux 自动关 automatic-rename(rename-window 会被自动改名顶回)
  sleep 1   # 等 tmux 已从登录 shell 切到目标进程，⛔ 把启动瞬间误判为死席
  printf "%s\\n" "| **测试机务窗** | **\`live-seat-zz\`**(**在班**) | — | 任 | 时 | 人 |" > /tmp/lx-sl2-reg.md
  out="$(LAIXIN_SEATLIVE_TMUX_SESSIONS=lxslt-$$ seat_liveness /tmp/lx-sl2-reg.md)"
  tmux kill-session -t lxslt-$$ 2>/dev/null
  [ -z "$out" ]'
t "#130 tmux 无此窗 ⇒ 仍走心跳判如实报(失效可见性不降)" bash -c '
  source /tmp/lx-sl2-fn.sh
  printf "%s\\n" "| **幽灵席** | **\`no-such-win-zz\`**(**在班**) | — | 任 | 时 | 人 |" > /tmp/lx-sl2-reg.md
  out="$(LAIXIN_SEATLIVE_TMUX_SESSIONS=lxslt-none-$$ seat_liveness /tmp/lx-sl2-reg.md)"
  rm -f /tmp/lx-sl2-fn.sh /tmp/lx-sl2-reg.md
  grep -q "no-such-win-zz" <<< "$out"'

# ── #130-tmux 外活席:空闲不等于崩；procStart 对 ps lstart 防 PID 复用 ──
T130E="$(mktemp -d)"
sed -n "/^seat_liveness()/,/^}/p" "$LANE" > "$T130E/sl.sh"
mkdir -p "$T130E/home/.claude-test/sessions" "$T130E/socks"
sleep 900 & T130E_LIVE=$!
sleep 900 & T130E_REUSED=$!
T130E_START="$(LC_ALL=C ps -o lstart= -p "$T130E_LIVE" | sed 's/^ *//; s/  *$//')"
T130E_EPOCH="$(LC_ALL=C date -j -f '%a %b %e %T %Y' "$T130E_START" +%s)"
T130E_PROC_START="$(TZ=UTC LC_ALL=C date -r "$T130E_EPOCH" '+%a %b %e %T %Y')"
T130E_DEAD=999999
while kill -0 "$T130E_DEAD" 2>/dev/null; do T130E_DEAD=$((T130E_DEAD+1)); done
printf '{"name":"seatlive-live","updatedAt":0,"procStart":"%s"}\n' "$T130E_PROC_START" > "$T130E/home/.claude-test/sessions/$T130E_LIVE.json"
printf '{"name":"seatlive-reused","updatedAt":0,"procStart":"Thu Jan  1 00:00:00 1970"}\n' > "$T130E/home/.claude-test/sessions/$T130E_REUSED.json"
printf '{"name":"seatlive-dead","updatedAt":0,"procStart":"Thu Jan  1 00:00:00 1970"}\n' > "$T130E/home/.claude-test/sessions/$T130E_DEAD.json"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$T130E/socks/$T130E_LIVE.sock"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$T130E/socks/$T130E_REUSED.sock"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$T130E/socks/$T130E_DEAD.sock"
printf '| **活席** | **`seatlive-live`**(**在班**) | — | 任 | 时 | 人 |\n' > "$T130E/live.md"
printf '| **复用席** | **`seatlive-reused`**(**在班**) | — | 任 | 时 | 人 |\n' > "$T130E/reused.md"
printf '| **死席** | **`seatlive-dead`**(**在班**) | — | 任 | 时 | 人 |\n' > "$T130E/dead.md"
t "#130 tmux 外活席:socket+同一进程活而心跳过期 ⇒ 不报" env HOME="$T130E/home" LAIXIN_CC_SESS="$T130E/home/.claude-test/sessions" LAIXIN_CC_SOCKS="$T130E/socks" LAIXIN_SEATLIVE_TMUX_SESSIONS=seatlive-none bash -c '
  source "$1/sl.sh"; out="$(seat_liveness "$1/live.md")"; [ -z "$out" ]' _ "$T130E"
t "#130 tmux 外 PID 复用:socket+别的活进程 ⇒ 仍报" env HOME="$T130E/home" LAIXIN_CC_SESS="$T130E/home/.claude-test/sessions" LAIXIN_CC_SOCKS="$T130E/socks" LAIXIN_SEATLIVE_TMUX_SESSIONS=seatlive-none bash -c '
  source "$1/sl.sh"; out="$(seat_liveness "$1/reused.md")"; grep -q "seatlive-reused" <<< "$out"' _ "$T130E"
t "#130 tmux 外真死席:socket+死 PID ⇒ 仍报" env HOME="$T130E/home" LAIXIN_CC_SESS="$T130E/home/.claude-test/sessions" LAIXIN_CC_SOCKS="$T130E/socks" LAIXIN_SEATLIVE_TMUX_SESSIONS=seatlive-none bash -c '
  source "$1/sl.sh"; out="$(seat_liveness "$1/dead.md")"; grep -q "seatlive-dead" <<< "$out"' _ "$T130E"
kill "$T130E_LIVE" "$T130E_REUSED" 2>/dev/null || true
rm -rf "$T130E"

t "#108-fix 提及型不误报:窗口条目里提及他窗口交班的句子不算交班条" bash -c 'source /tmp/lx-hb-fn.sh 2>/dev/null || awk "/^handover_unpaired\\(\\)\\{/,/^}/" "'"$LANE"'" > /tmp/lx-hb-fn.sh && source /tmp/lx-hb-fn.sh; printf "%s\n" "| 08-20 10:40 | 方案窗口 | dispatch 41 交班三件处置:①CDP skill 片 |" "| 08-20 11:15 | 方案窗口 | 收口读数入账 方案窗口第十五任真正收摊,第十六任在班 |" > /tmp/lx-hb-b.md; printf "## 占位\n" > /tmp/lx-hb-p.md; [ -z "$(handover_unpaired /tmp/lx-hb-b.md /tmp/lx-hb-p.md)" ]'
t "#108-fix 真交班条仍报:正文开头形态命中" bash -c 'source /tmp/lx-hb-fn.sh; printf "%s\n" "| 08-20 10:58 | 方案窗口 | 方案窗口第十五任 pingxia-8a 交班(date 10:58 实测封班) |" > /tmp/lx-hb-b.md; printf "## 占位\n" > /tmp/lx-hb-p.md; handover_unpaired /tmp/lx-hb-b.md /tmp/lx-hb-p.md | grep -q 第十五任'
t "#105 E2E 反向:不带该开关即不命中(绊线钉住开关不许丢)" bash -c 'source "'"$V16F2"'"; ! git -C "'"$V105"'" log --name-only --format= HEAD~1..HEAD | ev_material_filter >/dev/null'
t "#105 接线:生产调用带 quotePath=false" bash -c 'grep -qF -- "quotePath=false log --name-only" "'"$LANE"'"'
rm -rf "$V105"
rm -rf "$V16" "$V16F2"
# ── 验收窗口走查通道的交接(2026-08-22 反向裁定,撤回同日 902033d 的起窗探活告警)──────
# 902033d 在起窗当口探 CDP 端口、不通即上看板 ⚠️。**实测推翻**:端口无监听在起窗那一刻是
# **设计常态而非故障**——lane-a/lane-b/dispatch 三个正在正常干活的窗口,端口(9231/9232/9230)
# 全部无监听。注入的是「通道」不是「浏览器」,浏览器由使用方需要走查时自己起、用完自己关
# (创始人 2026-08-17「每窗一通道」+「用完要关」)。⇒ 那条告警两重错:①**恒真噪音**(起窗那刻
# 必然无监听,每起一窗刷一条 ⚠️,与真故障不可分辨);②**用机器复现了已记录在案的失败样本**
# ——lane-b 正是把「预留端口无监听」读成「环境坏了/要外部给浏览器」而停车 15 分钟(2026-08-18
# 实撞,开发轨 prompt 第 43 条逐字立此口径:「端口无人监听是你还没起,不是环境坏了」)。
# 🔑 真缺口在**交接**不在探活:白名单放行 Bash(browser-harness*)=设计意图就是验收方自己走查,
#    而派单消息的硬要求里一个字没提 CDP/浏览器(开发轨 prompt 有 17 行详述)⇒ 验收方拿到变量却
#    不知道浏览器要自己起,看到端口不通就报「变量像是没注入」(13:25 实撞的真因;现象与真因
#    指向两个方向,正是因为它手里缺这一段)。
# ⚠️ 判据必须 grep -v 掉注释行:本节与 cmd_verify 的新注释都逐字引用了被禁的串(⛔ 自匹配)。
t "验收起窗:⛔ 探 CDP 端口报「无监听」(恒真噪音+复现 lane-b 停车 15 分钟那个失败样本)" \
  bash -c '! sed -n "/^cmd_verify()/,/^}/p" "'"$LANE"'" | grep -v "^[[:space:]]*#" | grep -q "无监听"'
t "验收派单:两引擎版本都带走查通道段(⛔ 只补 claude 版——codex 验收窗同样拿得到通道)" \
  bash -c '[ "$(sed -n "/^cmd_verify()/,/^}/p" "'"$LANE"'" | grep -c "走查通道:注入给你的是")" = 2 ]'
# 🔑 下面两条验的是**真实产物**不是源码字面:msg 的 heredoc 是 <<EOF 不带引号,少一个反斜杠,
#    发给验收方的就是**空串**——它 echo $BU_CDP_URL 得到空,正好回到 13:25「变量未注入」那个误判。
#    源码里 grep "\$BU_CDP_URL" 对这种漏法完全无感(源码看着好好的),只有展开一次才看得见。
VCDP="$(mktemp -d)"
# ⚠️ 先圈定 cmd_verify 函数体再抽第一个 msg heredoc(2026-08-22 实撞:relay-once 插在 cmd_verify 之前且同形 heredoc,
#   按「全文件第一个」抽就抽到别的函数的派单,三条断言齐红而被测内容没变——范围锚必须是被测对象本身)。
sed -n "/^cmd_verify()/,/^}/p" "$LANE" | awk '/^  msg="\$\(cat <<EOF$/{n++} n==1{print} n==1 && /^EOF$/{exit}' > "$VCDP/body"
# ⚠️ 抽取终点取 EOF 会漏掉收尾的 `)"` ⇒ 落盘脚本语法错、跑不出东西而症状像「断言写错了」
#   (本仓 sed 范围终点取早了那一课的同族,当轮自撞)——补回收尾行。⛔ source <(…):fd 竞态。
{ echo '#!/bin/bash'
  echo 'slice=S; prompt=P; branch=B; commit=C; report=R; evid=E; to=T; receipt=RC'
  cat "$VCDP/body"; echo ')"'; echo 'printf "%s\n" "$msg"'
} > "$VCDP/run.sh"
bash "$VCDP/run.sh" > "$VCDP/out.txt" 2>&1
t "验收派单展开后:BU_CDP_URL 是**字面变量名**(⛔ 被 heredoc 吃成空串=「变量未注入」误判的来源)" \
  grep -qF -- '$BU_CDP_URL' "$VCDP/out.txt"
t "验收派单展开后:起浏览器命令的端口取值式完整(⛔ 少个反斜杠就成空口)" \
  grep -qF -- '${BU_CDP_URL##*:}' "$VCDP/out.txt"
t "验收派单展开后:带「用完必关」的回收命令(创始人 2026-08-17;⛔ 只教起不教关=留孤儿占通道)" \
  grep -qF -- 'pkill -f -- "--remote-debugging-port=$PORT"' "$VCDP/out.txt"
rm -rf "$VCDP"
# ── vmsg:给在跑的验收窗口补发工具侧信息(2026-08-22 立)────────────────────────────
# 起因:当日 C6/A1A2 两个验收窗口在工具换代前一两分钟起窗,手里缺「走查通道」段而两片都要走查
# ⇒ 眼看要重演 13:25 的误判。补发时才发现**给验收窗口补发信息根本没有正规通道**——
# dispatch 历来只能手工 tmux send-keys(无留痕、无防污染)。
# ⚠️ 本节只测**校验失败路径**(都在碰 tmux 之前 die)与源码判据 —— 套件红线:⛔ 碰 tmux 窗口。
tfail "vmsg:缺片名即拒" "vmsg 需要片名" bash -c '"'"$LANE"'" vmsg'
tfail "vmsg:缺 --from 即拒(匿名注入验收窗口=事后无从追责)" "匿名注入" \
  bash -c '"'"$LANE"'" vmsg 某片 "正文"'
tfail "vmsg:缺正文即拒" "vmsg 需要正文" bash -c '"'"$LANE"'" vmsg 某片 --from 创始人窗口'
tfail "vmsg:只发给在跑的窗口(⛔ 静默投空)" "不在跑" \
  bash -c '"'"$LANE"'" vmsg 查无此片 --from 创始人窗口 "正文"'
# 🔑 vmsg 开了一条能绕过 cmd_verify「交接只传客观信息 ⛔ 任何预期暗示」原则的路,所以防御必须
#   在抬头里,且**把污染检测交给收方**——⛔ 指望发方自律,发方正是污染源。三条回退即红。
t "vmsg:抬头把污染检测交给收方(⛔ 只写「请勿暗示」指望发方自律)" \
  bash -c 'sed -n "/^cmd_vmsg()/,/^}/p" "'"$LANE"'" | grep -q "忽略,并在回执里"   # 2026-08-23 固定段改形后措辞变、意不变(收方检测)'
t "vmsg:片名经 vwin 转义(#130:未转义会静默作用到别的窗口)" \
  bash -c 'sed -n "/^cmd_vmsg()/,/^}/p" "'"$LANE"'" | grep -qF "vwin \"\$slice\""'
t "vmsg:上看板留痕(⛔ 无痕注入验收窗口)" \
  bash -c 'sed -n "/^cmd_vmsg()/,/^}/p" "'"$LANE"'" | grep -qF "board \"\$from\""'
# ── ctx 监控:**已停用**,并钉住不许重造(2026-08-22 当天上线当天撤)──────────────
# 🔴 整套机制建立在一个错误前提上:「上下文满了必须换人」是 **claude 席位**的模型,
#   而 dispatch / lane-a / lane-b 全是 **codex**,codex 自带翻页。二进制内原文:
#   "Your context window is nearly exhausted ... will be **automatically reset** for you soon.
#    Once reset, message items in current context window will be cleared in the new window,
#    but **notes and history items will be persistent across windows**."
#   auto_compact_token_limit 与 context_window 并列在 model catalog 里 = 内置默认行为,非可选。
# 实证(同一会话 id 全程未变):dispatch 15-19-18 第 49 次请求 222,994(86.3%),第 50 次归零
#   自行翻页,之后继续干活未换人;lane-b 15-25-31 同样 82.3% → 17.1%。
# 代价:dispatch 本可一任连干三个半小时(11:25→14:55),被这套机制催后 15 分钟连换四任
#   (14:55:41 / 14:58:33 / 15:13:56 / 15:19:18),把正常运转的流水线打断。
# ⇒ 巡检已从 wd_loop 摘除;ctx_watch_tick 函数保留但不再被调用(留说明给后人);
#   ctx-all 保留,但只描述填充度。下面三条钉住这个结论——「给 codex 加个 ctx 监控」
#   听起来天经地义,下一个人极可能重造它。要恢复,先回答:codex 自动翻页之后,
#   人工换班还解决什么问题?
t "ctx:巡检 ⛔ 挂回看门狗循环(codex 自带翻页,填充度高不是需要人处置的状态)" \
  bash -c '! sed -n "/^wd_loop()/,/^}/p" "'"$LANE"'" | grep -v "^[[:space:]]*#" | grep -q "ctx_watch_tick"'
t "ctx:ctx-all ⛔ 出现催人换班的祈使句(它只描述离自动翻页多远)" \
  bash -c '! sed -n "/^cmd_ctx_all()/,/^}/p" "'"$LANE"'" | grep -v "^[[:space:]]*#" | grep -qE "立刻写状态|就交班|别开新调查"'
t "ctx:ctx-all 必须留下「codex 自行翻页」的结论(⛔ 只删措辞不留因由——后人会重造)" \
  bash -c 'sed -n "/^cmd_ctx_all()/,/^}/p" "'"$LANE"'" | grep -qF "自行 reset"'
t "ctx:ctx_watch_tick 函数保留但 ⛔ 被任何地方调用(留作说明,⛔ 留作可随手接回的开关)" \
  bash -c 'grep -qF "ctx_watch_tick()" "'"$LANE"'" && [ "$(grep -v "^[[:space:]]*#" "'"$LANE"'" | grep -c "ctx_watch_tick")" = 1 ]'
# ⭐ 2026-08-22 16:43 dispatch 换回并锁定 claude 后,wd_loop 0.7 段必须**写明「引擎换回不是恢复巡检的理由」**——
#   否则下一任读到「撤因=dispatch 是 codex」会顺手把巡检接回去(引擎换了、纪律跟着换错方向,是同一族失效)。
t "ctx:wd_loop 0.7 段已写明 dispatch 换回 claude 后仍不恢复巡检(statusline 65/75 已在当事人眼前)" \
  bash -c 'sed -n "/^wd_loop()/,/^}/p" "'"$LANE"'" | grep -qF "引擎换回不是恢复巡检的理由"'
# ⭐ AGENTS.md「双真相源」条的机器化(立规先问机器化):contrib-statusline.py 的闸门线与 cmd_ctx claude 分支必须同步。
#   2026-08-22 实撞:bash 侧 07f59d2 上调 65/75,contrib 副本仍 55/70,AGENTS.md 原文也还写着 70/55——三处两真相。
t "statusline 双真相源:contrib-statusline.py 闸门线与 cmd_ctx 一致(75/65)" bash -c \
  'c="$(dirname "$1")/../contrib-statusline.py"; grep -q "^GATE_HARD = 75" "$c" && grep -q "^GATE_WARN = 65" "$c" && b="$(sed -n "/^cmd_ctx()/,/^}/p" "$1")" && grep -q "pct>=75" <<< "$b" && grep -q "pct>=65" <<< "$b"' _ "$LANE"

# ── 看门狗反向守护:自愈链的根不许是单点(2026-08-22 生产级)──────────────────────
# 盘点时发现:wd 管 ev/relay/dispatch,而 wd 自己死了**没有任何东西管它**;两个 launchd 项
# 都只有 RunAtLoad(开机跑一次,⛔ KeepAlive),boot-full 的兜底文案还写着「五次未成交给看门狗」
# ——把它当最后一道,而它自己没有最后一道。更要命的是**告警也是它发的** ⇒ 它一死,
# 「自愈链失效」这件事本身也不会被喊出来,与「一切正常只是没事发生」完全不可分辨。
# ⇒ ev 反向守 wd,与「wd 守 ev」构成互守,单点变双点。三条判据回退即红。
t "ev_loop:反向检查看门狗(⛔ 自愈链的根是单点——它一死连告警都没了)" \
  bash -c 'sed -n "/^ev_loop()/,/^}/p" "'"$LANE"'" | grep -v "^[[:space:]]*#" | grep -qF "if ! wd_alive; then"'
t "ev_loop:反向重起要节流(⛔ 起不来时每拍重试——刷满的日志=没有日志)" \
  bash -c 'sed -n "/^ev_loop()/,/^}/p" "'"$LANE"'" | grep -v "^[[:space:]]*#" | grep -qF "EV_WD_RETRY:-300"'
t "ev_loop:反向重起的死因落 EV_LOG(⛔ 进 /dev/null,同 ctx 巡检那一课)" \
  bash -c 'sed -n "/^ev_loop()/,/^}/p" "'"$LANE"'" | grep -v "^[[:space:]]*#" | grep -qF "cmd_watchdog start ) >/dev/null 2>>"'
# ── 闸门线一致性(2026-08-22 上调 65/75 当轮立)────────────────────────────────────
# SKILL.md 早把它写成「**已知的双真相源**,不是疏忽——一个 bash 一个 python,跨语言共用常量
# 的代价大于收益」,并要求「改一处必须同步另一处」。⇒ 代价既然选了,防线就不能只是「记得改」:
# 08-22 这次上调要动 laixin-lane 两个引擎分支 + statusline.py 两个常量 + SKILL.md 六处引用,
# **漏任一处的症状都是「闸门静默失效」**(SKILL.md 自己写的那句)。⇒ 机器比,⛔ 靠人记。
# ⚠️ statusline.py 不在本仓(~/.claude-official/),不存在即跳过 —— ⛔ 让别的机器上忽红忽绿
#    (「会因环境忽红忽绿的测试比没有测试更糟」,本仓写过)。
t "闸门线:两个引擎分支与 statusline.py 三处一致(⛔ 双真相源漂移=闸门静默失效)" python3 -c '
import re,sys,os
lane=open(sys.argv[1],encoding="utf-8").read()
hard=set(re.findall(r"pct>=(\d+): print\(\"\N{LARGE RED CIRCLE}", lane))
warn=set(re.findall(r"pct>=(\d+): print\(\"\N{LARGE YELLOW CIRCLE}", lane))
assert len(hard)==1, "laixin-lane 两个引擎分支的硬闸门值不一致(或没找到):%s" % hard
assert len(warn)==1, "laixin-lane 两个引擎分支的预备线值不一致(或没找到):%s" % warn
h,w=hard.pop(),warn.pop()
assert int(h)>int(w), "硬闸门必须高于预备线:%s/%s" % (h,w)
sl=os.path.expanduser("~/.claude-official/statusline.py")
if os.path.exists(sl):
    s=open(sl,encoding="utf-8").read()
    gh=re.search(r"GATE_HARD\s*=\s*(\d+)",s); gw=re.search(r"GATE_WARN\s*=\s*(\d+)",s)
    assert gh and gw, "statusline.py 找不到 GATE_HARD/GATE_WARN"
    assert gh.group(1)==h and gw.group(1)==w, \
        "闸门线漂移:laixin-lane=%s/%s 而 statusline.py=%s/%s" % (h,w,gh.group(1),gw.group(1))
' "$LANE"
# ── M1 升级提醒的销账判据(2026-08-22 监测中实撞)──────────────────────────────────
# 13:09 事件总线报「交付 V0.2包①… 投递 45 分钟无认领」,而**该片 12:58 就已 ff-only 合入 main**、
# 12:54 验收回执落盘。两处叠加:
# ① 认领判据拼的是**未转义**的 `verify-<原片名>`,而 vwin 已把片名里的 tmux 目标字符换成 `-`
#    ⇒ 凡片名含点必然对不上 —— **这是 vwin 修复的连带影响,同批补上 ⛔ 留给下一个人撞**;
# ② 「verify 窗口此刻在不在」只能证明**正在被处理**,证明不了**已经处理完** —— 窗口是短命的,
#    验收跑完即回收,回收之后这条判据永远为假 ⇒ 片都合并了还在报无人认领。
tout "M1 销账:窗口名经 vwin 转义后再比(⛔ 拼未转义原片名——含点片名 100% 误报)" "vwin \"\$_ps\"" \
  bash -c 'sed -n "/M1 认领巡检/,/新交付 → 投递/p" "'"$LANE"'"'
tout "M1 销账:第二条=交付报告末行不再是【交付完成】(复用既有设计 ⛔ 新造约定)" "末行已被验收结论覆盖" \
  bash -c 'sed -n "/M1 认领巡检/,/新交付 → 投递/p" "'"$LANE"'"'
# ⚠️ 断言的 sed 范围终点 ⛔ 用 `EV_PENDING.new` —— 它在循环**开始之前**的 `: > "$EV_PENDING.new"`
#   那行就出现了,范围只截到两行 ⇒ 断言红而代码是对的(**当日第二次踩「范围终点锚取太早」**,
#   前一次是 DISPATCH_BRIEF_CODEX 那条)。⇒ 终点一律取**下一节的起始锚**,⛔ 取一个碰巧更早出现的串。
# ⚠️ 该条首版写成 `grep "合并 <片名>" 看板` —— **依赖措辞,当轮实测零命中**:codex dispatch 写的是
#   「…已 ff-only 合入 main@3952ee52」,与 claude 时代的固定格式不同。本仓判据方向早写过
#   「事实优先于措辞 ⛔ 靠子串匹配措辞下结论」,当轮照撞 ⇒ 钉住:销账 ⛔ 回到措辞匹配。
tout "M1 销账 ⛔ 靠看板措辞(合并/打回的写法随引擎而变,claude 与 codex 就不同)" "ZERO" \
  bash -c 'sed -n "/M1 认领巡检/,/新交付 → 投递/p" "'"$LANE"'" | grep -v "^[[:space:]]*#" | grep -n "合并 \$_ps" || echo ZERO'
# ⚠️ 判据必须**跳过注释行**:上面那段注释里为了说明「首版错在哪」逐字引用了该串 ⇒ 不跳过就自匹配,
#   断言红而代码是对的。这正是 dispatch 51 记过的一族:**「写它的说明就会污染它,而写得越负责
#   越容易复现它」**;也是本仓检查器三约束①「判据 ⛔ 建立在裸文本形态上,扫描器必须跳过备注格」。
# ── 看板来源自动推断(2026-08-22 监测中实撞)──────────────────────────────────────
# dispatch(codex)记看板不带前缀 ⇒ 条目落成「未标注来源」(当日第 3 条)。根因**不在它**:
# 三个接管指令与 RELAY_BRIEF 都没教过这件事,全靠 cmd_log 事后打一行 stderr 提示,
# 而提示是事后的、且未必被读。⇒ 窗口名→角色是固定映射、免语义,直接推断。
SRCF="$(mktemp)"; sed -n '/^seat_src_infer()/,/^}/p' "$LANE" > "$SRCF"
t "来源推断:dispatch 窗口 → 派工窗口" bash -c 'source "'"$SRCF"'"; tmux(){ echo dispatch; }; TMUX_PANE=%9 seat_src_infer | grep -qx 派工窗口'
t "来源推断:relay → 中继窗口" bash -c 'source "'"$SRCF"'"; tmux(){ echo relay; }; TMUX_PANE=%9 seat_src_infer | grep -qx 中继窗口'
t "来源推断:verify-* → 验收窗口(前缀匹配 ⛔ 逐个片名硬编码)" bash -c 'source "'"$SRCF"'"; tmux(){ echo "verify-V0-2包①x"; }; TMUX_PANE=%9 seat_src_infer | grep -qx 验收窗口'
t "来源推断:未知窗口名 → 空(推不出就是推不出 ⛔ 瞎猜一个)" bash -c 'source "'"$SRCF"'"; tmux(){ echo zz-unknown; }; [ -z "$(TMUX_PANE=%9 seat_src_infer)" ]'
t "来源推断:不在 tmux 内 → 空(手开窗口照旧走提示那条路)" bash -c 'source "'"$SRCF"'"; tmux(){ echo dispatch; }; [ -z "$(TMUX_PANE= seat_src_infer)" ]'
rm -f "$SRCF"
# 显式给的来源**优先于推断**:重生路径(看门狗/resurrect)靠 LAIXIN_BOARD_SRC 声明自己是谁,
# ⛔ 被窗口名推断覆盖成「派工窗口」——那会让「谁起的这个窗口」这条信息丢失。
tout "来源优先级:LAIXIN_BOARD_SRC > LAIXIN_WINDOW > 窗口名推断 > 手工" "LAIXIN_BOARD_SRC" \
  bash -c 'sed -n "/^caller_src()/,/^}/p" "'"$LANE"'"'
t "来源优先级:推断排在两个显式变量之后" bash -c 'sed -n "/^caller_src()/,/^}/p" "'"$LANE"'" | grep -n "seat_src_infer" | cut -d: -f1 | { read -r n; [ "$n" -ge 4 ]; }'
# 四处接管指令都要教到(此前一处没有 ⇒ 每任窗口都要重新踩一次)
tout "接管指令:kimi 版教了记看板的来源(⛔ 只靠事后 stderr 提示;codex 版已随派工废除删除)" "来源会按窗口名自动标" \
  bash -c 'sed -n "/^DISPATCH_BRIEF_KIMI=/,/^# ---- 派工权认领/p" "'"$LANE"'"'
# ⚠️ 范围终点 ⛔ 用「窗口记忆不算数」:新加的行就在它下一行,会被截掉 ⇒ 断言红而代码是对的
#   (当轮自撞;同族=拿一个"恰好在被测内容之前"的锚做范围终点)。改用下一个块的起始注释。
tout "接管指令:relay 版教了记看板的来源" "来源按窗口名自动标" \
  bash -c 'sed -n "/^RELAY_BRIEF=/,/laixin-lane log/p" "'"$LANE"'"'
# ── 6r. 一次性应召中继窗 relay-once(2026-08-22 创始人定案:中继两条路线都落到位——常驻 relay=claude;
#   一次性 relay-once=claude 默认 / codex 第二方案)────────────────────────────────────────────
# 背景:常驻中继第十八任 17:49 收摊(创始人「把 relay 换成 codex,直接动手干」),方案窗口把中继搬到执行层=一次性应召窗,
#   但工具侧零实现零验证;创始人 19:2x:「这个路线没有验证过,需要把 2 种方案都落好。默认还是 claude code,因为后面 11C
#   可能会用到,把 codex 当作第 2 方案。」⇒ 两条起窗链路都做实,并各在隔离 tmux 会话实起过一次(claude/codex 均就绪后回收)。
echo "== 6r. 一次性应召中继窗 relay-once(claude 默认 / codex 第二)+ rdown =="
RO_ITEM="$(mktemp)"; printf '自检件\n' > "$RO_ITEM"
t "relay-once:引擎默认 claude(resolve 兜底 echo claude;⛔ 兜底 codex)" bash -c \
  'b="$(sed -n "/^relay_once_engine_resolve()/,/^}/p" "$1")"; grep -q "LAIXIN_RELAY_ONCE_ENGINE:-.*echo claude" <<< "$b" && ! grep -q "echo codex)" <<< "$b"' _ "$LANE"
t "relay-once:合法集 claude|codex(kimi ⛔ 入列——创始人定案只有这两条路线)" bash -c \
  'b="$(sed -n "/^relay_once_engine_resolve()/,/^}/p" "$1")"; grep -q "claude|codex) eff=" <<< "$b" && ! grep -q "kimi" <<< "$b"' _ "$LANE"
# ⚠️ 「默认」要用**空开关目录**测(2026-08-22 自撞:本机开关文件按创始人令写成 codex 后本条立刻红——测试 ⛔ 依赖本机可变状态)
RO_SW="$(mktemp -d)"
tout "relay-once --dry 默认走 claude(空开关目录+无 env)" "引擎=claude(请求=claude)" env LAIXIN_RELAY_ONCE_ENGINE= LAIXIN_SWITCH_DIR="$RO_SW" "$LANE" relay-once 测试件 --file "$RO_ITEM" --dry
rmdir "$RO_SW"
tout "relay-once --dry 开关=codex 走 codex(第二方案)" "引擎=codex(请求=codex)" env LAIXIN_RELAY_ONCE_ENGINE=codex "$LANE" relay-once 测试件 --file "$RO_ITEM" --dry
tout "relay-once --engine 显式优先于开关" "引擎=codex(请求=codex)" env LAIXIN_RELAY_ONCE_ENGINE=claude "$LANE" relay-once 测试件 --file "$RO_ITEM" --engine codex --dry
tout "relay-once 开关非法值按 claude 并当面点名(⛔ 静默回落)" "一次性中继引擎请求「bogus」无效" env LAIXIN_RELAY_ONCE_ENGINE=bogus "$LANE" relay-once 测试件 --file "$RO_ITEM" --dry
tfail "relay-once --engine 非法值在动窗口前拒(按件人工发起,非自愈路径 ⇒ die 合法)" "只接受 claude|codex" \
  env LAIXIN_SESSION=bogus-ro "$LANE" relay-once 测试件 --file "$RO_ITEM" --engine bogus
t "relay-once 非法引擎被拒时零 tmux 副作用" bash -c '! tmux has-session -t bogus-ro 2>/dev/null'
tfail "relay-once 必须 --file(正文是件的事实载体,⛔ 塞命令行)" "必须 --file" env LAIXIN_SESSION=bogus-ro "$LANE" relay-once 测试件
tfail "relay-once 正文文件不存在即拒" "正文文件不存在" env LAIXIN_SESSION=bogus-ro "$LANE" relay-once 测试件 --file /nonexistent/x.md
tout "relay-once --dry 给出回复契约(末行【中转回复】<件名> 来自 relay-once——events 既有扫描零改动)" "末行【中转回复】测试件 来自 relay-once" \
  "$LANE" relay-once 测试件 --file "$RO_ITEM" --dry
t "relay-once:claude 分支钉 RELAY_MODEL + RELAY_ONCE_DENY + vwait_ready(与常驻 relay 同形态)" bash -c \
  'b="$(sed -n "/^cmd_relay_once()/,/^}/p" "$1")"; grep -q "\-\-model \$RELAY_MODEL" <<< "$b" && grep -q "RELAY_ONCE_DENY\[@\]" <<< "$b" && grep -q "vwait_ready \"\$w\"" <<< "$b"' _ "$LANE"
# 🔁 沿革(2026-08-23 #164):本条原断言「codex 分支走 codex_launch_cmd(33d679b 起显式 luna/max)」——创始人当日直令
#   「书记员的模型差点意思了,后面 11C 的书记员用 5.6-sol」⇒ relay-once 的 codex 配型改为**独立口径**
#   (⛔ 复用 codex_launch_cmd 的 CODEX_MODEL——那同时是**验收窗**的模型,动它会误伤验收)。
#   ⇒ 断言随之更新 **⛔ 删**:仍钉「显式配型 + 就绪自证」,只把配型来源换成 RELAY_ONCE_CODEX_MODEL。
t "relay-once:codex 分支显式配型(独立口径 RELAY_ONCE_CODEX_MODEL)+ vwait_ready_codex 就绪自证" bash -c 'b="$(sed -n "/^cmd_relay_once()/,/^}/p" "$1")"; grep -q "RELAY_ONCE_CODEX_MODEL" <<< "$b" && grep -q "vwait_ready_codex" <<< "$b"' _ "$LANE"
t "relay-once:引擎校验在 ensure_session 之前(#60① 一课)" bash -c \
  'b="$(sed -n "/^cmd_relay_once()/,/^}/p" "$1")"; c="$(grep -n "未知一次性中继引擎" <<< "$b" | head -1 | cut -d: -f1)"; e="$(grep -n "^  ensure_session" <<< "$b" | head -1 | cut -d: -f1)"; [ -n "$c" ] && [ -n "$e" ] && [ "$c" -lt "$e" ]' _ "$LANE"
t "relay-once:点名指令含回复契约/⛔ dmsg 注入/件毕即收/rdown 四要件" bash -c \
  'b="$(sed -n "/^cmd_relay_once()/,/^}/p" "$1")"; grep -q "【中转回复】\${item} 来自 relay-once" <<< "$b" && grep -q "dmsg 注入派工窗格" <<< "$b" && grep -q "件毕即收" <<< "$b" && grep -q "laixin-lane rdown \${item}" <<< "$b"' _ "$LANE"
t "relay-once:codex 版红线写进指令本体(无 disallowedTools 等价物)" bash -c \
  'b="$(sed -n "/^cmd_relay_once()/,/^}/p" "$1")"; grep -q "以本指令为准,越线即整件作废" <<< "$b"' _ "$LANE"
t "RELAY_ONCE_DENY ⊇ RELAY_DENY 且加 relay*/rdown*(一次性窗 ⛔ 起/收任何中继、⛔ 自我繁殖)" bash -c \
  'grep -q "^RELAY_ONCE_DENY=(\"\${RELAY_DENY\[@\]}\" \"Bash(laixin-lane relay\*)\" \"Bash(laixin-lane rdown\*)\")" "$1"' _ "$LANE"
tout "rowin 转义 tmux 目标字符(与 vwin 同款:. : % \$ @ 空格 斜杠)" "relay-a-b-c-d-e" bash -c \
  'eval "$(sed -n "/^rowin()/,/^}/p" "$1")"; die(){ echo "$@"; exit 1; }; rowin "a.b:c d/e"' _ "$LANE"
t "seat_src_infer:relay-* → 一次性中继窗(看板来源自动标)" bash -c \
  'b="$(sed -n "/^seat_src_infer()/,/^}/p" "$1")"; grep -q "relay-\*)   echo \"一次性中继窗\"" <<< "$b"' _ "$LANE"
t "看门狗对话框扫描覆盖 relay-*(同为无人值守一次性席位)" bash -c \
  'b="$(sed -n "/^wd_loop()/,/^}/p" "$1")"; grep -q "grep -E .\^(verify|relay|m)-." <<< "$b"' _ "$LANE"
tout "doctor §6 报一次性中继引擎(默认 claude)" "一次性中继引擎:claude" env LAIXIN_RELAY_ONCE_ENGINE=claude "$LANE" doctor
tout "doctor §6 报一次性中继引擎=codex(第二方案)" "一次性中继引擎:codex" env LAIXIN_RELAY_ONCE_ENGINE=codex "$LANE" doctor
tout "doctor §6 一次性中继引擎非法值点名" "一次性中继引擎请求「bogus」无效" env LAIXIN_RELAY_ONCE_ENGINE=bogus "$LANE" doctor
t "doctor §4:非 claude 派工席 + 常驻中继不在班 ⇒ 硬错(kimi 顶班的出站靠 relay-msg 注入窗口名 relay,一次性窗 ⛔ 替代)" bash -c \
  'b="$(sed -n "/^cmd_doctor()/,/^}/p" "$1")"; grep -q "无代发方" <<< "$b" && grep -q "! relay_alive" <<< "$b"' _ "$LANE"
t "路由表含 relay-once / rdown / peek-ro" bash -c \
  'grep -q "^  relay-once) shift; cmd_relay_once" "$1" && grep -q "^  rdown)      shift; cmd_rdown" "$1" && grep -q "^  peek-ro)    shift; cmd_peekro" "$1"' _ "$LANE"
tout "rdown 对不存在的窗口幂等(本就不存在 ⇒ 0)" "本就不存在" env LAIXIN_SESSION=bogus-ro "$LANE" rdown 测试件
# ⭐ 创始人 2026-08-22 19:5x:「派工窗口如果换成 kimi 的时候,relay 就一定要是 claude」——两半机器形态各一条绊线
tout "kimi 规则①:派工席=kimi 时一次性中继开关 codex 被压制为 claude 并在 doctor 点名" "中继一律 claude" \
  env LAIXIN_DISPATCH_ENGINE=kimi LAIXIN_RELAY_ONCE_ENGINE=codex "$LANE" doctor
tout "kimi 规则①:压制后 doctor 报的一次性中继引擎是 claude" "一次性中继引擎:claude" \
  env LAIXIN_DISPATCH_ENGINE=kimi LAIXIN_RELAY_ONCE_ENGINE=codex "$LANE" doctor
tout "kimi 规则①:relay-once --dry 在 kimi 派工席下按 claude 起并说明" "按 claude 起" \
  env LAIXIN_DISPATCH_ENGINE=kimi LAIXIN_RELAY_ONCE_ENGINE=codex "$LANE" relay-once 测试件 --file "$RO_ITEM" --dry
tfail "kimi 规则①:派工席=kimi 时显式 --engine codex 是被禁组合 ⇒ 拒(人在要求违令)" "中继一律 claude" \
  env LAIXIN_DISPATCH_ENGINE=kimi LAIXIN_SESSION=bogus-ro "$LANE" relay-once 测试件 --file "$RO_ITEM" --engine codex
tout "kimi 规则①:派工席=claude 时开关 codex 照常生效(规则只对非 claude 派工席)" "引擎=codex(请求=codex)" \
  env LAIXIN_DISPATCH_ENGINE=claude LAIXIN_RELAY_ONCE_ENGINE=codex "$LANE" relay-once 测试件 --file "$RO_ITEM" --dry
t "kimi 规则②:cmd_dispatch kimi 分支起窗前自动拉起常驻 claude 中继(relay_alive 假 ⇒ cmd_relay --fresh --resurrect),拉不起 die" bash -c \
  'b="$(sed -n "/^cmd_dispatch()/,/^}/p" "$1")"; k="$(grep -n "_brief=\"\$DISPATCH_BRIEF_KIMI\"" <<< "$b" | head -1 | cut -d: -f1)"; w="$(grep -n "kimi_launch_cmd \"dispatch\"" <<< "$b" | head -1 | cut -d: -f1)"; seg="$(sed -n "${k},${w}p" <<< "$b")"; grep -q "! relay_alive" <<< "$seg" && grep -q "cmd_relay --fresh --resurrect" <<< "$seg" && grep -q "自动拉起失败" <<< "$seg"' _ "$LANE"
t "常驻 relay 仍只起 claude(结构:代发 SendMessage;⛔ 被一次性窗的引擎开关波及)" bash -c \
  'b="$(sed -n "/^cmd_relay()/,/^}/p" "$1")"; grep -q "\-\-model \$RELAY_MODEL" <<< "$b" && ! grep -q "RELAY_ONCE_ENGINE\|codex_launch_cmd" <<< "$b"' _ "$LANE"
rm -f "$RO_ITEM"

# ── 交付去重键:内容哈希 ⛔ mtime(2026-08-22 实撞)──────────────────────────────────
# 原键是 mtime,于是 `touch` 一下就足以让**内容一字未变**的报告被当成新交付重投。当日实况:
# dispatch 做空跑验证时 touch 过首片交付报告,事件总线 12:05 投一次、12:23 又投一次,
# dispatch 被迫花一整轮全文复读确认「提交与报告内容不变」。同族还有备份工具改 mtime、
# 编辑器保存同内容。⇒ 改哈希后:整改重交(内容真变)照旧触发,touch 不再制造假事件。
EVSF="$(mktemp)"; { sed -n '/^last_contract_line()/,/^}/p' "$LANE"; sed -n '/^ev_scan_deliveries()/,/^}/p' "$LANE"; } > "$EVSF"
EVT="$(mktemp -d)"; mkdir -p "$EVT/4-开发层/记录"
printf 'x\n【交付完成】br abc123\n' > "$EVT/4-开发层/记录/probe.md"
t "交付去重:touch 后键不变(⛔ 假交付事件把 dispatch 一整轮花在复读上)" bash -c '
  A="$(KB="'"$EVT"'"; source "'"$EVSF"'"; ev_scan_deliveries)"
  touch "'"$EVT"'/4-开发层/记录/probe.md"
  B="$(KB="'"$EVT"'"; source "'"$EVSF"'"; ev_scan_deliveries)"
  [ "$A" = "$B" ]'
t "交付去重:内容变则键变(整改重交必须仍能触发 ⛔ 为了防重投把真重交也挡掉)" bash -c '
  A="$(KB="'"$EVT"'"; source "'"$EVSF"'"; ev_scan_deliveries)"
  printf "x\n【交付完成】br def456\n" > "'"$EVT"'/4-开发层/记录/probe.md"
  C="$(KB="'"$EVT"'"; source "'"$EVSF"'"; ev_scan_deliveries)"
  [ "$A" != "$C" ]'
t "交付去重:键的第二段不是纯数字(=已离开 mtime 形态)" bash -c '
  L="$(KB="'"$EVT"'"; source "'"$EVSF"'"; ev_scan_deliveries | head -1)"
  h="${L##*|}"; [ -n "$h" ] && ! printf "%s" "$h" | grep -qE "^[0-9]+$"'
rm -rf "$EVT" "$EVSF"
# 🔴 格式迁移必须**静默重建 ⛔ 回放**:旧基线第二段是纯数字,与新键全体失配 ⇒ 不处理的话
#   升级后第一拍会把全部历史交付/回执一次性重投,把 dispatch 淹掉。
tout "交付去重:检出旧格式基线即重建并声明 ⛔ 回放历史" "⛔ 回放历史" \
  bash -c 'sed -n "/^cmd_events()/,/^}/p" "'"$LANE"'"; sed -n "/^ev_loop()/,/^}/p" "'"$LANE"'"'
# ── 验收窗口名:tmux 目标语法字符必须转义(2026-08-22 V0.2 首片实撞,dispatch 52 报)──────
# 原实现只换空格与斜杠,点号原样留着。而 tmux 目标语法里 `.` 是 **pane 分隔符** ⇒ 片名
# `V0.2包①…` 生成的窗口名进 `-t "$SESSION:$w"` 后,window 只取到 `verify-V0`。
# 🔴 **后果不是「起不来」而是「静默作用到别的窗口」**:当轮实测同时存在 verify-V0 与
# verify-V0.2probe 时,`display-message -t laixin:verify-V0.2probe` 返回的是 **verify-V0**,
# 毫无报错 ⇒ 派单送错窗、读状态读别人画面、回收 kill 错窗口。「成功」与「作用错对象」同形。
# ⚠️ 判据函数落盘再 source,⛔ `source <(…)`:进程替换有 fd 竞态,source 可能读到空 ⇒ 函数没定义,
#   而症状是 `vwin: command not found` 后 `[ "" = "verify-…" ]` 判假 —— **看起来像转义没生效**,
#   指向的方向与真因完全无关(本仓 #108-fix 那几条已用落盘写法,首版没照抄,当轮自撞)。
VWF="$(mktemp)"; sed -n '/^vwin()/,/^}/p' "$LANE" > "$VWF"
t "vwin:片名含点必须转义(⛔ 让 tmux 把 .2 当 pane 号)" bash -c 'die(){ return 1; }; source "'"$VWF"'"; [ "$(vwin "V0.2包①x")" = "verify-V0-2包①x" ]'
t "vwin:同族字符 : % \$ @ 一并转义(全是 tmux 目标语法的一部分)" bash -c 'die(){ return 1; }; source "'"$VWF"'"; [ "$(vwin "a:b%c\$d@e")" = "verify-a-b-c-d-e" ]'
t "vwin:空格/斜杠原有行为保持" bash -c 'die(){ return 1; }; source "'"$VWF"'"; [ "$(vwin "含 空格/斜杠")" = "verify-含-空格-斜杠" ]'
t "vwin:函数体确实被 source 到了(⛔ 空 source 让上面三条以「未定义」假过/假败)" bash -c 'die(){ return 1; }; source "'"$VWF"'"; type vwin >/dev/null 2>&1'

# 🔴 端到端:在**独立 tmux 会话**里造出「同前缀 + 含点」两个窗口,证明未转义时 tmux 真的解析到前者
# (这条是本 bug 的要害证据;⛔ 只测字符串替换——那证明不了危害)。
t "vwin E2E:未转义名在 tmux 里会解析到同前缀的另一个窗口(危害证据)" bash -c '
  S=lx-vwin-probe-$$; tmux kill-session -t "$S" 2>/dev/null
  tmux new-session -d -s "$S" -n "verify-V0" 2>/dev/null || exit 1
  tmux new-window -d -t "$S" -n "verify-V0.2probe" 2>/dev/null
  got="$(tmux display-message -p -t "$S:verify-V0.2probe" "#{window_name}" 2>/dev/null)"
  tmux kill-session -t "$S" 2>/dev/null
  [ "$got" = "verify-V0" ]'
# ── 交班形态判据(2026-08-22 实撞后立)──────────────────────────────────────────────
# 失败样本:方案窗口第二十任把**同账号正常交班**办成了「2 个 CC 账号切换的交班」(创始人当面
# 纠正);连锁=relay 据此报一条「即将静默发生的断链」告警,前提为假,10 分钟后撤回。
# 🔑 根因不在人在卡:当日新落的跨账号切换剧本只写「怎么切」,**没写「什么时候才算在切」**,
#   而「这次是不是跨账号」当时没有任何可执行判据 ⇒ 只能推定,推错即全套附则误用。
#   二十任的认账:**「规则在案」≠「规则适用于当下」**。⇒ 把那个判断变成一个能跑的动作。
tout "交班形态:同账号分支必须明说「附则整卡 ⛔ 适用」(本次事故的要害)" "附则整卡" \
  bash -c 'sed -n "/^cmd_handover_mode()/,/^}/p" "'"$LANE"'"'
tout "交班形态:跨账号分支存在" "跨账号交班" \
  bash -c 'sed -n "/^cmd_handover_mode()/,/^}/p" "'"$LANE"'"'
tfail "交班形态:⛔ 猜前任是谁(猜错会给出一个看起来确定的答案)" "让本命令去猜" \
  bash -c '"'"$LANE"'" handover-mode only-one-arg'
tfail "交班形态:继任未起窗时说「判不了」⛔ 给答案(此时唯一判据=创始人明示)" "判不了" \
  bash -c '"'"$LANE"'" handover-mode zz-nonexistent-succ /Users/pingxia/.claude-b'
# 📌 前任常在继任起窗前就已关闭(交班的常见顺序就是前任先关)⇒ 判据 ⛔ 依赖两窗同时在线:
#   交班方生前跑 channel-of <自己> 写进交接包,继任照抄传通道目录 —— 两次调用各自在活着时发生。
# ⚠️ 本条只能做**结构断言**:行为路径要求继任是真实活会话(否则先在继任那步退出),
#   而拿"当前恰好有哪个窗口在跑"当 fixture 的测试会随运行态忽红忽绿——那种测试比没有更糟。
tout "交班形态:前任已关闭时给出正路(传通道目录)⛔ 只说查不到" "改传\*\*通道目录\*\*" \
  bash -c 'sed -n "/^cmd_handover_mode()/,/^}/p" "'"$LANE"'"'
tfail "channel-of:查不到即说查不到 ⛔ 读成「不在别的通道」" "⛔ 据此判断交班形态" \
  bash -c '"'"$LANE"'" channel-of zz-nonexistent'
# ── 11C 双盲三类文件分居(2026-08-22 机器化;通则出自 relay 16 的两次实撞自捕)────────────
# 代号映射全表 / 各席取号文件 / 席位写入的暂存区,**两类同居即双盲当场漏**,漏法是「某席 ls
# 一下就看见了」——不需要它做任何越界动作。实撞一:取号写进各席落卷的暂存目录;实撞二:取号
# 放在映射表所在目录 ⇒ 拿到该目录路径的席位 ls 见映射表文件名。判据免语义故可机器化。
# 🔴 绊线全部在**临时目录**里造靶子,⛔ 拿真实封存档做实验(一次中断就在生产目录留脏文件)。
# 🔴 被测对象必须是**仓库版**(照 T11C 与 LANE 同款取法),⛔ `command -v` 找 PATH ——
#   PATH 上是**发布版**(上一次 release 的快照),新加的子命令在它那里根本不存在。
#   ⚠️ 首版写成 command -v 时的真实后果:两条「应该过」的断言红了(发布版没有 audit 子命令),
#   而四条「应该失败」的断言**全部假绿** —— 因为「功能不存在」与「功能拦下了」都表现为
#   非零退出码,**两者在断言眼里同形**。⇒ 断言"应该失败"时,必须确认失败的**原因**是被测的那个。
SEATB="$(cd "$(dirname "$0")/.." && pwd)/bin/laixin-11c-seat"
# ⭐ 兄弟脚本随行(2026-08-22 实撞):seat 加了硬闸、测试全绿、提交并 release 之后,**PATH 上跑的
#   仍是旧快照**(它单独软链、不在 release 射程)⇒ 硬闸在真实起席时根本不跑。"仓库改了+测试绿了+
#   发布了"三件齐备而生效面为零,且三件都指向"已生效"。⇒ 钉住 release 必须把兄弟脚本一起发。
tout "release 兄弟脚本随行(⛔ 只发 *.py:seat 会永远停在旧版而三处证据都说已发布)" "laixin-11c-seat" \
  bash -c 'sed -n "/^cmd_release()/,/^}/p" "'"$LANE"'"'
tout "release 兄弟脚本换链失败必须出声(⛔ 静默吞掉=PATH 停旧版而输出说发布成功)" "换链失败" \
  bash -c 'sed -n "/^cmd_release()/,/^}/p" "'"$LANE"'"'

B11="$(mktemp -d)"; mkdir -p "$B11/allow/局X" "$B11/seal" "$B11/pick"
b11env(){ env LAIXIN_11C_ALLOW_ROOT="$B11/allow" LAIXIN_11C_SEAL_DIR="$B11/seal" LAIXIN_11C_PICK_DIR="$B11/pick" "$@"; }
t "11C 双盲:三类分居时 audit 过" bash -c 'env LAIXIN_11C_ALLOW_ROOT="'"$B11"'/allow" LAIXIN_11C_SEAL_DIR="'"$B11"'/seal" LAIXIN_11C_PICK_DIR="'"$B11"'/pick" "'"$SEATB"'" audit >/dev/null'
t "11C 双盲实撞一:取号文件落进席位暂存区即报(任一席 ls 即见)" bash -c 'touch "'"$B11"'/allow/局X/取号-t.txt"; ! env LAIXIN_11C_ALLOW_ROOT="'"$B11"'/allow" LAIXIN_11C_SEAL_DIR="'"$B11"'/seal" LAIXIN_11C_PICK_DIR="'"$B11"'/pick" "'"$SEATB"'" audit >/dev/null; rc=$?; rm -f "'"$B11"'/allow/局X/取号-t.txt"; [ "$rc" = 0 ]'
t "11C 双盲实撞二:取号文件落进映射表目录即报(ls 见映射表文件名)" bash -c 'touch "'"$B11"'/seal/取号-t.txt"; ! env LAIXIN_11C_ALLOW_ROOT="'"$B11"'/allow" LAIXIN_11C_SEAL_DIR="'"$B11"'/seal" LAIXIN_11C_PICK_DIR="'"$B11"'/pick" "'"$SEATB"'" audit >/dev/null; rc=$?; rm -f "'"$B11"'/seal/取号-t.txt"; [ "$rc" = 0 ]'
t "11C 双盲:取号目录混入代号映射全表即报" bash -c 'touch "'"$B11"'/pick/x-代号映射.md"; ! env LAIXIN_11C_ALLOW_ROOT="'"$B11"'/allow" LAIXIN_11C_SEAL_DIR="'"$B11"'/seal" LAIXIN_11C_PICK_DIR="'"$B11"'/pick" "'"$SEATB"'" audit >/dev/null; rc=$?; rm -f "'"$B11"'/pick/x-代号映射.md"; [ "$rc" = 0 ]'
# 🔴 起席必须 **fail-closed**:双盲一旦漏就是整局作废,代价远高于「起席被拦一次」。
#   ⚠️ 退出码 ⛔ 经管道读(`… | head` 会用 head 的码覆盖真码,本仓记过这一族)。
t "11C 双盲:分居不过时 start 拒起(fail-closed,退出码 1)" bash -c 'touch "'"$B11"'/allow/局X/取号-t.txt"; env LAIXIN_11C_ALLOW_ROOT="'"$B11"'/allow" LAIXIN_11C_SEAL_DIR="'"$B11"'/seal" LAIXIN_11C_PICK_DIR="'"$B11"'/pick" "'"$SEATB"'" start seat-zz terra "'"$B11"'/allow/局X" >/dev/null 2>&1; rc=$?; rm -f "'"$B11"'/allow/局X/取号-t.txt"; [ "$rc" = 1 ]'
t "11C 双盲:目录不存在时报「不适用」⛔ 报通过(失效降级 ⛔ 反向)" bash -c 'out="$(env LAIXIN_11C_ALLOW_ROOT="'"$B11"'/nope" LAIXIN_11C_SEAL_DIR="'"$B11"'/seal" LAIXIN_11C_PICK_DIR="'"$B11"'/pick" "'"$SEATB"'" audit)"; grep -q "不适用" <<< "$out"'
rm -rf "$B11"
# ── 11C claude 双账号通道(2026-08-23;fable 席此前硬编码 claude-b,流水线切账号时圆桌没通道可换)──
SW11="$(mktemp -d)"; sed -n "/^claude_launcher_11c()/,/^}/p" "$SEATB" > "$SW11/f.sh"
t "11C 通道解析:无任何开关 ⇒ claude(与 laixin-lane 同默认)" bash -c 'SWITCH_DIR="$1"; source "$1/f.sh"; unset LAIXIN_11C_CLAUDE_LAUNCHER; [ "$(claude_launcher_11c)" = "claude 默认" ]' _ "$SW11"
t "11C 通道解析:跟随与流水线共用的开关 claude-launcher(创始人切账号时圆桌跟着切)" bash -c 'SWITCH_DIR="$1"; source "$1/f.sh"; unset LAIXIN_11C_CLAUDE_LAUNCHER; echo claude-b > "$1/claude-launcher"; read -r v s <<< "$(claude_launcher_11c)"; [ "$v" = claude-b ] && grep -q "共用" <<< "$s"' _ "$SW11"
t "11C 通道解析:11C 专用开关 claude-launcher-11c 压过共用开关(圆桌与流水线可分账号)" bash -c 'SWITCH_DIR="$1"; source "$1/f.sh"; unset LAIXIN_11C_CLAUDE_LAUNCHER; echo claude-b > "$1/claude-launcher"; echo claude > "$1/claude-launcher-11c"; read -r v s <<< "$(claude_launcher_11c)"; [ "$v" = claude ] && grep -q "11C 专用" <<< "$s"' _ "$SW11"
t "11C 通道解析:env LAIXIN_11C_CLAUDE_LAUNCHER 最优先" bash -c 'SWITCH_DIR="$1"; source "$1/f.sh"; echo claude > "$1/claude-launcher-11c"; read -r v s <<< "$(LAIXIN_11C_CLAUDE_LAUNCHER=claude-b claude_launcher_11c)"; [ "$v" = claude-b ] && grep -q "env" <<< "$s"' _ "$SW11"
t "11C fable 起席串走通道变量 ⛔ 硬编码 claude-b(改开关即切账号)" bash -c 'b="$(sed -n "/^cmd_start()/,/^}/p" "$1")"; grep -qF "launch=\"\${_cl} -n \$seat --model claude-fable-5" <<< "$b" && ! grep -q "launch=\"claude-b -n" <<< "$b"' _ "$SEATB"
t "11C fable:通道入口不在 PATH ⇒ 起席前拒(在双盲核/tmux 之前,零副作用)" bash -c 'out="$(env LAIXIN_11C_CLAUDE_LAUNCHER=claude-不存在的入口 LAIXIN_11C_ALLOW_ROOT="$1/allow" "$2" start seat-t fable "$1/allow/局X" 2>&1)"; rc=$?; [ $rc -ne 0 ] && grep -q "不在 PATH" <<< "$out"' _ "$SW11" "$SEATB"
t "11C launcher_cfg_dir:从包装器文件读配置目录(claude→.claude-official);读不到显 未知 ⛔ 猜" bash -c '
  sed -n "/^launcher_cfg_dir()/,/^}/p" "$1" > "$2/cfg.sh"; source "$2/cfg.sh"
  mkdir -p "$2/bin"; printf "#!/bin/bash\n  CLAUDE_OFFICIAL_CONFIG_DIR=\"/Users/x/.claude-official\" \\\n  exec true\n" > "$2/bin/claude-x"; chmod +x "$2/bin/claude-x"
  PATH="$2/bin:$PATH"; [ "$(launcher_cfg_dir claude-x)" = "/Users/x/.claude-official" ] || { echo "得 $(launcher_cfg_dir claude-x)"; exit 1; }
  [ "$(launcher_cfg_dir 不存在的入口)" = "未知" ]' _ "$SEATB" "$SW11"
rm -rf "$SW11"
t "loop_stale:取 pid 走 loop_pids ⛔ 宽 pgrep(量错对象与量对同形)" bash -c '! sed -n "/^loop_stale()/,/^}/p" "'"$LANE"'" | grep -vE "^[[:space:]]*#" | grep -q "pgrep -f"'
t "loop_stale:逐字 loop_pids" bash -c 'sed -n "/^loop_stale()/,/^}/p" "'"$LANE"'" | grep -q "loop_pids \"\$1\""'

# ── 通道拓扑(账号隔离 + 软切换,2026-08-19;创始人「两个通道独立运行、软切换」)──────────
# 运行形态:claude 与 claude-b 两条通道各自独立跑,一条 token 将尽时逐步停工、另一条逐步拉起。
# ⇒ **多通道并存是正常中间态,⛔ 判成错** —— 那会把每一次切换都报成故障。
# 🔴 真正该报的两种都无声:①两通道同时有 dispatch(违反派工唯一,两条线各自看都正常);
#   ②孤儿席位(某通道只剩一个 dispatch/relay,跨通道消息发不到,它没有任何可通信对象)。
#   2026-08-19 19:34~19:58 真实出现过②的雏形(方案窗口已切、三件套未切),零告警。
# 判定只读 stdin ⛔ 引用顶层变量(#75:顶层不被抽取,set -u 下静默退出)⇒ 裸 source 即可测。
VCH="$(mktemp -d)"; VCHF="$VCH/fn.sh"
sed -n "/^channel_verdict()/,/^}$/p" "$LANE" > "$VCHF"
tout "通道:单通道判完整" "单通道运行" bash -c '
  source "'"$VCHF"'"; printf "1 /a dispatch\n2 /a relay\n3 /a outside\n" | channel_verdict'
tout "通道:双通道各有对象=软切换正常态 ⛔ 判错" "软切换态" bash -c '
  source "'"$VCHF"'"; printf "1 /a dispatch\n2 /a outside\n3 /b relay\n4 /b outside\n" | channel_verdict'
t "通道:软切换态 rc=0(⛔ 把正常切换报成故障)" bash -c '
  source "'"$VCHF"'"; printf "1 /a dispatch\n2 /a outside\n3 /b relay\n4 /b outside\n" | channel_verdict >/dev/null'
tout "通道:两通道同时有 dispatch 判危险(派工唯一)" "两个派工窗口同时活着" bash -c '
  source "'"$VCHF"'"; printf "1 /a dispatch\n2 /a outside\n3 /b dispatch\n4 /b outside\n" | channel_verdict'
tout "通道:孤儿席位判危险(跨通道发不到,无可通信对象)" "孤儿" bash -c '
  source "'"$VCHF"'"; printf "1 /a dispatch\n2 /a outside\n3 /b relay\n" | channel_verdict'
t "通道:危险态 rc=1" bash -c '
  source "'"$VCHF"'"; ! printf "1 /a dispatch\n2 /b dispatch\n3 /b outside\n4 /a outside\n" | channel_verdict >/dev/null'
tout "通道:空输入报不适用 ⛔ 报健康(那是假绿)" "不适用" bash -c '
  source "'"$VCHF"'"; printf "" | channel_verdict'
tout "通道:取数走 sock 名 ⛔ pgrep(调用者看不见自己那个 claude 进程)" "CC_SOCKS_DIR" \
  sed -n "/^session_seats()/,/^}$/p" "$LANE"
tout "通道:席位识别与 outside_sessions 同口径(tty 配对 ⛔ 猜窗口名)" "pane_tty" \
  sed -n "/^session_seats()/,/^}$/p" "$LANE"
tout "通道:doctor 已接入(⛔ 只有函数没人调)" "channel_verdict" \
  sed -n "/^cmd_doctor()/,/^}$/p" "$LANE"
rm -rf "$VCH"

# ── dmsg:主动消息通道(2026-08-19;dispatch 换 codex/kimi 后的入站路径)────────────────
# 缺口成因:events 只扫四种末行标记(交付完成/验收回执/中转回执/转办回复),**四种全是回复类**
# ⇒ 主动消息无路可走。而这在 dispatch=claude 时完全看不见(直接 SendMessage 就到了),
# **换引擎当天才露出来** —— 与 #75/#66 同族的「只在切换时刻才显形」的缺口。本组守它不退化。
tfail "dmsg:缺 --from 必须拒(⛔ 匿名注入派工窗口)" "必须带 --from" "$LANE" dmsg "正文"
tfail "dmsg:有 --from 无正文必须拒" "需要消息正文" "$LANE" dmsg --from 方案窗口
tout "dmsg:消息体带来源标记(收方要能追到发起人)" "【消息】来自" sed -n "/^cmd_dmsg()/,/^}$/p" "$LANE"
tout "dmsg:走 ev_deliver ⛔ 自拼 tmux(引擎无关全靠这一点)" "ev_deliver" sed -n "/^cmd_dmsg()/,/^}$/p" "$LANE"
t "dmsg:kind=消息 且 ev_deliver 把它归**暂存**档 ⛔ 丢弃档" bash -c '
  sed -n "/^cmd_dmsg()/,/^}$/p" "'"$LANE"'" | grep -q "ev_deliver \"消息\"" &&
  sed -n "/^ev_deliver()/,/^}$/p" "'"$LANE"'" | grep -qE "交付\|回执\|消息\)"'
tout "dmsg:已接入 case 分发(⛔ 只有函数没人调)" "cmd_dmsg" bash -c 'grep "^  dmsg)" "'"$LANE"'"'
tout "dmsg:回执点明「注入成功⛔等于已读」(#69 同族)" "⛔ 等于已读" sed -n "/^cmd_dmsg()/,/^}$/p" "$LANE"
# 🔁 沿革(2026-08-23 #165-2):原实现是**全文** grep,而它要钉的只是 RELAY_DENY 这一段 ⇒ **判据比缺陷宽**;
#   #165 的 TOOL_DENY **有意含 dmsg**(工具窗有交付契约走 events,⛔ 直接注入派工窗格)于是被误命中。
#   ⇒ 收窄到 RELAY_DENY 段内扫 ⛔ 放宽原意。
t "dmsg:⛔ 进 RELAY_DENY(relay 恰是最需要它的席位;判据只扫该段 ⛔ 全文)" bash -c '
  seg="$(sed -n "/^RELAY_DENY=(/,/^)/p" "'"$LANE"'")"; ! grep -q "laixin-lane dmsg" <<< "$seg"' 

# ── 未知子命令必须**大声**(2026-08-19 实撞)────────────────────────────────────────
# 原行为:只打 help + exit 1。退出码对,但输出看起来像一次正常结果 ⇒ 用 `cmd | grep` 读它
# 的人会把 help 正文当命令输出(11B 归口多次 `laixin-lane board | tail` 看"看板末段",
# 看到的全是 help,并据此判过一条"看板没记录"——而记录其实在看板文件里)。
tfail "未知子命令:退出码非零且 stderr 有明确告警(⛔ 静默打 help)" "未知子命令" "$LANE" 完全不存在的子命令xyz
t "未知子命令:告警走 stderr ⛔ stdout(混进 stdout 会被当成输出的一部分)" bash -c '
  out="$("'"$LANE"'" 不存在xyz 2>/dev/null)"; ! grep -q "未知子命令" <<< "$out"'

# ── dispatch 方案 C:kimi(2026-08-19)────────────────────────────────────────────────
# 三家引擎的通信能力实测:claude 有 SendMessage;codex 无;**kimi 无**(0.37.2 自报逐字
# 「没有任何 SendMessage / ListAgents 之类的工具」)⇒ 与 codex 同档,出站 relay-msg、
# 入站 dmsg/events,通信面已闭合,kimi 不需要额外机制。
VKM="$(mktemp -d)"; VKMF="$VKM/fn.sh"
{ echo 'KIMI_BIN=/k/kimi; KIMI_MODEL=k3; CODEX_MODEL=luna-probe; CODEX_EFFORT=max-probe; LANE_SWITCH_DIR=/nonexistent-codex-tier-test';
  sed -n "/^agent_launch_cmd()/,/^}$/p" "$LANE";
  sed -n "/^codex_service_tier()/,/^}$/p" "$LANE";
  grep '^codex_service_tier_flag(){' "$LANE";
  sed -n "/^codex_launch_cmd()/,/^}$/p" "$LANE";
  sed -n "/^kimi_launch_cmd()/,/^}$/p" "$LANE"; } > "$VKMF"
tout "kimi:构造串走同一注入形态(⛔ 各写一套)" 'BU_NAME="d" BU_CDP_URL="http://127.0.0.1:9" "/k/kimi" --auto -m k3' bash -c '
  source "'"$VKMF"'"; kimi_launch_cmd d 9'
# ⚠️ 原判据是「与引入 kimi 前逐字一致」——该前提已被 2026-08-22 创始人配档裁定推翻(验收窗须显式带
#    模型与推理档)⇒ 判据改守**语义**:注入形态仍与 kimi 同源 + 模型档显式取自变量(⛔ 硬编码、⛔ 吃 config.toml)。
#    测试值用可辨识的 luna-probe/max-probe:若实现改成硬编码,此断言会因取不到探针值而变红。
tout "codex:构造串显式带模型档与普通用量档且取自变量" 'BU_NAME="d" BU_CDP_URL="http://127.0.0.1:9" codex -m luna-probe -c model_reasoning_effort="max-probe" -c service_tier="default" --x' bash -c '
  source "'"$VKMF"'"; codex_launch_cmd d 9 "--x"'
# ⛔ 在这里再写一条"未知引擎被拒":既有 #67 那条已覆盖,且它带 LAIXIN_SESSION 隔离;
# 照抄时漏掉隔离 ⇒ 会在**真实** tmux 会话里跑起窗命令(2026-08-19 自撞,当轮发现并撤回)。
tout "kimi:错误文案列出全部合法引擎(claude|kimi;codex 08-22 废除后只剩两种,⛔ 漏列 kimi)" "claude|kimi" bash -c '
  grep "未知派工引擎" "'"$LANE"'"'
tout "kimi:BRIEF 禁 Agent/AgentSwarm(用子代理会绕过派工权锁且看板看不出)" "AgentSwarm" bash -c '
  sed -n "/^DISPATCH_BRIEF_KIMI=/,/^铁律/p" "'"$LANE"'"'
tout "kimi:BRIEF 明示 ctx 看自己界面(laixin-lane ctx 对本引擎无效,会读到别人的数)" "context: N%" bash -c '
  sed -n "/^DISPATCH_BRIEF_KIMI=/,/^铁律/p" "'"$LANE"'"'
tout "kimi:BRIEF 告知 dmsg 入站路(⛔ 让它去自建监听)" "dmsg" bash -c '
  sed -n "/^DISPATCH_BRIEF_KIMI=/,/^铁律/p" "'"$LANE"'"'
t "kimi:起窗前必须预写信任记录(#68,⛔ 起完再点按钮——托管窗口无人可点)" bash -c '
  n=$(grep -n "kimi_launch_cmd \"dispatch\"" "'"$LANE"'" | cut -d: -f1)
  sed -n "$((n-6)),${n}p" "'"$LANE"'" | grep -q kimi_trust_prewrite'
tout "kimi:就绪判据认状态栏 ⛔ 认启动横幅(横幅在输入框可用前就打出来了)" "context: " \
  sed -n "/^vwait_ready_kimi()/,/^}$/p" "$LANE"
t "kimi:doctor 引擎行⛔ 写死 codex(三态要可分辨)" bash -c '
  ! sed -n "/^cmd_doctor()/,/^}$/p" "'"$LANE"'" | grep -q "派工引擎:codex("'
rm -rf "$VKM"

# ── 看板截断必须带标记(2026-08-19 relay 第十二任实撞)──────────────────────────────
# 裸 cut 出来的记录**读起来是完整的一句话**,没有任何信号提示还有下文 ⇒ 凭库接班的窗口
# 会以为自己掌握了全部明文。这是「失效必须可见」的一个实例。
tout "dmsg:看板长条截断带显式标记(⛔ 静默截断)" "截断,全文已投" \
  sed -n "/^cmd_dmsg()/,/^}$/p" "$LANE"
t "dmsg:短消息⛔ 误加截断标记(判据按首行长度,⛔ 一律加)" bash -c '
  sed -n "/^cmd_dmsg()/,/^}$/p" "'"$LANE"'" | grep -q "gt 70"'

# ── pane_cmd 必须用枚举 ⛔ 按目标查询(2026-08-19 晚;relay 第十二任定位,11B 复核)────────
# 缺陷:`tmux display-message -p -t <目标>` 对解析不到的目标**静默回退到别的窗口**(实测传
# 不存在的窗口名返回 `node` 而不报错)⇒ `|| echo NONE` 兜底永不触发,真实失效是**读到另一个
# 窗口的值**;events/watchdog 的 pane 是 bash ⇒ 被读成中继 ⇒ **判一个活着的中继已死并杀掉**。
# 当晚 9 次判中继不在,9 次都紧跟 ev-loop 重启,零例外。
t "pane_cmd ⛔ 用 display-message -t(它解析不到时回退到别的窗口)" bash -c '
  ! grep "^pane_cmd()" "'"$LANE"'" | grep -q "display-message"'
tout "pane_cmd 用枚举+精确匹配(不存在就是不存在)" "list-windows" bash -c '
  grep "^pane_cmd()" "'"$LANE"'"'
t "pane_cmd:不存在的窗口必须返回 NONE ⛔ 别人的值(真机)" bash -c '
  v="$(tmux list-windows -t laixin -F "#{window_name} #{pane_current_command}" 2>/dev/null | awk -v W=绝无此窗口zzz "\$1==W{print \$2; f=1} END{exit !f}" || echo NONE)"
  [ "$v" = NONE ]'
t "判活:NONE ⇒ 存疑不动 ⛔ 判死(三约束②失效必须降级)" bash -c '
  n=$(grep -c "NONE) return 0" "'"$LANE"'"); [ "$n" -ge 2 ]'

# ── lane_busy 必须收 Waiting(2026-08-19;dispatch 第三十八任双样本)────────────────────
# codex 等后台终端时屏上是 `Waiting for background terminal (2m30s)`,判据没这词 ⇒ 在飞被读成
# 空闲 ⇒ 空闲告警第①项会打断正在跑的全量。⚠️ 只改 lane_busy,**⛔ 动 #40 send_swallow_check
# 的同名词表**(那条裁定逐字「⛔ 放宽判据」,目的相反)——11B 当轮误改并撤回一次,本组守住边界。
t "lane_busy:codex 档收 Waiting" bash -c '
  sed -n "/^lane_busy()/,/^}$/p" "'"$LANE"'" | grep -q "Applying|Running|Waiting"'
KPF="$(mktemp -d)/kp.sh"; sed -n "/^kimi_act_pat()/,/^}/p" "$LANE" > "$KPF"   # ⛔ source <(…):bash 3.2 下函数不落地(2026-08-22 实测)
t "lane_busy:kimi 档同样收 Waiting(2026-08-22 起词表在单点源 kimi_act_pat)" bash -c '
  source "'"$KPF"'"; pat="$(kimi_act_pat)"
  grep -q "Running|Waiting for background terminal|" <<< "$pat" && grep -q "🌑" <<< "$pat" &&
  sed -n "/^lane_busy()/,/^}$/p" "'"$LANE"'" | grep -q "kimi_act_pat"'
t "边界:#40 的判据⛔ 被顺手放宽(裁定=⛔ 放宽判据)" bash -c '
  sed -n "/^send_swallow_check()/,/^}$/p" "'"$LANE"'" | grep -q "Read |Thinking|Ran " &&
  ! sed -n "/^send_swallow_check()/,/^}$/p" "'"$LANE"'" | grep -q "Ran |Waiting"'
tout "空闲告警:首选项改为先 peek,⛔ 直接 fresh+send" "⛔ 直接 fresh+send" bash -c '
  grep "分钟无变化(空闲或卡住)" "'"$LANE"'"'


# ── 裸 $name 紧跟非 ASCII(2026-08-20 00:32 实撞:ev-loop M1 升级提醒分支首次走到即 `_ps�: unbound variable` 连崩,
#    看门狗每分钟重起=事件总线实瘫;bash 3.2 在 zh_CN/en_US.UTF-8 下把全角字符首字节卷进变量名,C locale 反而正常)──
t "locale 机理:bash 3.2 UTF-8 locale 下裸 \$v」 被吞成变量名(记录现象,失败说明 bash 升级后本规可撤)" bash -c '
  ! LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 bash -c "set -u; v=x; echo \"\$v」\"" >/dev/null 2>&1'
t "locale 机理:花括号 \${v}」 在同一 locale 下正常" bash -c '
  LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 bash -c "set -u; v=x; echo \"\${v}」\"" >/dev/null 2>&1'
t "全文件:⛔ 裸 \$name 紧跟非 ASCII 字符(一律写 \${name};冷路径首跑即炸且与 locale 相关)" python3 -c '
import re,sys
s=open(sys.argv[1],encoding="utf-8").read()
hits=[(i,m.group(0)) for i,l in enumerate(s.split("\n"),1) for m in re.finditer(r"\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7f])",l)]
print(hits); sys.exit(1 if hits else 0)' "$LANE"

# ── 中转回执销账取 id(2026-08-20 01:4x,11B pingxia-37;零实跑史,04:00 dispatch 切 codex 前核出)──
# 原写法取标记后第 2 字段当 id,而信封要求写 `【中转回执】<id> 已转出 <to>` ⇒ 取到「已转出」⇒ 永远销不了账 ⇒
# 10 分钟后假「疑似丢失」告警 + 原样重发 ⇒ 中继代发两次。改为按 outbox 里的 id 匹配,格式无关。
VRA="$(mktemp -d)"; VRAF="$VRA/fn.sh"; VRAO="$VRA/outbox"
sed -n "/^relay_ack_id()/,/^}/p" "$LANE" > "$VRAF"
printf '1700000000|ab12cd34|dispatch|裁定请求\n1700000001|zz99yy88|pingxia-fb|另一条\n' > "$VRAO"
t "中转回执:信封规定格式 <id> 已转出 <to> 能销到 id(原第 2 字段写法取到「已转出」)" bash -c '
  source "'"$VRAF"'"; [ "$(relay_ack_id "【中转回执】ab12cd34 已转出 dispatch" "'"$VRAO"'")" = "ab12cd34" ]'
t "中转回执:id 在第二位也能销(格式无关)" bash -c '
  source "'"$VRAF"'"; [ "$(relay_ack_id "【中转回执】已转出 zz99yy88" "'"$VRAO"'")" = "zz99yy88" ]'
t "中转回执:末行不含任何 outbox id ⇒ 空(⛔ 误销别的账)" bash -c '
  source "'"$VRAF"'"; [ -z "$(relay_ack_id "【中转回执】已转出 dispatch" "'"$VRAO"'")" ]'
t "中转回执:零匹配时 ev_loop 大声记日志 ⛔ 静默" bash -c 'grep -q "中转回执末行未命中任何 outbox id" "'"$LANE"'"'
rm -rf "$VRA"

# ── laixin-11c-trust:codex 座席信任预写(2026-08-20 首局 R4 拍板;独立 11C 脚本 ⛔ lane 子命令)──
# 全部走 LAIXIN_CODEX_CONFIG 临时副本,⛔ 碰真 ~/.codex/config.toml
T11C="$(cd "$(dirname "$0")/.." && pwd)/bin/laixin-11c-trust"
TTD="$(mktemp -d)"; TCFG="$TTD/config.toml"
printf 'model = "gpt-5.6-terra"\n\n[projects."/Users/pingxia"]\ntrust_level = "trusted"\n' > "$TCFG"
TDIR="$HOME/.laixin-11c/测试-预写-$$"
tfail "11c-trust:相对路径拒绝" "绝对路径" env LAIXIN_CODEX_CONFIG="$TCFG" "$T11C" foo/bar
tfail "11c-trust:白名单外目录拒绝(vault/HOME 不许信任)" "白名单外" env LAIXIN_CODEX_CONFIG="$TCFG" "$T11C" "$HOME/Obsidian/某处"
tfail "11c-trust:路径含引号拒绝(TOML 注入面)" "注入面" env LAIXIN_CODEX_CONFIG="$TCFG" "$T11C" "$HOME/.laixin-11c/a\"b"
tfail "11c-trust:配置不存在拒绝且不代建" "不存在" env LAIXIN_CODEX_CONFIG="$TTD/没有.toml" "$T11C" "$TDIR"
tout "11c-trust:--check 未信任报 1" "未信任" bash -c 'LAIXIN_CODEX_CONFIG="'"$TCFG"'" "'"$T11C"'" --check "'"$TDIR"'"; true'
tout "11c-trust:预写成功且出 before/after diff" "before/after diff" env LAIXIN_CODEX_CONFIG="$TCFG" "$T11C" "$TDIR"
t "11c-trust:写后 TOML 可解析或无解析器时键在" bash -c '
  if python3 -c "import tomllib" >/dev/null 2>&1; then
    python3 -c "import tomllib,sys; d=tomllib.load(open(sys.argv[1],\"rb\")); assert sys.argv[2] in d[\"projects\"]" "$1" "$2"
  else
    grep -qF "[projects.\"$2\"]" "$1"
  fi' _ "$TCFG" "$TDIR"
tout "11c-trust:二次运行幂等零写盘(键值判据 ⛔ mtime)" "零写盘" env LAIXIN_CODEX_CONFIG="$TCFG" "$T11C" "$TDIR"
t "11c-trust:幂等未产生重复表(重复表=TOML 致命)" bash -c '[ "$(grep -cF "[projects.\"'"$TDIR"'\"]" "'"$TCFG"'")" = "1" ]'
t "11c-trust:既有条目(/Users/pingxia)原样未动" bash -c 'grep -qF "[projects.\"/Users/pingxia\"]" "'"$TCFG"'"'
t "11c-trust:备份文件已生成" bash -c 'ls "'"$TTD"'"/config.toml.bak-11ctrust-* >/dev/null'
rm -rf "$TTD"

# ── kimi 0.38 签名漂移(2026-08-22 21:4x 11B 监测实撞):盲文转轮+小写 thinking;三处词表收单点源 ──────
# 失败样本:lane-c 屏上逐字 `⠹ thinking...` 在改文件,lane_busy c=空闲;send 广播给它报「疑似被吞」。
# 夹具构造成「修复被回退即红」:0.38 画面必须判在飞/已送达;干完残留在屏的「● Ran a command」⛔ 判在飞。
KP="$(bash -c "source \"$KPF\"; kimi_act_pat")"   # KPF 见上文 lane_busy 组(bash 3.2 ⛔ source <(…))
# 自带夹具目录:C60 的 busy.sh/swallow.sh 在 rm -rf "$C60" 之后已不存在,⛔ 复用(首跑实撞:迷你跑道绿、全量红)
K38="$(mktemp -d)"
K38B="$K38/busy.sh"; { sed -n "/^lane_engine()/,/^}/p" "$LANE"; sed -n "/^kimi_act_pat()/,/^}/p" "$LANE"; sed -n "/^lane_busy()/,/^}/p" "$LANE"; } > "$K38B"
K38S="$K38/swallow.sh"; { sed -n "/^lane_engine()/,/^}/p" "$LANE"; sed -n "/^kimi_act_pat()/,/^}/p" "$LANE"; sed -n "/^win()/,/^}/p" "$LANE"; sed -n "/^target()/,/^}/p" "$LANE"; sed -n "/^send_swallow_check()/,/^}/p" "$LANE"; } > "$K38S"
t "#kimi0.38:单点源词表两代签名并存(月相+盲文+小写 thinking+排队提示),⛔ 收干完残留词" bash -c '
  grep -q "⠦" <<< "$1" && grep -q "🌕" <<< "$1" && grep -q "thinking" <<< "$1" && grep -q "ctrl-s to steer" <<< "$1" &&
  ! grep -q "Ran a command" <<< "$1" && ! grep -q "Used Edit" <<< "$1"' _ "$KP"
t "#kimi0.38:三处 kimi 词表零内联(lane_busy/send_swallow_check/confirm_briefed 全走 kimi_act_pat)" bash -c '
  for fn in lane_busy send_swallow_check confirm_briefed; do
    body="$(sed -n "/^$fn()/,/^}/p" "$1")"
    grep -q "kimi_act_pat" <<< "$body" || { echo "$fn 未走单点源"; exit 1; }
    grep -qE "pat=.*🌑" <<< "$body" && { echo "$fn 赋值行仍内联月相词表"; exit 1; }
  done; true' _ "$LANE"
t "#kimi0.38:lane_busy 认 0.38 工作画面(⠹ thinking...)=在飞;干完残留「● Ran a command」=空闲" bash -c '
  source "'"$K38B"'"; SESSION=s; win_exists(){ return 0; }
  tmux(){ echo " ⠹ thinking..."; echo "   Hmm, the residue scan only shows line 54"; }
  lane_busy c || exit 1
  tmux(){ echo " ● Ran a command"; echo " ● Used Edit (…page.tsx)"; echo " │ >                │"; echo " auto  K3 thinking: max  ~/来信平台-c1"; }
  ! lane_busy c'
t "#kimi0.38:send 被吞检测认 0.38 工作画面与排队提示(ctrl-s to steer)=已送达;空闲提示符照报" bash -c '
  source "'"$K38S"'"; SESSION=s; die(){ echo "die: $*" >&2; exit 1; }; board(){ :; }
  tmux(){ echo " ⠦ thinking..."; echo "   The file was modified on disk since my last read"; }
  out="$(send_swallow_check c 2>&1)"; [ -z "$out" ] || exit 1
  tmux(){ echo "   ❯ 【main 前进广播 · 客观事实】 main 已从 ed94d7d 前进到 …"; echo "   ↑ to edit · ctrl-s to steer immediately"; }
  out="$(send_swallow_check c 2>&1)"; [ -z "$out" ] || exit 1
  tmux(){ echo " ● Ran a command"; echo " │ >                │"; }
  out="$(send_swallow_check c 2>&1)"; grep -q "疑似被吞" <<< "$out"'
t "#kimi0.38:底栏「K3 thinking: max」不得被 thinking... 判据击中(那是常驻状态栏,⛔ 当在飞)" bash -c '
  source "'"$K38B"'"; SESSION=s; win_exists(){ return 0; }
  tmux(){ echo " │ >                │"; echo " auto  K3 thinking: max  ~/来信平台-c1  v02-merchant"; }
  ! lane_busy c'
rm -rf "$K38"

# ── 交付投递去抖 ev_unsettled(2026-08-22 11B 监测实证:430 次投递 86 次为 ≤10min 重投,间隔 61~63s=边写边存)──
EVU="$(mktemp -d)/u.sh"; sed -n "/^ev_unsettled()/,/^}/p" "$LANE" > "$EVU"
t "ev_unsettled:一拍内还在写 ⇒ 待稳定(0)" bash -c 'source "'"$EVU"'"; ev_unsettled 1000 1030 60'
t "ev_unsettled:写完满一拍 ⇒ 可投(1)" bash -c 'source "'"$EVU"'"; ! ev_unsettled 1000 1060 60 && ! ev_unsettled 1000 1100 60'
t "ev_unsettled:失效降级 ⛔ 反向——mtime 空/非数/未来时间一律可投" bash -c 'source "'"$EVU"'"; ! ev_unsettled "" 1000 60 && ! ev_unsettled abc 1000 60 && ! ev_unsettled 2000 1000 60'
t "ev-loop:待稳定候选 ⛔ 进 seen 基线(进了就永远投不出)" bash -c '
  body="$(sed -n "/^ev_loop/,/^}/p" "$1")"
  grep -q "ev_unsettled" <<< "$body" && grep -qF "$2" <<< "$body" && grep -qF "$3" <<< "$body"' _ "$LANE" \
  'comm -23 <(echo "$cur") <(sort "$EV_SETTLING")' ': > "$EV_SETTLING"'
t "ev-loop:去抖判据在陈旧闸门之后(陈旧报告照旧记日志不投,⛔ 被去抖截住后反复记「待稳定」)" bash -c '
  body="$(sed -n "/^ev_loop/,/^}/p" "$1")"
  a=$(grep -n "跳过陈旧交付" <<< "$body" | head -1 | cut -d: -f1); b=$(grep -n "ev_unsettled" <<< "$body" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$LANE"

# ── #136 常驻循环随发布自换代 / #137 无燃料静默 / #138 M1 台账(2026-08-22 11B 监测后优化批)──────────
T136="$(mktemp -d)"
{ sed -n "/^loop_self_gen()/,/^}/p" "$LANE"; sed -n "/^loop_gen_record()/,/^}/p" "$LANE"; sed -n "/^loop_reload_due()/,/^}/p" "$LANE"; sed -n "/^loop_gen_label()/,/^}/p" "$LANE"; } > "$T136/f.sh"
mkdir -p "$T136/rel/aaa" "$T136/rel/bbb" "$T136/rel/ccc" "$T136/out"
printf '#!/bin/bash\necho a\n' > "$T136/rel/aaa/laixin-lane"; printf '#!/bin/bash\necho b\n' > "$T136/rel/bbb/laixin-lane"
printf '#!/bin/bash\nif then fi\n' > "$T136/rel/ccc/laixin-lane"; : > "$T136/out/x"
ln -s "$T136/rel/aaa/laixin-lane" "$T136/link"
t "#136:软链未变 ⇒ 不到期" bash -c 'source "$1/f.sh"; ! loop_reload_due "$1/rel/aaa/laixin-lane" "$1/link" "$1/rel"' _ "$T136"
t "#136:软链已指向另一个可用发布版 ⇒ 到期(exec 自换代)" bash -c 'source "$1/f.sh"; ln -sfn "$1/rel/bbb/laixin-lane" "$1/link"; loop_reload_due "$1/rel/aaa/laixin-lane" "$1/link" "$1/rel"' _ "$T136"
t "#136:新目标 bash -n 不过 ⇒ 不到期(半截发布 ⛔ exec 进去自杀)" bash -c 'source "$1/f.sh"; ln -sfn "$1/rel/ccc/laixin-lane" "$1/link"; ! loop_reload_due "$1/rel/aaa/laixin-lane" "$1/link" "$1/rel"' _ "$T136"
t "#136:指向发布目录之外 / 自身不是软链(开发直连)/ 记录为空 ⇒ 均不到期" bash -c 'source "$1/f.sh"
  ln -sfn "$1/out/x" "$1/link"; ! loop_reload_due "$1/rel/aaa/laixin-lane" "$1/link" "$1/rel" || exit 1
  ! loop_reload_due "$1/rel/aaa/laixin-lane" "$1/rel/aaa/laixin-lane" "$1/rel" || exit 2
  ln -sfn "$1/rel/bbb/laixin-lane" "$1/link"; ! loop_reload_due "" "$1/link" "$1/rel"' _ "$T136"
t "#136:loop_gen_label 发布路径取短名(目录名=commit 短 hash),非发布路径原样" bash -c 'source "$1/f.sh"; export LAIXIN_RELEASE_DIR="$1/rel"; [ "$(loop_gen_label "$1/rel/bbb/laixin-lane")" = bbb ] && [ "$(loop_gen_label /x/y)" = /x/y ]' _ "$T136"
sed -n "/^loop_stale()/,/^}/p" "$LANE" > "$T136/stale.sh"
t "#136:loop_stale 优先读 <loop>.gen——pid 相符且版本=软链现值 ⇒ 不落后;≠ ⇒ 落后;pid 不符回落 etime 判据" bash -c '
  source "$1/stale.sh"; EV_DIR="$1/ev"; mkdir -p "$EV_DIR"
  loop_pids(){ echo 4242; }; ps(){ :; }; etime_secs(){ echo 0; }
  ln -sfn "$1/rel/bbb/laixin-lane" "$1/lbin"; export LAIXIN_RELEASE_BIN="$1/lbin"
  echo "4242 $1/rel/bbb/laixin-lane" > "$EV_DIR/wd-loop.gen"; loop_stale wd-loop && exit 1
  echo "4242 $1/rel/aaa/laixin-lane" > "$EV_DIR/wd-loop.gen"; loop_stale wd-loop || exit 2
  echo "9999 $1/rel/aaa/laixin-lane" > "$EV_DIR/wd-loop.gen"; loop_stale wd-loop; [ $? -eq 1 ]' _ "$T136"
t "#136:两条常驻循环都挂了自换代钩(记 gen + loop_reload_due + exec 同名循环)" bash -c '
  w="$(sed -n "/^wd_loop()/,/^}$/p" "$1")"; e="$(sed -n "/^ev_loop()/,/^}$/p" "$1")"
  grep -q "loop_gen_record wd-loop" <<< "$w" && grep -q "loop_reload_due" <<< "$w" && grep -qF "exec \"\$0\" wd-loop" <<< "$w" &&
  grep -q "loop_gen_record ev-loop" <<< "$e" && grep -q "loop_reload_due" <<< "$e" && grep -qF "exec \"\$0\" ev-loop" <<< "$e"' _ "$LANE"
t "#136:release 文案改口——不再写「仍需 stop && start」为唯一路径" bash -c 'b="$(sed -n "/^cmd_release()/,/^}/p" "$1")"; grep -q "自换代" <<< "$b"' _ "$LANE"
rm -rf "$T136"

T137="$(mktemp -d)"; sed -n "/^wd_fuel()/,/^}/p" "$LANE" > "$T137/f.sh"
t "#137:wd_fuel 只认可行动燃料:空闲轨 ready / 待认领 P;忙轨 ready、verify/工具等待窗、relay outbox 都不算;总表不可读朝告警侧" bash -c '
  source "$1/f.sh"; SESSION=s; TABLE="$1/table.md"; : > "$TABLE"; EV_PENDING="$1/pending"; RELAY_OUTBOX="$1/outbox"; : > "$EV_PENDING"; : > "$RELAY_OUTBOX"
  ev_next_ready(){ :; }; win_exists(){ return 1; }; lane_busy(){ return 1; }; tmux(){ :; }
  [ -z "$(wd_fuel)" ] || { echo "全无应为空:$(wd_fuel)"; exit 1; }
  ev_next_ready(){ [ "$1" = B ] && echo "某片"; }; grep -q "B:某片" <<< "$(wd_fuel)" || exit 2; ev_next_ready(){ :; }
  ev_next_ready(){ [ "$1" = B ] && echo "某片"; }; lane_busy(){ [ "$1" = b ]; }; [ -z "$(wd_fuel)" ] || exit 21; lane_busy(){ return 1; }; ev_next_ready(){ :; }
  echo "1|x|E" > "$EV_PENDING"; [ -z "$(wd_fuel)" ] || exit 3
  echo "1|x|P" >> "$EV_PENDING"; grep -q "待认领" <<< "$(wd_fuel)" || exit 4; : > "$EV_PENDING"
  tmux(){ echo "verify-某片"; }; [ -z "$(wd_fuel)" ] || exit 5; tmux(){ :; }
  echo "1|id|to|x" > "$RELAY_OUTBOX"; [ -z "$(wd_fuel)" ] || exit 6; : > "$RELAY_OUTBOX"
  win_exists(){ [ "$1" = lane-c ]; }; ev_next_ready(){ [ "$1" = C ] && echo "C片"; }; grep -q "C:C片" <<< "$(wd_fuel)" || exit 7
  win_exists(){ return 1; }; [ -z "$(wd_fuel)" ] || exit 8
  rm -f "$TABLE"; grep -q "不可读" <<< "$(wd_fuel)"' _ "$T137"
t "#137:wd_loop 无行动燃料钩位置正确——在 dispatch 死亡重起之后(死了照重起)、在静默重起分支之前;且燃料回归时封顶静默 ⛔ 直接触发重起" bash -c '
  w="$(sed -n "/^wd_loop()/,/^}$/p" "$1")"
  a=$(grep -n "if ! dispatch_alive; then" <<< "$w" | head -1 | cut -d: -f1); b=$(grep -n "无行动燃料" <<< "$w" | head -1 | cut -d: -f1); c=$(grep -n "\"\$silent\" -ge \"\$restart_after\"" <<< "$w" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] &&
  grep -qF "[ \"\$silent\" -gt \"\$nudge_after\" ] && silent=\"\$nudge_after\"" <<< "$w" && grep -q "wd_fuel" <<< "$w"' _ "$LANE"
rm -rf "$T137"

t "#138:M1 登记同片去重(已在台账不重复登记)+ E 态超期出清(EV_PENDING_TTL)" bash -c '
  d="$(sed -n "/^ev_deliver()/,/^}$/p" "$1")"; e="$(sed -n "/^ev_loop()/,/^}$/p" "$1")"
  grep -qF "grep -qF \"|\${_slug}|\" \"\$EV_PENDING\"" <<< "$d" && grep -q "不重复登记" <<< "$d" &&
  grep -q "EV_PENDING_TTL" <<< "$e" && grep -q "M1 台账出清" <<< "$e"' _ "$LANE"

# ── M 轨机动窗 m-up/m-down/peek-m/mlist(2026-08-22 方案窗口规格 → 11B 首发批;执行总表 M 子节「11B:M 件常规起窗命令」)──
echo "== M 轨机动窗 m-up(codex 全局默认 ⛔ 钉模型;件毕即收;各件独立 worktree;双向自证)=="
TM="$(mktemp -d)"; printf '# 任务单\n' > "$TM/task.md"; mkdir -p "$TM/wt" "$TM/main"
printf 'model = "gpt-5.6-terra"\nmodel_reasoning_effort = "xhigh"\n' > "$TM/config.toml"
MUP_ENV=(env LAIXIN_CODEX_CONFIG="$TM/config.toml" LAIXIN_REPO="$TM/main" LAIXIN_KB="$TM/kb")
sed -n "/^mwin()/,/^}/p" "$LANE" > "$TM/mwin.sh"
tout "m-up:窗名转义同 vwin/rowin(. : % $ @ 空格斜杠 → -)" "m-V0-2包①a-b" bash -c 'die(){ echo "$*" >&2; exit 1; }; source "$1/mwin.sh"; mwin "V0.2包①a b"' _ "$TM"
tfail "m-up:缺 --task 拒(任务单是唯一依据,起窗即派任务单路径)" "必须 --task" "${MUP_ENV[@]}" "$LANE" m-up 测试件 --dir "$TM/wt" --dry
tfail "m-up:任务单不存在拒" "任务单不存在" "${MUP_ENV[@]}" "$LANE" m-up 测试件 --task "$TM/没有.md" --dir "$TM/wt" --dry
tfail "m-up:缺 --dir 拒(各件独立 worktree 机器执法 ⛔ 靠自觉)" "必须 --dir" "${MUP_ENV[@]}" "$LANE" m-up 测试件 --task "$TM/task.md" --dry
tfail "m-up:--dir 不存在拒(窗口未动)" "目录不存在" "${MUP_ENV[@]}" "$LANE" m-up 测试件 --task "$TM/task.md" --dir "$TM/没有" --dry
tfail "m-up:--dir=A 轨主树拒(两轨对写同一工作树同族)" "不得落 A 轨主树" "${MUP_ENV[@]}" "$LANE" m-up 测试件 --task "$TM/task.md" --dir "$TM/main" --dry
MUP_DRY="$("${MUP_ENV[@]}" "$LANE" m-up 测试件 --task "$TM/task.md" --dir "$TM/wt" --dry 2>&1)"
t "m-up --dry:起动串与开发轨同源——含 codex、零 -m、零推理档、零 luna(⛔ codex_launch_cmd 的 luna/max)" bash -c '
  l="$(grep "起动串:" <<< "$1")"; [ -n "$l" ] || exit 1
  grep -q "BU_NAME=" <<< "$l" && grep -q "BU_CDP_URL=" <<< "$l" && grep -q " codex " <<< "$l" &&
  ! grep -q " -m " <<< "$l" && ! grep -q "luna" <<< "$l" && ! grep -q "model_reasoning_effort" <<< "$l"' _ "$MUP_DRY"
tout "m-up --dry:全局默认读自 config.toml(LAIXIN_CODEX_CONFIG 可覆盖)" "全局默认=gpt-5.6-terra xhigh" echo "$MUP_DRY"
tout "m-up --dry:交付契约=记录/M轨-<件名>-报告.md 末行【交付完成】M轨-<件名>" "M轨-测试件-报告.md 末行【交付完成】M轨-测试件" echo "$MUP_DRY"
tout "m-up --dry:窗名 m-<slug>,BU 以 m 开头,端口落验收段 93xx-99xx" "窗口=m-测试件" echo "$MUP_DRY"
t "m-up 点名指令:含任务单路径/worktree/四要件/红线(⛔ push/merge/reset/dmsg/起新窗)/⛔ 自收/按件轻量复核/⛔ 借 M 轨绕片级闸门" bash -c '
  b="$(sed -n "/^cmd_mup()/,/^}$/p" "$1")"
  for k in "任务单(先通读" "工作目录=本 worktree" "四要件" "⛔ git push" "⛔ laixin-lane dmsg" "⛔ 起任何新窗口" "你 ⛔ 自收" "轻量复核" "⛔ 借 M 轨绕" "机动窗"; do
    grep -qF "$k" <<< "$b" || { echo "缺:$k"; exit 1; }
  done' _ "$LANE"
t "m-up:自证①先于派单(模型≠全局默认 ⇒ die 且不 paste 任务单);luna 二字在 die 文案里点名" bash -c '
  b="$(sed -n "/^cmd_mup()/,/^}$/p" "$1")"
  a=$(grep -n "m_self_attest_model" <<< "$b" | head -1 | cut -d: -f1); p=$(grep -n "laixin-mmsg" <<< "$b" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$p" ] && [ "$a" -lt "$p" ] && grep -q "自证①失败" <<< "$b" && grep -q "⛔ luna" <<< "$b"' _ "$LANE"
sed -n "/^codex_global_default()/,/^}/p" "$LANE" > "$TM/gd.sh"
t "codex_global_default:读 model+effort;缺项显 ?(读不到 ⛔ 显默认);文件不存在显「? ?」" bash -c '
  source "$1/gd.sh"
  [ "$(LAIXIN_CODEX_CONFIG="$1/config.toml" codex_global_default)" = "gpt-5.6-terra xhigh" ] || exit 1
  printf "model = \"gpt-x\"\n" > "$1/c2.toml"; [ "$(LAIXIN_CODEX_CONFIG="$1/c2.toml" codex_global_default)" = "gpt-x ?" ] || exit 2
  [ "$(LAIXIN_CODEX_CONFIG="$1/没有.toml" codex_global_default)" = "? ?" ]' _ "$TM"
{ sed -n "/^cdp_port_verify()/,/^}/p" "$LANE"; sed -n "/^oneshot_port_clash()/,/^}/p" "$LANE"; } > "$TM/clash.sh"
t "oneshot_port_clash:同端口在跑一次性窗被点名(verify/relay/m 三族都在射程),排除自身,无撞为空" bash -c '
  source "$1/clash.sh"; SESSION=s
  tmux(){ printf "%s\n" "verify-x" "relay-y" "m-z" "lane-a"; }
  p="$(cdp_port_verify m-z)"; [ "$(oneshot_port_clash "$p")" = "m-z" ] || exit 1
  [ -z "$(oneshot_port_clash "$p" m-z)" ] || exit 2
  [ -z "$(oneshot_port_clash 1)" ]' _ "$TM"
sed -n "/^m_self_attest_model()/,/^}/p" "$LANE" > "$TM/attest.sh"
t "m_self_attest_model:横幅 model: 行优先(实屏形态);底栏兜底(terra xhigh / luna max 都读得出);空屏退 1" bash -c '
  source "$1/attest.sh"; SESSION=s; sleep(){ :; }
  tmux(){ echo "│ model:       gpt-5.6-terra xhigh   fast   /model to cha… │"; echo "  gpt-5.6-terra default · ~/x"; }; [ "$(m_self_attest_model m-x)" = "gpt-5.6-terra xhigh" ] || { echo "横幅优先失败:$(m_self_attest_model m-x)"; exit 1; }
  tmux(){ echo " gpt-5.6-terra xhigh fast · ~/来信平台-m1"; }; [ "$(m_self_attest_model m-x)" = "gpt-5.6-terra xhigh" ] || exit 2
  tmux(){ echo "  gpt-5.6-luna max · ~/x"; }; [ "$(m_self_attest_model m-x)" = "gpt-5.6-luna max" ] || exit 3
  tmux(){ :; }; ! m_self_attest_model m-x' _ "$TM"
t "m_self_attest_model:底栏过渡态「… default」先等(2026-08-22 首火实撞:横幅已 xhigh 底栏仍 default 被误判不符),等满仍 default 才照实返回" bash -c '
  source "$1/attest.sh"; SESSION=s; sleep(){ :; }; CNT="$1/cnt"; : > "$CNT"
  tmux(){ echo x >> "$CNT"; if [ "$(wc -l < "$CNT")" -le 2 ]; then echo "  gpt-5.6-terra default · ~/x"; else echo "  gpt-5.6-terra xhigh fast · ~/x"; fi; }   # 计数走文件:桩在 $(…) 子 shell 里跑,内存计数不回传
  [ "$(m_self_attest_model m-x)" = "gpt-5.6-terra xhigh" ] || exit 1
  tmux(){ echo "  gpt-5.6-terra default · ~/x"; }; [ "$(m_self_attest_model m-x)" = "gpt-5.6-terra default" ]' _ "$TM"
t "机动窗:win() 映射 m-*→「机动窗」;doctor §4 列在跑机动窗;一次性窗扫描正则都含 m" bash -c '
  grep -q "m-\*)       echo \"机动窗\"" "$1" && grep -q "在跑的机动窗" "$1" &&
  [ "$(grep -c "(verify|relay|m)-" "$1")" -ge 3 ]' _ "$LANE"
t "机动窗:events——M 件交付 ⛔ 进 M1 台账;ev_loop 有机动件分支(⛔ verify-from,按件轻量复核 + m-down)" bash -c '
  d="$(sed -n "/^ev_deliver()/,/^}$/p" "$1")"; e="$(sed -n "/^ev_loop()/,/^}$/p" "$1")"
  grep -qF "! grep -q '"'"'/M轨-'"'"' <<< \"\$text\"" <<< "$d" &&
  grep -q "【交付完成】M轨-\*)" <<< "$e" && grep -q "机动件交付落盘" <<< "$e" && grep -q "m-down" <<< "$e"' _ "$LANE"
t "机动窗:帮助文本与子命令分发齐全(m-up/m-down/peek-m/mlist)" bash -c '
  for c in m-up m-down peek-m mlist; do grep -q "^#   laixin-lane $c" "$1" || { echo "help 缺 $c"; exit 1; }; grep -qE "^  $c\)" "$1" || { echo "分发缺 $c"; exit 2; }; done' _ "$LANE"
tout "m-down:不存在的窗幂等(本就不存在)" "本就不存在" "${MUP_ENV[@]}" "$LANE" m-down 从未起过的件
# 信任前置核(2026-08-22 隔离首火实撞:新目录起 codex 撞「Do you trust…」对话框哑等 90s)
{ sed -n "/^codex_trust_root()/,/^}/p" "$LANE"; sed -n "/^codex_dir_trusted()/,/^}/p" "$LANE"; } > "$TM/trust.sh"
git -C "$TM/main" init -q 2>/dev/null && git -C "$TM/main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null && git -C "$TM/main" worktree add -q --detach "$TM/wt2" HEAD 2>/dev/null
t "codex_trust_root:git worktree ⇒ 主仓根(物理路径);主仓 ⇒ 自身;非 git ⇒ 目录本身" bash -c '
  source "$1/trust.sh"; R="$(cd "$1/main" && pwd -P)"
  [ "$(codex_trust_root "$1/wt2")" = "$R" ] || { echo "wt2→$(codex_trust_root "$1/wt2") ≠ $R"; exit 1; }
  [ "$(codex_trust_root "$1/main")" = "$R" ] || exit 2
  [ "$(codex_trust_root "$1/wt")" = "$(cd "$1/wt" && pwd -P)" ]' _ "$TM"
t "codex_dir_trusted:主仓已信任 ⇒ 其 worktree 判已信任(0);别的目录 1;配置不可读 2" bash -c '
  source "$1/trust.sh"; R="$(cd "$1/main" && pwd -P)"
  printf "[projects.\"%s\"]\ntrust_level = \"trusted\"\n" "$R" > "$1/trust.toml"
  LAIXIN_CODEX_CONFIG="$1/trust.toml" codex_dir_trusted "$1/wt2" || exit 1
  LAIXIN_CODEX_CONFIG="$1/trust.toml" codex_dir_trusted "$1/wt"; [ $? -eq 1 ] || exit 2
  LAIXIN_CODEX_CONFIG="$1/没有.toml" codex_dir_trusted "$1/wt"; [ $? -eq 2 ]' _ "$TM"
tout "m-up --dry 报信任根与状态" "codex 信任根=" "${MUP_ENV[@]}" "$LANE" m-up 测试件 --task "$TM/task.md" --dir "$TM/wt" --dry
t "m-up:目录未信任 ⇒ 起窗前 die(零窗口零会话;⛔ 哑等对话框)" bash -c '
  out="$(env LAIXIN_CODEX_CONFIG="$1/config.toml" LAIXIN_REPO="$1/main" LAIXIN_KB="$1/kb" LAIXIN_SESSION="lx-nowin-$$" LAIXIN_BOARD="$1/b.md" "$2" m-up 测试件 --task "$1/task.md" --dir "$1/wt" 2>&1)"; rc=$?
  [ $rc -ne 0 ] && grep -q "未信任该目录的项目根" <<< "$out" && ! tmux has-session -t "lx-nowin-$$" 2>/dev/null' _ "$TM" "$LANE"
t "vwait_ready_codex:信任对话框快速失败并点名根因(⛔ 自动选默认项 ⛔ 哑等 90s)" bash -c '
  b="$(sed -n "/^vwait_ready_codex()/,/^}/p" "$1")"; grep -q "Do you trust the contents of this directory" <<< "$b" && grep -q "⛔ 自动按 Enter/默认项" <<< "$b"' _ "$LANE"
git -C "$TM/main" worktree remove --force "$TM/wt2" 2>/dev/null || true
rm -rf "$TM"

# ── 额度哨兵 + 账号切换机器化(2026-08-23;创始人「先把这个机制做好,再留下来后面复用」)──────────────────
echo "== 额度哨兵(看门狗只提醒 ⛔ 自动切)+ laixin-lane quota / account-switch =="
TQ="$(mktemp -d)"
cat > "$TQ/usage.json" <<'JSON'
{"official_accounts":[{"account":"a@x","data":{"limits":[{"kind":"session","percent":5,"resets_at":"2026-08-23T10:00:00Z"},{"kind":"weekly_all","percent":94,"resets_at":"2026-08-25T17:00:00Z"}]}},{"account":"b@x","data":{"limits":[{"kind":"weekly_all","percent":7,"resets_at":"2026-08-26T16:00:00Z"}]}}]}
JSON
{ sed -n "/^quota_snapshot()/,/^}/p" "$LANE"; sed -n "/^quota_alert_due()/,/^}/p" "$LANE"; sed -n "/^launcher_cfgdir()/,/^}/p" "$LANE"; } > "$TQ/f.sh"
t "quota_snapshot:从 LAIXIN_USAGE_RAW 读两账号(mail|周%|重置|5h%|重置);5h 缺显 ?;文件不存在退 1" bash -c '
  source "$1/f.sh"; out="$(LAIXIN_USAGE_RAW="$1/usage.json" quota_snapshot)" || exit 1
  grep -q "^a@x|94|2026-08-25T17:00|5|2026-08-23T10:00$" <<< "$out" && grep -q "^b@x|7|2026-08-26T16:00|?|$" <<< "$out" &&
  ! LAIXIN_USAGE_RAW="$1/没有.json" quota_snapshot >/dev/null' _ "$TQ"
t "quota_alert_due:95 无;96 预警一次;再 96 不重复;98 到切换线一次;重置窗口换了再提醒(每线每窗口一次)" bash -c '
  source "$1/f.sh"; QUOTA_WARN=96; QUOTA_SWITCH=98; F="$1/alerted"
  [ -z "$(quota_alert_due 95 a@x R1 "$F")" ] || exit 1
  [ "$(quota_alert_due 96 a@x R1 "$F")" = "96" ] || exit 2
  [ -z "$(quota_alert_due 96 a@x R1 "$F")" ] || exit 3
  [ "$(quota_alert_due 98 a@x R1 "$F")" = "98" ] || exit 4
  [ -z "$(quota_alert_due 99 a@x R1 "$F")" ] || exit 5
  [ "$(quota_alert_due 99 a@x R2 "$F" | tr "\n" ",")" = "96,98," ] || exit 6
  [ -z "$(quota_alert_due abc a@x R2 "$F")" ]' _ "$TQ"
t "launcher_cfgdir:claude→~/.claude-official,claude-b→~/.claude-b" bash -c 'source "$1/f.sh"; [ "$(launcher_cfgdir claude)" = "$HOME/.claude-official" ] && [ "$(launcher_cfgdir claude-b)" = "$HOME/.claude-b" ]' _ "$TQ"
t "看门狗:挂了额度哨兵拍(子 shell 隔离),且哨兵/看门狗里零切换动作(⛔ account_switch ⛔ cmd_dispatch ⛔ cmd_dmsg 出现在哨兵体)" bash -c '
  w="$(sed -n "/^wd_loop()/,/^}$/p" "$1")"; q="$(sed -n "/^quota_sentinel_tick()/,/^}/p" "$1")"
  grep -q "( quota_sentinel_tick )" <<< "$w" && ! grep -q "account_switch" <<< "$w" &&
  ! grep -qE "cmd_dispatch|cmd_dmsg|cmd_relay|account_switch" <<< "$q" && grep -q "desktop_notify" <<< "$q" && grep -q "board \"看门狗\"" <<< "$q"' _ "$LANE"
t "account-switch:缺 --to / 入口不在 PATH ⇒ 拒" bash -c '
  out="$("$1" account-switch 2>&1)"; [ $? -ne 0 ] && grep -q "必须 --to" <<< "$out" || exit 1
  out="$("$1" account-switch --to claude-不存在 2>&1)"; [ $? -ne 0 ] && grep -q "不在 PATH" <<< "$out"' _ "$LANE"
t "account-switch --dry:两个目标里恰一个打印四步计划、另一个报「已在目标通道」;dry 不写开关" bash -c '
  SW="$1/sw"; mkdir -p "$SW"; echo claude-b > "$SW/claude-launcher"
  a="$(env LAIXIN_SWITCH_DIR="$SW" LAIXIN_USAGE_RAW="$1/usage.json" "$2" account-switch --to claude --dry 2>&1)"; ra=$?
  b="$(env LAIXIN_SWITCH_DIR="$SW" LAIXIN_USAGE_RAW="$1/usage.json" "$2" account-switch --to claude-b --dry 2>&1)"; rb=$?
  na=$(grep -c "步骤:" <<< "$a"); nb=$(grep -c "步骤:" <<< "$b")
  [ $((na+nb)) -eq 1 ] || { echo "计划数 $na+$nb"; exit 1; }
  grep -q "已在目标通道" <<< "$a$b" || exit 2
  grep -qE "① 开关.*② 方案窗口.*③ dispatch|① 开关" <<< "$a$b" && grep -q "\[dry\] 以上为计划" <<< "$a$b" &&
  [ "$(cat "$SW/claude-launcher")" = claude-b ]' _ "$TQ" "$LANE"
t "account-switch:写开关后同步本进程 CLAUDE_LAUNCHER(否则 cmd_dispatch 用旧入口起新窗);收班令→等收班条→--fresh 顺序;收班令含交接包/⛔ 接新活/跨通道" bash -c '
  b="$(sed -n "/^cmd_account_switch()/,/^}$/p" "$1")"
  grep -qF "echo \"\$to\" > \"\$sw\"; CLAUDE_LAUNCHER=\"\$to\"" <<< "$b" || { echo "未同步变量"; exit 1; }
  s1=$(grep -n "echo \"\$to\" > \"\$sw\"" <<< "$b" | head -1 | cut -d: -f1); s2=$(grep -n "cmd_dmsg --from" <<< "$b" | head -1 | cut -d: -f1); s3=$(grep -n "收班|交班|换班) dispatch" <<< "$b" | head -1 | cut -d: -f1); s4=$(grep -n "d_out=\"\$(cmd_dispatch --fresh" <<< "$b" | head -1 | cut -d: -f1)
  [ -n "$s1" ] && [ -n "$s2" ] && [ -n "$s3" ] && [ -n "$s4" ] && [ "$s1" -lt "$s2" ] && [ "$s2" -lt "$s3" ] && [ "$s3" -lt "$s4" ] || { echo "顺序 $s1 $s2 $s3 $s4"; exit 2; }
  for k in "交接包" "⛔ 接新活" "跨通道 SendMessage" "收班条"; do grep -qF "$k" <<< "$b" || { echo "缺 $k"; exit 3; }; done' _ "$LANE"
t "account-switch ⛔ 被看门狗/events 调用(只许人手跑)+ 帮助与分发齐全" bash -c '
  w="$(sed -n "/^wd_loop()/,/^}$/p" "$1")"; e="$(sed -n "/^ev_loop()/,/^}$/p" "$1")"
  ! grep -q "cmd_account_switch" <<< "$w" && ! grep -q "cmd_account_switch" <<< "$e" &&
  grep -q "^#   laixin-lane quota" "$1" && grep -q "^#   laixin-lane account-switch" "$1" && grep -qE "^  quota\)" "$1" && grep -qE "^  account-switch\)" "$1" && grep -qE "^  quota-tick\)" "$1"' _ "$LANE"
tout "quota:仪表盘读不到时说读不到 ⛔ 读成充裕(退 1)" "读不到" bash -c 'LAIXIN_USAGE_RAW="'"$TQ"'/没有.json" "'"$LANE"'" quota; true'
rm -rf "$TQ"

# ── 方案窗口第二十三任接班两件(2026-08-23 07:0x):log 旗标拒收 · doctor 8b 交班×总表请裁件 ──────────────
TPR="$(mktemp -d)"; : > "$TPR/board.md"
t "log:-h/--help/--xx 旗标拒收 ⛔ 入账(首撞=接班时 log --help 记出空条);正常文本照记" bash -c '
  out="$(env LAIXIN_BOARD="$1/board.md" LAIXIN_WINDOW=测试 "$2" log --help 2>&1)"; rc=$?; [ $rc -ne 0 ] && grep -q "没有旗标" <<< "$out" || { echo "未拒:$out"; exit 1; }
  out="$(env LAIXIN_BOARD="$1/board.md" LAIXIN_WINDOW=测试 "$2" log -h 2>&1)"; [ $? -ne 0 ] || exit 2
  [ ! -s "$1/board.md" ] || { echo "旗标入账了"; exit 3; }
  env LAIXIN_BOARD="$1/board.md" LAIXIN_WINDOW=测试 "$2" log "正文一条" >/dev/null 2>&1 && grep -q "正文一条" "$1/board.md"' _ "$TPR" "$LANE"
cat > "$TPR/table.md" <<'TBL'
## 📦 交接包 · dispatch 第N任
| **旧片(交接包里的)** | B | 候方案窗口裁落点 |
## 进行中(= 轨道占用)
| 片名 | 轨 | 状态 |
|---|---|---|
| **在飞请裁片** | A | 🔴 **已请方案窗口裁两件**(02:25 `date`)<br>叙述里再提一次候方案窗口裁 |
| **叙述提及片** | A | 开发中<br>历史上曾候方案窗口裁 |
| **划线已销片** | B | ~~候方案窗口裁落点~~ ✅ 已裁 |
> 引用块里写着 候方案窗口裁 也不算
## 排队(无裁定依赖)
| **V0.2 包④ B2 顾问发起转出** | B | 🔴🔴 **发车前重实测推翻了登记前提,已请方案窗口裁(2026-08-23 02:25:59 `date` 实测)**<br>方案包④第 39 行… |
## 已完成(今日)
| **已完成片** | A | 分支 | ✅ 已合入;当年候方案窗口裁过 |
TBL
sed -n "/^table_pending_rulings()/,/^}/p" "$LANE" > "$TPR/f.sh"
t "table_pending_rulings:只认进行中/排队/验收中三节 × 状态格首段;叙述/<br> 后/删除线/引用块/交接包/已完成一律不算" bash -c '
  source "$1/f.sh"; out="$(table_pending_rulings "$1/table.md")"
  [ "$(grep -c "|" <<< "$out")" -eq 2 ] || { echo "行数≠2:"; echo "$out"; exit 1; }
  grep -q "^进行中|在飞请裁片|" <<< "$out" && grep -q "^排队|V0.2包④B2顾问发起转出|" <<< "$out" &&
  ! grep -q "叙述提及片\|划线已销片\|旧片\|已完成片" <<< "$out"' _ "$TPR"
t "doctor 8b:方案窗口交班条**或接班条**(近 N 天)× 总表请裁未销号行 ⇒ 逐条 wrn(≤5 条,余计数);都无 ⇒ 只 ℹ️ 计数;零行 ⇒ ok(首跑实撞:第二十二任零交班条只写快照)" bash -c '
  d="$(sed -n "/^cmd_doctor()/,/^}$/p" "$1")"
  grep -q "table_pending_rulings \"\$TABLE\"" <<< "$d" && grep -q "未销号行——核它们是否进了交接快照" <<< "$d" && grep -q "head -5" <<< "$d" && grep -q "无「候/已请方案窗口裁」未销号行(8b)" <<< "$d" &&
  grep -qF "|接班 ?方案窗口 ?第[一二三四五六七八九十]+任)" <<< "$d"' _ "$LANE"
rm -rf "$TPR"

# ── #108 ①态:接班条纳入交班配对(方案窗口第二十三任 2026-08-23 裁;样本=第二十二任零交班条) ──────────────
TMP108="$(mktemp -d)"; sed -n "/^handover_missing_pred()/,/^}/p" "$LANE" > "$TMP108/f.sh"
printf '| 08-23 07:05 | 方案窗口 | 接班 方案窗口 第二十三任 pingxia-a4(通道 official)… |\n| 08-23 06:48 | 方案窗口 | 🟢 A 轨解卡(方案窗口第二十二任晨间第一件)… |\n' > "$TMP108/recent.md"
cp "$TMP108/recent.md" "$TMP108/full.md"; printf '## 二十七、别的节\n' > "$TMP108/page.md"
t "#108①:接班 第二十三任 已见、第二十二任无交班条无盘点节 ⇒ 报「方案窗口 第二十二任」;提及型「第二十二任晨间第一件」⛔ 当交班条" bash -c '
  source "$1/f.sh"; [ "$(handover_missing_pred "$1/recent.md" "$1/full.md" "$1/page.md")" = "方案窗口 第二十二任" ]' _ "$TMP108"
t "#108①:复盘页已有「方案窗口第二十二任收班盘点」节 ⇒ 不报;前任有交班条 ⇒ 不报(归 ②态);接班 第一任 ⇒ 不报" bash -c '
  source "$1/f.sh"
  printf "## 三十一、方案窗口第二十二任收班盘点\n" > "$1/p2.md"; [ -z "$(handover_missing_pred "$1/recent.md" "$1/full.md" "$1/p2.md")" ] || exit 1
  printf "| 08-23 06:57 | 方案窗口 | 方案窗口第二十二任 交班(快照 0823晨)… |\n" >> "$1/full.md"; [ -z "$(handover_missing_pred "$1/recent.md" "$1/full.md" "$1/page.md")" ] || exit 2
  printf "| 08-23 07:05 | 方案窗口 | 接班 方案窗口 第一任 x |\n" > "$1/r1.md"; [ -z "$(handover_missing_pred "$1/r1.md" "$1/r1.md" "$1/page.md")" ]' _ "$TMP108"
t "#108①:中文数字递减(第十→第九 / 第二十→第十九 / 第二十一→第二十 / 第三十三→第三十二)" bash -c '
  source "$1/f.sh"; for pair in "十:九" "二十:十九" "二十一:二十" "三十三:三十二"; do n="${pair%%:*}"; e="${pair##*:}"
    printf "| 08-23 07:05 | 方案窗口 | 接班 方案窗口 第%s任 x |\n" "$n" > "$1/r.md"; : > "$1/e.md"
    [ "$(handover_missing_pred "$1/r.md" "$1/e.md" "$1/page.md")" = "方案窗口 第${e}任" ] || { echo "第${n}任 → $(handover_missing_pred "$1/r.md" "$1/e.md" "$1/page.md")"; exit 1; }; done' _ "$TMP108"
t "doctor 8c:①态与 ②态分句报(先补交班条再盘点 vs 直接盘点),射程方案窗口席" bash -c '
  d="$(sed -n "/^cmd_doctor()/,/^}$/p" "$1")"; grep -q "handover_missing_pred" <<< "$d" && grep -q "先补交班条再盘点" <<< "$d" && grep -q "#108 ①态" <<< "$d"' _ "$LANE"
rm -rf "$TMP108"

# ── 11B 待定轨首批四件(2026-08-23 方案窗口第二十三任点名排序):①seat_liveness 多通道 ④Waiting 收口 ③假交付降级 ⑤#107 按 diff ──
echo "== 11B 待定轨首批:seat_liveness 多通道 · lane_busy Waiting 收口 · 假交付降级 · #107 按 diff =="
TB4="$(mktemp -d)"
sed -n "/^seat_liveness()/,/^}/p" "$LANE" > "$TB4/sl.sh"
mkdir -p "$TB4/home/.claude-b/sessions" "$TB4/home/.claude-official/sessions" "$TB4/socks"
now_ms=$(( $(date +%s) * 1000 ))
printf '{"name":"pingxia-a4","updatedAt":%s}\n' "$now_ms" > "$TB4/home/.claude-official/sessions/111.json"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$TB4/socks/111.sock"   # 真 unix socket(-S 判据;⛔ 空文件冒充)
printf '| **方案窗口** | **`pingxia-a4`**(第二十三任在班)… |\n| **派工窗口** | **`dispatch`**(在班 · tmux 内看门狗托管)… |\n' > "$TB4/reg.md"
t "①seat_liveness:缺省枚举全部 \$HOME/.claude*/sessions(席位在 official 不再被判死);LAIXIN_CC_SESS 显式单目录仍可用" bash -c '
  source "$1/sl.sh"; export HOME="$1/home" LAIXIN_CC_SOCKS="$1/socks"
  unset LAIXIN_CC_SESS; out="$(seat_liveness "$1/reg.md")"; [ -z "$out" ] || { echo "误判死:$out"; exit 1; }
  out="$(LAIXIN_CC_SESS="$1/home/.claude-b/sessions" seat_liveness "$1/reg.md")"; grep -q "pingxia-a4|" <<< "$out" || { echo "单目录应判死:$out"; exit 2; }
  grep -q "已枚举全部通道" <<< "$(rm -f "$1/socks/111.sock"; seat_liveness "$1/reg.md")"' _ "$TB4"
t "④lane_busy:裸 Waiting 退场——uvicorn「Waiting for application startup.」⛔ 判在飞;codex「Waiting for background terminal」仍在飞;kimi 词表同口径" bash -c '
  { sed -n "/^lane_engine()/,/^}/p" "$1"; sed -n "/^kimi_act_pat()/,/^}/p" "$1"; sed -n "/^lane_busy()/,/^}/p" "$1"; } > "$2/lb.sh"; source "$2/lb.sh"; SESSION=s; win_exists(){ return 0; }
  tmux(){ echo "INFO:     Waiting for application startup."; echo "INFO:     Application startup complete."; }; lane_busy a && { echo "uvicorn 日志被判在飞"; exit 1; }
  tmux(){ echo "  Waiting for background terminal (2m30s)"; }; lane_busy a || exit 2
  tmux(){ echo "INFO:     Waiting for application startup."; }; lane_busy c && { echo "kimi 同族误判"; exit 3; }
  ! grep -qE "\|Waiting\|" <<< "$(kimi_act_pat)"' _ "$LANE" "$TB4"
{ sed -n "/^ev_last_get()/,/^}$/p" "$LANE"; grep -E '^ev_last_(get|set)\(\)' "$LANE" >/dev/null; grep -E '^ev_last_get\(\)|^ev_last_set\(\)' "$LANE"; } > "$TB4/el.sh"
t "③ev_last_get/set:按文件记末行哈希,覆盖不累积,不同文件互不干扰" bash -c '
  source "$1/el.sh"; EV_DIR="$1/ev"; EV_LAST="$1/ev/deliveries.last"
  [ -z "$(ev_last_get /a.md)" ] || exit 1
  ev_last_set /a.md h1; ev_last_set /b.md h9; ev_last_set /a.md h2
  [ "$(ev_last_get /a.md)" = h2 ] && [ "$(ev_last_get /b.md)" = h9 ] && [ "$(grep -c "^/a.md|" "$EV_LAST")" -eq 1 ]' _ "$TB4"
# 🔁 沿革(2026-08-23 #167):本条钉的是「降级判断在**分流 case** 之前」。#167 在降级处新增了一个
#   `case "$lastline" in 【交付完成】*|…` **单行** case(限定降级射程),使原来按 `case "$lastl` 取「第一个 case」
#   的定位落到了新那行 ⇒ 顺序断言假红。⇒ 定位收紧为**行尾 `in`**(分流那个 case 是行尾 in,新加的是同行带模式)。
#   ⛔ 删本条——它钉的意图仍然成立,只是定位串要跟着代码形态走。
t "③ev-loop:末行未变的内容变更 ⇒ 投「更新」(⛔ verify-from ⛔ M1),且判在分流 case 之前;末行变了照旧全量投并登记" bash -c '
  e="$(sed -n "/^ev_loop()/,/^}$/p" "$1")"
  a=$(grep -n "ev_last_get \"\$f\"" <<< "$e" | head -1 | cut -d: -f1); b=$(grep -n "ev_deliver \"更新\"" <<< "$e" | head -1 | cut -d: -f1); c=$(grep -n "case \"\$lastline\" in$" <<< "$e" | head -1 | cut -d: -f1); c_unused=$(grep -n "case \"\$lastline\" in" <<< "$e" | head -1 | cut -d: -f1); d=$(grep -n "ev_last_set \"\$f\" \"\$_llh\"" <<< "$e" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$d" ] && [ "$d" -lt "$c" ] &&
  grep -q "末行未变,非新交付" <<< "$e" && grep -q "⛔ 重起 verify-from" <<< "$e" &&
  dd="$(sed -n "/^ev_deliver()/,/^}$/p" "$1")"; grep -qF "[ \"\$kind\" = \"交付\" ]" <<< "$dd"' _ "$LANE"
# ⑤ kb-commit 按 diff:临时 vault git 仓
V5="$TB4/vault"; mkdir -p "$V5" && git -C "$V5" init -q && printf '| 08-22 22:4x | 历史行含占位 | 内容 |\n' > "$V5/f.md" && git -C "$V5" add f.md && git -C "$V5" -c user.email=t@t -c user.name=t commit -q -m init
t "⑤kb-commit #107:改含历史占位(22:4x)的长行而新增文本无占位 ⇒ 不报;新增文本含 23:1x ⇒ 报且只报新引入的" bash -c '
  printf "| 08-22 22:4x | 历史行含占位 | 内容 追加一段无占位文字 |\n" > "$1/f.md"
  out="$(env LAIXIN_VAULT="$1" GIT_AUTHOR_EMAIL=t@t GIT_AUTHOR_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_COMMITTER_NAME=t "$2" kb-commit "t1" "$1/f.md" 2>&1)"; grep -q "已提交" <<< "$out" || { echo "$out"; exit 1; }
  ! grep -q "#107 占位时刻" <<< "$out" || { echo "误报历史占位:$out"; exit 2; }
  printf "| 08-22 22:4x | 历史行含占位 | 内容 追加 23:1x 新占位 |\n" > "$1/f.md"
  out="$(env LAIXIN_VAULT="$1" GIT_AUTHOR_EMAIL=t@t GIT_AUTHOR_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_COMMITTER_NAME=t "$2" kb-commit "t2" "$1/f.md" 2>&1)"
  grep -q "#107 占位时刻" <<< "$out" && grep -q "23:1x" <<< "$out" && ! grep -q "22:4x" <<< "$out"' _ "$V5" "$LANE"
rm -rf "$TB4"

# ── 11B 待定轨第二批(2026-08-23):vlist 端口 · verify --no-send/vsend · #106 来源标签 · M1 结构销账 ──────────
TB5="$(mktemp -d)"
t "vlist:比照 mlist 输出 BU=v<cksum> 与端口(两窗互异可核);无窗时照旧提示" bash -c '
  { sed -n "/^cdp_port_verify()/,/^}/p" "$1"; sed -n "/^cmd_vlist()/,/^}/p" "$1"; } > "$2/vl.sh"; source "$2/vl.sh"; SESSION=s
  tmux(){ case "$1" in has-session) return 0 ;; list-windows) printf "verify-a node\nverify-b node\nlane-a node\n" ;; esac; }
  out="$(cmd_vlist)"; [ "$(grep -c "BU=v" <<< "$out")" -eq 2 ] || { echo "$out"; exit 1; }
  p1=$(grep "^verify-a" <<< "$out" | grep -oE "端口=[0-9]+"); p2=$(grep "^verify-b" <<< "$out" | grep -oE "端口=[0-9]+"); [ -n "$p1" ] && [ -n "$p2" ] && [ "$p1" != "$p2" ] || exit 2
  tmux(){ case "$1" in has-session) return 0 ;; list-windows) printf "lane-a node\n" ;; esac; }; grep -q "没有在跑的验收窗口" <<< "$(cmd_vlist)"' _ "$LANE" "$TB5"
t "verify --no-send:停在未派单态(正文落 vbrief/<窗>.md、return 在 paste 之前);vsend 派出并删文件;不带参数保持原子派单" bash -c '
  v="$(sed -n "/^cmd_verify()/,/^}$/p" "$1")"
  grep -q "\-\-no-send) nosend=1" <<< "$v" || exit 1
  a=$(grep -n "if \[ -n \"\$nosend\" \]; then" <<< "$v" | head -1 | cut -d: -f1); b=$(grep -n "tmux load-buffer -b laixin-vmsg -" <<< "$v" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || { echo "顺序 $a $b"; exit 2; }
  grep -q "vbrief/\$w.md" <<< "$v" && grep -q "未派单态" <<< "$v" || exit 3
  s="$(sed -n "/^cmd_vsend()/,/^}$/p" "$1")"; grep -q "rm -f \"\$f\"" <<< "$s" && grep -q "confirm_briefed" <<< "$s" && grep -q "load-buffer -b laixin-vmsg" <<< "$s" || exit 4
  grep -qE "^  vsend\)" "$1" && grep -q "^#   laixin-lane vsend" "$1"' _ "$LANE"
tfail "vsend:无落盘正文(非 --no-send 起的/已派过)⇒ 拒" "未找到" env LAIXIN_SESSION=lx-nowin-$$ "$LANE" vsend 从未起过的片
t "#106:搬运投递来源级别按原文取值(来源=第 3 列、标记按原文关键词),⛔ 模板断言「创始人直令」" bash -c '
  e="$(sed -n "/^ev_loop()/,/^}$/p" "$1")"
  ! grep -q "【事件】创始人直令/在飞口径变更已落看板" <<< "$e" && grep -q "口径事件已落看板(来源=\${_dl_src:-?};标记=\${_dl_mark}" <<< "$e" &&
  grep -qF "case \"\$_dl\" in *创始人直令*) _dl_mark=\"创始人直令\" ;; *在飞口径变更*) _dl_mark=\"在飞口径变更\" ;; esac" <<< "$e"' _ "$LANE"
git -C "$TB5" init -q 2>/dev/null && git -C "$TB5" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base && git -C "$TB5" branch -M main 2>/dev/null; H1=$(git -C "$TB5" rev-parse --short HEAD); git -C "$TB5" checkout -q -b feat && git -C "$TB5" -c user.email=t@t -c user.name=t commit -q --allow-empty -m f1; H2=$(git -C "$TB5" rev-parse --short HEAD); git -C "$TB5" checkout -q main
t "M1 结构销账:末行 commit 是 main 祖先 ⇒ 销账;未合入分支 commit ⇒ 不销;no-commit ⇒ 不适用(判据本体=merge-base --is-ancestor)" bash -c '
  cd "$1"; h1="$2"; h2="$3"
  x="$(printf "【交付完成】片甲 %s" "$h1" | grep -oE "\b[0-9a-f]{7,40}\b" | tail -1)"; git merge-base --is-ancestor "$x" main || exit 1
  y="$(printf "【交付完成】片乙 %s" "$h2" | grep -oE "\b[0-9a-f]{7,40}\b" | tail -1)"; git merge-base --is-ancestor "$y" main && exit 2
  z="$(printf "【交付完成】M轨-丙 no-commit" | grep -oE "\b[0-9a-f]{7,40}\b" | tail -1 || true)"; [ -z "$z" ] || exit 3
  e="$(sed -n "/^ev_loop()/,/^}$/p" "$4")"; grep -q "merge-base --is-ancestor \"\$_rc_hex\" main" <<< "$e" && grep -q "结构判据" <<< "$e"' _ "$TB5" "$H1" "$H2" "$LANE"
rm -rf "$TB5"

# ── 11B 待定轨文档批(2026-08-23):两卡句 · 宪法头两句 prompt-lint 绊线 · version-flow 收敛入仓 ──────────────
TDB="$(mktemp -d)"; mkdir -p "$TDB/kb/索引" "$TDB/repo"
printf '宪法头\n8. 需要 prompt 未授权的新机制=停车报告\n   - 片射程与红线冲突=停车场景:停车请裁\n9. 交付报告落盘\n   - 消费者可见片的交付报告必须单列「文案口径」节\n【交付完成】x y\n' > "$TDB/new.md"
printf '宪法头\n8. 需要 prompt 未授权的新机制=停车报告\n9. 交付报告落盘\n【交付完成】x y\n' > "$TDB/old.md"
printf '不是 prompt 的普通文档,没有契约句\n' > "$TDB/doc.md"
t "prompt-lint:宪法头两句绊线——含两句 ⇒ 零缺句;缺 ⇒ 两条 ❌ 宪法头缺句;无宪法头的文档不核" bash -c '
  a="$(env LAIXIN_KB="$1/kb" LAIXIN_REPO="$1/repo" "$2" prompt-lint "$1/new.md" 2>&1)"; ! grep -q "宪法头缺句" <<< "$a" || { echo "$a"; exit 1; }
  b="$(env LAIXIN_KB="$1/kb" LAIXIN_REPO="$1/repo" "$2" prompt-lint "$1/old.md" 2>&1)"; [ "$(grep -c "宪法头缺句" <<< "$b")" -eq 2 ] || { echo "$b"; exit 2; }
  c="$(env LAIXIN_KB="$1/kb" LAIXIN_REPO="$1/repo" "$2" prompt-lint "$1/doc.md" 2>&1)"; ! grep -q "宪法头缺句" <<< "$c"' _ "$TDB" "$LANE"
t "宪法头模板本体含两句(射程红线停车句挂第 8 条 / 文案口径节挂第 9 条)" bash -c '
  m="$HOME/Obsidian/项目入口/来信平台/知识库/4-开发层/prompt/来信平台-prompt宪法头模板.md"; [ -f "$m" ] || { echo "模板不在(环境)"; exit 0; }
  grep -q "片射程与红线冲突=停车场景" "$m" && grep -q "单列「文案口径」节" "$m"'
t "两张卡:pipeline 卡「挂起 ≠ 停工」只放指针 ⛔ 抄全文;kickoff 卡「结构未知字段族先实测」句在" bash -c '
  grep -q "挂起 ≠ 停工" "$1/skills/laixin-pipeline/SKILL.md" && grep -q "本卡只放指针 ⛔ 抄全文" "$1/skills/laixin-pipeline/SKILL.md" &&
  grep -q "结构未知的字段族,prompt ⛔ 替开发方假设结构" "$1/skills/laixin-kickoff/SKILL.md" &&
  grep -q "^### 1-ter. 关系判据的样本值必须能让「通过」与「失败」分开" "$1/skills/laixin-kickoff/SKILL.md"' _ "$(cd "$(dirname "$0")/.." && pwd)"
t "pipeline 派工卡防回胖(≤220 行且 ≤12000 bytes)" bash -c '
  f="$1/skills/laixin-pipeline/SKILL.md"; [ "$(wc -l < "$f" | tr -d " ")" -le 220 ] && [ "$(wc -c < "$f" | tr -d " ")" -le 12000 ]' _ "$(cd "$(dirname "$0")/.." && pwd)"
t "pipeline 瘦身不丢六条操作程序:三条已迁协作流程权威节,另三条卡内留精确指针" bash -c '
  repo="$1"; flow="$HOME/Obsidian/项目入口/来信平台/知识库/4-开发层/来信平台-开发协作流程.md"; card="$repo/skills/laixin-pipeline/SKILL.md"
  sq=$(printf "\\047")
  for want in "流水线纪律（派工操作程序权威）" "1. 先登记后发车" "2. 台账书写八律" "text = text.replace(${sq}⛔ ${sq}, ${sq}不要${sq})" "3. 整行移出与移入" "4. 收方扫存量" "触发不依赖发方标记" "固定做双层扫" "文本零命中不等于零冲突" "结果必须留痕"; do grep -qF "$want" "$flow" || exit 1; done
  grep -qF "核发车位→登记→fresh→send" "$flow" && grep -qF "无 ready 记一次后静默" "$flow" || exit 3
  for want in "先登记后发车 →" "台账八律 →" "整行移出 →" "发车位 →" "打回座位 →" "扫存量 →" "“硬规则” > “发车位纪律”" "“挂起升级创始人” > “打回整改的座位裁决”" "“流水线纪律（派工操作程序权威）” > “4. 收方扫存量”"; do grep -qF "$want" "$card" || exit 2; done' _ "$(cd "$(dirname "$0")/.." && pwd)"
t "version-flow:仓库单点源在(skills/laixin-version-flow/SKILL.md)且 doctor §1 落位清单含它" bash -c '
  [ -s "$1/skills/laixin-version-flow/SKILL.md" ] && grep -q "for sk in laixin-pipeline laixin-acceptance laixin-kickoff laixin-dual-audience laixin-version-flow" "$2"' _ "$(cd "$(dirname "$0")/.." && pwd)" "$LANE"

# ── plan-window 绊线(2026-08-24 11B 工具件「方案窗口skill」)──────────────────────────────
# 夹具落临时文件再跑 ⛔ source <(…)/内联多层引号(bash 3.2 第六发)。
# 🔴 探针**双向验证**:每条判据串必须在权威档里命中 ≥1(阳性对照)且在卡里命中 0(阴性)——
#    只测「卡里 0 命中」会在抽取写错时全绿,那正是本卡自己写死要防的两态同形;
# 🔴 **失效方向朝红**(检查器三约束②):权威档读不到 / 抽不出条目 ⇒ 直接红,⛔ 静默跳过当绿。
cat > "$TDB/lx-planwin-lint.py" <<'PLANWIN_PY'
import io, os, re, sys
repo = sys.argv[1]
card = os.path.join(repo, 'skills/laixin-plan-window/SKILL.md')
lane = os.path.join(repo, 'bin/laixin-lane')
flow = os.path.expanduser('~/Obsidian/项目入口/来信平台/知识库/4-开发层/来信平台-开发协作流程.md')
NOISE = r'[*`🔴⚠️⛔⭐🔑⚖️📌\s]'
strip = lambda t: re.sub(NOISE, '', t)
errs = []
if not os.path.isfile(card) or os.path.getsize(card) == 0:
    print('卡不在或为空:', card); sys.exit(1)
c = io.open(card, encoding='utf-8').read()
cs = strip(c)
n = len(c.rstrip('\n').split('\n'))
b = len(c.encode('utf-8'))
if n > 180: errs.append('卡 %d 行 > 180' % n)
if b > 20000: errs.append('卡 %d bytes > 20000' % b)
if 'name: laixin-plan-window' not in c: errs.append('frontmatter name 不对')
if 'laixin-version-flow laixin-plan-window' not in io.open(lane, encoding='utf-8').read():
    errs.append('doctor §1 落位清单未含 laixin-plan-window')
st = [x for x in ('第二十六任', 'dd33beb', '5959042', '候创始人') if x in c]
if st: errs.append('卡内出现项目状态串:%s' % st)
if not os.path.isfile(flow):
    print('权威档读不到(失效朝红 ⛔ 跳过):', flow); sys.exit(1)
raw = io.open(flow, encoding='utf-8').read()
lines = raw.split('\n')
rawc, flows = raw, strip(raw)
role = os.path.join(os.path.dirname(flow), '来信平台-方案窗口角色卡.md')
if not os.path.isfile(role):
    print('角色卡读不到(失效朝红 ⛔ 跳过):', role); sys.exit(1)
rc = io.open(role, encoding='utf-8').read()
r2a, r2b = rc.find('## 二、上岗两步'), rc.find('## 三、纪律十条')
r2 = rc[r2a:r2b] if 0 <= r2a < r2b else ''
r2_wait = r2.find('接班全程保持「待接」')
r2_doctor = r2.find('`doctor` 0 错')
r2_ready = r2.find('最后把注册表改为「在班」')
if min(r2_wait, r2_doctor, r2_ready) < 0 or not (r2_wait < r2_doctor < r2_ready):
    errs.append('C18:角色卡未锁死待接→doctor→在班次序')
if '「在班」是唯一机器就绪标记' not in raw:
    errs.append('C18:协作流程未定义唯一机器就绪标记')
def sect(title):
    a = next((i for i, l in enumerate(lines) if l.startswith('### ' + title)), None)
    if a is None: return []
    b = next((j for j in range(a + 1, len(lines)) if l_is_head(lines[j])), len(lines))
    return lines[a + 1:b]
def l_is_head(l): return l.startswith('### ') or l.startswith('#### ')
probes = []
for title, lo, hi in (('方案窗口纪律', 1, 11), ('方案窗口交班卡', 0, 7)):
    got = []
    for l in sect(title):
        m = re.match(r'^(\d+)\.\s+', l)
        if m and lo <= int(m.group(1)) <= hi:
            body = l[m.end():]
            got.append(('raw', body[:12]))
            got.append(('strip', strip(body)[:12]))
    if len(got) != (hi - lo + 1) * 2:
        errs.append('%s 抽出 %d 条判据串(期望 %d)——抽取失效,判红' % (title, len(got), (hi - lo + 1) * 2))
    probes += got
for kind, pb in probes:
    src, tgt = (rawc, c) if kind == 'raw' else (flows, cs)
    if len(pb) < 6: errs.append('判据串过短无分辨力:%r' % pb); continue
    if pb not in src: errs.append('阳性对照失败(%s 语料里找不到 %r)——抽取或去噪写错,判红' % (kind, pb))
    if pb in tgt: errs.append('卡内抄了条文正文(%s):%r' % (kind, pb))
# ── 整改轮绊线(2026-08-24 干跑 #1 十七条里可机器判的那几条)──────
# 病灶级:下面每一条在修复被回退时都会变红 ⛔ 只测字串在不在。
kb4 = os.path.expanduser('~/Obsidian/项目入口/来信平台/知识库/4-开发层')
i3 = c.find('### ③ 读注册表你那一行')
i4 = c.find('### ④ 保持注册表「待接」')
i5 = c.find('### ⑤ 读交接包其余五件')
i6 = c.find('### ⑥ 体检 → 落接班条')
doctor = c.find('laixin-lane doctor', i6)
ctx = c.find('laixin-lane ctx', i6)
log = c.find('LAIXIN_WINDOW=方案窗口 laixin-lane log', i6)
ready = c.find('**接班完成闸**', i6)
commit = c.find("laixin-lane kb-commit '注册表:方案窗口第N任", ready)
report = c.find('随后按在局状态报到', ready)
if min(i3, i4, i5, i6, doctor, ctx, log, ready, commit, report) < 0:
    errs.append('C2/C18:接班六步或就绪闸标记不齐')
elif not (i3 < i4 < i5 < i6 < doctor < ctx < log < ready < commit < report):
    errs.append('C2/C18:必须读注册表→保持待接→读包→doctor→最终 ctx→接班条→发布在班→报到')
if 'laixin-lane ctx' in c[:i6]:
    errs.append('接班就绪读数过早:ctx 只能在全部读取与 doctor 后运行')
WANT = ((u'起手式六步', 'C2 步数'),
        (u'N = M+1', 'C1 任次取法'),
        (u'sessionId', 'C11 前8位取处'),
        (u'自证是「证」', 'C3 名字不符分支'),
        (u'名字裸写', 'C4 看板名字形态'),
        (u'已见·归属=', 'C5 警告认领动作'),
        (u'改写同一行', 'C6/C7 注册表行处置'),
        (u'同日多份仍不定', 'C8/C9 快照选型'),
        (u'候方案窗口裁', 'C10 总表 grep 关键词'),
        (u'书写形态四条', 'C15 LAIXIN_WINDOW 第四条'),
        (u'先落盘成文件再派', 'C17 scribe-up 前置'),
        (u'「在班」是就绪标记', 'C18 就绪闸'),
        (u'【接班令】角色=方案窗口第N任', 'C19 短指针接班令'),
        (u'⛔ 复制起步顺序 / 待创始人清单 / 在途正文', 'C19 禁止大段交接消息'),
        (u'11C 未在局且第一件不属于 11C', '11C 按需读'),
        (u'默认只发「动作 + 权威路径#内容锚 + commit」', '通信短指针'),
        (u'ACK-only', '零确认消息'),
        (u'只有关键且仍会变化的文件', '可变指针自核'),
        (u'卡自身步序死锁', '第六族'))
for want, why in WANT:
    if want not in c:
        errs.append('整改项回退(%s):卡内找不到 %r' % (why, want))
s6 = c[c.find('## 六 已发生过的失败'):]
rows6 = [l for l in s6.split('\n')
         if l.startswith('| ') and not l.startswith('| 族 ') and not l.startswith('|---')]
if len(rows6) < 6:
    errs.append('§六 失败样本表只有 %d 行(期望 >= 6 族)' % len(rows6))
if not os.path.isdir(kb4):
    print('知识库 4-开发层读不到(失效朝红 ⛔ 跳过):', kb4); sys.exit(1)
for r in rows6:
    mds = re.findall(r'`([^`]+\.md)`', r)
    if not mds:
        errs.append('§六 该行无真实文件名锚(⛔ 简称):%s' % r[:36]); continue
    for m in mds:
        if not os.path.isfile(os.path.join(kb4, m)):
            errs.append('§六 锚指向盘上不存在的文件:%s' % m)
if errs:
    for e in errs: print('❌', e)
    sys.exit(1)
print('plan-window 绊线全过:%d 行/%d bytes · 判据串 %d 条(raw/strip 各半)阳性命中且卡内 0 命中 · 整改绊线 %d 条全存 · §六 %d 族锚均指盘上真实文件' % (n, b, len(probes), len(WANT), len(rows6)))
PLANWIN_PY
t "plan-window:卡在仓 + 零条文复制/项目状态 + ≤180 行/20000 bytes + 整改不可回退" \
  python3 "$TDB/lx-planwin-lint.py" "$(cd "$(dirname "$0")/.." && pwd)"
rm -rf "$TDB"

# ── vmsg 固定段改形(2026-08-23 M 件「验收窗污染声明文本源定位」结论 A;dispatch 58 建议采)──────────────
t "vmsg 固定段:⛔ 举例词样(旧三词不再出现)· 正文在前提醒在后 · 标注工具固定段且要求逐字引用正文那一句报污染" bash -c '
  b="$(sed -n "/^cmd_vmsg()/,/^}$/p" "$1")"
  ! grep -qF "「该怎么判、期望结果是什么、哪里应该没问题」" <<< "$b" || { echo "仍举例词样"; exit 1; }
  a=$(grep -n "^\$body$" <<< "$b" | head -1 | cut -d: -f1); c=$(grep -n "\[工具固定段" <<< "$b" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ] || { echo "顺序 $a $c"; exit 2; }
  grep -q "⛔ 发件方所写 ⛔ 复述进回执" <<< "$b" && grep -q "逐字引用正文里那一句" <<< "$b" && grep -q "以上为发件方正文" <<< "$b"' _ "$LANE"

# ── 词表引用行号失准机器防线(2026-08-23 待定轨件:①无指纹即红 ③prompt-rescan 批量重扫)────────────────
TRS="$(mktemp -d)"; mkdir -p "$TRS/kb/索引" "$TRS/kb/4-开发层/prompt" "$TRS/repo"
printf '| 键 | 句 |\n|---|---|\n| a | 未能提交:这项金额变更已不存在 |\n| b | 第二句 |\n' > "$TRS/kb/索引/wiki-消费者词汇表.md"
printf '裁定池(夹具)\n' > "$TRS/kb/索引/wiki-裁定池总表.md"; printf '红线清单(夹具)\n' > "$TRS/kb/索引/wiki-红线清单.md"   # lint 读不到这两张会另报 ❌,与本组判据无关
printf '引用 索引/wiki-消费者词汇表.md:3「未能提交」 带指纹\n' > "$TRS/kb/4-开发层/prompt/ok.md"
printf '引用 索引/wiki-消费者词汇表.md:3 无指纹\n' > "$TRS/kb/4-开发层/prompt/nofp.md"
printf '引用 索引/wiki-消费者词汇表.md:4「未能提交」 指纹漂了\n' > "$TRS/kb/4-开发层/prompt/drift.md"
t "prompt-lint:词表引用无指纹 ⇒ ❌(2026-08-23 升红);带对指纹 ⇒ 零错;指纹漂移 ⇒ ❌ 不匹配" bash -c '
  e="env LAIXIN_KB=$1/kb LAIXIN_REPO=$1/repo"
  a="$($e "$2" prompt-lint "$1/kb/4-开发层/prompt/ok.md" 2>&1)"; ! grep -q "❌" <<< "$a" || { echo "$a"; exit 1; }
  b="$($e "$2" prompt-lint "$1/kb/4-开发层/prompt/nofp.md" 2>&1)"; grep -q "❌ 词表引用未带内容指纹" <<< "$b" || { echo "$b"; exit 2; }
  c="$($e "$2" prompt-lint "$1/kb/4-开发层/prompt/drift.md" 2>&1)"; grep -q "❌ 内容指纹不匹配" <<< "$c"' _ "$TRS" "$LANE"
printf '## 进行中(= 轨道占用)\n| 片甲 | A | prompt/drift.md 在飞 |\n## 排队(无裁定依赖)\n| 片乙 | B | 4-开发层/prompt/ok.md 待发 |\n## 已完成(今日)\n| 片丙 | A | prompt/nofp.md 已合 |\n' > "$TRS/table.md"
t "prompt-rescan:只扫总表进行中/排队/验收中引用的 prompt(已完成节的 nofp 不扫),报出 drift 失准、ok 零失准,退出码随失准数" bash -c '
  out="$(env LAIXIN_KB="$1/kb" LAIXIN_REPO="$1/repo" LAIXIN_TABLE="$1/table.md" "$2" prompt-rescan 2>&1)"; rc=$?
  grep -q "扫 2 份 prompt,1 份有引用失准" <<< "$out" || { echo "$out"; exit 1; }
  grep -q "❌ drift.md" <<< "$out" && ! grep -q "nofp.md" <<< "$out" && [ $rc -ne 0 ] || exit 2
  printf "## 进行中\n| 片甲 | A | prompt/ok.md |\n" > "$1/t2.md"
  out2="$(env LAIXIN_KB="$1/kb" LAIXIN_REPO="$1/repo" LAIXIN_TABLE="$1/t2.md" "$2" prompt-rescan 2>&1)"; [ $? -eq 0 ] && grep -q "扫 1 份 prompt,0 份有引用失准" <<< "$out2"' _ "$TRS" "$LANE"
t "prompt-rescan --all:扫 prompt/ 目录近 N 天全部(含 nofp ⇒ 2 份失准)" bash -c '
  out="$(env LAIXIN_KB="$1/kb" LAIXIN_REPO="$1/repo" "$2" prompt-rescan --all --days 1 2>&1)"; grep -q "扫 3 份 prompt,2 份有引用失准" <<< "$out"' _ "$TRS" "$LANE"
rm -rf "$TRS"

# ── 分支命名闸(2026-08-23;版本流卡 A-4 单点源):prompt-lint 分支名校验 + kickoff 卡第 7 条 ───────────────
TBN="$(mktemp -d)"; mkdir -p "$TBN/kb/索引" "$TBN/repo"; printf '裁定池\n' > "$TBN/kb/索引/wiki-裁定池总表.md"; printf '红线\n' > "$TBN/kb/索引/wiki-红线清单.md"
printf '分支:`v02-frontend-nickname-guard`\n' > "$TBN/good.md"
printf '**分支名**:`verify-v02-x-y`\n' > "$TBN/bad1.md"
printf '分支：`advisor-next-milestone`\n' > "$TBN/bad2.md"
printf '分支:`V02-Frontend_x`\n' > "$TBN/bad3.md"
printf '没有分支声明的宪法头 prompt\n【交付完成】x y\n' > "$TBN/nodecl.md"
t "prompt-lint 分支名:v02-<域>-<slug> 过;verify 前缀/旧式短名/大写下划线 ⇒ ❌ 分支名不合规;宪法头 prompt 未声明只 ⚠️" bash -c '
  e="env LAIXIN_KB=$1/kb LAIXIN_REPO=$1/repo"
  a="$($e "$2" prompt-lint "$1/good.md" 2>&1)"; ! grep -q "分支名不合规" <<< "$a" || { echo "$a"; exit 1; }
  for f in bad1 bad2 bad3; do b="$($e "$2" prompt-lint "$1/$f.md" 2>&1)"; grep -q "❌ 分支名不合规" <<< "$b" || { echo "$f: $b"; exit 2; }; done
  c="$($e "$2" prompt-lint "$1/nodecl.md" 2>&1)"; grep -q "⚠️ prompt 未见「分支」" <<< "$c" && ! grep -q "❌ 分支名不合规" <<< "$c"' _ "$TBN" "$LANE"
t "kickoff 卡:发车闸门第 7 条分支命名闸在,指向版本流卡 A-4 单点源" bash -c 'grep -q "^7\. \*\*分支命名闸" "$1/skills/laixin-kickoff/SKILL.md" && grep -q "版本流卡 A-4 为单点源" "$1/skills/laixin-kickoff/SKILL.md"' _ "$(cd "$(dirname "$0")/.." && pwd)"
rm -rf "$TBN"

# ── 验收回执末行分类 × 正文一致性自检(2026-08-23;实证=B5 第二次回执) ──────────────────────────
TRC="$(mktemp -d)"; sed -n "/^receipt_consistency()/,/^}/p" "$LANE" > "$TRC/f.sh"
printf '验收通道注入问题,不是候选代码的可复现缺陷。\n不要求开发轨因本回执改代码。\n【验收回执】打回 工程\n' > "$TRC/r1.md"
printf '全量两轮 PASS。\n【验收回执】通过 v02-x abc1234 def5678\n' > "$TRC/r2.md"
printf '问题 1:状态渲染缺失,可复现。\n【验收回执】打回 工程\n' > "$TRC/r3.md"
printf '本轮复核:上轮打回的两条已改。\n【验收回执】通过 v02-x abc1234 def5678\n' > "$TRC/r4.md"
printf '第二条仍然必须整改。\n【验收回执】通过 v02-x abc1234 def5678\n' > "$TRC/r5.md"
printf '第 1 轮:缺陷两条。\n【验收回执】打回 工程\n第 2 轮复核:两条已改,全量 PASS。\n【验收回执】通过 v02-x abc1234 def5678\n' > "$TRC/r6.md"   # 多轮同文件(真库 B5 形态)
t "receipt_consistency:末行打回+正文「不是候选代码的缺陷/不要求开发轨改」⇒ 报冲突;一致的通过/打回不报;「上轮打回」提及不误报;末行通过+正文「必须整改」⇒ 报" bash -c '
  source "$1/f.sh"
  grep -q "末行=打回,而正文自述非缺陷" <<< "$(receipt_consistency "$1/r1.md")" || exit 1
  [ -z "$(receipt_consistency "$1/r2.md")" ] || exit 2
  [ -z "$(receipt_consistency "$1/r3.md")" ] || exit 3
  [ -z "$(receipt_consistency "$1/r4.md")" ] || { echo "上轮提及误报"; exit 4; }
  grep -q "末行=通过,而正文含打回/整改语" <<< "$(receipt_consistency "$1/r5.md")" || exit 5
  [ -z "$(receipt_consistency "$1/r6.md")" ] || { echo "多轮文件把上一轮末行当本轮打回语误报:$(receipt_consistency "$1/r6.md")"; exit 6; }' _ "$TRC"
t "ev-loop 回执分支附一致性标注(⛔ 按末行自动转整改),verify 派单契约含落盘前自检句" bash -c '
  e="$(sed -n "/^ev_loop()/,/^}$/p" "$1")"; grep -q "receipt_consistency \"\$f\"" <<< "$e" && grep -q "按正文人判 ⛔ 按末行自动转整改" <<< "$e" &&
  v="$(sed -n "/^cmd_verify()/,/^}$/p" "$1")"; grep -q "落盘前自检(2026-08-23)" <<< "$v" && grep -q "末行分类须与正文实质一致" <<< "$v"' _ "$LANE"
rm -rf "$TRC"

# ── relay 双中继守卫按身份判别(2026-08-23;总表待定轨;旧「按 tmux 外会话数」已成狼来了)──────────────────
t "双中继守卫:常态拓扑(tmux 外 2 会话,无一名为 relay)放行——死因 ⛔ 起窗中止(wd44 驱动 guard-ok 模式)" bash -c \
  'out="$(bash "$0" guard-ok "$1")"; ! grep -q "起窗中止" <<< "$out"' "$(cd "$(dirname "$0")/.." && pwd)/tests/wd44-driver.sh" "$LANE"
TRR="$(mktemp -d)"; mkdir -p "$TRR/c1/sessions" "$TRR/c2/sessions"
printf '{"name":"relay"}\n' > "$TRR/c1/sessions/111.json"; printf '{"name":"pingxia-a4"}\n' > "$TRR/c2/sessions/222.json"; printf '{"name":"relay-件甲"}\n' > "$TRR/c2/sessions/333.json"
{ sed -n "/^rival_relay_sessions()/,/^}/p" "$LANE"; sed -n "/^check_rival_relay()/,/^}/p" "$LANE"; } > "$TRR/f.sh"
t "rival_relay_sessions/check_rival_relay:tmux 外名为 relay 的会话=候选(拦);方案窗口名不算;tmux 内 relay-件窗不算;无候选时多会话只 ℹ️ 放行" bash -c '
  source "$1/f.sh"; R="$1"; outside_sessions(){ echo 3; }   # 桩内 $1 是桩自己的参数,目录用 $R
  session_seats(){ printf "111 %s/c1 outside\n222 %s/c2 outside\n333 %s/c2 relay-件甲\n" "$R" "$R" "$R"; }
  [ "$(rival_relay_sessions)" = "111 relay" ] || { echo "候选=$(rival_relay_sessions)"; exit 1; }
  check_rival_relay 2>/dev/null && exit 2
  session_seats(){ printf "222 %s/c2 outside\n333 %s/c2 relay-件甲\n" "$R" "$R"; }
  [ -z "$(rival_relay_sessions)" ] || exit 3
  check_rival_relay 2>"$1/err" || exit 4; grep -q "放行" "$1/err"' _ "$TRR"
rm -rf "$TRR"

# ── #42 走查 Chrome 起停 chrome-up/down/list(2026-08-23 方案窗口第二十三任裁 A)──────────────────────────
TCH="$(mktemp -d)"
t "chrome-up --dry:目标 a/b/dispatch/verify-窗/m-窗 各解析到固定端口(与 BU_CDP_URL 同源);--port 覆盖;未知目标拒" bash -c '
  e="env LAIXIN_SESSION=lx-nowin-$$"
  a="$($e "$1" chrome-up a --dry 2>&1)"; grep -q "端口=9231" <<< "$a" && grep -q "窗=lane-a" <<< "$a" || { echo "$a"; exit 1; }
  b="$($e "$1" chrome-up b --dry 2>&1)"; grep -q "端口=9232" <<< "$b" || exit 2
  d="$($e "$1" chrome-up dispatch --dry 2>&1)"; grep -q "端口=9230" <<< "$d" || exit 3
  v="$($e "$1" chrome-up verify-x-y --dry 2>&1)"; grep -qE "端口=9[3-9][0-9][0-9]" <<< "$v" && grep -q "tmux窗=chrome-" <<< "$v" || exit 4
  m="$($e "$1" chrome-up m-z --dry 2>&1)"; grep -qE "端口=9[3-9][0-9][0-9]" <<< "$m" || exit 5
  p="$($e "$1" chrome-up a --port 9555 --dry 2>&1)"; grep -q "端口=9555" <<< "$p" || exit 6
  pe="$($e "$1" chrome-up --port=9556 --dry 2>&1)"; grep -q "端口=9556" <<< "$pe" && ! grep -q "verify---port" <<< "$pe" || exit 7
  x="$($e "$1" chrome-up "" --dry 2>&1)"; [ $? -ne 0 ]' _ "$LANE"
t "chrome-up --help:打印用法且前后 CDP 进程数不变(⛔ 把 --help 当目标起 Chrome)" bash -c '
  root="$2"; mkdir -p "$root/home" "$root/kb" "$root/repo"
  before="$(pgrep -f -- "--remote-debugging-port=" | wc -l)"
  out="$(env HOME="$root/home" LAIXIN_SESSION=lx-chrome-help-$$ LAIXIN_BOARD="$root/board.md" LAIXIN_KB="$root/kb" LAIXIN_REPO="$root/repo" LAIXIN_CHROME_BIN=/no/such/chrome "$1" chrome-up --help 2>&1)"; rc=$?
  after="$(pgrep -f -- "--remote-debugging-port=" | wc -l)"
  [ "$rc" -eq 0 ] && grep -q "用法:laixin-lane chrome-up" <<< "$out" && [ "$before" = "$after" ] && ! tmux has-session -t lx-chrome-help-$$ 2>/dev/null' _ "$LANE" "$TCH"
t "chrome-up 实体:tmux 服务端托管(new-window chrome-<端口>)⛔ nohup/裸 &;就绪判据=/json/version;url 写回 EV_DIR/cdp;chrome-down 杀窗+cdp_sweep+清 url" bash -c '
  u="$(sed -n "/^cmd_chrome_up()/,/^}$/p" "$1")"; d="$(sed -n "/^cmd_chrome_down()/,/^}$/p" "$1")"
  grep -q "tmux new-window -d -t \"\$SESSION\" -n \"\$cw\"" <<< "$u" && ! grep -q "nohup" <<< "$u" && grep -q "/json/version" <<< "$u" && grep -q "EV_DIR/cdp" <<< "$u" &&
  grep -q "tmux kill-window -t \"\$SESSION:\$cw\"" <<< "$d" && grep -q "cdp_sweep \"\$p\"" <<< "$d" && grep -q "rm -f \"\$EV_DIR/cdp/" <<< "$d"' _ "$LANE"
mkdir -p "$TCH/fakebin" "$TCH/home" "$TCH/kb" "$TCH/repo"
cat > "$TCH/fakebin/pgrep" <<'SH'
#!/bin/bash
[ "${FAKE_PROBE_BROKEN:-}" != 1 ] || exit 2
[ -s "${FAKE_CDP_STATE:?}" ] || exit 1
cat "$FAKE_CDP_STATE"
if [ -s "$FAKE_CDP_STATE.settling" ]; then : > "$FAKE_CDP_STATE"; : > "$FAKE_CDP_STATE.settling"; fi
SH
cat > "$TCH/fakebin/pkill" <<'SH'
#!/bin/bash
[ -s "${FAKE_CDP_STATE:?}" ] || exit 1
if [ "${FAKE_SWEEP_STUCK:-}" = 1 ]; then :
elif [ "${FAKE_SWEEP_DELAY:-}" = 1 ]; then printf '1\n' > "$FAKE_CDP_STATE.settling"
else : > "$FAKE_CDP_STATE"
fi
exit 0
SH
chmod +x "$TCH/fakebin/pgrep" "$TCH/fakebin/pkill"
# 🔴 2026-08-23 监测破案:原夹具漏沙盒 LAIXIN_BOARD ⇒ 每跑一遍套件往生产看板写一条假清理记录(当日 46 条)。
#   本组同时接管 HOME/SESSION/BOARD/KB/REPO,并用状态桩让 before/after 两读数可反证,⛔ 触碰真 Chrome。
t "chrome-down:无→无按读数报未动作;--port=N 解析到 N(⛔ 哈希成目标端口、⛔ 恒真已关)" bash -c '
  root="$2"; state="$root/cdp-empty"; : > "$state"
  out="$(env PATH="$root/fakebin:$PATH" FAKE_CDP_STATE="$state" HOME="$root/home" LAIXIN_SESSION=lx-chrome-down-$$ LAIXIN_BOARD="$root/board-empty.md" LAIXIN_KB="$root/kb" LAIXIN_REPO="$root/repo" "$1" chrome-down --port=9295 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && grep -q "端口 9295 未发现在跑实例,未动作" <<< "$out" && ! grep -q "已关" <<< "$out" && grep -q "未发现在跑实例,未动作" "$root/board-empty.md"' _ "$LANE" "$TCH"
t "chrome-down:有→无按 before-after 报实际关闭数;目标 + --port N 仍解析 N" bash -c '
  root="$2"; state="$root/cdp-running"; printf "101\n102\n" > "$state"
  out="$(env PATH="$root/fakebin:$PATH" FAKE_CDP_STATE="$state" HOME="$root/home" LAIXIN_SESSION=lx-chrome-down-$$ LAIXIN_BOARD="$root/board-closed.md" LAIXIN_KB="$root/kb" LAIXIN_REPO="$root/repo" "$1" chrome-down a --port 9295 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && grep -q "端口 9295 实际关闭了 2 个进程" <<< "$out" && [ ! -s "$state" ] && grep -q "实际关闭了 2 个进程" "$root/board-closed.md"' _ "$LANE" "$TCH"
t "chrome-down:Chrome 退出中的短暂有→有会有界复探到无(⛔ 把终态取早误报关闭失败)" bash -c '
  root="$2"; state="$root/cdp-settling"; printf "111\n112\n" > "$state"
  out="$(env PATH="$root/fakebin:$PATH" FAKE_CDP_STATE="$state" FAKE_SWEEP_DELAY=1 HOME="$root/home" LAIXIN_SESSION=lx-chrome-down-$$ LAIXIN_BOARD="$root/board-settling.md" LAIXIN_KB="$root/kb" LAIXIN_REPO="$root/repo" "$1" chrome-down --port=9295 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && grep -q "实际关闭了 2 个进程" <<< "$out" && [ ! -s "$state" ]' _ "$LANE" "$TCH"
t "chrome-down:有→有输出关闭失败并非零,仍完成 url 清理(⛔ die 在结论前)" bash -c '
  root="$2"; state="$root/cdp-stuck"; printf "201\n" > "$state"; mkdir -p "$root/home/.laixin-events.d/cdp"; printf x > "$root/home/.laixin-events.d/cdp/port-9295.url"
  out="$(env PATH="$root/fakebin:$PATH" FAKE_CDP_STATE="$state" FAKE_SWEEP_STUCK=1 HOME="$root/home" LAIXIN_SESSION=lx-chrome-down-$$ LAIXIN_BOARD="$root/board-stuck.md" LAIXIN_KB="$root/kb" LAIXIN_REPO="$root/repo" "$1" chrome-down --port=9295 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && grep -q "关闭失败.*动作前 1 个.*动作后仍有 1 个" <<< "$out" && grep -q "关闭失败" "$root/board-stuck.md" && [ ! -e "$root/home/.laixin-events.d/cdp/port-9295.url" ]' _ "$LANE" "$TCH"
t "chrome-down:探针损坏显式失败(⛔ 冒充端口无实例)" bash -c '
  root="$2"; state="$root/cdp-broken"; : > "$state"
  out="$(env PATH="$root/fakebin:$PATH" FAKE_CDP_STATE="$state" FAKE_PROBE_BROKEN=1 HOME="$root/home" LAIXIN_SESSION=lx-chrome-down-$$ LAIXIN_BOARD="$root/board-broken.md" LAIXIN_KB="$root/kb" LAIXIN_REPO="$root/repo" "$1" chrome-down --port=9295 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && grep -q "探针失败" <<< "$out" && ! grep -q "未发现在跑实例" <<< "$out"' _ "$LANE" "$TCH"
tfail "chrome-down --port 缺值明确报错(⛔ 当目标名哈希)" "需要端口" env PATH="$TCH/fakebin:$PATH" FAKE_CDP_STATE="$TCH/cdp-empty" HOME="$TCH/home" LAIXIN_SESSION=lx-chrome-down-$$ LAIXIN_BOARD="$TCH/board-invalid.md" LAIXIN_KB="$TCH/kb" LAIXIN_REPO="$TCH/repo" "$LANE" chrome-down --port
t "doctor §4 报无主 tmux 托管 Chrome;宪法头第 12 条含 chrome-up 句(方案窗口给句);帮助与分发齐" bash -c '
  grep -q "tmux 托管 headless Chrome 有 \${_orph} 个无主" "$1" && grep -q "^#   laixin-lane chrome-up" "$1" && grep -qE "^  chrome-(up|down|list)\)" "$1" &&
  m="$HOME/Obsidian/项目入口/来信平台/知识库/4-开发层/prompt/来信平台-prompt宪法头模板.md"; { [ ! -f "$m" ] || grep -q "一律用 \`laixin-lane chrome-up <轨>\`" "$m"; }' _ "$LANE"
rm -rf "$TCH"

# ── ctx 换班双阈(2026-08-23 方案窗口第二十三任裁:提示态下限 + 交班→接班区间自动采样)────────────────────────
TCX="$(mktemp -d)"; { sed -n "/^ctx_abs_min()/,/^}/p" "$LANE" | head -1; grep -E '^ctx_abs_min\(\)' "$LANE"; sed -n "/^ctx_sample_mark()/,/^}/p" "$LANE"; sed -n "/^usage_total_now()/,/^}/p" "$LANE"; sed -n "/^ctx_sample_scan()/,/^}/p" "$LANE"; } > "$TCX/f.sh"
t "ctx_abs_min:env > 开关文件 ctx-abs-min > 空(提示态)" bash -c '
  source "$1/f.sh"; CTX_ABS_MIN_FILE="$1/ctx-abs-min"
  [ -z "$(ctx_abs_min)" ] || exit 1; echo 90000 > "$1/ctx-abs-min"; [ "$(ctx_abs_min)" = 90000 ] || exit 2; [ "$(LAIXIN_CTX_ABS_MIN=5 ctx_abs_min)" = 5 ]' _ "$TCX"
t "ctx_sample_mark:dispatch 交班/收班/换班条=handoff;接管/接班条=takeover;方案窗口交班条与普通派工条=none" bash -c '
  source "$1/f.sh"
  [ "$(ctx_sample_mark "| 08-23 01:58 | 派工窗口 | 收班 dispatch 第五十六任(交班前三轨全空) |")" = handoff ] || exit 1
  [ "$(ctx_sample_mark "| 08-23 02:15 | 派工窗口 | 接管 dispatch 第五十七任(02:10,ctx 实测 24.7%) |")" = takeover ] || exit 2
  [ "$(ctx_sample_mark "| 08-23 07:05 | 方案窗口 | 接班 方案窗口 第二十三任 |")" = none ] || exit 3
  [ "$(ctx_sample_mark "| 08-23 06:50 | 派工窗口 | B1C4 停车已解 |")" = none ]' _ "$TCX"
t "ctx_sample_scan:交班条记起点(仪表盘 current.total)→接班条算增量上看板+落 ctx-samples.log;仪表盘读不到 ⛔ 填 0" bash -c '
  source "$1/f.sh"; EV_DIR="$1/ev"; mkdir -p "$EV_DIR"; board(){ printf "%s\n" "$2" >> "$EV_DIR/board.out"; }; ev_log(){ printf "%s\n" "$*" >> "$EV_DIR/ev.log"; }
  printf "{\"current\":{\"total\":1000}}" > "$1/u.json"; export LAIXIN_USAGE_RAW="$1/u.json"
  printf "| 08-23 01:58 | 派工窗口 | 收班 dispatch 第五十六任 |\n" | ctx_sample_scan; [ -s "$EV_DIR/ctx-sample.pending" ] || exit 1
  printf "{\"current\":{\"total\":1250}}" > "$1/u.json"
  printf "| 08-23 02:15 | 派工窗口 | 接管 dispatch 第五十七任 |\n" | ctx_sample_scan
  grep -q "token 增量 250" "$EV_DIR/board.out" && [ "$(cut -d"|" -f3 "$EV_DIR/ctx-samples.log")" = 250 ] && [ ! -f "$EV_DIR/ctx-sample.pending" ] || { cat "$EV_DIR/board.out"; exit 2; }
  export LAIXIN_USAGE_RAW="$1/没有.json"; printf "| 08-23 03:00 | 派工窗口 | 收班 dispatch 第五十七任 |\n" | ctx_sample_scan; [ ! -f "$EV_DIR/ctx-sample.pending" ] && grep -q "读不到" "$EV_DIR/ev.log"' _ "$TCX"

# ── #158-bis:采样补「席位自身重建耗量」列(2026-08-23;首版落的是机器总增量=上界,拿它写 abs-min 会得出荒谬值)──
t "#158-bis ctx_seat_tokens:未知席位 ⇒ 空且退 1(失效降级 ⛔ 填 0)" bash -c '
  T="$(mktemp -d)"; sed -n "/^ctx_seat_tokens()/,/^}$/p" "'"$LANE"'" > "$T/f.sh"
  source "$T/f.sh"; out="$(ctx_seat_tokens "绝不存在的席位名-zzz" 2>/dev/null)"; rc=$?
  rm -rf "$T"; [ "$rc" -ne 0 ] && [ -z "$out" ]'
t "#158-bis ctx_seat_tokens:空参数即退 1" bash -c '
  T="$(mktemp -d)"; sed -n "/^ctx_seat_tokens()/,/^}$/p" "'"$LANE"'" > "$T/f.sh"
  source "$T/f.sh"; ! ctx_seat_tokens "" >/dev/null 2>&1; rc=$?; rm -rf "$T"; [ "$rc" -eq 0 ]'
t "#158-bis 采样行第 5 列=席位自身耗量(读不到落 ?,⛔ 落 0)" bash -c '
  seg="$(sed -n "/^ctx_sample_scan()/,/^}$/p" "'"$LANE"'")"
  grep -q "ctx_seat_tokens dispatch" <<< "$seg" && grep -q "\${seat:-?}" <<< "$seg"'
t "cmd_ctx 传 CTX_ABS_MIN 并分三态报(硬阈/准备区/提示态待校准);statusline 同读单点源 ctx-abs-min;ev_loop 新增行扫描接了 ctx_sample_scan" bash -c '
  x="$(sed -n "/^cmd_ctx()/,/^}$/p" "$1")"; grep -q "CTX_ABS_MIN=\"\$(ctx_abs_min)\" python3" <<< "$x" && grep -q "下限\*\*待实测校准,当前仅提示\*\*" <<< "$x" && grep -q "绝对余量 {rem:,} < 下限" <<< "$x" &&
  grep -q "ctx-abs-min" "$2" && grep -q "LAIXIN_CTX_ABS_MIN" "$2" &&
  e="$(sed -n "/^ev_loop()/,/^}$/p" "$1")"; grep -q "ctx_sample_scan" <<< "$e"' _ "$LANE" "$(cd "$(dirname "$0")/.." && pwd)/contrib-statusline.py"
rm -rf "$TCX"

# ── 套件零副作用:真实派工权锁(开跑时在 ⇒ 跑完仍在;内容允许变,在班 dispatch/看门狗会续期)──
if [ -n "$REAL_LOCK_BEFORE" ]; then
  t "套件零副作用:真实派工权锁 ~/.laixin-dispatch.lock 未被本套件删除(2026-08-22 halt fixture 实撞)" bash -c '[ -f "$HOME/.laixin-dispatch.lock" ]'
else
  echo "  ℹ️ 套件零副作用:开跑时无真实派工权锁,本断言无对象(不计)"
fi


# ── #162 11C 取号命名族单点源 + 收卷比对报形态(2026-08-23 11C 主持给单;实撞=分居自检对 pick-* 失明 + R1 收卷卡住)──
echo "== #162 11C 取号命名族 + pickcheck =="
SEATB="$(cd "$(dirname "$0")/.." && pwd)/bin/laixin-11c-seat"
S162="$(mktemp -d)"; mkdir -p "$S162/seal" "$S162/pick" "$S162/allow"; : > "$S162/seal/局-测试-代号映射.md"
A162='LAIXIN_11C_SEAL_DIR="$S162/seal" LAIXIN_11C_PICK_DIR="$S162/pick" LAIXIN_11C_ALLOW_ROOT="$S162/allow"'
a162(){ LAIXIN_11C_SEAL_DIR="$S162/seal" LAIXIN_11C_PICK_DIR="$S162/pick" LAIXIN_11C_ALLOW_ROOT="$S162/allow" "$SEATB" audit 2>&1; }
: > "$S162/seal/pick-deadbeef.txt"
tout "#162 造 pick-*.txt 在 SEAL_DIR ⇒ 红〔判据生效的唯一证据:旧判据只认「取号-*」,同一文件改个名就绿,⛔ 删本条〕" "取号族文件出现在 PICK_DIR 之外" a162
tout "#162 报红必附形态(字节+时刻+正确落点)⛔ 只报布尔" "正确落点=" a162
rm -f "$S162/seal/pick-deadbeef.txt"
: > "$S162/seal/取号-x.txt"
tout "#162 旧命名 取号-* 仍红(⛔ 回归)" "取号族文件出现在 PICK_DIR 之外" a162
rm -f "$S162/seal/取号-x.txt"
: > "$S162/seal/无关备件.md"
t "#162 无关文件 ⇒ 绿(⛔ 误报)" bash -c 'out="$(LAIXIN_11C_SEAL_DIR="'"$S162"'/seal" LAIXIN_11C_PICK_DIR="'"$S162"'/pick" LAIXIN_11C_ALLOW_ROOT="'"$S162"'/allow" "'"$SEATB"'" audit 2>&1)"; ! grep -q "取号族文件出现在" <<< "$out"'
rm -f "$S162/seal/无关备件.md"
t "#162 命名族=单点源(判据零内联中文前缀,改一处三处同步)" bash -c '[ "$(grep -c "PICK_NAME_GLOBS" "'"$SEATB"'")" -ge 2 ]'
printf '前缀ABC甲' > "$S162/pick-1.txt"
tout "#162 pickcheck 双向自证①:末字回卷 ⇒ lastchar 吻合" "lastchar" "$SEATB" pickcheck "$S162/pick-1.txt" "甲"
t "#162 pickcheck 双向自证②:错回卷 ⇒ 两规则均不吻合且报**两侧形态差**、rc=1" bash -c '
  out="$("'"$SEATB"'" pickcheck "'"$S162"'/pick-1.txt" "乙" 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && grep -q "6 字符 vs 1 字符" <<< "$out"'
t "#162 pickcheck ⛔ 回显任何一侧内容(输出零命中取号串——工具输出会进日志=第二条泄露路径)" bash -c '
  out="$( { "'"$SEATB"'" pickcheck "'"$S162"'/pick-1.txt" "甲"; "'"$SEATB"'" pickcheck "'"$S162"'/pick-1.txt" "乙"; } 2>&1 )"
  ! grep -q "前缀ABC" <<< "$out"'
t "#162 pickcheck 读不到 ⛔ 读成不吻合(rc=2 与 rc=1 必须分辨)" bash -c '
  "'"$SEATB"'" pickcheck "'"$S162"'/不存在.txt" "甲" >/dev/null 2>&1; [ "$?" -eq 2 ]'
rm -rf "$S162"


# ── #163 注入落地校验(2026-08-23 11C 主持给单;dispatch 59 实撞 seat-thirdview 注入成功而内容未落地)──
echo "== #163 注入落地校验 =="
V163="$(mktemp -d)"; V163F="$V163/fn.sh"
grep -E '^INJECT_SCROLLBACK=' "$LANE" > "$V163F"
for fn in inject_feature inject_features inject_count inject_count_max inject_verify; do sed -n "/^${fn}()/,/^}/p" "$LANE" >> "$V163F"; done
t "#163 特征串:取首非空行前 40 字符,太短则并次行" bash -c 'source "'"$V163F"'"; out="$(printf "%s\n%s" "短" "第二行内容够长了吧" | inject_feature)"; [ "${#out}" -ge 8 ]'
# ── #163 补丁二(dispatch 59 第二次实撞,已产生真实后果:书记员收到两遍门铃)──
t "#163-2 多串:输出 ≥2 个候选且**每个都短**(≤14 字符;长串会被 TUI 折行拆开 ⇒ grep 假阴性 ⇒ 重复投递)" bash -c '
  source "'"$V163F"'"
  out="$(printf "%s\n%s\n%s" "【派工窗口门铃 · dispatch 59 → 书记员席】一条你必须先知道的时序约束" "正文提到 PICK_DIR 与质量五律" "末段说明文字" | inject_features)"
  n="$(printf "%s\n" "$out" | grep -c .)"; [ "$n" -ge 2 ] || exit 1
  while IFS= read -r l; do [ "${#l}" -le 14 ] || exit 1; done <<< "$out"'
t "#163-2 候选串 ⛔ 断字节乱码〔病灶:awk substr 按字节切中文 ⇒ 候选本身是乱码 ⇒ 永远 0 命中 ⇒ 校验静默失效且方向=触发重投〕" bash -c '
  source "'"$V163F"'"
  out="$(printf "%s" "【派工窗口门铃 · dispatch 59 → 书记员席】时序约束" | inject_features)"
  python3 -c "import sys;d=sys.stdin.buffer.read();d.decode(\"utf-8\");sys.exit(0)" <<< "$out"'
t "#163-2 max 取值:三串计数 0/2/1 ⇒ 取 2" bash -c '
  source "'"$V163F"'"; tmux(){ printf "%s\n" "BBB 与 BBB" "CCC"; return 0; }
  [ "$(inject_count_max t "$(printf "%s\n%s\n%s" AAA BBB CCC)")" = "2" ]'
t "#163-2 全部串都读不到 ⇒ 退 1(⛔ 落 0)" bash -c '
  source "'"$V163F"'"; tmux(){ return 1; }; ! inject_count_max t "$(printf "%s\n%s" AAA BBB)" >/dev/null 2>&1'
t "#163 特征串提取零 stderr 噪声(⛔ tr -d 处理多字节:中文 locale 下 Illegal byte sequence,tr 失败会吞掉整串 ⇒ 校验静默失效)" bash -c '
  source "'"$V163F"'"; err="$(printf "%s" "落地校验探针 中文正文" | inject_feature 2>&1 >/dev/null)"; [ -z "$err" ]'
t "#163 计数:同一行内两次出现要计 2〔病灶——grep -c 计行数,同行两次算 1 ⇒ 假报未落地 ⇒ 触发重复投递,比不校验更糟〕" bash -c '
  source "'"$V163F"'"; tmux(){ printf "%s\n" "前缀 AAA 中间 AAA 后缀"; return 0; }; [ "$(inject_count t AAA)" = "2" ]'
t "#163 空屏 ⇒ 计数 0 而非「读不到」〔病灶——按输出是否为空判会让新窗口基线缺失,整条校验退化成判不了〕" bash -c '
  source "'"$V163F"'"; tmux(){ printf ""; return 0; }; out="$(inject_count t AAA)"; rc=$?; [ "$rc" -eq 0 ] && [ "$out" = "0" ]'
t "#163 capture 失败 ⇒ 退 1(读不到 ⛔ 读成 0)" bash -c '
  source "'"$V163F"'"; tmux(){ return 1; }; ! inject_count t AAA >/dev/null 2>&1'
t "#163 判增量 ⛔ 判绝对:历史已有 1 次、投递后 2 次 ⇒ 已落地" bash -c '
  source "'"$V163F"'"; tmux(){ printf "%s\n" "X" "X"; return 0; }; inject_verify t X 1 | grep -q "已落地"'
t "#163 判增量 ⛔ 判绝对:历史已有 1 次、投递后仍 1 次 ⇒ 未落地(绝对计数在此永远命中,失去分辨力)" bash -c '
  source "'"$V163F"'"; tmux(){ printf "%s\n" "X"; return 0; }; out="$(inject_verify t X 1)"; rc=$?; [ "$rc" -eq 1 ] && grep -q "未落地" <<< "$out"'
t "#163 基线缺失 ⇒ rc=2 判不了(⛔ 读成未落地 ⇒ ⛔ 触发重投)" bash -c '
  source "'"$V163F"'"; tmux(){ printf "%s\n" "X"; return 0; }; out="$(inject_verify t X "")"; rc=$?; [ "$rc" -eq 2 ] && grep -q "判不了" <<< "$out"'
t "#163 抓屏必须带 scrollback〔dispatch 实测陷阱:不带 -S 时「没送达」与「已滚出屏幕」同形 ⇒ 校验器自身假阳性 ⇒ 重复投递〕" bash -c '
  sed -n "/^inject_count()/,/^}/p" "'"$LANE"'" | sed "s/#.*//" | grep -q -- "-S .\$INJECT_SCROLLBACK"'
t "#163 增量 4(codex TUI 一次投递渲染多行)⇒ 仍判已落地〔病灶:写成 == 1 会在该类席位永远判失败 ⇒ 重投 ⇒ 计数又增 ⇒ 重投循环〕" bash -c '
  source "'"$V163F"'"; tmux(){ printf "%s\\n" "› X" "  ↳ X" "  ↳ X" "› X"; return 0; }; out="$(inject_verify t X 0)"; rc=$?
  [ "$rc" -eq 0 ] && grep -q "+4" <<< "$out"'
t "#163 判据用 -ge ⛔ -eq;实现里零「倍数」常量(不同 TUI 渲染倍数不同,同引擎两窗实测 +1 与 +4)" bash -c '
  seg="$(sed -n "/^inject_verify()/,/^}/p" "'"$LANE"'" | sed "s/#.*//")"; grep -q -- "-ge 1" <<< "$seg" && ! grep -q -- "-eq 1" <<< "$seg"'
t "#163 cmd_send 接线:投递前取基线(⛔ 事后拿绝对计数)" bash -c '
  seg="$(sed -n "/^cmd_send()/,/^}/p" "'"$LANE"'")"; grep -q "inject_count" <<< "$seg" && grep -q "inject_verify" <<< "$seg"'
t "#163 开发轨只报 ⛔ 自动重投(既有裁定:重发有搞乱 Codex 上下文风险;主持「失败即重投」射程=席位/中继类)" bash -c '
  seg="$(sed -n "/^cmd_send()/,/^}/p" "'"$LANE"'")"; grep -q "⛔ 盲目重发" <<< "$seg"'
rm -rf "$V163"


# ── #164 relay-once codex 独立配型(2026-08-23 创始人令「11C 书记员用 5.6-sol」)──
echo "== #164 relay-once codex 独立配型 =="
t "#164 默认 sol:relay-once codex 配型 ⛔ 复用验收窗的 CODEX_MODEL〔病灶:改全局会误伤验收窗〕" bash -c '
  T="$(mktemp -d)"; echo x > "$T/f.md"
  out="$("'"$LANE"'" relay-once "t164" --file "$T/f.md" --engine codex --dry 2>&1)"; rm -rf "$T"
  grep -q "codex 配型:gpt-5.6-sol xhigh" <<< "$out"'
t "#164 --codex-model 按件覆盖生效" bash -c '
  T="$(mktemp -d)"; echo x > "$T/f.md"
  out="$("'"$LANE"'" relay-once "t164" --file "$T/f.md" --engine codex --codex-model gpt-5.6-terra --dry 2>&1)"; rm -rf "$T"
  grep -q "codex 配型:gpt-5.6-terra" <<< "$out"'
t "#164 起窗串用独立口径变量 ⛔ codex_launch_cmd(那条是验收窗射程)" bash -c '
  seg="$(sed -n "/^cmd_relay_once()/,/^}/p" "'"$LANE"'" | sed "s/#.*//")"
  grep -q "RELAY_ONCE_CODEX_MODEL" <<< "$seg" && ! grep -q "codex_launch_cmd" <<< "$seg"'
t "#164 doctor 显示该配型(⛔ 只能靠起窗横幅事后看)" bash -c '"'"$LANE"'" doctor 2>&1 | grep -q "一次性中继 codex 配型"'
t "#164 11c-seat 认 sol 引擎且显式带档(⛔ 依赖默认——luna 那次默认 medium 咬人)" bash -c '
  seg="$(sed -n "/^  *sol)/,/;;/p" "$(dirname "'"$LANE"'")/laixin-11c-seat")"
  grep -q "gpt-5.6-sol" <<< "$seg" && grep -q "xhigh" <<< "$seg"'
t "#164 11c-seat 引擎枚举含 sol(⛔ 只改帮助文本不改校验)" bash -c '
  grep -q "fable|k3|terra|luna|sol) : ;;" "$(dirname "'"$LANE"'")/laixin-11c-seat"'


# ── #165 11B/11C 开发维护窗(2026-08-23 创始人当面定形态,三次补正:tmux 托管应召 → codex → 只维护 11B/11C)──
echo "== #165 11B/11C 开发维护窗 =="
W165="$(mktemp -d)"; mkdir -p "$W165/kb/4-开发层/记录"; printf '# p\n探针\n' > "$W165/p.md"
t "#165 窗名转义与 rowin/vwin 同款(tmux 目标字符)" bash -c '
  T="$(mktemp -d)"; sed -n "/^toolwin()/,/^}/p" "'"$LANE"'" > "$T/f.sh"; source "$T/f.sh"
  out="$(toolwin "件 名/带.特:殊")"; rm -rf "$T"; [ "$out" = "tool-件-名-带-特-殊" ]'
t "#165 tool_running 零命中恒返 0〔病灶:pipefail 下 grep 退 1 ⇒ 调用方 set -e 当场退出 ⇒ tool-up --dry 静默 rc=1,而「零个在跑」正是最常见的正常态〕" bash -c '
  T="$(mktemp -d)"; sed -n "/^tool_running()/,/^}/p" "'"$LANE"'" > "$T/f.sh"; source "$T/f.sh"
  SESSION=绝不存在的会话-zzz; tool_running >/dev/null; rc=$?; rm -rf "$T"; [ "$rc" -eq 0 ]'
tfail "#165 --prompt 必填(创始人:也需要派工窗口写 prompt;⛔ 把任务塞进命令行)" "必须 --prompt" "$LANE" tool-up t165 --dir "'"$W165"'"
tfail "#165 --dir 必填且必须是工具仓 worktree" "必须 --dir" "$LANE" tool-up t165 --prompt "$W165/p.md"
# 🔴 2026-08-23 三撞:本测原拿「被测脚本所在仓」当主树靶子,套件在 worktree 里跑时该路径 ≠ TOOL_REPO ⇒ 守卫正确放行
#   一棵合法 worktree、测试假红,**且误放行会在真 laixin 会话漏起一个 tool-t165 codex 窗**(当日三次,均人工回收)。
#   修法=LAIXIN_RELEASE_REPO 钉到被测仓自身 ⇒ 任何检出位置下守卫都拒绝「自己的树」,失败面不再漏窗。
tfail "#165 ⛔ 工具仓主树(它是 release 发布源且多窗口共用;与 M 件 ⛔ 落 A 轨主树同族)〔worktree 里跑也成立〕" "不得落工具仓主树" env LAIXIN_RELEASE_REPO="$(cd "$(dirname "$LANE")/.." && pwd)" "$LANE" tool-up t165 --prompt "$W165/p.md" --dir "$(cd "$(dirname "$LANE")/.." && pwd)"
tfail "#165 ⛔ 拿产品仓 worktree 起工具件(本线只维护 11B/11C)" "不是\*\*工具仓\*\*的 worktree" "$LANE" tool-up t165 --prompt "$W165/p.md" --dir "$HOME/来信平台"
t "#165 起动串与开发轨同源:零 -m 零推理档 ⛔ codex_launch_cmd(那条钉 luna/sol,是验收窗与中继件的射程)" bash -c '
  seg="$(sed -n "/^cmd_tool_up()/,/^}/p" "'"$LANE"'" | sed "s/#.*//")"
  grep -qF '"'"'codex$(codex_service_tier_flag)'"'"' <<< "$seg" && ! grep -q "codex_launch_cmd" <<< "$seg"'
# ⚠️ 判据必须**剥注释**再扫:本函数注释里有意写着反引号包的样例(`claude-fable-5[1m]` 等),
#   而互指注释是本仓惯例 ⇒ 该适配的是判据(今日第二次撞同族,前一次是 dry_win_clash 的 ensure_session)。
t "#165 点名指令(**代码部分**)零反引号〔病灶:反引号在 $(cat <<EOF) 里被求值,首火实撞 run.sh: command not found + grep usage〕" bash -c '
  seg="$(sed -n "/^cmd_tool_up()/,/^}/p" "'"$LANE"'" | sed "s/#.*//")"; ! grep -q "\`" <<< "$seg"' 
t "#165 指令写死开分支纪律(⛔ 直接提交 main;与开发轨 AGENTS ③ 同款)" bash -c '
  seg="$(sed -n "/^cmd_tool_up()/,/^}/p" "'"$LANE"'")"; grep -q "开分支开发" <<< "$seg" && grep -q "⛔ 直接提交 main" <<< "$seg"'
t "#165 指令写死射程:只维护 11B/11C ⛔ 产品代码" bash -c '
  seg="$(sed -n "/^cmd_tool_up()/,/^}/p" "'"$LANE"'")"; grep -q "本线只维护 11B/11C" <<< "$seg"'
t "#165 events 认【工具件完成】末行标记" bash -c '
  seg="$(sed -n "/^ev_scan_deliveries/,/^}/p" "'"$LANE"'")"; grep -q "工具件完成" <<< "$seg"'
t "#165 ev_loop 分流:工具件 ⛔ verify-from ⛔ 进 M1" bash -c '
  seg="$(sed -n "/^ev_loop/,/^}/p" "'"$LANE"'")"; grep -q "工具件完成" <<< "$seg" && grep -q "⛔ 起验收窗 ⛔ 进 M1 台账" <<< "$seg"'
t "#165 等待窗不是派工燃料(工具/验收/中继在跑 ⇒ 派工席静默可健康等待)" bash -c '
  seg="$(sed -n "/^wd_fuel()/,/^}/p" "'"$LANE"'" | sed "s/#.*//")"; ! grep -q "verify|relay|m|tool" <<< "$seg"'
t "#165 doctor 报在跑工具窗 ⛔ 单例(worktree 隔离 ⇒ 可并发)" bash -c '
  seg="$(sed -n "/^cmd_doctor/,/^}/p" "'"$LANE"'" | sed "s/#.*//")"
  grep -q "开发维护窗" <<< "$seg" && ! grep -q "单例被破" <<< "$seg"'
# ── #165-2 两条引擎路线(创始人 2026-08-23:「这个位置默认 codex,也写个 claude 的版本」)──
t "#165-2 默认引擎=codex(⛔ 开关缺失时静默变别的)" bash -c '
  T="$(mktemp -d)"; echo x > "$T/p.md"
  # 用真工具仓自身当 --dir:它会被 ⛔主树 那条拦下,但**引擎解析在更前面**,所以 dry 头行仍能验默认引擎;
  # ⛔ 拿 mktemp 目录当 --dir(它连 git 工作树都不是,会先被那条拦掉,验不到引擎)
  out="$(LAIXIN_TOOL_ENGINE= "'"$LANE"'" tool-up t1652 --prompt "$T/p.md" --dir "$(cd "$(dirname "'"$LANE"'")/.." && pwd)" --dry 2>&1 || true)"
  rm -rf "$T"
  # 默认路线的证据:要么 dry 打出「引擎=codex(默认)」,要么被主树那条拦下(说明走到了引擎之后的校验)
  grep -qE "引擎=codex\(默认\)|不得落工具仓主树" <<< "$out"' 
t "#165-2 --engine claude 走第二路线且**模型串带引号**〔病灶:claude-fable-5[1m] 的方括号被 zsh 当 glob ⇒ no matches found ⇒ 整条起动命令没执行,而外部只看到「90s 未见输入框」〕" bash -c '
  seg="$(sed -n "/^cmd_tool_up()/,/^}/p" "'"$LANE"'" | sed "s/#.*//")"
  grep -q -- "--model .\\\"\$TOOL_CLAUDE_MODEL" <<< "$seg"'
t "#165-2 claude 路线带工具层禁令且含 release(两条路线都开分支 ⛔ 提交 main ⇒ release 归合并方)" bash -c '
  T="$(mktemp -d)"; sed -n "/^TOOL_DENY=(/,/^)/p" "'"$LANE"'" > "$T/f.sh"; source "$T/f.sh"
  n="${#TOOL_DENY[@]}"; has=0; for d in "${TOOL_DENY[@]}"; do case "$d" in *release*) has=1 ;; esac; done
  rm -rf "$T"; [ "$n" -ge 20 ] && [ "$has" -eq 1 ]'
t "#165-2 未知引擎即 die(⛔ 静默回落)" bash -c '
  T="$(mktemp -d)"; echo x > "$T/p.md"
  out="$("'"$LANE"'" tool-up t1652 --prompt "$T/p.md" --dir "'"$W165"'" --engine gemini --dry 2>&1 || true)"; rm -rf "$T"
  grep -q "未知引擎" <<< "$out"'
t "#165-2 vtrusted_dir 按 git 结构认工具仓 worktree(⛔ 路径通配:worktree 可建在任意路径)" bash -c '
  T="$(mktemp -d)"; sed -n "/^vtrusted_dir()/,/^}/p" "'"$LANE"'" > "$T/f.sh"; source "$T/f.sh"
  r=0; vtrusted_dir "$(cd "$(dirname "'"$LANE"'")/.." && pwd)" || r=1
  vtrusted_dir /tmp && r=2
  rm -rf "$T"; [ "$r" -eq 0 ]'
t "#165-2 起手式与红线按引擎分叉(claude 说工具层已禁 / codex 说以本指令为准)" bash -c '
  seg="$(sed -n "/^cmd_tool_up()/,/^}/p" "'"$LANE"'")"
  grep -q "工具层已禁" <<< "$seg" && grep -q "没有 claude 的工具层禁令" <<< "$seg" && grep -q "opener=" <<< "$seg"'
t "#165-3 Claude print 薄桥恰为主脚本内三函数(⛔ 独立 runtime)" bash -c '
  [ "$(grep -c "^tool_native_[a-z_]*()" "'"$LANE"'")" -eq 3 ] &&
  grep -q "^tool_native_launch()" "'"$LANE"'" && grep -q "^tool_native_parse()" "'"$LANE"'" && grep -q "^tool_native_status()" "'"$LANE"'"'

N165="$(mktemp -d)"
mkdir -p "$N165/repo" "$N165/home" "$N165/kb" "$N165/sw" "$N165/fakebin"
git init -q -b main "$N165/repo"
git -C "$N165/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$N165/repo" worktree add -q -b item "$N165/wt" main
printf 'probe fixture prompt\n' > "$N165/p.md"
cat > "$N165/fake-claude" <<'SH'
#!/bin/bash
printf '%s\n' "$@" > "${FAKE_ARGS:?}"
if IFS= read -r unexpected; then
  echo 'stdin was not closed' >&2
  exit 91
fi
sid="${FAKE_SESSION:-s-$$}"
init(){ printf '{"type":"system","subtype":"init","session_id":"%s","claude_code_version":"%s","skills":["laixin-pipeline"],"tools":["Skill"],"mcp_servers":[],"permissionMode":"auto"}\n' "$sid" "${FAKE_VERSION:-2.1.241}"; }
case "${FAKE_MODE:-normal}" in
  timeout) sleep 5 ;;
  kill) init; echo 'fixture native killed' >&2; kill -TERM $$ ;;
  unknown) init; printf '%s\n' '{"type":"future_event","session_id":"x"}' '{"type":"result","subtype":"success","session_id":"x"}' ;;
  badjson) init; printf '%s\n' '{"type":bad}' '{"type":"result","subtype":"success"}' ;;
  missing-init) printf '%s\n' '{"type":"assistant","session_id":"none","message":{"content":[]}}' ;;
  missing-result) init ;;
  *)
    printf '%s\n' 'wrapper readiness line'
    printf '{"type":"system","subtype":"hook_started","session_id":"%s","hook_name":"SessionStart:startup"}\n' "$sid"
    printf '{"type":"system","subtype":"hook_response","session_id":"%s","hook_name":"SessionStart:startup","outcome":"success"}\n' "$sid"
    init
    printf '{"type":"system","subtype":"thinking_tokens","session_id":"%s","estimated_tokens":7}\n' "$sid"
    printf '{"type":"assistant","session_id":"%s","message":{"id":"m1","content":[{"type":"tool_use","id":"u1","name":"Skill","input":{"skill":"laixin-pipeline"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1}}}\n' "$sid"
    printf '{"type":"user","session_id":"%s","message":{"content":[{"type":"tool_result","tool_use_id":"u1","is_error":false}]}}\n' "$sid"
    printf '{"type":"tool_progress","session_id":"%s","tool_use_id":"u1","tool_name":"Bash","elapsed_time_seconds":30,"heartbeat":true}\n' "$sid"
    printf '{"type":"rate_limit_event","session_id":"%s","rate_limit_info":{"status":"allowed"}}\n' "$sid"
    printf '{"type":"result","subtype":"success","session_id":"%s","terminal_reason":"completed","permission_denials":[],"usage":{"input_tokens":3,"cache_read_input_tokens":1},"total_cost_usd":0.01}\n' "$sid"
    ;;
esac
SH
cat > "$N165/fakebin/tmux" <<'SH'
#!/bin/sh
[ "${1:-}" != new-window ] || : > "${TMUX_MARK:?}"
exit 0
SH
cat > "$N165/fakebin/codex" <<'SH'
#!/bin/bash
if [ "${1:-}" = "--version" ]; then printf '%s\n' 'codex-cli fixture'; exit 0; fi
printf '%s\n' "$@" > "${FAKE_CODEX_ARGS:?}"
if IFS= read -r unexpected; then echo 'stdin was not closed' >&2; exit 91; fi
thread="${FAKE_CODEX_THREAD:-thread-$$}"
started(){ printf '{"type":"thread.started","thread_id":"%s"}\n{"type":"turn.started"}\n' "$thread"; }
completed(){ printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":3,"cached_input_tokens":1,"cache_write_input_tokens":0,"output_tokens":2,"reasoning_output_tokens":1}}'; }
case "${FAKE_CODEX_MODE:-normal}" in
  failed) started; printf '%s\n' '{"type":"error","message":"429 reconnect evidence"}' '{"type":"turn.failed","error":{"message":"429 fixture exhausted"}}' ;;
  missing) started ;;
  unknown) started; printf '%s\n' '{"type":"future_event"}' ;;
  badjson) started; printf '%s\n' '{"type":bad}' ;;
  quiet) started; sleep "${FAKE_CODEX_SLEEP:-2}"; completed ;;
  *)
    echo 'Skill laixin-pipeline loaded; MCP unavailable fixture evidence' >&2
    started
    printf '%s\n' \
      '{"type":"item.completed","item":{"id":"e1","type":"error","message":"agent refusal evidence"}}' \
      '{"type":"item.completed","item":{"id":"m1","type":"agent_message","text":"objective notice"}}' \
      '{"type":"item.started","item":{"id":"c1","type":"command_execution","command":"false","status":"in_progress"}}' \
      '{"type":"item.completed","item":{"id":"c1","type":"command_execution","command":"false","aggregated_output":"fixture command failed","exit_code":23,"status":"completed"}}'
    completed
    ;;
esac
exit "${FAKE_CODEX_CLI_RC:-0}"
SH
chmod +x "$N165/fake-claude" "$N165/fakebin/tmux" "$N165/fakebin/codex"

dry165(){
  env HOME="$N165/home" LAIXIN_RELEASE_REPO="$N165/repo" LAIXIN_SWITCH_DIR="$N165/sw" \
    LAIXIN_BOARD="$N165/board.md" LAIXIN_KB="$N165/kb" LAIXIN_REPO="$N165/repo" \
    LAIXIN_HEADLESS_SETTINGS="$N165/headless.json" "$LANE" tool-up t165-print \
    --prompt "$N165/p.md" --dir "$N165/wt" --engine claude "$@"
}
printf 'print\n' > "$N165/sw/tool-transport"
out165_cli="$(LAIXIN_TOOL_TRANSPORT=tui dry165 --transport print --dry 2>&1)"
out165_env="$(LAIXIN_TOOL_TRANSPORT=tui dry165 --dry 2>&1)"
out165_file="$(dry165 --dry 2>&1)"
: > "$N165/sw/tool-transport"
out165_empty="$(dry165 --dry 2>&1)"
rm -f "$N165/sw/tool-transport"
out165_default="$(dry165 --dry 2>&1)"
t "#165-3 transport 优先级=参数 > env > 文件 > tui；空/删开关均回 TUI" bash -c '
  grep -q "transport=print" <<< "$1" && grep -q "transport=tui" <<< "$2" &&
  grep -q "transport=print" <<< "$3" && grep -q "transport=tui" <<< "$4" && grep -q "transport=tui" <<< "$5"' \
  _ "$out165_cli" "$out165_env" "$out165_file" "$out165_empty" "$out165_default"
tfail "#165-3 非法 transport 在昂贵校验/起窗前 die" "未知 transport" "$LANE" tool-up t165 --transport warp
t "#165-3 kimi+print 明拒第三片未开且零 tmux 副作用" bash -c '
  out="$(env HOME="$1/home" PATH="$1/fakebin:$PATH" TMUX_MARK="$1/tmux-called" "'$LANE'" tool-up x --engine kimi --transport print 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && grep -q "第三片未开" <<< "$out" && [ ! -e "$1/tmux-called" ]' _ "$N165"
t "#165-3 codex+print 缺 prompt 仍到既有必填校验且零 tmux 副作用" bash -c '
  out="$(env HOME="$1/home" PATH="$1/fakebin:$PATH" TMUX_MARK="$1/tmux-called" "'$LANE'" tool-up x --engine codex --transport print 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && grep -q "必须 --prompt" <<< "$out" && [ ! -e "$1/tmux-called" ]' _ "$N165"
t "#165-3 codex+print 走官方 exec JSON 且 --dry 零 tmux 副作用" bash -c '
  out="$(env HOME="$1/home" PATH="$1/fakebin:$PATH" TMUX_MARK="$1/tmux-called" LAIXIN_RELEASE_REPO="$1/repo" LAIXIN_SWITCH_DIR="$1/sw" LAIXIN_BOARD="$1/board.md" LAIXIN_KB="$1/kb" LAIXIN_REPO="$1/repo" "'$LANE'" tool-up x --engine codex --transport print --prompt "$1/p.md" --dir "$1/wt" --dry 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && grep -q "codex exec --json --sandbox workspace-write -C" <<< "$out" && [ ! -e "$1/tmux-called" ]' _ "$N165"
t "#165-3 --dry 报 engine/transport/账/回退且零持久写" bash -c '
  grep -q "引擎=claude" <<< "$1" && grep -q "transport=print" <<< "$1" && grep -q "native 账:" <<< "$1" && grep -q "回退:" <<< "$1" &&
  [ ! -e "$2/headless.json" ] && [ ! -e "$2/home/.laixin-events.d" ]' _ "$out165_cli" "$N165"
t "#165-3 TUI 路线保留原 vwait_ready + paste；print 判据零抓屏/对话框" bash -c '
  tui="$(sed -n "/^cmd_tool_up()/,/^}/p" "'$LANE'")"
  print="$(sed -n "/print transport begin/,/print transport end/p" "'$LANE'")"
  grep -q "vwait_ready" <<< "$tui" && grep -q "paste-buffer" <<< "$tui" &&
  ! grep -qE "vwait_ready|capture-pane|dialog_sweep" <<< "$print"'
t "#165-3 shipping 只走 -p argv + stream-json/verbose + </dev/null，零 input stream-json" bash -c '
  seg="$(sed -n "/^tool_native_launch()/,/^}/p" "'$LANE'")"
  grep -q -- "-p \"\$brief\"" <<< "$seg" && grep -q -- "--output-format stream-json --verbose" <<< "$seg" &&
  grep -q "</dev/null" <<< "$seg" && ! grep -q -- "--input-format" <<< "$seg"'
t "#165-3 native 账独立按窗/run；零复用 spool/seen/outbox" bash -c '
  seg="$(sed -n "/^tool_native_launch()/,/^}/p;/^tool_native_parse()/,/^}/p;/^tool_native_status()/,/^}/p" "'$LANE'")"
  grep -q "raw.jsonl" <<< "$seg" && grep -q "events.jsonl" <<< "$seg" && grep -q "stderr.log" <<< "$seg" &&
  ! grep -qE "EV_SPOOL|EV_SEEN|RELAY_OUTBOX|EV_PENDING" <<< "$seg"'

native165(){
  local mode="$1" name="$2" version="${3:-2.1.241}" run
  run="$N165/native/$name/run"
  mkdir -p "$run"
  env HOME="$N165/home" LAIXIN_CLAUDE_LAUNCHER="$N165/fake-claude" LAIXIN_BOARD="$N165/native-board.md" \
    LAIXIN_HEADLESS_SETTINGS="$N165/native-headless.json" LAIXIN_TOOL_NATIVE_INIT_TIMEOUT=2 \
    FAKE_MODE="$mode" FAKE_VERSION="$version" FAKE_ARGS="$run/args" FAKE_SESSION="s-$name" \
    "$LANE" tool-native-run "tool-$name" "$run" "$N165/p.md" "$N165/wt" bu 9999
}
native165 normal normal > "$N165/normal.out" 2>&1; normal_rc=$?
native165 unknown unknown > "$N165/unknown.out" 2>&1; unknown_rc=$?
native165 badjson badjson > "$N165/badjson.out" 2>&1; badjson_rc=$?
native165 kill killed > "$N165/killed.out" 2>&1; killed_rc=$?
native165 timeout timeout > "$N165/timeout.out" 2>&1; timeout_rc=$?
native165 missing-init missing-init > "$N165/missing-init.out" 2>&1; missing_init_rc=$?
native165 missing-result missing-result > "$N165/missing-result.out" 2>&1; missing_result_rc=$?
native165 normal drift 9.9.9 > "$N165/drift.out" 2>&1; drift_rc=$?

native165_codex(){
  local mode="$1" name="$2" cli_rc="${3:-0}" run
  run="$N165/native-codex/$name/run"
  mkdir -p "$run"
  env HOME="$N165/home" PATH="$N165/fakebin:$PATH" LAIXIN_TOOL_NATIVE_ENGINE=codex \
    LAIXIN_TOOL_NATIVE_CODEX_FIXTURE_VERSION=fixture-codex LAIXIN_BOARD="$N165/native-codex-board.md" \
    LAIXIN_TOOL_NATIVE_INIT_TIMEOUT=2 FAKE_CODEX_MODE="$mode" FAKE_CODEX_CLI_RC="$cli_rc" \
    FAKE_CODEX_ARGS="$run/args" FAKE_CODEX_THREAD="thread-$name" \
    "$LANE" tool-native-run "tool-codex-$name" "$run" "$N165/p.md" "$N165/wt" bu 9999
}
native165_codex normal normal 7 > "$N165/codex-normal.out" 2>&1; codex_normal_rc=$?
native165_codex failed failed 1 > "$N165/codex-failed.out" 2>&1; codex_failed_rc=$?
native165_codex missing missing > "$N165/codex-missing.out" 2>&1; codex_missing_rc=$?
native165_codex unknown unknown > "$N165/codex-unknown.out" 2>&1; codex_unknown_rc=$?
native165_codex badjson badjson > "$N165/codex-badjson.out" 2>&1; codex_badjson_rc=$?
FAKE_CODEX_SLEEP=2 native165_codex quiet quiet > "$N165/codex-quiet.out" 2>&1 & codex_quiet_pid=$!
sleep 1
codex_quiet_one="$(head -1 "$N165/native-codex/quiet/run/status")"
sleep 0.2
codex_quiet_two="$(head -1 "$N165/native-codex/quiet/run/status")"
wait "$codex_quiet_pid"; codex_quiet_rc=$?

resume165_root="$N165/native-codex/resume"
mkdir -p "$resume165_root/boot" "$resume165_root/turn"
env HOME="$N165/home" PATH="$N165/fakebin:$PATH" LAIXIN_TOOL_NATIVE_ENGINE=codex \
  LAIXIN_TOOL_NATIVE_CODEX_FIXTURE_VERSION=fixture-codex LAIXIN_BOARD="$N165/native-codex-board.md" \
  FAKE_CODEX_ARGS="$resume165_root/boot/args" FAKE_CODEX_THREAD=thread-resume \
  "$LANE" tool-native-run native-resume "$resume165_root/boot" "$N165/p.md" "$N165/wt" bu 9999 > "$N165/resume-boot.out" 2>&1
resume_boot_rc=$?
env HOME="$N165/home" PATH="$N165/fakebin:$PATH" LAIXIN_TOOL_NATIVE_ENGINE=codex \
  LAIXIN_TOOL_NATIVE_CODEX_FIXTURE_VERSION=fixture-codex LAIXIN_BOARD="$N165/native-codex-board.md" \
  FAKE_CODEX_ARGS="$resume165_root/turn/args" FAKE_CODEX_THREAD=thread-resume \
  "$LANE" tool-native-run native-resume "$resume165_root/turn" "$N165/p.md" "$N165/wt" bu 9999 thread-resume __all__ > "$N165/resume-turn.out" 2>&1
resume_turn_rc=$?

t "#165-3 普通前置行 raw+notice 双留且后续可 settled；prompt 是单 argv、stdin=EOF" bash -c '
  [ "$1" -eq 0 ] && grep -Fxq "wrapper readiness line" "$2/raw.jsonl" && grep -q "\"phase\":\"notice\"" "$2/events.jsonl" &&
  grep -q "\"phase\":\"settled\"" "$2/events.jsonl" && grep -Fxq "probe fixture prompt" "$2/args"' _ "$normal_rc" "$N165/native/normal/run"
t "#165-3 init 前官方 hook 生命周期只作未绑定 notice；accepted 仍只认 init" python3 - "$N165/native/normal/run/events.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1])]
hooks = [e for e in events if e.get("native_subtype") in {"hook_started", "hook_response"}]
accepted = [i for i, e in enumerate(events) if e["phase"] == "accepted"]
assert len(hooks) == 2 and all(e["phase"] == "notice" and e["session_id"] is None for e in hooks)
assert len(accepted) == 1 and all(events.index(e) < accepted[0] for e in hooks)
PY
t "#165-3 标准事件每行必有最小信封键且 phase 不越权" python3 - "$N165/native/normal/run/events.jsonl" <<'PY'
import json, sys
required = {"ts","window","engine","cli_version","session_id","pid","cwd","phase","raw_type","usage","exit_code"}
allowed = {"launched","accepted","turn_started","tool_started","tool_finished","assistant_message","settled","failed","protocol_unknown","notice","cancel_requested","cancel_confirmed"}
events = [json.loads(line) for line in open(sys.argv[1])]
assert events and all(required <= set(e) for e in events)
assert all(e["phase"] in allowed for e in events)
assert not any(set(e) & {"quality","success","pass"} for e in events)
PY
t "#165-3 init 保留 skills；真实 Skill tool_started/tool_finished；settled 保留 permission_denials/usage/费用/rate-limit" python3 - "$N165/native/normal/run/events.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1])]
assert any(e["phase"] == "accepted" and "laixin-pipeline" in e["skills"] for e in events)
assert any(e["phase"] == "tool_started" and e["name"] == "Skill" for e in events)
assert any(e["phase"] == "tool_finished" and e["is_error"] is False for e in events)
assert any(e["raw_type"] == "tool_progress" and e["phase"] == "notice" and e["tool_progress_event"]["heartbeat"] is True for e in events)
assert any(e["raw_type"] == "rate_limit_event" and e["rate_limit_event"]["status"] == "allowed" for e in events)
assert any(e["raw_type"] == "system" and e["phase"] == "notice" and e["native_subtype"] == "thinking_tokens" for e in events)
assert any(e["phase"] == "settled" and e["permission_denials"] == [] and e["total_cost_usd"] == .01 and e["usage"]["input_tokens"] == 3 for e in events)
PY
t "#165-3 未知 type:raw+protocol_unknown+非零+零 settled+看板报警" bash -c '
  [ "$1" -ne 0 ] && grep -q "future_event" "$2/raw.jsonl" && grep -q "\"phase\":\"protocol_unknown\"" "$2/events.jsonl" &&
  ! grep -q "\"phase\":\"settled\"" "$2/events.jsonl" && grep -q "protocol_unknown" "$3"' _ "$unknown_rc" "$N165/native/unknown/run" "$N165/native-board.md"
t "#165-3 形似 JSON 坏行:raw+protocol_unknown+非零+零 settled" bash -c '
  [ "$1" -ne 0 ] && grep -Fq "\"type\":bad" "$2/raw.jsonl" && grep -q "\"reason\":\"invalid_json\"" "$2/events.jsonl" && ! grep -q "\"phase\":\"settled\"" "$2/events.jsonl"' _ "$badjson_rc" "$N165/native/badjson/run"
t "#165-3 kill CLI:failed 非零+stderr 尾+零 settled；窗口外状态可区分" bash -c '
  [ "$1" -ne 0 ] && grep -q "\"phase\":\"failed\"" "$2/events.jsonl" && grep -q "fixture native killed" "$2/events.jsonl" &&
  ! grep -q "\"phase\":\"settled\"" "$2/events.jsonl" && grep -q "^failed " "$2/status"' _ "$killed_rc" "$N165/native/killed/run"
t "#165-3 首个合法 init 超时:有界失败+零 settled" bash -c '
  [ "$1" -ne 0 ] && grep -q "\"reason\":\"init_timeout\"" "$2/events.jsonl" && ! grep -q "\"phase\":\"settled\"" "$2/events.jsonl"' _ "$timeout_rc" "$N165/native/timeout/run"
t "#165-3 init/session_id 与 result/subtype 必需；缺任一均非零且零 settled" bash -c '
  [ "$1" -ne 0 ] && [ "$2" -ne 0 ] && ! grep -q "\"phase\":\"settled\"" "$3/events.jsonl" && ! grep -q "\"phase\":\"settled\"" "$4/events.jsonl"' \
  _ "$missing_init_rc" "$missing_result_rc" "$N165/native/missing-init/run" "$N165/native/missing-result/run"
t "#165-3 版本漂移只警一次且不阻断 settled" bash -c '
  [ "$1" -eq 0 ] && [ "$(grep -c "协议版本漂移" "$2")" -eq 1 ] && grep -q "\"cli_version\":\"9.9.9\"" "$3/events.jsonl" && grep -q "\"phase\":\"settled\"" "$3/events.jsonl"' \
  _ "$drift_rc" "$N165/native-board.md" "$N165/native/drift/run"

t "#165-3 codex 官方 exec 固定 argv、零 ephemeral、stdin=EOF" bash -c '
  [ "$1" -eq 0 ] && grep -Fxq exec "$2/args" && grep -Fxq -- --json "$2/args" &&
  grep -Fxq workspace-write "$2/args" && grep -Fxq "probe fixture prompt" "$2/args" &&
  ! grep -q -- --ephemeral "$2/args"' _ "$codex_normal_rc" "$N165/native-codex/normal/run"
t "#165-3 codex thread 接受+持久化；五 usage 键/cost 空；命令 rc23 不覆盖 turn.completed/CLI rc7" python3 - "$codex_normal_rc" "$N165/native-codex/normal/run" <<'PY'
import json, sys
rc, run = int(sys.argv[1]), sys.argv[2]
events = [json.loads(line) for line in open(run + "/events.jsonl")]
assert rc == 0 and open(run + "/thread_id").read().strip() == "thread-normal"
assert any(e["phase"] == "accepted" and e["thread_id"] == "thread-normal" for e in events)
assert any(e["phase"] == "tool_finished" and e["exit_code"] == 23 for e in events)
settled = [e for e in events if e["phase"] == "settled"][-1]
assert settled["cli_exit_code"] == 7 and settled["cost"] is None
assert set(settled["usage"]) == {"input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens"}
assert any(e["phase"] == "notice" and e["item_type"] in {"error", "agent_message"} for e in events)
assert "settled 0" in open(run + "/status").read() and "MCP unavailable" in open(run + "/stderr.log").read()
PY
t "#165-3 codex turn.failed 保留 429、失败且绝不 running" bash -c '
  [ "$1" -ne 0 ] && grep -q "429 fixture exhausted" "$2/events.jsonl" && grep -q "429 reconnect evidence" "$2/events.jsonl" &&
  grep -Fq "\"raw_type\":\"error\"" "$2/events.jsonl" && ! grep -Fq "\"phase\":\"protocol_unknown\"" "$2/events.jsonl" &&
  grep -q "^failed .*turn_failed" "$2/status" && ! grep -q "^running" "$2/status"' \
  _ "$codex_failed_rc" "$N165/native-codex/failed/run"
t "#165-3 codex CLI rc0 + 缺 terminal = result_missing(零假 settled)" bash -c '
  [ "$1" -ne 0 ] && grep -q "^failed 1 result_missing" "$2/status" && grep -Fq "\"cli_exit_code\":0" "$2/events.jsonl" && ! grep -Fq "\"phase\":\"settled\"" "$2/events.jsonl"' \
  _ "$codex_missing_rc" "$N165/native-codex/missing/run"
t "#165-3 codex 未知/坏 JSON 均 raw 留账+protocol_unknown+零 settled" bash -c '
  [ "$1" -ne 0 ] && [ "$2" -ne 0 ] && grep -q future_event "$3/raw.jsonl" && grep -Fq "\"reason\":\"invalid_json\"" "$4/events.jsonl" &&
  ! grep -Fq "\"phase\":\"settled\"" "$3/events.jsonl" && ! grep -Fq "\"phase\":\"settled\"" "$4/events.jsonl"' \
  _ "$codex_unknown_rc" "$codex_badjson_rc" "$N165/native-codex/unknown/run" "$N165/native-codex/badjson/run"
t "#165-3 codex 长静默期间两读都是 running，终态后才 settled" bash -c '
  [ "$1" -eq 0 ] && grep -q "^running" <<< "$2" && grep -q "^running" <<< "$3" && grep -q "^settled 0" "$4/status"' \
  _ "$codex_quiet_rc" "$codex_quiet_one" "$codex_quiet_two" "$N165/native-codex/quiet/run"
t "#165-3 codex resume 同一 thread 再次 accepted，固定官方 resume argv 且零 sandbox" python3 - "$resume_boot_rc" "$resume_turn_rc" "$resume165_root" <<'PY'
import json, sys
boot_rc, turn_rc = map(int, sys.argv[1:3])
root = sys.argv[3]
assert boot_rc == turn_rc == 0
args = open(root + "/turn/args").read().splitlines()
assert args[0:3] == ["exec", "resume", "--json"]
assert "thread-resume" in args and "--sandbox" not in args
events = [json.loads(line) for line in open(root + "/turn/events.jsonl")]
assert any(e["phase"] == "accepted" and e.get("resumed") is True and e["thread_id"] == "thread-resume" for e in events)
assert open(root + "/turn/accepted").read().strip() == "thread-resume"
PY

sed -n '/^tool_native_parse()/,/^}/p' "$LANE" > "$N165/native-parse.sh"
t "#165-3 pid/session 绑定:同 session 后续放行；第二 init/错 pid/错 session/跨 run 重复均拒" env T="$N165" bash -c '
  board(){ printf "%s\n" "$*" >> "$T/parse-board"; }
  source "$T/native-parse.sh"
  prep(){ mkdir -p "$1"; : > "$1/raw.jsonl"; : > "$1/events.jsonl"; : > "$1/status"; }
  init(){ printf "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"%s\",\"claude_code_version\":\"2.1.241\"}" "$1"; }
  prep "$T/bind/run"; tool_native_parse "$T/bind/run" w 100 100 /tmp "$(init S1)" || exit 1
  tool_native_parse "$T/bind/run" w 100 100 /tmp "{\"type\":\"assistant\",\"session_id\":\"S1\",\"message\":{\"content\":[]}}" || exit 2
  tool_native_parse "$T/bind/run" w 100 100 /tmp "$(init S1)" && exit 3
  tool_native_parse "$T/bind/run" w 100 101 /tmp plain && exit 4
  tool_native_parse "$T/bind/run" w 100 100 /tmp "{\"type\":\"assistant\",\"session_id\":\"WRONG\",\"message\":{\"content\":[]}}" && exit 5
  prep "$T/cross/r1"; prep "$T/cross/r2"; tool_native_parse "$T/cross/r1" w 200 200 /tmp "$(init SX)" || exit 6
  tool_native_parse "$T/cross/r2" w 201 201 /tmp "$(init SX)" && exit 7
  [ "$(grep -c protocol_unknown "$T/bind/run/events.jsonl")" -ge 3 ] && grep -q "duplicate_session_across_run" "$T/cross/r2/events.jsonl"'
t "#165-3 codex thread 绑定:持久化、第二 thread/跨 run 重复拒绝，未绑定 turn 拒绝" env T="$N165" bash -c '
  board(){ :; }; export LAIXIN_TOOL_NATIVE_ENGINE=codex
  source "$T/native-parse.sh"
  prep(){ mkdir -p "$1"; : > "$1/raw.jsonl"; : > "$1/events.jsonl"; : > "$1/status"; }
  thread(){ printf "{\"type\":\"thread.started\",\"thread_id\":\"%s\"}" "$1"; }
  prep "$T/codex-bind/run"; tool_native_parse "$T/codex-bind/run" w 300 300 /tmp "$(thread C1)" || exit 1
  [ "$(cat "$T/codex-bind/run/thread_id")" = C1 ] || exit 2
  tool_native_parse "$T/codex-bind/run" w 300 300 /tmp "$(thread C1)" && exit 3
  prep "$T/codex-cross/r1"; prep "$T/codex-cross/r2"; tool_native_parse "$T/codex-cross/r1" w 301 301 /tmp "$(thread CX)" || exit 4
  tool_native_parse "$T/codex-cross/r2" w 302 302 /tmp "$(thread CX)" && exit 5
  prep "$T/codex-before/run"; tool_native_parse "$T/codex-before/run" w 303 303 /tmp "{\"type\":\"turn.started\"}" && exit 6
  grep -q second_thread "$T/codex-bind/run/events.jsonl" && grep -q duplicate_session_across_run "$T/codex-cross/r2/events.jsonl" && grep -q event_before_thread "$T/codex-before/run/events.jsonl"'
t "#165-3 codex resume 只放行同一 thread，错 thread 仍是协议错误" env T="$N165" bash -c '
  board(){ :; }; export LAIXIN_TOOL_NATIVE_ENGINE=codex
  source "$T/native-parse.sh"
  prep(){ mkdir -p "$1"; : > "$1/raw.jsonl"; : > "$1/events.jsonl"; : > "$1/status"; }
  prep "$T/codex-resume/ok"; printf C1 > "$T/codex-resume/ok/bound-session"; : > "$T/codex-resume/ok/resume-thread"
  tool_native_parse "$T/codex-resume/ok" w 401 401 /tmp "{\"type\":\"thread.started\",\"thread_id\":\"C1\"}" || exit 1
  prep "$T/codex-resume/bad"; printf C1 > "$T/codex-resume/bad/bound-session"; : > "$T/codex-resume/bad/resume-thread"
  tool_native_parse "$T/codex-resume/bad" w 402 402 /tmp "{\"type\":\"thread.started\",\"thread_id\":\"C2\"}" && exit 2
  grep -q "resumed.*true" "$T/codex-resume/ok/events.jsonl" && grep -q resume_thread_mismatch "$T/codex-resume/bad/events.jsonl"'
t "#165-4 lane transport 优先级与 print 入口同源，C 轨在动窗前拒绝" bash -c '
  T="$(mktemp -d)"; mkdir -p "$T/sw"; sed -n "/^lane_transport_resolve()/,/^}/p" "'$LANE'" > "$T/f.sh"; source "$T/f.sh"
  LANE_SWITCH_DIR="$T/sw"; printf print > "$T/sw/lane-transport"
  a="$(lane_transport_resolve print)"; b="$(LAIXIN_LANE_TRANSPORT=tui lane_transport_resolve "")"; c="$(lane_transport_resolve "")"; : > "$T/sw/lane-transport"; d="$(lane_transport_resolve "")"
  f="$(sed -n "/^cmd_fresh()/,/^}/p" "'$LANE'")"; rm -rf "$T"
  [ "$a" = print ] && [ "$b" = tui ] && [ "$c" = print ] && [ "$d" = tui ] && grep -q "lane_native_fresh" <<< "$f" && grep -q "不是 Codex 轨" <<< "$f"'
t "#165-4 Kimi 的 TUI 回退保持 cmd_up 原路径，零 native 账写入" bash -c '
  f="$(sed -n "/^cmd_fresh()/,/^}/p" "'$LANE'")"
  compact="$(tr "\\n" " " <<< "$f")"; grep -q "lane_engine.*codex.*native_transport_set" <<< "$compact"'
t "#165-4 print 分支用 native 账续轮，TUI 读屏判据只留在回退分支" bash -c '
  fresh="$(sed -n "/^cmd_fresh()/,/^}/p" "'$LANE'")"; send="$(sed -n "/^cmd_send()/,/^}/p" "'$LANE'")"; verify="$(sed -n "/^cmd_verify()/,/^}/p" "'$LANE'")"
  grep -q "lane_native_fresh" <<< "$fresh" && grep -q "native_print_resume" <<< "$send" && grep -q "native_print_bootstrap" <<< "$verify" && grep -q "native_print_resume" <<< "$verify"'
t "#165-4 native print 把 BU 通道注入窗内启动串" bash -c '
  T="$(mktemp -d)"; mkdir -p "$T/root" "$T/wt"; printf x > "$T/brief"
  sed -n "/^native_run_start()/,/^}/p" "'$LANE'" > "$T/f.sh"; source "$T/f.sh"
  tmux(){ printf "%s\\n" "$*" > "$T/tmux"; }; native_tmux_start(){ tmux -L native new-session "$@"; }; SESSION=s BOARD="$T/board" KB="$T/kb" DEFAULT_DIR="$T/repo" TOOL_REPO="$T/tool" LANE_SWITCH_DIR="$T/sw"
  native_run_start lane-a "$T/root" "$T/brief" "$T/wt" lane-a 9231 >/dev/null
  ok=0; grep -Fq "BU_NAME=lane-a" "$T/tmux" && grep -Fq "BU_CDP_URL=http://127.0.0.1:9231" "$T/tmux" && grep -Fq -- "-L native new-session" "$T/tmux" || ok=1; rm -rf "$T"; exit "$ok"'
t "#165-4 native print 每 run 用独立 TMUX_TMPDIR、继承当前环境且回收 server" bash -c '
  T="$(mktemp -d)"; sed -n "/^native_tmux_start()/,/^}/p;/^native_tmux_cleanup()/,/^}/p" "'"$LANE"'" > "$T/f.sh"; source "$T/f.sh"
  mkdir "$T/run"; launch="printf %s \"\$HTTP_PROXY\" > \"$T/proxy\"; sleep 30"
  HTTP_PROXY=print-isolated native_tmux_start "$T/run" "$T" "$launch" || exit 1
  tmp="$(cat "$T/run/tmux-tmpdir")"
  for n in $(seq 1 30); do TMUX_TMPDIR="$tmp" tmux -L native has-session -t native 2>/dev/null && break; sleep 0.1; done
  TMUX_TMPDIR="$tmp" tmux -L native has-session -t native 2>/dev/null || { rm -rf "$T"; exit 2; }
  [ "$(cat "$T/proxy")" = print-isolated ] || { native_tmux_cleanup "$T/run"; rm -rf "$T"; exit 3; }
  native_tmux_cleanup "$T/run"
  ! TMUX_TMPDIR="$tmp" tmux -L native has-session -t native 2>/dev/null && [ -e "$T/run/tmux-cleaned" ]; rc=$?
  rm -rf "$T"; exit "$rc"'
t "#165-4 tool-up 的 print native runner 走隔离 server，默认窗只作回收载体" bash -c '
  seg="$(sed -n "/^cmd_tool_up()/,/^}/p" "'"$LANE"'")"
  grep -q "native_tmux_start \"\$native_run\" \"\$dir_r\" \"\$launch\"" <<< "$seg" &&
  grep -q "默认窗只作回收载体" <<< "$seg"'
t "#165-4 BU 自检只接受 native shell 的精确通道输出，缺失或错值必失败" bash -c '
  T="$(mktemp -d)"; sed -n "/^native_bu_self_check()/,/^}/p" "'$LANE'" > "$T/f.sh"; source "$T/f.sh"
  mkdir -p "$T/run"; python3 - "$T/run/events.jsonl" <<"PY"
import json, sys
json.dump({"phase":"tool_finished", "item_type":"command_execution", "exit_code":0,
           "aggregated_output":"lane-a\nhttp://127.0.0.1:9231\n"}, open(sys.argv[1], "w"))
PY
  native_bu_self_check "$T/run" lane-a 9231 && ! native_bu_self_check "$T/run" lane-b 9231; rc=$?; rm -rf "$T"; exit "$rc"'
t "#165-4 tmux 回收杀掉 native 进程后，read 不得把旧账读成 running" bash -c '
  T="$(mktemp -d)"; sed -n "/^tool_native_status()/,/^}/p" "'"$LANE"'" > "$T/f.sh"; source "$T/f.sh"
  board(){ printf "| 00-00 00:00 | %s | %s |\\n" "$1" "$2" >> "$T/board"; }
  mkdir -p "$T/run"; printf "running stale-thread\\n" > "$T/run/status"; printf tool-test > "$T/run/window"; printf codex > "$T/run/engine"
  sleep 30 & p=$!; kill "$p"; wait "$p" 2>/dev/null || true; printf "%s\\n" "$p" > "$T/run/pid"
  out="$(tool_native_status read "$T/run")"; grep -q "^failed 1 process_gone" <<< "$out" && grep -qx "failed 1 process_gone" "$T/run/status" && awk -F"|" "\$3 ~ /^ tool-native \$/ && \$4 ~ /process_gone/ { found=1 } END { exit !found }" "$T/board"; rc=$?; rm -rf "$T"; exit "$rc"'
t "#165-4 print bootstrap 在接受任务前执行并核 BU 自检" bash -c '
  f="$(sed -n "/^native_print_bootstrap()/,/^}/p" "'$LANE'")"
  grep -q "native_bu_self_check" <<< "$f" && grep -q "BU_CDP_URL" <<< "$f"'
t "#165-3 settled 与报告契约彻底分离；失败零 retry；看板仍唯一经 board()" bash -c '
  status="$(sed -n "/^tool_native_status()/,/^}/p" "'$LANE'")"
  native="$(sed -n "/^tool_native_parse()/,/^}/p;/^tool_native_status()/,/^}/p;/^tool_native_launch()/,/^}/p" "'$LANE'")"
  ! grep -q "工具件完成" <<< "$status" && ! grep -qi "retry" <<< "$native" && grep -q "codex exec resume" <<< "$native" && [ "$(grep -cF ">> \"\$BOARD\"" "'$LANE'")" -eq 1 ]'
rm -rf "$N165"
rm -rf "$W165"


# ── #166 stats 油表两列同权 + table-lint 前导竖线(2026-08-23 dispatch 60 报,三条全属实)──
echo "== #166 stats/_blocked 两列同权 · table-lint 前导竖线 =="
V166="$(mktemp -d)"
cat > "$V166/t.md" <<'MD'
## 排队

| 片 | 轨 | 内容 | 发车状态 |
|---|---|---|---|
| A片 | A | 射程说明(此列刻意不写依赖:本条要验的正是「依赖只写在状态列」) | 🔴 prompt 已 ready 但不可立即发车——候 P1 交付落盘 |
| B片 | A | 零前置 | prompt ready |

## 进行中

| 片 | 轨 | 内容 | 发车状态 |
|---|---|---|---|
MD
# ⚠️ 夹具措辞也要过判据:首版内容列写「射程说明**无前置**词」,被解除词族 `无前置` 命中 ⇒ 整行判不阻塞,
#    红的原因在夹具不在被测代码。⭐ 造反例夹具时,先确认它没有意外命中**另一条**判据。
# 🔴 真跑 stats 对沙盒总表(⛔ 用占位命令假装跑过——本条首版正是那样写的,红了才发现)
tout "#166① 依赖写在**状态列**也要算阻塞〔病灶:两条正则原本只作用在内容列 ⇒ 夜间会据虚高油表发一个发不出去的片〕" "前置未解 1 行" env LAIXIN_TABLE="$V166/t.md" "$LANE" stats
tout "#166① 同表里无前置的行仍进 ✅ 桶(⛔ 一刀切判阻塞)" "可立即发车(prompt ready 且未发): 1" env LAIXIN_TABLE="$V166/t.md" "$LANE" stats
# ⚠️ 提取范围要到**函数末**:`return False` 在 _blocked 里出现两次(解除词那条先),
#    首版 sed 写 /return False/ 被第一个截断 ⇒ seg 里看不到后面的判据(红的原因与被测行为无关)
t "#166① _blocked 两列同权(both=pre+st)⛔ 只读内容列" bash -c '
  seg="$(sed -n "/def _blocked/,/^    return False$/p" "'"$LANE"'" | sed "s/#.*//")"
  grep -q "both=pre" <<< "$seg" && [ "$(grep -c ",both)" <<< "$seg")" -ge 3 ]'
t "#166② 补中文否定词族(台账第 7 律禁表格行用 ⛔ ⇒ 守纪律的人写的阻塞标记此前永远命不中)" bash -c '
  seg="$(sed -n "/def _blocked/,/^    return False$/p" "'"$LANE"'" | sed "s/#.*//")"
  grep -q "不可立即发车" <<< "$seg"'
t "#166① ⛔ 宽词族/⛔ 阻塞挂起停车(真库实测:宽词族状态列命中 22%、阻塞族 22 行全是历史记录)" bash -c '
  seg="$(sed -n "/def _blocked/,/^    return False$/p" "'"$LANE"'" | sed "s/#.*//")"
  ! grep -qE "阻塞\\|挂起\\|停车" <<< "$seg"'
printf '| 名 | b | c | d |\n|---|---|---|---|\n| ⛔ 甲行 | x | y | z |\n' > "$V166/m.md"
tout "#166③ --match 带前导竖线应命中〔真根因=前导竖线 ⛔ 报告方归因的「含 ⛔」;三态实测:带竖线不含⛔ 同样零命中〕" "唯一命中" "$LANE" table-lint "$V166/m.md" --match "| ⛔ 甲行"
tout "#166③ --match 不带前导竖线等价命中" "唯一命中" "$LANE" table-lint "$V166/m.md" --match "⛔ 甲行"
rm -rf "$V166"


# ── #167 末行未变降级只对带 commit 的契约(2026-08-23 实撞:书记员回复被判「更新」⇒ 收方据文案判不用管)──
echo "== #167 降级射程 =="
t "#167 降级射程=只对【交付完成】/【验收回执】(末行带 commit/结论)" bash -c '
  seg="$(sed -n "/末行未变的内容变更/,/^      fi$/p" "'"$LANE"'" | sed "s/#.*//")"
  grep -q "【交付完成】\*|【验收回执】\*) _prev=" <<< "$seg"'
t "#167 末行固定句的三种契约 ⛔ 降级〔病灶:中转回复末行永远是「…来自 relay-once」,同件第二次落盘会永远被判更新〕" bash -c '
  seg="$(sed -n "/末行未变的内容变更/,/^      fi$/p" "'"$LANE"'" | sed "s/#.*//")"
  grep -q "\*) _prev=\"\"" <<< "$seg"'
t "#167 病灶级:失败面是「投了一条告诉人别管的事件」⛔「没投递」——注释须留住这条判读" bash -c '
  grep -q "投的却是一条\*\*告诉人别管\*\*的事件" "'"$LANE"'"'
t "#167 降噪:交付报告同契约正文更新只记日志;回执同契约更新仍投事件" bash -c '
  e="$(sed -n "/末行未变的内容变更/,/^      fi$/p" "'"$LANE"'")"
  grep -q "ev_same_contract_mode" <<< "$e" && grep -q "报告正文更新静默" <<< "$e"'


# ── #168 doctor 报 11C 在局(方案窗口第二十四任批:条文靠人记,提示靠机器)──
t "#168 11C 有席位/机务窗在跑 ⇒ doctor 出提示" bash -c '
  T="$(mktemp -d)"; sed -n "/#168(2026-08-23 方案窗口第二十四任批)/,/^    fi$/p" "'"$LANE"'" > "$T/f.sh"
  grep -q "11C 在局" "$T/f.sh" && grep -q "秒级" "$T/f.sh"; rc=$?; rm -rf "$T"; [ "$rc" -eq 0 ]'
t "#168 只报事实 ⛔ 下令(射程边界写进输出本身)" bash -c '
  grep -q "⛔ 据本行下令,它只报事实" "'"$LANE"'"'
t "#168 零在局时不出这行(⛔ 常驻噪声)" bash -c '
  seg="$(sed -n "/#168(2026-08-23 方案窗口第二十四任批)/,/^    fi$/p" "'"$LANE"'")"
  grep -q "gt 0 \] || \[ " <<< "$seg"'


# ── #169/#170 双盲 status 默认零画面 · claim 身份闸(2026-08-23 分窗后)──
echo "== #169 status 零画面 · #170 claim 身份闸 =="
SEATB2="$(cd "$(dirname "$0")/.." && pwd)/bin/laixin-11c-seat"
t "#169 status 默认**零画面**〔病灶:原实现固定打印末 8 行 ⇒ 判个死活就把席位作答正文带上屏,而总纲收卷禁深读条点名的正是这个判据〕" bash -c '
  seg="$(sed -n "/^cmd_status()/,/^}/p" "'"$SEATB2"'" | sed "s/#.*//")"
  grep -q "pane_n" <<< "$seg" && ! grep -q "S -8" <<< "$seg"'
t "#169 活性判据=两次 capture 比 SHA(零正文出屏)⛔ 词表匹配画面" bash -c '
  seg="$(sed -n "/^cmd_status()/,/^}/p" "'"$SEATB2"'" | sed "s/#.*//")"
  [ "$(grep -c "capture-pane" <<< "$seg")" -ge 2 ] && grep -q "shasum" <<< "$seg"'
t "#169 --pane 硬上限 3 行(总纲禁深读条)" bash -c '
  seg="$(sed -n "/^cmd_status()/,/^}/p" "'"$SEATB2"'")"; grep -q "le 3 \]" <<< "$seg"'
# 🔁 沿革(#169-2):文案由「静止也可能是在思考或已卡住」升级为**点明三个真值 + 指向真判据**
#   ⇒ 断言随文案更新 ⛔ 删(它钉的意图=静止态必须自带「⛔ 读成已完卷」的警告,意图不变)。
t "#169 静止态必须自带「⛔ 读成已完卷」警告" bash -c '
  grep -q "三个真值" "'"$SEATB2"'"'
t "#170 claim 身份闸:窗口名 ≠ \$DISPATCH_WIN 一律要 --force〔缺口:原判据只在「锁被别人持有且新鲜」时拦 ⇒ 锁过期/无人持有时任何窗口都能拿走派工权〕" bash -c '
  seg="$(sed -n "/^cmd_claim()/,/^}/p" "'"$LANE"'" | sed "s/#.*//")"
  grep -q "me\" != \"\$DISPATCH_WIN\" \] && \[ \"\${1:-}\" != \"--force\"" <<< "$seg"'
t "#170 夺锁必须点名两窗(⛔ 静默易主:原来只记新持有者,被夺方无痕)" bash -c '
  seg="$(sed -n "/^cmd_claim()/,/^}/p" "'"$LANE"'")"; grep -q "派工权易主" <<< "$seg"'


# ── #169-2 status 三态说明 + 会话名可覆盖(2026-08-23;补验 dispatch-11c 未覆盖的 Working 分支)──
echo "== #169-2 status Working 分支 · 会话名可覆盖 =="
S169="lx-t169-$$"
tmux kill-session -t "$S169" 2>/dev/null || true
tmux new-session -d -s "$S169" -n seat-probe 'while true; do date +%s.%N; sleep 0.3; done' 2>/dev/null && sleep 1
tout "#169-2 Working 分支(画面在变)〔dispatch-11c 真环境只覆盖到静止分支,这条是本仓自造的另一半〕" "Working(画面在变)" env LAIXIN_11C_SESSION="$S169" "$SEATB2" status seat-probe
tmux new-window -d -t "$S169" -n seat-idle 'sleep 600' 2>/dev/null && sleep 1
tout "#169-2 静止分支点明**三个真值**并指向真判据(⛔ 只写「⛔ 读成已完卷」)" "三个真值" env LAIXIN_11C_SESSION="$S169" "$SEATB2" status seat-idle
tout "#169-2 静止行指向真判据=带末行契约的文件数 ⛔ 用本行" "带末行契约的文件数" env LAIXIN_11C_SESSION="$S169" "$SEATB2" status seat-idle
t "#169-2 --pane 超限降到 3 行 ⛔ 照给" bash -c '
  out="$(LAIXIN_11C_SESSION="'"$S169"'" "'"$SEATB2"'" status seat-idle --pane 8 2>&1)"
  grep -q "上限 3 行" <<< "$out" && grep -q "画面末 3 行" <<< "$out"'
t "#169-2 会话名可覆盖〔缺口:原为硬编码 laixin-11c ⇒ 本脚本自己测不了隔离会话,把自己排除在「真环境首火在隔离会话做」那条纪律之外〕" bash -c '
  grep -q "SESSION=\"\${LAIXIN_11C_SESSION:-laixin-11c}\"" "'"$SEATB2"'"'
tmux kill-session -t "$S169" 2>/dev/null || true


# ── #171 「末行」判据下沉为单点源(2026-08-23 dispatch 61 实撞,有真实损失:白等 6 分钟)──
echo "== #171 契约行取法单点源 =="
T171="$(mktemp -d)"
printf '# 报告\n正文\n【交付完成】测试片 abc1234\n\n\n' > "$T171/tail_blank.md"
printf '# 报告\n【交付完成】测试片 abc1234\n' > "$T171/tail_clean.md"
printf '' > "$T171/empty.md"
sed -n "/^last_contract_line()/,/^}/p" "$LANE" > "$T171/f.sh"
t "#171 契约行后有空行仍取得到〔病灶:ev_scan 用 tail -1 读到空行 ⇒ 交付事件根本没投,而 verify-from 四道校验全过 ⇒ 一个说没交付一个说合规〕" bash -c '
  source "'"$T171"'/f.sh"; [ "$(last_contract_line "'"$T171"'/tail_blank.md")" = "【交付完成】测试片 abc1234" ]'
t "#171 无尾随空行时结果不变(⛔ 回归)" bash -c '
  source "'"$T171"'/f.sh"; [ "$(last_contract_line "'"$T171"'/tail_clean.md")" = "【交付完成】测试片 abc1234" ]'
t "#171 空文件出空 ⛔ 报错" bash -c '
  source "'"$T171"'/f.sh"; [ -z "$(last_contract_line "'"$T171"'/empty.md")" ]'
t "#171 文件不存在退非零(读不到 ⛔ 读成无契约)" bash -c '
  source "'"$T171"'/f.sh"; ! last_contract_line "'"$T171"'/nope.md" >/dev/null 2>&1'
t "#171 单点源:ev_scan_deliveries 与 report-lint 都调它,全仓零残留裸 tail -1 取契约行" bash -c '
  seg1="$(sed -n "/^ev_scan_deliveries()/,/^}/p" "'"$LANE"'" | sed "s/#.*//")"
  seg2="$(sed -n "/^cmd_report_lint()/,/^}/p" "'"$LANE"'" | sed "s/#.*//")"
  grep -q "last_contract_line" <<< "$seg1" && grep -q "last_contract_line" <<< "$seg2" &&
  ! grep -q "tail -1 \"\$f\" | grep -qE" <<< "$seg1"'
rm -rf "$T171"


# ══ 并入:11C 专属派工窗口通道(原 tests/run-11c-dispatch.sh,42 条)══════════════════════
# 🔴 并入自独立文件(2026-08-23):它落盘时 `tests/run.sh` 被 11B 归口在飞件(#166)占用 ⇒ 作者按
#   AGENTS 并发红线独立成文件并注明「并入 run.sh 归合并方」。本次由 11B 归口合并并删除原文件。
echo "== 11C 专属派工窗口通道(laixin-11c-dispatch) =="
BIN="$(cd "$(dirname "$0")/.." && pwd)/bin/laixin-11c-dispatch"
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

# ══ 并入:写单窗 prompt-up(原 tests/run-prompt-lane.sh,27 条)═══════════════════════════
# 🔴 同上:独立成文件的原因是同文件并发红线,⛔ 读成「它该独立」。
# ⚠️ **合并方 ⛔ 把 `^(verify|relay|m)-|^prompt-` 那处正则改回等价形**(报告点名;本套件两处断言
#    钉着它的**字面**,等价改写实撞过 2 红)——判据钉字面是有意的,⛔ 「整齐化」。
echo "== 写单窗(prompt-up 写 prompt 动线) =="
# (LANE 已在本套件顶部定义,⛔ 重复声明)
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
