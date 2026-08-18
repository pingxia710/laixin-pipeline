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
tout "up 有 codex 启动自检(拒载秒退=脚本说成功现场没成功,回头验尸)" "codex 未在跑" sed -n "/^cmd_up/,/^}/p" "$LANE"
tout "启动自检不自动重试(同因重试同死,只会刷屏)" "盲目重试" sed -n "/^cmd_up/,/^}/p" "$LANE"
tout "send 有被吞检测(8s 抓屏找活动迹象)" "send 疑似被吞" sed -n "/^cmd_send/,/^}/p" "$LANE"
tout "send 被吞检测不自动重发" "盲目重发" sed -n "/^cmd_send/,/^}/p" "$LANE"

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
printf '引用 索引/wiki-消费者词汇表.md:2 与 转单-9。\n' > "$TMPP/ph-good.md"
tfail "词表占位符未注取值来源 → 红(优化#11)" "占位符" \
  env LAIXIN_KB="$TMPP/kb" LAIXIN_REPO="$TMPP/repo" "$LANE" prompt-lint "$TMPP/ph-bad.md"
tout "占位符带取值注 → 过" "0 项查无" \
  env LAIXIN_KB="$TMPP/kb" LAIXIN_REPO="$TMPP/repo" "$LANE" prompt-lint "$TMPP/ph-good.md"
# #22a(2026-08-19):占位符只扫词格——第三格备注引用被替换旧句(含 N)不再算到新句头上。
# 定稿句零占位而备注引旧句 ⇒ 修复前报红(结构性误报),修复后过。
printf '| 付款指引 | 收款方式会短信发给你 | 替换「请按线下收款指令支付 N 元」旧句 |\n' >> "$TMPP/kb/索引/wiki-消费者词汇表.md"
printf '引用 索引/wiki-消费者词汇表.md:3 与 转单-9。\n' > "$TMPP/ph-note.md"
tout "备注格引旧句含占位不误伤新句(#22a 只扫词格)" "0 项查无" \
  env LAIXIN_KB="$TMPP/kb" LAIXIN_REPO="$TMPP/repo" "$LANE" prompt-lint "$TMPP/ph-note.md"
printf '| 坏例 | 预计 X 日内原路到账 | 备注 |\n' >> "$TMPP/kb/索引/wiki-消费者词汇表.md"
printf '引用 索引/wiki-消费者词汇表.md:4 与 转单-9。\n' > "$TMPP/ph-cell.md"
tfail "词格本身含占位仍红(#22a 不放松词格)" "占位符" \
  env LAIXIN_KB="$TMPP/kb" LAIXIN_REPO="$TMPP/repo" "$LANE" prompt-lint "$TMPP/ph-cell.md"
# #22b:供给侧半面提示(提示级不拦,退出码仍 0)
printf 'admin 工作台改造。引用 索引/wiki-消费者词汇表.md:2 与 转单-9。\n' > "$TMPP/ph-side.md"
tout "提及供给侧界面只引消费者词表 → ⚠️ 提示(#22b)" "供给侧词汇表逐角色" \
  env LAIXIN_KB="$TMPP/kb" LAIXIN_REPO="$TMPP/repo" "$LANE" prompt-lint "$TMPP/ph-side.md"
t "#22b 提示不改变退出码(纯提示级)" \
  env LAIXIN_KB="$TMPP/kb" LAIXIN_REPO="$TMPP/repo" "$LANE" prompt-lint "$TMPP/ph-side.md"
# #18a:改读法片缺消费点清单 → 提示级
printf '收敛 payload 序列化面。引用 索引/wiki-消费者词汇表.md:2 与 转单-9。\n' > "$TMPP/ph-read.md"
tout "改读法片缺消费点清单 → ⚠️ 提示(#18a)" "消费点清单" \
  env LAIXIN_KB="$TMPP/kb" LAIXIN_REPO="$TMPP/repo" "$LANE" prompt-lint "$TMPP/ph-read.md"
printf '收敛 payload 序列化面,消费点清单如下。引用 索引/wiki-消费者词汇表.md:2 与 转单-9。\n' > "$TMPP/ph-read2.md"
t "带消费点清单不提示(#18a)" bash -c 'out="$(env LAIXIN_KB="'"$TMPP"'/kb" LAIXIN_REPO="'"$TMPP"'/repo" "'"$LANE"'" prompt-lint "'"$TMPP"'/ph-read2.md" 2>&1)"; ! grep -q "消费点清单——" <<< "$out"' 
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
rm -rf "$TMPP"

echo
echo "结果:$PASS 过 / $FAIL 败"
[ "$FAIL" -eq 0 ]
