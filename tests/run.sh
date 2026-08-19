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
env LAIXIN_SESSION="$R32S" LAIXIN_RELAY_ENABLED="$R32/m" LAIXIN_BOARD="$R32/b.md" "$LANE" halt >/dev/null 2>&1 || true
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
# ⭐ 绊线①(本批最关键的一条):默认值必须是 claude。#66 的教训=换默认值会让「同一条命令在换代前后
#   语义不同,而命令本身长得一模一样」;而 dispatch 起窗会被 resurrect/boot 链**无人值守自动调用**。
t "#67 派工引擎默认 claude(⛔ 学 #60① 默认 codex:起窗会被 boot/resurrect 无人值守自动调用)" bash -c \
  'grep -qE "LAIXIN_DISPATCH_ENGINE:-.*echo claude" "'"$LANE"'" && ! grep -qE "LAIXIN_DISPATCH_ENGINE:-codex" "'"$LANE"'"'
  "LAIXIN_DISPATCH_ENGINE:-claude" grep -n "^DISPATCH_ENGINE=" "$LANE"
t "#67 默认值确实不是 codex(回退检测:谁把默认改了本行立刻红)" bash -c \
  '! grep -q "LAIXIN_DISPATCH_ENGINE:-codex" "'"$LANE"'"'
# ⭐ 绊线②:值打错在**动窗口之前**拒(同 #60① 一课)——dispatch 起窗会先 kill 掉旧窗口,
#   校验放后面等于「参数打错就把正在派工的窗口杀了」。
tfail "#67 未知派工引擎被拒且指明合法值" "只接受 codex|claude" \
  env LAIXIN_DISPATCH_ENGINE=bogus LAIXIN_SESSION=bogus-d67 "$LANE" dispatch   # ⚠️ 样本原为 kimi,
  # 2026-08-19 kimi 成为**合法**第三引擎后必须换掉:否则本条不再测「拒绝」而是真的起一个 kimi
  # 派工窗口,并在 fixture 会话里留下残渣。⇒ **加新引擎时先查有没有绊线拿它当反例。**
t "#67 未知引擎被拒时零 tmux 副作用(⛔ 留下半个死会话)" bash -c \
  '! tmux has-session -t bogus-d67 2>/dev/null'
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
# ⭐ 绊线④:codex 路径起窗形态=照 cmd_verify 的 codex 分支(MCP 全关 + 通道注入 + codex 就绪判据)
tout "#67 codex 起窗 MCP 全量关闭(照 lane/verify 同一函数,⛔ 另拼)" "lane_mcp_off_flags" \
  sed -n "/^cmd_dispatch()/,/^}/p" "$LANE"
tout "#67 codex 就绪判据复用 vwait_ready_codex(⛔ 拿 claude 输入框判据量 codex)" "vwait_ready_codex \"\$DISPATCH_WIN\"" \
  sed -n "/^cmd_dispatch()/,/^}/p" "$LANE"
# ⭐ 绊线⑤:工具层锁失效必须**明写进派单指令**——DISPATCH_DENY 实测只有 git push 一条,
#   codex 无 disallowedTools 等价物 ⇒ 锁静默失效,而「锁在」与「锁没了」在体检输出里原本同形。
tout "#67 codex 派单指令明写 git push 禁令(工具层锁失效的补位)" "⛔ git push" \
  sed -n "/^DISPATCH_BRIEF_CODEX=/,/窗口记忆不算数/p" "$LANE"
tfail "#67 doctor 在 codex 引擎下点名 push 锁失效(⛔ 只写在提交信息里)" "工具层锁\*\*不生效\*\*" \
  bash -c 'env LAIXIN_DISPATCH_ENGINE=codex "'"$LANE"'" doctor | grep "工具层锁"; exit 1'
tout "#67 doctor 在 claude 引擎下旧文案逐字保留" "派工窗口钉:" \
  env LAIXIN_DISPATCH_ENGINE=claude "$LANE" doctor
# ⭐ 绊线⑥:派单指令必须告诉 codex「回程不会弹进你的输入框」——否则它会干等一个永远不来的消息
tout "#67 codex 派单指令写明回程走落盘+路径指针(⛔ 等它直接注入)" "那条路不存在" \
  sed -n "/^DISPATCH_BRIEF_CODEX=/,/窗口记忆不算数/p" "$LANE"
tout "#67 codex 派单指令写明 ctx 必须带 --engine codex(否则读到别人的数)" "ctx --engine codex" \
  sed -n "/^DISPATCH_BRIEF_CODEX=/,/窗口记忆不算数/p" "$LANE"

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
{ sed -n "/^ev_scan_deliveries/,/^}/p" "$LANE"; sed -n "/^relay_outbox_overdue/,/^}/p" "$LANE"; } > "$TMPR/fn.sh"
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
t "#75 三处起窗调用点全部走变量,零硬编码 claude(漏一处=该窗口静默用旧账号)" bash -c \
  'n="$(grep -c "\$CLAUDE_LAUNCHER -n " "'"$LANE"'")"; [ "$n" = 3 ] || { echo "变量调用点=$n,应为3"; exit 1; };
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
t "#44 绊线:首起路径双中继守卫照旧(无豁免旗,常态拓扑必拦且 rc 非零)" bash -c \
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
{ sed -n "/^lane_engine()/,/^}/p" "$LANE"; sed -n "/^send_swallow_check()/,/^}/p" "$LANE"; } > "$T40/f.sh"   # #60②:检测分引擎,lane_engine 一并抽出
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
tout "词表引用未带指纹 → ⚠️ 提示并给写法" "未带内容指纹" "${FPE[@]}" "$LANE" prompt-lint "$FPD/fp-none.md"
t "未带指纹提示不改退出码(提示级)" "${FPE[@]}" "$LANE" prompt-lint "$FPD/fp-none.md"
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
# ⭐ fresh c 必须 --dir(机器执法):不带即拒且**窗口未动**(破坏性动作前置校验);--dir 不存在同拒
tfail "#60②:fresh c 不带 --dir 被拒(每片独立 worktree,同 B 轨形态)" "fresh c 必须带 --dir" \
  env LAIXIN_SESSION=lx60c-nonexist "$LANE" fresh c
tfail "#60②:fresh c --dir 目录不存在照拒(窗口未动)" "目录不存在" \
  env LAIXIN_SESSION=lx60c-nonexist "$LANE" fresh c --dir "$C60/没有这个worktree"
t "#60②:fresh c 被拒时零 tmux 副作用" bash -c '! tmux has-session -t lx60c-nonexist 2>/dev/null'
# ⭐ --with-mcp 是 codex 专属语法:C 轨拒收(静默吞掉=调用者以为生效了),且动窗口之前拒
tfail "#60②:up c --with-mcp 被拒(codex 专属参数 ⛔ 静默吞)" "codex 专属参数" \
  env LAIXIN_SESSION=lx60c-nonexist "$LANE" up c --with-mcp aliyun-readonly
t "#60②:up c --with-mcp 被拒时零 tmux 副作用" bash -c '! tmux has-session -t lx60c-nonexist 2>/dev/null'
# ⭐ 起动命令按引擎分派:kimi --auto + -m 显式钉死(防配置漂移);codex 路径原样(MCP 关闭参数仍在)
t "#60②:cmd_up 起动命令分引擎(kimi --auto -m 钉死 / codex MCP 关闭原样)" bash -c '
  body="$(sed -n "/^cmd_up()/,/^}/p" "$0")"
  grep -q -- "\$KIMI_BIN\\\\\" --auto -m \$KIMI_MODEL" <<< "$body" || grep -q -- "--auto -m \$KIMI_MODEL" <<< "$body" || exit 1
  grep -q "codex \$_mcp_off" <<< "$body"' "$LANE"
KM="$(bash -c "eval \"\$(grep '^KIMI_MODEL=' '$LANE')\"; echo \"\$KIMI_MODEL\"")"
tout "#60②:kimi 模型默认钉 kimi-code/k3" "kimi-code/k3" echo "$KM"
KM2="$(env LAIXIN_KIMI_MODEL=kimi-code/k4 bash -c "eval \"\$(grep '^KIMI_MODEL=' '$LANE')\"; echo \"\$KIMI_MODEL\"")"
tout "#60②:kimi 模型可覆盖(LAIXIN_KIMI_MODEL)" "kimi-code/k4" echo "$KM2"
# ⭐ kimi 画面判据(2026-08-19 临时会话实测):在飞=月相转轮/Running;codex 词表(Explored)⛔ 量 kimi
C60B="$C60/busy.sh"; { sed -n "/^lane_engine()/,/^}/p" "$LANE"; sed -n "/^lane_busy()/,/^}/p" "$LANE"; } > "$C60B"
t "#60②:lane_busy 分引擎——kimi 月相=在飞,codex 词表不误判 kimi" bash -c '
  source "'"$C60B"'"; SESSION=s; win_exists(){ return 0; }
  tmux(){ echo " 🌔 · Tip: /sessions to browse"; }
  lane_busy c || exit 1
  tmux(){ echo "  Explored codebase"; }
  lane_busy a || exit 1
  ! lane_busy c'
C60S="$C60/swallow.sh"; { sed -n "/^lane_engine()/,/^}/p" "$LANE"; sed -n "/^win()/,/^}/p" "$LANE"; sed -n "/^target()/,/^}/p" "$LANE"; sed -n "/^send_swallow_check()/,/^}/p" "$LANE"; } > "$C60S"
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
t "#60②:wd_loop 正常等待判定含 lane-c 条件(起了才算数)" bash -c '
  body="$(sed -n "/^wd_loop()/,/^}/p" "$0")"
  grep -q "win_exists \"lane-c\" || lane_busy c" <<< "$body" || exit 1
  grep -q "lane-c" <<< "$(grep "idle=" <<< "$body")"' "$LANE"
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
V60S="$V60/scan.sh"; sed -n "/^ev_scan_deliveries()/,/^}/p" "$LANE" > "$V60S"
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
tout "#60①:doctor 引擎=codex 报引擎行 ⛔ 旧文案误导" "验收引擎:codex" "$LANE" doctor
tout "#60①:doctor 引擎=claude 旧文案逐字保留" "验收窗口钉:claude-opus-5  派工窗口钉" \
  env LAIXIN_VERIFY_ENGINE=claude "$LANE" doctor
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
t "dmsg:⛔ 进 RELAY_DENY(relay 恰是最需要它的席位)" bash -c '
  ! grep -q "Bash(laixin-lane dmsg" "'"$LANE"'"'

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
{ echo 'KIMI_BIN=/k/kimi; KIMI_MODEL=k3';
  sed -n "/^agent_launch_cmd()/,/^}$/p" "$LANE";
  sed -n "/^codex_launch_cmd()/,/^}$/p" "$LANE";
  sed -n "/^kimi_launch_cmd()/,/^}$/p" "$LANE"; } > "$VKMF"
tout "kimi:构造串走同一注入形态(⛔ 各写一套)" 'BU_NAME="d" BU_CDP_URL="http://127.0.0.1:9" "/k/kimi" --auto -m k3' bash -c '
  source "'"$VKMF"'"; kimi_launch_cmd d 9'
tout "codex:构造串与引入 kimi 前**逐字一致**(回归保护)" 'BU_NAME="d" BU_CDP_URL="http://127.0.0.1:9" codex --x' bash -c '
  source "'"$VKMF"'"; codex_launch_cmd d 9 "--x"'
# ⛔ 在这里再写一条"未知引擎被拒":既有 #67 那条已覆盖,且它带 LAIXIN_SESSION 隔离;
# 照抄时漏掉隔离 ⇒ 会在**真实** tmux 会话里跑起窗命令(2026-08-19 自撞,当轮发现并撤回)。
tout "kimi:错误文案列出三种合法引擎(⛔ 只列两种)" "codex|claude|kimi" bash -c '
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
t "lane_busy:kimi 档同样收 Waiting" bash -c '
  sed -n "/^lane_busy()/,/^}$/p" "'"$LANE"'" | grep -q "Running|Waiting|🌑"'
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
echo
echo "结果:$PASS 过 / $FAIL 败"
[ "$FAIL" -eq 0 ]
