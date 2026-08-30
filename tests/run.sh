#!/bin/bash
# laixin-lane 自测套件——只测纯函数与只读命令,绝不碰 tmux 窗口/lane/派工权锁
# 用法:bash tests/run.sh   (在任何目录均可;依赖真仓库的部分只做只读操作)
set -uo pipefail
LANE="$(cd "$(dirname "$0")/.." && pwd)/bin/laixin-lane"
MIGRATE="$(cd "$(dirname "$0")/.." && pwd)/bin/migrate-11b-windows-from-11c"
APF="$(cd "$(dirname "$0")/.." && pwd)/bin/accept-preflight"   # M1 影子版(#九之九);零测试是它转正前的缺口
TOPIC_TEST="$(cd "$(dirname "$0")" && pwd)/test-laixin-11c-topic.sh"
PASS=0; FAIL=0
# 🔴 套件判据必须只依赖被测对象,⛔ 依赖调用者所在窗口/环境(2026-08-22 实撞:dispatch 窗口里跑本套件,shell 带着
#   LAIXIN_WINDOW / TMUX_PANE ⇒ 来源推断类 3 条 + 1 条误红,而干净 shell 全绿——「同一套测试两处两种结果」)。
#   ⇒ 开跑先卸掉会改变被测行为的调用者环境;需要它们的测试各自显式 env 传入。
unset LAIXIN_WINDOW LAIXIN_BOARD_SRC TMUX_PANE TMUX 2>/dev/null || true
# 🔴 套件零副作用的机器半边(2026-08-22 实撞):真实派工权锁在套件开跑时若在,跑完必须还在——
#   当日 halt fixture 用真 HOME 的锁,把在班 dispatch 的派工权删了两遍而套件全绿;「绝不碰派工权锁」此前只是上面那行自述。
REAL_LOCK_BEFORE="$(cat "$HOME/.laixin-dispatch.lock" 2>/dev/null || true)"

# ── 并发闸下沉到运行器自身(2026-08-29 值守窗「配合问题第 1 例」实撞)────────────────────
# 🔴 各窗此前的自核闸(合并前 `pgrep -f 'bash tests/run.sh'` 看是不是 0)**双源都会在放行方向骗人**:
#   · `pgrep -f` 在本机遇到命令行含非法字节的进程时**报错并让 stdout 为空** ⇒ 管到 `wc -l` 就是
#     一个漂亮的 `0`,与「真的没人在跑」完全同形 ⇒ **假零=放行合并**(本机 2026-08-29 10:19 实撞:
#     `pgrep: Regular expression evaluation error (illegal byte sequence)` 之后紧跟一行 `0`)。
#   · 换成 `ps | grep` 又反过来:命令行里**提到** tests/run.sh 的外壳(如包着它的 zsh -c)被当成在跑
#     ⇒ 假阳性=白等。两种实现各自在**它要防的那个方向上**失效,而两种失效都不可见。
# ⇒ 修法不是给每个窗一条更好的 grep(那还是同一族判据),而是**让运行器自己拒绝第二实例**:
#   起跑即取互斥锁;拿不到就明说是谁、从几点在跑,并 rc≠0 退出 ⛔ 静默等待 ⛔ 静默继续。
#   各窗口径随之变成「直接跑,被拒即让、盯释放即试」——闸从"每个调用方各自记得核一次"收到唯一一处。
#   ⚠️ 原写「被拒即等」在博弈上是错的(无队列原子试取下退避者系统性输),2026-08-29 创始人递读数后改。
# 锁路径可被 LAIXIN_TESTS_LOCK 覆盖:本文件的自测绊线要在临时锁上跑,⛔ 碰真锁。
TESTS_LOCK="${LAIXIN_TESTS_LOCK:-$HOME/.laixin-tests.lock}"
TESTS_LOCK_MSG=''
tests_lock_acquire(){ # <锁目录> → 0=取到;1=占用。消息写 TESTS_LOCK_MSG。⛔ 阻塞等待 ⛔ 静默
  local lock="$1" pidfile="$1/pid" pid started lock_rc
  # 锁文件由 lockf 原子持有,目录只作容器:旧版留下的目录/pid 可直接接管,无 pid 也不会永久占用。
  if ! mkdir -p "$lock" 2>/dev/null; then
    TESTS_LOCK_MSG="未判:无法准备锁目录 $lock,按占用处理"
    return 1
  fi
  if ! exec 9>> "$pidfile"; then
    TESTS_LOCK_MSG="未判:无法打开锁文件 $pidfile,按占用处理"
    return 1
  fi
  if /usr/bin/lockf -s -t 0 9; then
    if ! printf '%s\n' "$$" > "$pidfile"; then
      exec 9>&-
      TESTS_LOCK_MSG="未判:已取得内核锁但无法写 pid,已释放"
      return 1
    fi
    if [ "$(cat "$pidfile" 2>/dev/null || true)" != "$$" ] || ! kill -0 "$$" 2>/dev/null; then
      exec 9>&-
      TESTS_LOCK_MSG="未判:内核锁已取到但 pid 自证失败,已释放"
      return 1
    fi
    date '+%H:%M:%S' > "$lock/started" 2>/dev/null || true
    return 0
  else
    lock_rc=$?
  fi
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  exec 9>&-
  case "$pid" in
    '')        TESTS_LOCK_MSG="未判:内核锁未取到(rc=$lock_rc),持有者正在初始化,按占用处理"; return 1 ;;
    *[!0-9]*)  TESTS_LOCK_MSG="未判:内核锁未取到(rc=$lock_rc),pid 非法($pid),按占用处理"; return 1 ;;
  esac
  if kill -0 "$pid" 2>/dev/null; then
    started="$(cat "$lock/started" 2>/dev/null || true)"
    TESTS_LOCK_MSG="另一实例 pid $pid 自 ${started:-未知} 在跑"
  else
    TESTS_LOCK_MSG="未判:内核锁未取到(rc=$lock_rc),pid $pid 已死,按占用处理"
  fi
  return 1
}
tests_lock_release(){ # <锁目录> —— pid 文件须常驻;删除会让新文件绕过仍活着的内核锁。
  local pidfile="$1/pid"
  [ "$(cat "$pidfile" 2>/dev/null || true)" = "$$" ] || return 0
  exec 9>&- || true
}
if tests_lock_acquire "$TESTS_LOCK"; then
  [ -z "$TESTS_LOCK_MSG" ] || echo "并发闸:$TESTS_LOCK_MSG"
  trap 'tests_lock_release "$TESTS_LOCK"' EXIT
else
  echo "⛔ 本机已有一套自测在跑,拒绝并发:$TESTS_LOCK_MSG" >&2
  echo "   口径:直接跑、⛔ 用 pgrep/ps 自核(两者都会在放行方向骗人)。" >&2
  echo "   被拒后:⛔ 固定间隔退避 —— 本锁是**无队列的原子试取**,没有先来后到," >&2
  echo "   谁在释放那一刻恰好在试谁就拿到 ⇒ 退避者系统性输给随到随试者,且输得看不出来" >&2
  echo "   (退避方只看到「又被拒了」,看不到自己每次都错开了释放窗口;值守第二任 14:23–14:37" >&2
  echo "   实证:被拒 15 次而两次真实释放都不在场——「一直在等」与「一直没赶上」同形)。" >&2
  echo "   ⇒ 盯 \$LK 释放即试。登记序队列已排兑现窗 A 2.5,落地后本提示改回。" >&2
  exit 3
fi
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
t "11C 议题编排器:盲读隔离/冻结/恢复/原子收卷" bash "$TOPIC_TEST"
t "tmux 会话目标精确匹配(前缀误命中为阳性对照；迁移只干跑)" bash -c '
  set -e
  root="$(mktemp -d)"; sock="tmux-exact-$$"; tmux_bin="$(command -v tmux)"
  cleanup(){ "$tmux_bin" -L "$sock" kill-server >/dev/null 2>&1 || true; rm -rf "$root"; }
  trap cleanup EXIT
  mkdir "$root/bin"
  printf "%s\\n" "#!/bin/sh" "exec \"\$TMUX_EXACT_BIN\" -L \"\$TMUX_EXACT_SOCKET\" \"\$@\"" > "$root/bin/tmux"
  chmod +x "$root/bin/tmux"
  export TMUX_EXACT_BIN="$tmux_bin" TMUX_EXACT_SOCKET="$sock" PATH="$root/bin:$PATH"
  tmux -f /dev/null new-session -d -s laixin-11c -n hub
  tmux has-session -t laixin
  ! tmux has-session -t =laixin
  ! tmux has-session -t =laixin:hub
  out="$(LAIXIN_SESSION=laixin "$1" status)"; grep -q "会话 laixin 不存在" <<< "$out"
  tmux -f /dev/null new-session -d -s laixin -n hub
  tmux has-session -t =laixin
  tmux has-session -t =laixin:hub
  out="$(LAIXIN_SESSION=laixin "$1" status)"; grep -q "hub" <<< "$out"
  tmux new-window -d -t =laixin-11c -n lane-a
  tmux new-window -d -t =laixin-11c -n scribe-11c-only
  out="$(LAIXIN_SESSION=laixin-dst LAIXIN_11C_SESSION=laixin-11c "$2" --dry-run)"
  grep -q "迁移 laixin-11c:lane-a → laixin-dst" <<< "$out"
  grep -q "保留 11C 窗" <<< "$out"
  ! tmux has-session -t =laixin-dst
  ! grep -Eq "tmux [^#]*-t \\\"\\\$SESSION|\\\"\\\$SESSION:" "$1"' _ "$LANE" "$MIGRATE"
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
t "手开角色配型:方案窗口/opt-11b 钉 Opus 5,创始人窗口仍手选" bash -c '
  grep -qF "PLAN_WINDOW_MODEL=\"\${LAIXIN_PLAN_WINDOW_MODEL:-claude-opus-5}\"" "$1" &&
  grep -qF "OPT_11B_MODEL=\"\${LAIXIN_OPT_11B_MODEL:-claude-opus-5}\"" "$1" &&
  grep -qF "创始人窗口=手选" "$1" &&
  grep -qF -- "--model claude-opus-5" "$2" && grep -qF -- "--model claude-opus-5" "$3"' \
  _ "$LANE" "$(cd "$(dirname "$0")/.." && pwd)/skills/laixin-plan-window/SKILL.md" "$(cd "$(dirname "$0")/.." && pwd)/AGENTS.md"
t "账号切换的方案窗口新窗命令显式带 PLAN_WINDOW_MODEL" bash -c '
  seg="$(sed -n "/^cmd_account_switch()/,/^}/p" "$1")"; grep -qF -- "--model \${PLAN_WINDOW_MODEL}" <<< "$seg"' _ "$LANE"

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
tout "migrate 源会话不存在时不触发 bash 3.2 的中文变量吞并" "源会话不存在:lx-migrate-no-source-$$；无需迁移" \
  env TMUX= LAIXIN_11C_SESSION="lx-migrate-no-source-$$" "$MIGRATE" --dry-run
FRESH6F="$(mktemp -d)"
sed -n "/^cmd_fresh()/,/^}/p" "$LANE" > "$FRESH6F/fresh.sh"
t "fresh 裸调用在 bash 3.2 set -u 下启动成功，旧窗只在新窗启动后才回收" bash -uc '
  T="$1"; source "$2"
  SESSION=fresh6f; EV_PROMPT_DIR="$T/prompts"; printf "lane-a\\n" > "$T/windows"
  die(){ return 1; }; win(){ printf "lane-%s" "$1"; }; target(){ printf "=%s:%s" "$SESSION" "$(win "$1")"; }
  has_window(){ grep -Fqx "$(win "$1")" "$T/windows"; }; lane_transport_resolve(){ printf tui; }; lane_engine(){ printf codex; }
  lane_native_root(){ printf "%s/native" "$T"; }; native_transport_set(){ :; }; cdp_sweep(){ :; }; board(){ :; }
  tmux(){
    case "$1" in
      rename-window) old="${3##*:}"; new="$4"; awk -v o="$old" -v n="$new" "{if(\$0==o) print n; else print}" "$T/windows" > "$T/next"; mv "$T/next" "$T/windows"; printf "rename:%s:%s\\n" "$old" "$new" >> "$T/log" ;;
      kill-window) old="${3##*:}"; awk -v o="$old" "\$0!=o" "$T/windows" > "$T/next"; mv "$T/next" "$T/windows"; printf "kill:%s\\n" "$old" >> "$T/log" ;;
    esac
  }
  cmd_up(){ printf "lane-a\\n" >> "$T/windows"; printf "start\\n" >> "$T/log"; }
  cmd_fresh a
  start="$(grep -n "^start$" "$T/log" | cut -d: -f1)"; kill="$(grep -n "^kill:" "$T/log" | cut -d: -f1)"
  [ -n "$start" ] && [ -n "$kill" ] && [ "$start" -lt "$kill" ] && grep -Fqx lane-a "$T/windows" && [ "$(wc -l < "$T/windows" | tr -d " ")" = 1 ]
' _ "$FRESH6F" "$FRESH6F/fresh.sh"
t "fresh 启动失败后恢复原窗，失败不毁轨" bash -uc '
  T="$1"; source "$2"
  SESSION=fresh6f; EV_PROMPT_DIR="$T/prompts"; printf "lane-a\\n" > "$T/windows"; : > "$T/log"
  die(){ return 1; }; win(){ printf "lane-%s" "$1"; }; target(){ printf "=%s:%s" "$SESSION" "$(win "$1")"; }
  has_window(){ grep -Fqx "$(win "$1")" "$T/windows"; }; lane_transport_resolve(){ printf tui; }; lane_engine(){ printf codex; }
  lane_native_root(){ printf "%s/native" "$T"; }; native_transport_set(){ :; }; cdp_sweep(){ :; }; board(){ :; }
  tmux(){
    case "$1" in
      rename-window) old="${3##*:}"; new="$4"; awk -v o="$old" -v n="$new" "{if(\$0==o) print n; else print}" "$T/windows" > "$T/next"; mv "$T/next" "$T/windows"; printf "rename:%s:%s\\n" "$old" "$new" >> "$T/log" ;;
      kill-window) old="${3##*:}"; awk -v o="$old" "\$0!=o" "$T/windows" > "$T/next"; mv "$T/next" "$T/windows"; printf "kill:%s\\n" "$old" >> "$T/log" ;;
    esac
  }
  cmd_up(){ return 1; }
  if cmd_fresh a --dir "$T"; then exit 1; fi
  grep -Fqx lane-a "$T/windows" && [ "$(wc -l < "$T/windows" | tr -d " ")" = 1 ] && ! grep -q "^kill:" "$T/log"
' _ "$FRESH6F" "$FRESH6F/fresh.sh"
rm -rf "$FRESH6F"
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
{ sed -n "/^last_contract_line/,/^}/p" "$LANE"; sed -n "/^pane_hash/,/^}/p" "$LANE"; sed -n "/^native_print_active()/,/^}/p" "$LANE"; sed -n "/^ev_watch_target/,/^}/p" "$LANE"; sed -n "/^ev_scan_deliveries/,/^}/p" "$LANE"; sed -n "/^ev_next_ready/,/^}/p" "$LANE"; sed -n "/^ev_lane_assigned/,/^}/p" "$LANE"; sed -n "/^ev_verify_receipt_ready/,/^}/p" "$LANE"; } > "$TMPE/fns.sh"
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

# 守护: 11B-三个探针面选错
NWB="$TMPE/native-watch"; mkdir -p "$NWB"
cat > "$NWB/common.sh" <<'SH'
source "$NATIVE_FNS"
EV_DIR="$NW_ROOT"; EV_TICK=1; EV_STALL=2; ALERTS="$NW_ROOT/alerts"
pane_hash(){ printf 'PANE-FIXED\n'; }
tool_native_status(){ cat "$2/status" 2>/dev/null; }
ev_deliver(){ printf '%s\n' "$2" >> "$ALERTS"; }
ev_next_ready(){ :; }
ev_lane_assigned(){ return 0; }
lane_engine(){ printf 'codex\n'; }
ev_verify_receipt_ready(){ return 1; }
ev_log(){ :; }
nw_setup(){
  local w="$1" status="${2:-running thread-1}" run="$EV_DIR/native/$1/run-1"
  mkdir -p "$run"
  printf 'print\n' > "$EV_DIR/native/$w/transport"
  printf '%s\n' "$run" > "$EV_DIR/native/$w/current"
  printf '%s\n' "$status" > "$run/status"
  printf 'raw-1\n' > "$run/raw.jsonl"
}
SH
t "三探针 B 阳性1/2:lane print raw 每拍推进，跨 stall 仍零告警" env NATIVE_FNS="$TMPE/fns.sh" NW_ROOT="$NWB/progress" NW_COMMON="$NWB/common.sh" bash -c '
  mkdir -p "$NW_ROOT"; source "$NW_COMMON"; nw_setup lane-a; ev_watch_target lane-a
  for n in 2 3 4 5; do printf "raw-%s\n" "$n" >> "$NW_ROOT/native/lane-a/run-1/raw.jsonl"; ev_watch_target lane-a; done
  [ ! -s "$ALERTS" ] && grep -q "^NATIVE-" "$NW_ROOT/lane-a.state"'
t "三探针 B 阴性1/3:lane print raw 停滞只告一次，推进后四字段 state 复位" env NATIVE_FNS="$TMPE/fns.sh" NW_ROOT="$NWB/stuck" NW_COMMON="$NWB/common.sh" bash -c '
  mkdir -p "$NW_ROOT"; source "$NW_COMMON"; nw_setup lane-a
  for n in 1 2 3 4; do ev_watch_target lane-a; done
  [ "$(grep -c "lane-a 已" "$ALERTS")" -eq 1 ] || exit 1
  printf "raw-2\n" >> "$NW_ROOT/native/lane-a/run-1/raw.jsonl"; ev_watch_target lane-a
  read -r old silent alerted started < "$NW_ROOT/lane-a.state"; [ "$silent" -eq 0 ] && [ "$alerted" -eq 0 ] && [ -n "$started" ]'
t "三探针 B 阴性2/3:settled/failed 都不投同义卡住告警" env NATIVE_FNS="$TMPE/fns.sh" NW_ROOT="$NWB/terminal" NW_COMMON="$NWB/common.sh" bash -c '
  mkdir -p "$NW_ROOT"; source "$NW_COMMON"; nw_setup lane-a "settled 0"; for n in 1 2 3 4; do ev_watch_target lane-a; done
  printf "failed 1 process_gone\n" > "$NW_ROOT/native/lane-a/run-1/status"; for n in 1 2 3 4; do ev_watch_target lane-a; done
  [ ! -s "$ALERTS" ] && grep -q "^NATIVE-TERMINAL 0 0 " "$NW_ROOT/lane-a.state"'
t "三探针 B 阴性3/3:native raw 缺失超过阈值后恰一次可观察告警" env NATIVE_FNS="$TMPE/fns.sh" NW_ROOT="$NWB/missing" NW_COMMON="$NWB/common.sh" bash -c '
  mkdir -p "$NW_ROOT"; source "$NW_COMMON"; nw_setup lane-a; rm -f "$NW_ROOT/native/lane-a/run-1/raw.jsonl"
  for n in 1 2 3 4; do ev_watch_target lane-a; done
  [ "$(grep -c "lane-a 已" "$ALERTS")" -eq 1 ]'
t "三探针 B 阳性2/2:verify print root 同走 native，停滞恰一次告警" env NATIVE_FNS="$TMPE/fns.sh" NW_ROOT="$NWB/verify" NW_COMMON="$NWB/common.sh" bash -c '
  mkdir -p "$NW_ROOT"; source "$NW_COMMON"; nw_setup verify-probe
  for n in 1 2 3 4; do ev_watch_target verify-probe; done
  [ "$(grep -c "验收窗口 verify-probe" "$ALERTS")" -eq 1 ] && grep -q "^NATIVE-" "$NW_ROOT/verify-probe.state"'

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
t "#夜间断链:全轨空闲且 0/0/缺设计 fixture 跑真 wd_loop 两拍——料断档与戳派工各恰一次,并留下三桶读数" bash -c \
  'out="$(bash "$0" fuelgap "$1")"; grep -q "FUELGAP_COUNT=1" <<< "$out" && grep -q "NUDGE_COUNT=1" <<< "$out" && grep -q "燃料读数 ready=0 selfwrite=0(产品0·工具0·其他0) design=2 pending=0" <<< "$out" && grep -q "料断档:缺设计产品格 2 件" <<< "$out"' \
  "$WDD" "$LANE"
# ⭐ 2026-08-29 值守实撞(04:50 / 05:24 两条料断档各紧跟一次自换代):去重位只在内存,#136 exec 后归零 ⇒ 每次 release 再报一次并再催派工席问料。
#   绊线:同一沙盒三代——代 2 不得再报(标记在盘上)且 wd.log 明写「持续」;燃料出现后标记必须清掉(否则下一次真断档会被吞)。
t "#料断档落盘去重:自换代后同一断档 ⛔ 再报(代1=1 · 代2 仍=1 · 代2 记「持续」)" bash -c \
  'out="$(bash "$0" fuelgap-regen "$1")"; grep -q "GEN1_COUNT=1" <<< "$out" && grep -q "MARK_AFTER_GEN1=present" <<< "$out" && grep -q "GEN2_TOTAL=1" <<< "$out" && grep -q "GEN2_PERSIST_LINE=yes" <<< "$out"' \
  "$WDD" "$LANE"
# ── #186-bis(2026-08-29 方案窗口第三十七任):料断档只对**产品格**成立 ⛔ 取 design 合计 ──────────
#   实撞=看门狗对派工席报「料断档:缺设计 2 件」并要求走「问方案侧 → 无应答报创始人」程序,
#   而那 2 件实测是 11B 流程纪律 + 钓不钓基座存量债(design_product=0)——补齐产不出任何可发的产品片,
#   派工席照程序走了一整轮(问料 → 得答 → 报创始人)才自证「这不是我的活」。
#   与 #186 的 selfwrite 桶完全同构,只是换了个桶;轨列判据两桶**共用一份** `_track_bucket` ⛔ 各写一份。
t "#186-bis 阴性:缺设计合计非空但产品格 0 ⇒ ⛔ 上看板 ⛔ 催派工席 ⛔ 置告警标记(仍落日志留痕)" bash -c \
  'out="$(bash "$0" fuelgap-nonprod "$1")"
   grep -q "BOARD_ALERT_COUNT=0" <<< "$out" || { echo "误上看板"; exit 1; }
   grep -q "NUDGE_COUNT=0" <<< "$out" || { echo "误催派工席"; exit 2; }
   grep -q "INFO_LINE=1" <<< "$out" || { echo "日志留痕应恰 1 行(0=静默丢掉 · >1=每拍刷屏):$(grep INFO_LINE= <<< "$out")"; exit 3; }
   grep -q "MARK_EXISTS=no" <<< "$out" || { echo "置了告警标记会吃掉下一次真断档首报"; exit 4; }' \
  "$(dirname "$0")/wd44-driver.sh" "$LANE"
# 🔴 三态位的关键路径:0=未处理 · 1=已真告警 · 2=已记 ℹ️。⛔ 只测「产品格 0 不报」——
#   那条通过而升级路径坏掉时,现象是**真断档永远不报**,而「被吃掉」与「本来就没有」在告警面同形。
t "#186-bis 升级:产品格由 0 变 >0 ⇒ 真断档必须报出来(⛔ 被 ℹ️ 态吃掉)" bash -c \
  'out="$(bash "$0" fuelgap-upgrade "$1")"
   grep -q "INFO_LINE=1" <<< "$out" || { echo "ℹ️ 态异常:$(grep INFO_LINE= <<< "$out")"; exit 1; }
   grep -q "REAL_ALERT=1" <<< "$out" || { echo "升级后真断档未报(被 ℹ️ 态吃掉):$(grep REAL_ALERT= <<< "$out")"; exit 2; }
   grep -q "NUDGE_COUNT=1" <<< "$out" || exit 3' \
  "$(dirname "$0")/wd44-driver.sh" "$LANE"
# 降级向:机器行无 design_product ⇒ 回落 design 合计并**照常告警** ⛔ 静默(与 #186 同一原则)。
# ⚠️ 本条自建夹具 ⛔ 借用后文的 $T137——那个变量在本行之后才定义,借用会拿到空串,
#   而空串路径下 source 失败的现象是「测试红了」而非「变量没定义」,两者在报错面同形。
DG186="$(mktemp -d)"; sed -n "/^wd_fuel()/,/^}/p" "$LANE" > "$DG186/f.sh"
t "#186-bis 降级:机器行不含 design_product ⇒ 回落合计并仍判有断档 ⛔ 静默" bash -c \
  'source "$1/f.sh"; TABLE="$1/t"; : > "$TABLE"; EV_PENDING="$1/p"; : > "$EV_PENDING"
   ev_next_ready(){ :; }; win_exists(){ return 1; }; lane_busy(){ return 1; }
   cmd_stats(){ printf "ready=0 selfwrite=0 design=3 pending=0\n"; }
   WD_STATS_TABLE_MTIME=""; wd_fuel >/dev/null
   [ "${WD_STATS_DG_PRODUCT:-}" = 3 ] || { echo "未回落合计:${WD_STATS_DG_PRODUCT:-空}"; exit 1; }
   [ "${WD_STATS_DG_DEGRADED:-}" = 1 ] || exit 2' _ "$DG186"
rm -rf "$DG186"
t "#料断档落盘去重:燃料出现即清标记(⛔ 吞掉下一次真断档)" bash -c \
  'out="$(bash "$0" fuelgap-regen "$1")"; grep -q "MARK_AFTER_FUEL=absent" <<< "$out"' \
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

echo "== 7a-bis. P0 派工席保活开关 keepalive + 单事故单告警(2026-08-28 R4 第一条命令;隔离 fixture,零真实 tmux) =="
# 起因(实测,⛔ 转述):创始人直令「派工窗干完直接关闭」撞上机器缺口——派工席**默认托管、没有可清的标记**,
#   只能走「让重起上限自然用掉」;而达上限后 wd_loop **每拍在第 1 分支 continue**:
#   ① 看板被同一条告警灌到 148 条(08-28 20:53 实测,仍 +1/分钟);
#   ② silent 累积与 wd_fuel 都排在该分支之后 ⇒ **燃料判定自 18:17 起一拍未跑**,当晚夜测数字①的采数面随之失效。
# ⭐ ②的形态值得记:**「计数被清零」与「计数从来没在涨」,在事后读数上完全同形**——都只是一个小数字。
# 三条主绊线全为**执行级**(跑真 wd_loop),回退验证已实做:拆保活闸门 ⇒ DISPATCH_CALLS 0→3、关闭条 1→0;
#   拆单告警闸 ⇒ 达上限条 1→4(正是真环境那 148 条的同一形态)。
t "P0 绊线:保活关闭态跑真 wd_loop ≥3 拍——零拉起 + 关闭条恰一条 + 零「派工窗口不在」告警" bash -c \
  'out="$(bash "$0" ka-hold "$1")"; grep -q "DISPATCH_CALLS=0" <<< "$out" && grep -q "HOLD_BOARD_COUNT=1" <<< "$out" && grep -q "NOTIN_BOARD_COUNT=0" <<< "$out"' \
  "$WDD" "$LANE"
t "P0 绊线:运行中恢复保活——抑制期零拉起,清标记后意外死亡仍被拉起(证明抑制 ⛔ 把自愈整个打死)" bash -c \
  'out="$(bash "$0" ka-restore "$1")"; a="$(sed -n "s/^CALLS_AFTER=//p" <<< "$out")"; grep -q "CALLS_HELD=0" <<< "$out" && grep -q "RESTORE_BOARD_COUNT=1" <<< "$out" && [ "${a:-0}" -ge 1 ]' \
  "$WDD" "$LANE"
t "P0 绊线:达上限告警按**状态转移**恰一条(⛔ 时间窗去重;回退成每拍一条即 ≥3)" bash -c \
  'out="$(bash "$0" ka-capped "$1")"; grep -q "CAPPED_BOARD_COUNT=1" <<< "$out" && grep -q "CAPPED_LOG_COUNT=1" <<< "$out"' \
  "$WDD" "$LANE"
# 模式级:闸门位置。挂在派工分支**之后**等于「关了还会被拉起一拍」;照 relay 的 relay_enabled 同款要求。
t "P0 模式绊线:wd_loop 内保活闸门排在 dispatch 分支之前" bash -c \
  'b="$(awk "/^wd_loop\(\)/,/^}/" "$0" | grep -n "dispatch_keepalive_off" | head -1 | cut -d: -f1)";
   d="$(awk "/^wd_loop\(\)/,/^}/" "$0" | grep -n "dispatch_alive" | head -1 | cut -d: -f1)";
   [ -n "$b" ] && [ -n "$d" ] && [ "$b" -lt "$d" ]' "$LANE"
# 方向性(最容易被「顺手优化」掉):看门狗的自愈路径 ⛔ 自己清关闭标记——否则关闭令会被它要抑制的那个动作解除。
t "P0 方向绊线:wd_loop 内不清关闭标记(只有人工/boot 链的 cmd_dispatch 才清)" bash -c \
  'body="$(sed -n "/^wd_loop()/,/^}/p" "$0")"; ! grep -q "rm -f \"\$DISPATCH_KEEPALIVE_OFF\"" <<< "$body"' "$LANE"
tout "P0:cmd_dispatch 起窗即恢复保活(与 relay 起窗即写启用标记对称)" 'rm -f "$DISPATCH_KEEPALIVE_OFF"' \
  sed -n "/^cmd_dispatch()/,/^}/p" "$LANE"
# ⭐ 同批修的第四份载体:「无 ready = 有意空闲」在 ev 侧是**活的判定分支**,前三份文字改完它照旧生效。
tout "P0 同批:ev 侧「有意空闲」判定已含第三桶 selfwrite(⛔ 停在两桶)" "ev_selfwrite_pending" \
  sed -n "/^ev_watch_target()/,/^}/p" "$LANE"
tout "P0 同批:selfwrite 探针失效按有燃料(⛔ 因探针失效而静默)" 'WD_STATS_SELFWRITE:-?' \
  sed -n "/^ev_selfwrite_pending()/,/^}/p" "$LANE"
# keepalive 命令面:三态回显 + 接线 + 清标记(可观察面是「关不掉 vs 没关」不同形的唯一依据)
KA="$(mktemp -d)"; KAS="lx-ka-nonexistent-$$"
tout "keepalive 无参:默认托管态如实回显" "派工席保活:开" \
  env LAIXIN_SESSION="$KAS" LAIXIN_DISPATCH_KEEPALIVE_OFF="$KA/none" LAIXIN_BOARD="$KA/b.md" "$LANE" keepalive
printf '2026-08-28 21:00:00 测试\n' > "$KA/mark"
tout "keepalive 无参:奉令关闭态回显含落令时刻与来源(标记 ⛔ 空文件)" "2026-08-28 21:00:00 测试" \
  env LAIXIN_SESSION="$KAS" LAIXIN_DISPATCH_KEEPALIVE_OFF="$KA/mark" LAIXIN_BOARD="$KA/b.md" "$LANE" keepalive
tout "keepalive on 已接线并清关闭标记" "派工席保活已恢复" \
  env LAIXIN_SESSION="$KAS" LAIXIN_DISPATCH_KEEPALIVE_OFF="$KA/mark" LAIXIN_BOARD="$KA/b.md" "$LANE" keepalive on
t "keepalive on 后标记确已不在(闸门真的开了)" bash -c '[ ! -f "'"$KA"'/mark" ]'
tfail "keepalive 拒未知子命令(⛔ 静默当 status)" "只接受 off|on|status" \
  env LAIXIN_SESSION="$KAS" LAIXIN_DISPATCH_KEEPALIVE_OFF="$KA/none" LAIXIN_BOARD="$KA/b.md" "$LANE" keepalive bogus
rm -rf "$KA"

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
# ⭐ 绊线(2026-08-29 立):干净判据只管**发布物**——`bin/` 之外的未提交 ⛔ 挡发布,但必须列出来。
#   实撞:派工窗口未提交的卡改动(skills/)两次挡住发布,其中一次让「事件总线假阴性」的修复
#   合入 main 却上不了线,生产继续跑旧行为 ⇒ 拦的东西根本不进发布物,拦它没有任何不出错收益。
mkdir -p "$R25/repo/skills"; printf 'card body\n' > "$R25/repo/skills/CARD.md"
tout "#25 绊线:发布物之外脏 ⇒ 仍发布(卡改动 ⛔ 挡发布)" "已发布" "${RENV[@]}" "$LANE" release
tout "#25 绊线:发布物之外脏时逐条列出备核(⛔ 静默放行)" "仓内其余未提交" "${RENV[@]}" "$LANE" release
t "#25 对照:同一状态下旧全仓判据会拒、新发布单元判据放行——绊线能分成败" bash -c '
  [ -n "$(git -C "$1/repo" status --porcelain)" ] || exit 1
  [ -z "$(git -C "$1/repo" status --porcelain -- bin)" ]' 25 "$R25"
rm -rf "$R25/repo/skills"
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
# ⭐ trust-nav 绊线(2026-08-28 热修;病灶=claude 2.1.250 起 trust 对话框默认项反转,❯ 停在「No, exit」,
#    原「见框即 C-m」按下去是退出 ⇒ 无人值守托管窗被自愈重起时**每次都被自己按死**,而「按死」与
#    「起窗失败」在读数面同形)。三条缺一即红:回退成裸 C-m 会红、导航判据被换成发键计数会红、
#    $HOME 放行被并回 vtrusted_dir(会顺带放宽 tool-up :6290 那条有意的 --dir 闸)会红。
# ⭐ 五仓灾备绊线(2026-08-29;病灶=「远端建好了」与「已进自动备份」同形——两个私有灾备仓 08-28 建好并首推
#    完成后**仍在仓表外**,而 backup 连续多轮全绿:它只报表内三仓的成败,表外的仓**不会以任何形式显影**)。
#    ⇒ 判据取**仓表本身** ⛔ 取 backup 的退出码(那是「表内全推成功」,不是「该备的都备了」)。
t "#五仓灾备:backup 仓表含全部五仓(漏一个即红;⛔ 拿 backup 退出码当判据)" bash -c '
  line="$(sed -n "/^cmd_backup()/,/^}/p" "$0" | grep "for r in ")"
  [ -n "$line" ] || exit 1
  for repo in Obsidian Developer/laixin-pipeline 来信平台 钓不钓 钓不钓-基座; do
    grep -qF "\$HOME/$repo\"" <<< "$line" || exit 1
  done' "$LANE"
t "#五仓灾备:只推 origin main(⛔ --all/--mirror,⛔ 推非 origin 的本地 remote)" bash -c '
  b="$(sed -n "/^cmd_backup()/,/^}/p" "$0" | grep -v "^[[:space:]]*#")"
  grep -q "push origin main" <<< "$b" || exit 1
  ! grep -qE "push .*(--all|--mirror)" <<< "$b"' "$LANE"
t "#trust-nav①:vwait_ready 的 trust 分支必须经 trust_nav_confirm,⛔ 裸 C-m(回退即红)" bash -c '
  body="$(sed -n "/^vwait_ready()/,/^}/p" "$0" | grep -v "^[[:space:]]*#")"
  seg="$(sed -n "/trust this folder/,/fi ;;/p" <<< "$body")"
  [ -n "$seg" ] || exit 1
  grep -q "trust_nav_confirm" <<< "$seg" || exit 1
  ! grep -q "send-keys.*C-m" <<< "$seg"' "$LANE"
t "#trust-nav②:判据是复核 ❯ 选中项读数 ⛔ 发键计数,且确认后须核进程存活" bash -c '
  fn="$(sed -n "/^trust_nav_confirm()/,/^}/p" "$0" | grep -v "^[[:space:]]*#")"
  [ -n "$fn" ] || exit 1
  grep -q "Yes, I trust" <<< "$fn" || exit 1
  grep -q "send-keys -t \"\$t\" Down" <<< "$fn" || exit 1
  grep -q "pane_current_command" <<< "$fn"' "$LANE"
t "#trust-nav③:托管窗自动确认这一路的前提=vtrusted_dir 首 case 认 \$HOME(误删即托管窗全卡)" bash -c '
  vfn="$(sed -n "/^vtrusted_dir()/,/^}/p" "$0" | grep -v "^[[:space:]]*#")"
  grep -q "\"\$HOME\")" <<< "$vfn" || grep -q "\"\$HOME\"|" <<< "$vfn" || exit 1
  body="$(sed -n "/^vwait_ready()/,/^}/p" "$0" | grep -v "^[[:space:]]*#")"
  ! grep -q "cd \"\$HOME\"" <<< "$body"' "$LANE"
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
# 措辞随判据一起收窄(2026-08-29):判据只核发布单元,回执就 ⛔ 再说「工作树干净」——
# 那是一条**看起来正常**的假话(仓里可能正躺着未提交的卡),比没有回执更难发现。
tout "release 成功回显已核清单(措辞=发布单元 ⛔ 工作树)" "已核:发布单元(bin/ 与 contrib-statusline.py)干净" sed -n "/^cmd_release/,/^}/p" "$LANE"

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
tfail "kb-commit 涉注册表 ⇒ 新增劈行被**闸**在提交前(2026-08-29 由警升闸:#51 注册表劈 10 列 + 事实归一 16 行劈表照样入库=两次实撞)" "表结构断言未过,未提交" \
  env LAIXIN_VAULT="$TLV" "$LANE" kb-commit "test: 注册表劈行" 来信平台-窗口角色注册表.md
t "劈行未进库(HEAD 仍是 seed)——闸是真的拦了 ⛔ 只是喊了一声" bash -c \
  'git -C "$1" log --oneline -1 | grep -q "seed"' tl "$TLV"
tout "显式 LAIXIN_KB_LINT_WARN=1 才能越过(留痕形态)" "照提交" \
  env LAIXIN_VAULT="$TLV" LAIXIN_KB_LINT_WARN=1 "$LANE" kb-commit "test: 注册表劈行越过" 来信平台-窗口角色注册表.md
t "越过后已入库(证明越过路径可用 ⛔ 死锁)" bash -c \
  'git -C "$1" log --oneline -1 | grep -q "注册表劈行越过"' tl "$TLV"
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
# 2026-08-29:三轨 --dir 必填后,本例补上 --dir ⇒ 它继续只测「--with-mcp 被拒」这一件事,
#   ⛔ 让 --dir 守卫为它避让(那会让守卫在 up c 这条路径上形同虚设)。
tfail "#60②:up c --with-mcp 被拒(codex 专属参数 ⛔ 静默吞)" "codex 专属参数" \
  env LAIXIN_SESSION=lx60c-nonexist "$LANE" up c --dir "$C60" --with-mcp aliyun-readonly
t "#60②:up c --with-mcp 被拒时零 tmux 副作用" bash -c '! tmux has-session -t lx60c-nonexist 2>/dev/null'
# ⭐ 起动命令按引擎分派:kimi 与 Codex 都显式钉模型;Codex 的 MCP 关闭参数仍在。
t "#60②:cmd_up 起动命令分引擎(kimi/Codex 均显式配型)" bash -c '
  body="$(sed -n "/^cmd_up()/,/^}/p" "$0")"
  grep -q -- "\$KIMI_BIN\\\\\" --auto -m \$KIMI_MODEL" <<< "$body" || grep -q -- "--auto -m \$KIMI_MODEL" <<< "$body" || exit 1
  grep -qF -- "-m \$LANE_CODEX_MODEL" <<< "$body" &&
  grep -qF -- "model_reasoning_effort=\\\"\$LANE_CODEX_EFFORT\\\"" <<< "$body" &&
  grep -qF "\$_mcp_off" <<< "$body"' "$LANE"
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
tout "#配档:Codex 验收模型默认钉 gpt-5.6-sol" "gpt-5.6-sol" echo "$CXM"
CXE="$(bash -c "eval \"\$(grep '^CODEX_EFFORT=' '$LANE')\"; echo \"\$CODEX_EFFORT\"")"
tout "#配档:Codex 验收推理档默认钉 max" "max" echo "$CXE"
LXM="$(bash -c "eval \"\$(grep '^LANE_CODEX_MODEL=' '$LANE')\"; echo \"\$LANE_CODEX_MODEL\"")"
tout "#配档:Codex 开发轨模型默认钉 gpt-5.6-terra" "gpt-5.6-terra" echo "$LXM"
LXE="$(bash -c "eval \"\$(grep '^LANE_CODEX_EFFORT=' '$LANE')\"; echo \"\$LANE_CODEX_EFFORT\"")"
tout "#配档:Codex 开发轨推理档默认钉 xhigh" "xhigh" echo "$LXE"
CXM2="$(env LAIXIN_CODEX_MODEL=gpt-5.6-luna bash -c "eval \"\$(grep '^CODEX_MODEL=' '$LANE')\"; echo \"\$CODEX_MODEL\"")"
tout "#配档:验收窗保留显式单次逃生口(⛔ 改 config.toml)" "gpt-5.6-luna" echo "$CXM2"
t "#配档:开发轨 cmd_up 只取 LANE_CODEX 配型(⛔ 误用验收 CODEX_MODEL)" bash -c '
  body="$(sed -n "/^cmd_up()/,/^}/p" "$0")"
  grep -q "LANE_CODEX_MODEL" <<< "$body" && grep -q "LANE_CODEX_EFFORT" <<< "$body" &&
  ! grep -q "[^_]CODEX_MODEL" <<< "$body"' "$LANE"
t "#配档:print 路径按窗口角色透传验收/AB 两套配型" bash -c '
  body="$(sed -n "/^native_run_start()/,/^}/p" "$0")"
  grep -q "lane-a|lane-b).*LANE_CODEX_MODEL" <<< "$body" &&
  grep -q "verify-\\*).*CODEX_MODEL" <<< "$body" &&
  grep -q "LAIXIN_NATIVE_CODEX_MODEL=%q" <<< "$body" &&
  grep -q "LAIXIN_NATIVE_CODEX_EFFORT=%q" <<< "$body"' "$LANE"
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
tout "#60②:doctor 拓扑节报 lane-c 可选轨(两态都含「可选轨」)" "可选轨" \
  env LAIXIN_SESSION=laixin-11c "$LANE" doctor
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
# ── #108-fix3(2026-08-29 方案窗口第三十七任):方案窗口/中继窗口席也须认**倒装**语序 ──────────
#   实撞=第三十六任交班条写成「🔄 **交班 方案窗口第三十六任 `x` → 第三十七任 `y`」——动词在任次**前**,
#   「第三十六任」后 24 字内无动词 ⇒ 原正装正则认不出 ⇒ handover_missing_pred 误报 ①态「前任无交班条」,
#   而 ①态的字面处置是「**先补交班条**再盘点」⇒ 照做就是**往台账补一条假交班记录**(交班条其实存在且完整)。
#   🔴 根因是判据缺口 ⛔ 谁写错了:dispatch 席 :3370 认的**本就是倒装**,两席判据语序相反,
#   而书写习惯已经漂过去了。全量回扫另查出第二十/三十二/三十三/三十四任同为倒装 ⇒ ②态对这 4 任一直是盲的。
FIX3="$(mktemp -d)"
printf '%s\n' '| 08-29 03:34 | 方案窗口 | 🔄 **交班 方案窗口第三十六任 `x` → 第三十七任 `y`(创始人当轮令) |' > "$FIX3/board"
printf '## 占位\n' > "$FIX3/page"
t "#108-fix3 倒装交班条(动词在任次前)方案窗口席须认出" bash -c 'source "'"$V16F"'"; handover_unpaired "'"$FIX3"'/board" "'"$FIX3"'/page" | grep -q "方案窗口第三十六任"'
# ⚠️ 倒装交班条**常含两个任次**(「交班 X 第N任 → 第N+1任」)。BSD grep/sed 无非贪婪,贪婪匹配会抽到**继任号**
#   ⇒ 报错人;:3370 的 dispatch 段靠 head 取第一个绕开,本处靠 python 非贪婪 {0,24}? 取第一个。
t "#108-fix3 倒装条含两个任次 ⇒ 取**交出的那任** ⛔ 取继任号" bash -c 'source "'"$V16F"'"; ! handover_unpaired "'"$FIX3"'/board" "'"$FIX3"'/page" | grep -q "第三十七任"'
printf '%s\n' '| 08-29 03:37 | 方案窗口 | 🟢 接班 方案窗口 第三十七任 y(起手式六步全过;前任交班条见看板) |' > "$FIX3/b2"
t "#108-fix3 接班条 ⛔ 被倒装分支认成交班条" bash -c 'source "'"$V16F"'"; [ -z "$(handover_unpaired "'"$FIX3"'/b2" "'"$FIX3"'/page")" ]'
# 反向锚:正装形态**不得回归**(改倒装时最容易把原分支挤掉)
printf '%s\n' '| 08-20 10:58 | 方案窗口 | 方案窗口第十五任 pingxia-8a 交班(date 10:58 实测封班) |' > "$FIX3/b3"
t "#108-fix3 反向:正装形态仍须认出(⛔ 加倒装把正装挤掉)" bash -c 'source "'"$V16F"'"; handover_unpaired "'"$FIX3"'/b3" "'"$FIX3"'/page" | grep -q "方案窗口第十五任"'
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
# 守护: 11B-三个探针面选错
T3PA="$(mktemp -d)"; mkdir -p "$T3PA/sessions" "$T3PA/socks"
awk "/^seat_name_pick\\(\\)\\{/,/^}/;/^seat_liveness\\(\\)\\{/,/^}/" "$LANE" > "$T3PA/sl.sh"
printf '%s\n' '| **收班席** | `seat-closed`(**已收班 ⛔ 在班**; 历史 **第一任在班**、**第二任在班**) | — | 任 | 时 | 人 |' > "$T3PA/closed.md"
printf '%s\n' '| **真在班席** | `seat-active`(**第三任在班**; 历史 **第二任已收班**) | — | 任 | 时 | 人 |' > "$T3PA/active.md"
printf '%s\n' '| **待接席** | **待接**(`seat-pending` 历史 **第一任在班**) | — | 任 | 时 | 人 |' > "$T3PA/pending.md"
t "三探针 A 阴性1/2:当前已收班、历史两处在班 ⇒ 零告警" env LAIXIN_CC_SESS="$T3PA/sessions" LAIXIN_CC_SOCKS="$T3PA/socks" LAIXIN_SEATLIVE_TMUX_SESSIONS=three-probe-none bash -c '
  source "$1/sl.sh"; [ -z "$(seat_liveness "$1/closed.md")" ]' _ "$T3PA"
t "三探针 A 阳性1/1:当前真在班、历史已收班 ⇒ 恰一条原形告警" env LAIXIN_CC_SESS="$T3PA/sessions" LAIXIN_CC_SOCKS="$T3PA/socks" LAIXIN_SEATLIVE_TMUX_SESSIONS=three-probe-none bash -c '
  source "$1/sl.sh"; out="$(seat_liveness "$1/active.md")"; [ "$(grep -c "注册表标在班但无活会话" <<< "$out")" -eq 1 ] && grep -q "seat-active" <<< "$out"' _ "$T3PA"
t "三探针 A 阴性2/2:当前待接、历史在班 ⇒ 零告警" env LAIXIN_CC_SESS="$T3PA/sessions" LAIXIN_CC_SOCKS="$T3PA/socks" LAIXIN_SEATLIVE_TMUX_SESSIONS=three-probe-none bash -c '
  source "$1/sl.sh"; [ -z "$(seat_liveness "$1/pending.md")" ]' _ "$T3PA"
rm -rf "$T3PA"
# ⭐ #181 绊线(2026-08-29;病灶=seat_liveness 取「整格第一个反引号 token」,撞上台账 `date` 实测的书写纪律
#    ⇒ 抓到 date、找不到该会话 ⇒ **假崩告警**,而假崩的下游动作是「开新窗接任」⇒ 真实风险=第二个派工窗)。
#    fixture 形态硬约束(dispatch 第七十八任受控实验供):**状态词必须在括号外**且取「在班」——
#    写成「…(在班)」会被 current 解析截掉、根本走不到取名那一步,**全绿而什么都没证明**(与 #180 方法论① 同族)。
T181="$(mktemp -d)"; mkdir -p "$T181/sessions" "$T181/socks"
sed -n "/^seat_name_pick()/,/^}/p" "$LANE" > "$T181/sl.sh"; sed -n "/^seat_liveness()/,/^}/p" "$LANE" >> "$T181/sl.sh"
printf '%s\n' '| **测试席位** | ✅ **第一任在班**(2026-08-29 00:00:00 `date` 实测);`pingxia-zz9` 通道 .claude-b | 一 | 时 | 人 |' > "$T181/date-first-active.md"
printf '%s\n' '| **测试席位** | 🔁 **待接第二任**(2026-08-29 00:00:00 `date` 实测);`pingxia-zz9` 通道 .claude-b | 一 | 时 | 人 |' > "$T181/date-first-pending.md"
printf '%s\n' '| **测试席位** | `pingxia-zz9`(✅ **第一任在班**;2026-08-29 00:00:00 `date` 实测) | 一 | 时 | 人 |' > "$T181/name-first-active.md"
printf '%s\n' '| **测试席位** | ✅ **第一任在班**(2026-08-29 `date` 实测,`doctor` 与 `stats` 已跑) | 一 | 时 | 人 |' > "$T181/no-name.md"
t "#181 矩阵(date 在前 × 在班):认出 pingxia-zz9 ⛔ 抓成 date(回退成 head -1 即红)" env LAIXIN_CC_SESS="$T181/sessions" LAIXIN_CC_SOCKS="$T181/socks" LAIXIN_SEATLIVE_TMUX_SESSIONS=t181-none bash -c '
  source "$1/sl.sh"; out="$(seat_liveness "$1/date-first-active.md" 2>/dev/null)"
  grep -q "|pingxia-zz9|" <<< "$out" || exit 1
  ! grep -q "|date|" <<< "$out"' _ "$T181"
t "#181 矩阵(date 在前 × 待接):零输出(交接期 ⛔ 判崩)" env LAIXIN_CC_SESS="$T181/sessions" LAIXIN_CC_SOCKS="$T181/socks" LAIXIN_SEATLIVE_TMUX_SESSIONS=t181-none bash -c '
  source "$1/sl.sh"; [ -z "$(seat_liveness "$1/date-first-pending.md" 2>/dev/null)" ]' _ "$T181"
t "#181 矩阵(名在前 × 在班):原本就对的那格 ⛔ 被修法带坏" env LAIXIN_CC_SESS="$T181/sessions" LAIXIN_CC_SOCKS="$T181/socks" LAIXIN_SEATLIVE_TMUX_SESSIONS=t181-none bash -c '
  source "$1/sl.sh"; grep -q "|pingxia-zz9|" <<< "$(seat_liveness "$1/name-first-active.md" 2>/dev/null)"' _ "$T181"
t "#181 认不出名 ⇒ stdout 零 + stderr 提醒(失效降级 ⛔ 反向判崩)" env LAIXIN_CC_SESS="$T181/sessions" LAIXIN_CC_SOCKS="$T181/socks" LAIXIN_SEATLIVE_TMUX_SESSIONS=t181-none bash -c '
  source "$1/sl.sh"; e="$1/e.txt"; o="$(seat_liveness "$1/no-name.md" 2>"$e")"
  [ -z "$o" ] || exit 1
  grep -q "认不出席位名" "$e"' _ "$T181"
t "#181 取名两层且顺序不可换:①形态白名单 → ②命令名黑名单外兜底(只加不减)" bash -c '
  fn="$(sed -n "/^seat_name_pick()/,/^}/p" "$0" | grep -v "^[[:space:]]*#")"
  [ -n "$fn" ] || exit 1
  w="$(grep -n "pingxia-\*" <<< "$fn" | head -1 | cut -d: -f1)"
  b="$(grep -n "date|doctor" <<< "$fn" | head -1 | cut -d: -f1)"
  [ -n "$w" ] && [ -n "$b" ] || exit 1
  [ "$w" -lt "$b" ] || exit 1
  grep -q "return 1" <<< "$fn"' "$LANE"
# ⭐ 行为绊线(⛔ 只做静态断言):本条钉的是**第一版修法的真实缺陷** —— 只有形态白名单时,
#    `#130` 三条(幽灵席 / PID 复用 / 真死席)全红,因为白名单外的名字被降级成「读不出」⇒ **漏报真死席**。
#    漏报比误报更难发现(没人会来告诉你「本该报的没报」),所以这条守的是**不漏报**那一侧。
printf '%s\n' '| **幽灵席** | **`no-such-win-zz`**(**在班**) | 一 | 时 | 人 |' > "$T181/ghost.md"
t "#181 不漏报:白名单外的席位名仍须如实报 ⛔ 降级成读不出(只有①时此条红)" env LAIXIN_CC_SESS="$T181/sessions" LAIXIN_CC_SOCKS="$T181/socks" LAIXIN_SEATLIVE_TMUX_SESSIONS=t181-none bash -c '
  source "$1/sl.sh"; grep -q "|no-such-win-zz|" <<< "$(seat_liveness "$1/ghost.md" 2>/dev/null)"' _ "$T181"
t "#181-b 来源映射补 opt-11b/tool-*(缺席致看板来源落成「手工」⇒ 归因面全黑)" bash -c '
  fn="$(sed -n "/^seat_src_infer()/,/^}/p" "$0" | grep -v "^[[:space:]]*#")"
  grep -q "opt-11b)" <<< "$fn" || exit 1
  grep -q "tool-\*)" <<< "$fn"' "$LANE"
rm -rf "$T181"
t "#130 席位活性:在班无会话=报(受控真火形态)" bash -c 'awk "/^seat_name_pick\\(\\)\\{/,/^}/;/^seat_liveness\\(\\)\\{/,/^}/" "'"$LANE"'" > /tmp/lx-sl-fn.sh; source /tmp/lx-sl-fn.sh; printf "%s\n" "| **测试席位甲** | **\`pingxia-zz\`**(**第一任在班**) | — | 任 | 时 | 人 |" > /tmp/lx-sl-reg.md; seat_liveness /tmp/lx-sl-reg.md | grep -q "pingxia-zz"'
t "#130 席位活性:待接/看门狗托管不报(⛔ 交接期与 tmux 内误报)" bash -c 'source /tmp/lx-sl-fn.sh; printf "%s\n%s\n" "| **席位丙** | **待接**(\`pingxia-yy\` 已交班) | — | 任 | 时 | 人 |" "| **席位丁** | \`dwin\`(tmux 内,看门狗托管;**在班**) | — | 任 | 时 | 人 |" > /tmp/lx-sl-reg.md; [ -z "$(seat_liveness /tmp/lx-sl-reg.md)" ]'
t "#130 席位活性:首版 awk 分列假阴性已钉死(cell 必须取到第 3 竖列)" bash -c 'grep -q "cut -d.|. -f3" "'"$LANE"'" && ! grep -qE "awk -F. \\\\\| . .\{print .2\}" "'"$LANE"'"'
# ── #130-tmux 直测半边(2026-08-23 监测实撞:dispatch-11c 两局之间合法待命 >45 分钟,心跳启发式 19:16 假阳性)──
t "#130 tmux 内活窗(pane 非 shell)⇒ 直测判活不报〔应召机务窗形态〕" bash -c '
  awk "/^seat_name_pick\\(\\)\\{/,/^}/;/^seat_liveness\\(\\)\\{/,/^}/" "'"$LANE"'" > /tmp/lx-sl2-fn.sh; source /tmp/lx-sl2-fn.sh
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
sed -n "/^seat_name_pick()/,/^}/p" "$LANE" > "$T130E/sl.sh"; sed -n "/^seat_liveness()/,/^}/p" "$LANE" >> "$T130E/sl.sh"
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
t "ctx:wd_loop 0.7 段已写明 dispatch 换回 claude 后仍不恢复巡检(statusline 70/75 已在当事人眼前)" \
  bash -c 'sed -n "/^wd_loop()/,/^}/p" "'"$LANE"'" | grep -qF "引擎换回不是恢复巡检的理由"'
# ── 绝对余量闸(2026-08-29 实撞:它一次都没执行过)────────────────────────────────────
# 病灶:该段用 os.environ/os.path 而文件只 import json/sys ⇒ 每次抛 NameError,
#   又被裸 `except Exception: pass` 当场吞掉 ⇒ 2026-08-23 双阈裁定当刻**只有一阈在跑**,
#   而屏幕上「余量充足」与「这道闸根本没跑」完全同形(本文件 docstring 自己写着「兜底不许静默」)。
SLP="$(cd "$(dirname "$0")/.." && pwd)/contrib-statusline.py"
SLJ='{"model":{"display_name":"T"},"session_name":"s","context_window":{"used_percentage":30,"total_input_tokens":990000,"context_window_size":1000000}}'
tout "绝对余量闸:余量 1万 < 下限 5万 ⇒ 红行出现(当刻必红)" "绝对余量 10,000 < 下限 50,000" \
  bash -c 'printf "%s" "$2" | env LAIXIN_CTX_ABS_MIN=50000 python3 "$1"' _ "$SLP" "$SLJ"
t "绝对余量闸 阴性:无下限配置 ⇒ 不加噪(⛔ 恒挂一行)" bash -c '
  out="$(printf "%s" "$2" | env -u LAIXIN_CTX_ABS_MIN HOME=/nonexistent-home-4a python3 "$1")"
  ! grep -q "绝对余量" <<< "$out" && ! grep -q "读取异常" <<< "$out"' _ "$SLP" "$SLJ"
# ⭐ 对照:拆掉 import os ⇒ 阳性用例**必须**变红,且异常显形 ⛔ 静默绿
#   (只测「有 import 时能跑」证不了什么:出事前它也一直是绿的)
t "绝对余量闸 对照:拆掉 import os ⇒ 阳性红行消失且异常显形——绊线能分成败" bash -c '
  d="$(mktemp -d)"; sed "/^import os$/d" "$1" > "$d/sl.py"
  out="$(printf "%s" "$2" | env LAIXIN_CTX_ABS_MIN=50000 python3 "$d/sl.py")"
  rm -rf "$d"
  ! grep -q "绝对余量 10,000" <<< "$out" && grep -q "绝对余量闸:读取异常(NameError)" <<< "$out"' _ "$SLP" "$SLJ"

# ⭐ AGENTS.md「双真相源」条的机器化(立规先问机器化):contrib-statusline.py 的闸门线与 cmd_ctx claude 分支必须同步。
#   2026-08-22 实撞:bash 侧 07f59d2 上调 65/75,contrib 副本仍 55/70,AGENTS.md 原文也还写着 70/55——三处两真相。
t "statusline 双真相源:contrib-statusline.py 闸门线与 cmd_ctx 一致(75/70)" bash -c \
  'c="$(dirname "$1")/../contrib-statusline.py"; grep -q "^GATE_HARD = 75" "$c" && grep -q "^GATE_WARN = 70" "$c" && b="$(sed -n "/^cmd_ctx()/,/^}/p" "$1")" && grep -q "pct>=75" <<< "$b" && grep -q "pct>=70" <<< "$b"' _ "$LANE"

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
# 🔴 2.4b:改读**仓内** contrib-statusline.py ⛔ 线上那份 —— 仓内那份本就是单点源,
#   读它天然封闭;读线上那份会让这条测试随机器环境忽红忽绿(线上是否已发布、发布到哪一版)。
#   「线上那份与仓内是否脱节」不归本条管,归 doctor §9c + 看门狗每 N 拍自检(2.4b 迁移的正题)。
sl=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(sys.argv[1]))),"contrib-statusline.py")
if os.path.exists(sl):
    s=open(sl,encoding="utf-8").read()
    gh=re.search(r"GATE_HARD\s*=\s*(\d+)",s); gw=re.search(r"GATE_WARN\s*=\s*(\d+)",s)
    assert gh and gw, "statusline.py 找不到 GATE_HARD/GATE_WARN"
    assert gh.group(1)==h and gw.group(1)==w, \
        "闸门线漂移:laixin-lane=%s/%s 而 statusline.py=%s/%s" % (h,w,gh.group(1),gw.group(1))
' "$LANE"

# ⭐ 状态栏单点源(2026-08-29 改口径):上面那条只比对**闸门线常量**,而 `~/.claude-official/statusline.py`
#   当刻是**仓外独立副本** ⇒ 常量漂移抓得住、**文件级不同步抓不住**。今日实撞正是后者:两份
#   **同时**缺 `import os`(绝对余量闸一次都没执行过)而常量完全一致 ⇒ 那条绊线全绿。
#   ⇒ 新口径:线上那份必须是**软链**且 `readlink -f` 解析到**当前发布版**的 contrib-statusline.py;
#     仍是普通文件 / 指向别处 ⇒ **红 ⛔ 跳过**(「不存在即跳过」正是让这个缺陷藏住的那一句)。
# 📌 2.4b:此处原有一个 `sl_single_source_ok` 的三态夹具块,已**移除** —— 它是**测试本地**的
#   helper(生产代码 0 处引用),而它那三种态(软链→稳定 ✓ / 独立副本 ✗ / 软链指别处 ✗)
#   已被下面 `release_chain_check` 的夹具版**完全覆盖且更严**(另加内容比对 · sha 存在性 ·
#   sha ∈ main · 读不到 ⇒ unknown)。留着等于**判据在测判据**:测一个只有测试自己在用的函数,
#   证明不了生产那条路径。⇒ **覆盖面只增不减,少的是重复。**

# ══ 2.4b:真环境读数已迁 doctor §9c + 看门狗每 N 拍自检;这里只留**封闭夹具版** ═══════════
# 迁走的三条(线上是软链且解析到当前发布版 · 发布物 = 自称 sha 的已提交版 · sha ∈ main)
#   抓的都是真缺陷,但它们**读真实环境** ⇒ 套件不封闭。⛔ 删掉了事:删掉等于把
#   「线上跑着旧版/被手改」重新变回无人负责发现。⇒ 换住处 ⛔ 换有没有。
# 判据本体抽成 `release_chain_check <线上> <稳定> <仓>`(判定与取数分离,#75 家法)⇒ 夹具能造出
#   各种病态直接喂它,⛔ 只能靠真环境碰运气;doctor/看门狗拿同一个函数去断言真环境。
RCF="$(mktemp -d)"
sed -n "/^release_chain_check(){/,/^}/p" "$LANE" > "$RCF/fn.sh"
# 夹具:一个真 git 仓 + releases/<sha>/ 布局 + 稳定路径 + 线上软链(三层与生产同构)
( set -e; cd "$RCF"; git init -q .; printf 'x\n' > contrib-statusline.py
  git add -A; git -c user.email=t@t -c user.name=t commit -qm i; git branch -M main
  S="$(git rev-parse --short HEAD)"; mkdir -p "rel/$S"
  git show "$S:contrib-statusline.py" > "rel/$S/contrib-statusline.py"
  ln -s "$RCF/rel/$S/contrib-statusline.py" "$RCF/stable"; ln -s "$RCF/stable" "$RCF/live"
  cp "rel/$S/contrib-statusline.py" "$RCF/copy"; ln -s "$RCF/contrib-statusline.py" "$RCF/wrong"
  printf '%s\n' "$S" > "$RCF/sha" ) >/dev/null 2>&1
rcc(){ bash -c 'set -uo pipefail; source "$1/fn.sh"; release_chain_check "$2" "$3" "$4"' _ "$RCF" "$1" "$2" "$RCF"; }
export RCF; export -f rcc

t "2.4b 夹具 阳性:软链→稳定→发布物 ∧ 内容 = 该 sha 已提交版 ∧ sha ∈ main ⇒ ok" bash -c '
  grep -q "^verdict=ok " <<< "$(rcc "$RCF/live" "$RCF/stable")"'
t "2.4b 夹具 阴性①:线上是**独立副本**(非软链)⇒ drift(2026-08-29 线上真是这一态)" bash -c '
  o="$(rcc "$RCF/copy" "$RCF/stable")"; grep -q "^verdict=drift " <<< "$o" && grep -q "不是软链" <<< "$o"'
t "2.4b 夹具 阴性②:软链但**指别处** ⇒ drift 且点名两边各解析到哪" bash -c '
  o="$(rcc "$RCF/wrong" "$RCF/stable")"; grep -q "^verdict=drift " <<< "$o" && grep -q "稳定路径解析到" <<< "$o"'
t "2.4b 夹具 阴性③:发布物**被改一个字节** ⇒ drift(证明内容判据 ⛔ 摆设)" bash -c '
  printf "# drift\n" >> "$RCF/rel/$(cat "$RCF/sha")/contrib-statusline.py"
  o="$(rcc "$RCF/live" "$RCF/stable")"
  git -C "$RCF" show "$(cat "$RCF/sha"):contrib-statusline.py" > "$RCF/rel/$(cat "$RCF/sha")/contrib-statusline.py"
  grep -q "^verdict=drift " <<< "$o" && grep -q "已提交版不一致" <<< "$o"'
t "2.4b 夹具 阴性④:线上文件**不存在** ⇒ **unknown ⛔ ok ⛔ drift**(读不到 ⛔ 当健康 ⛔ 当故障)" bash -c '
  o="$(rcc "$RCF/nope" "$RCF/stable")"; grep -q "^verdict=unknown " <<< "$o"'
t "2.4b 夹具 阴性⑤:发布路径**不含 sha 段** ⇒ unknown 且点名(⛔ 拿路径乱猜)" bash -c '
  mkdir -p "$RCF/nosha"; cp "$RCF/contrib-statusline.py" "$RCF/nosha/contrib-statusline.py"
  ln -sf "$RCF/nosha/contrib-statusline.py" "$RCF/stable2"; ln -sf "$RCF/stable2" "$RCF/live2"
  o="$(rcc "$RCF/live2" "$RCF/stable2")"; grep -q "^verdict=unknown " <<< "$o" && grep -q "不含 sha 段" <<< "$o"'
t "2.4b 夹具 阴性⑥:sha 段合法但**仓里不存在该 commit** ⇒ drift 且点名来路不明" bash -c '
  mkdir -p "$RCF/rel/deadbee"; cp "$RCF/contrib-statusline.py" "$RCF/rel/deadbee/contrib-statusline.py"
  ln -sf "$RCF/rel/deadbee/contrib-statusline.py" "$RCF/stable3"; ln -sf "$RCF/stable3" "$RCF/live3"
  o="$(rcc "$RCF/live3" "$RCF/stable3")"; grep -q "^verdict=drift " <<< "$o" && grep -q "在仓里不存在" <<< "$o"'
rm -rf "$RCF"

# ── 迁移的**另一半**:看门狗必须真跑它。少了这半,闸就从「每次跑套件都查」降级成
#   「但愿有人跑 doctor」,而**拆掉之后的样子与迁移完成之后的样子完全同形**(套件都绿、
#   doctor 里都查得到)⇒ 这几条钉的正是那个"同形"里唯一不同的地方。
t "2.4b 迁移另一半:wd_loop **真调** release_chain_tick(⛔ 只留挂点)且每 N 拍 ⛔ 每拍" bash -c '
  b="$(sed -n "/^wd_loop()/,/^}/p" "$1")"; [ -n "$b" ] || exit 9
  grep -qE "qtick % \\$\{WD_RELEASE_CHECK_EVERY:-10\}" <<< "$b" &&
  grep -qE "^\s*\( release_chain_tick \)" <<< "$b"' _ "$LANE"
t "2.4b 迁移另一半:调用是**子 shell 隔离**(#44:保命循环里裸调用会被 die 无声带死宿主)" bash -c '
  b="$(sed -n "/^wd_loop()/,/^}/p" "$1")"; grep -qE "^\s*\( release_chain_tick \)" <<< "$b"' _ "$LANE"
t "2.4b tick:落盘含 verdict/ts/since/sha/why 且**每拍覆盖** ⛔ 追加(态文件是当刻态)" bash -c '
  b="$(sed -n "/^release_chain_tick()/,/^}/p" "$1")"; [ -n "$b" ] || exit 9
  grep -q "> \"\$RELEASE_STATE_FILE\"" <<< "$b" && ! grep -q ">> \"\$RELEASE_STATE_FILE\"" <<< "$b" &&
  for k in verdict ts since sha why; do grep -q "printf .${k}=" <<< "$b" || exit 1; done' _ "$LANE"

# ── 推送挂点:钉「挂点在 ∧ 当刻不出声」。⛔ 让它退化成"但愿以后有人接线":
#   挂点被删时这条必须变红,而当刻若已出声也必须变红(那就是写了占位代码)。
t "2.4b 推送挂点:标记**在**(挂点被删则红)" bash -c '
  grep -q "RELEASE_CHAIN_EMIT_HOOK" "$1"' _ "$LANE"
t "2.4b 推送挂点:当刻**不出声**——tick 体内零 board / 零 desktop_notify(片② 才接线)" bash -c '
  b="$(sed -n "/^release_chain_tick()/,/^}/p" "$1" | grep -v "^[[:space:]]*#")"; [ -n "$b" ] || exit 9
  ! grep -qE "board |desktop_notify " <<< "$b"' _ "$LANE"
t "2.4b 推送挂点 阳性对照:同一判据喂一段**真出声**的 tick ⇒ 必红(证明它 ⛔ 恒绿)" bash -c '
  fake="release_chain_tick(){\n  board \"x\" \"y\"\n}"
  b="$(printf "%b" "$fake" | sed -n "/^release_chain_tick()/,/^}/p" | grep -v "^[[:space:]]*#")"
  grep -qE "board |desktop_notify " <<< "$b"'

# ── doctor §9c 三态(喂夹具态文件;⛔ 读真环境)
t "2.4b doctor §9c:态文件不存在 ⇒ ⚠️ 且明说「本节当刻只有你手跑这一次」⛔ 报绿" bash -c '
  o="$(LAIXIN_RELEASE_STATE=/nope/nope/x "$1" doctor 2>&1)"
  seg="$(sed -n "/== 9c/,/^== /p" <<< "$o")"; [ -n "$seg" ] || exit 9
  grep -q "⚠️" <<< "$seg" && grep -q "看门狗没在跑" <<< "$seg"' _ "$LANE"
t "2.4b doctor §9c:自检在自动跑(读数新鲜)⇒ ✅ 通过态可见(#50)" bash -c '
  d="$(mktemp -d)"; printf "ts=%s\nverdict=ok\nsince=1\nsha=abc\nwhy=\n" "$(date +%s)" > "$d/s"
  o="$(LAIXIN_RELEASE_STATE="$d/s" "$1" doctor 2>&1)"; rm -rf "$d"
  seg="$(sed -n "/== 9c/,/^== /p" <<< "$o")"
  grep -q "发布链自检在自动跑" <<< "$seg"' _ "$LANE"
t "2.4b doctor §9c:自检读数**陈旧** ⇒ ⚠️ 并点名「自动那一半失效时本节退回但愿有人跑 doctor」" bash -c '
  d="$(mktemp -d)"; printf "ts=%s\nverdict=ok\nsince=1\nsha=abc\nwhy=\n" "$(( $(date +%s) - 99999 ))" > "$d/s"
  o="$(LAIXIN_RELEASE_STATE="$d/s" "$1" doctor 2>&1)"; rm -rf "$d"
  seg="$(sed -n "/== 9c/,/^== /p" <<< "$o")"
  grep -q "自检读数已陈旧" <<< "$seg" && grep -q "但愿有人跑 doctor" <<< "$seg"' _ "$LANE"

# ── statusline 发布链段(夹具态文件,与 seat_line 同族纪律)
SLR="$(cd "$(dirname "$0")/.." && pwd)/contrib-statusline.py"; SLRIN='{"context_window":{"used_percentage":30}}'
# 🔴 两处读数必须比一次(本件真验过程当场逼出来的):doctor §9c 的结论是**当场重跑**得来的,
#   而所有窗状态栏读的是**态文件** —— 两个来源可以不一致,而不一致时谁都不会知道
#   (doctor 显绿、屏幕显红,各说各的)。这正是本轮修过两次的那一族,⛔ 在这里第三次留下它。
t "2.4b doctor §9c:当场重跑与态文件**不一致** ⇒ 点名两个数并给两种解释 ⛔ 只信一个" bash -c '
  d="$(mktemp -d)"
  printf "ts=%s\nverdict=drift\nsince=1\nsha=deadbee\nwhy=造出来的不一致\n" "$(date +%s)" > "$d/s"
  o="$(LAIXIN_RELEASE_STATE="$d/s" "$1" doctor 2>&1)"; rm -rf "$d"
  seg="$(sed -n "/== 9c/,/^== /p" <<< "$o")"
  grep -q "两处读数\*\*不一致\*\*" <<< "$seg" && grep -q "当场重跑得" <<< "$seg" &&
  grep -q "态文件是" <<< "$seg" && grep -q "⛔ 只信其中一个" <<< "$seg"' _ "$LANE"
t "2.4b doctor §9c 阴性:两处**一致**时 ⛔ 报不一致(⛔ 恒噪)" bash -c '
  d="$(mktemp -d)"
  printf "ts=%s\nverdict=ok\nsince=1\nsha=abc\nwhy=\n" "$(date +%s)" > "$d/s"
  o="$(LAIXIN_RELEASE_STATE="$d/s" "$1" doctor 2>&1)"; rm -rf "$d"
  seg="$(sed -n "/== 9c/,/^== /p" <<< "$o")"
  ! grep -q "两处读数" <<< "$seg"' _ "$LANE"

t "2.4b statusline:态文件不存在 ⇒ **零输出**(本机没跑流水线,⛔ 加噪)" bash -c '
  o="$(printf "%s" "$3" | LAIXIN_SEAT_STATE=/nope LAIXIN_RELEASE_STATE=/nope/x python3 "$2" | sed "s/\x1b\[[0-9;]*m//g")"
  ! grep -q "发布链" <<< "$o"' _ "" "$SLR" "$SLRIN"
t "2.4b statusline:ok ⇒ 留暗色通过态标记(#50);drift ⇒ 红且带 why" bash -c '
  d="$(mktemp -d)"
  printf "ts=%s\nverdict=ok\nsha=abc\nwhy=\n" "$(date +%s)" > "$d/s"
  a="$(printf "%s" "$3" | LAIXIN_SEAT_STATE=/nope LAIXIN_RELEASE_STATE="$d/s" python3 "$2" | sed "s/\x1b\[[0-9;]*m//g")"
  printf "ts=%s\nverdict=drift\nsha=abc\nwhy=发布物与 abc 的已提交版不一致\n" "$(date +%s)" > "$d/s"
  b="$(printf "%s" "$3" | LAIXIN_SEAT_STATE=/nope LAIXIN_RELEASE_STATE="$d/s" python3 "$2")"
  rm -rf "$d"
  grep -q "发布链 ✓" <<< "$a" && grep -q "发布链脱节" <<< "$(sed "s/\x1b\[[0-9;]*m//g" <<< "$b")" &&
  grep -q $'"'"'\033\[1;31m'"'"' <<< "$b"' _ "" "$SLR" "$SLRIN"
t "2.4b statusline:unknown ⇒ 黄「未判」⛔ 红 ⛔ 绿;陈旧 ⇒ 报秒数;坏文件 ⇒ 报不可解析" bash -c '
  d="$(mktemp -d)"; r(){ printf "%s" "$3" | LAIXIN_SEAT_STATE=/nope LAIXIN_RELEASE_STATE="$d/s" python3 "$2" | sed "s/\x1b\[[0-9;]*m//g"; }
  printf "ts=%s\nverdict=unknown\nsha=—\nwhy=线上文件不存在\n" "$(date +%s)" > "$d/s"; u="$(r "" "$2" "$3")"
  printf "ts=%s\nverdict=ok\nsha=abc\nwhy=\n" "$(( $(date +%s) - 99999 ))" > "$d/s"; o="$(r "" "$2" "$3")"
  printf "garbage\n" > "$d/s"; g="$(r "" "$2" "$3")"
  rm -rf "$d"
  grep -q "发布链 未判" <<< "$u" && grep -qE "发布链 读数陈旧 [0-9]+s" <<< "$o" && grep -q "态文件不可解析" <<< "$g"' _ "" "$SLR" "$SLRIN"
t "2.4b statusline:发布链段异常 ⛔ 带死整条状态栏(拆掉 import os ⇒ ctx 行仍在)" bash -c '
  d="$(mktemp -d)"; sed "/^import os$/d" "$2" > "$d/sl.py"
  o="$(printf "%s" "$3" | python3 "$d/sl.py" | sed "s/\x1b\[[0-9;]*m//g")"; rm -rf "$d"
  grep -q "30%" <<< "$o"' _ "" "$SLR" "$SLRIN"


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
tout "通道:两通道同时有 dispatch 判危险(新活派工权唯一)" "新活派工权唯一" bash -c '
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

t "#夜间断链:两份派工 BRIEF 同步为三桶事实+收方判断,⛔ 穷举式有意空闲铁律" bash -c '
  a="$(sed -n "/^DISPATCH_BRIEF=/,/^# (DISPATCH/p" "$1")"
  b="$(sed -n "/^DISPATCH_BRIEF_KIMI=/,/^# ---- 派工权认领/p" "$1")"
  for brief in "$a" "$b"; do
    grep -qF "三桶读数是你的事实面;可自写非空时,写单就是当下动作——prompt 由你自己写、按批写(方案窗口交一批设计,一口气写完入排队节;卡点过了再写下一批),prompt-up 写单窗只作上下文扛不住时的备选;拿不准按目标(吞吐不断链)自判并留痕" <<< "$brief" || exit 1
    grep -qF "ready/可自写/待认领交付" <<< "$brief" || exit 1
    ! grep -qF "无在飞、无 ready、且 stats 可自写为零" <<< "$brief" || exit 1
  done' _ "$LANE"

T137="$(mktemp -d)"
cat > "$T137/table.md" <<'EOF'
## 进行中(=轨道占用)
| 片 | 轨 | 分支 | 状态 |
## 验收中
| 片 | 轨 | 分支 | 状态 |
## 已完成
| 片 | 轨 | 分支 | 状态 |
## 排队
| 片 | 轨 | 内容 | 状态 |
| ready片 | A | x | prompt ready |
| 可自写片 | B | x | 待写 |
| 缺设计片 | C | x | 发不了 |
EOF
mkdir -p "$T137/home/.laixin-events.d"
printf '1|待验片|P\n' > "$T137/home/.laixin-events.d/pending.ack"
# ⚠️ 这两条用**整行全等**钉 machine 契约 ⛔ 松成子串:全等才抓得住「新加的格被静默丢弃」
#   (#186 那族的形状:未列 case 分支的字段被无声丢掉,不报错、只是读数少一格)。
#   2026-08-29 加 unparsed/unparsed_product/roadmap_writable 三格,期望值同批更新——
#   两份夹具的排队行都能归桶(T1S 那条三格行走 short ⛔ 走 unparsed),进行中节表头也不是
#   路线图那套(序|片|状态|依赖)⇒ 三格皆 0 是**算出来的**,⛔ 照抄实际输出。
t "#夜间断链:stats --machine 复用既有四桶分桶,输出可自写/缺设计/待认领读数" bash -c '
  out="$(HOME="$1/home" LAIXIN_TABLE="$1/table.md" LAIXIN_KB="$1/kb" LAIXIN_BOARD="$1/board" "$2" stats --machine)"
  [ "$out" = "ready=1 selfwrite=1 design=1 pending=1 short=0 selfwrite_product=1 selfwrite_tool=0 selfwrite_other=0 design_product=1 design_tool=0 design_other=0 unparsed=0 unparsed_product=0 roadmap_writable=0" ]' _ "$T137" "$LANE"
# 第一片(2026-08-28 创始人改判后首片,创始人窗口直修;料窗 B 附带发现 a+b):
#   a 三格行原被 len(cells)<4 静默跳过——既不进已识别也不进未识别(总表 L8032 实撞)⇒ 报「格数不足」;
#   b 可自写合计会被读成产品线有活(当日 8 件全是 11B 工具件而两条开发轨空)⇒ 按片名前缀拆产品/工具。
#   回退验证:拆掉 a ⇒ short 字段消失且三格片无声;拆掉 b ⇒ product/tool 字段消失。
T1S="$(mktemp -d)"
cat > "$T1S/table.md" <<'EOF'
## 进行中(=轨道占用)
| 片 | 轨 | 分支 | 状态 |
## 验收中
| 片 | 轨 | 分支 | 状态 |
## 已完成
| 片 | 轨 | 分支 | 状态 |
## 排队
| 片 | 轨 | 内容 | 状态 |
| 三格片 | x | 待写 |
| 11B:工具片 | 工具轨(告警) | x | 待写 |
| 产品片 | A 轨 | x | 待写 |
| 档面片 | 档面维护(dispatch) | x | 待写 |
EOF
mkdir -p "$T1S/home/.laixin-events.d" "$T1S/kb"; : > "$T1S/board"   # 人读面读看板节奏节,夹具须有空看板 ⛔ 只给 --machine 用的最小集
t "第一片a:排队节三格行报 short=1 ⛔ 静默跳过(machine 行)" bash -c '
  out="$(HOME="$1/home" LAIXIN_TABLE="$1/table.md" LAIXIN_KB="$1/kb" LAIXIN_BOARD="$1/board" "$2" stats --machine)"
  [ "$out" = "ready=0 selfwrite=3 design=0 pending=0 short=1 selfwrite_product=1 selfwrite_tool=1 selfwrite_other=1 design_product=0 design_tool=0 design_other=0 unparsed=0 unparsed_product=0 roadmap_writable=0" ]' _ "$T1S" "$LANE"
t "第一片a+b:人读面点名三格片且可自写按轨列拆为 产品 1 / 工具 1 / 其他 1(⛔ 前缀名单)" bash -c '
  out="$(HOME="$1/home" LAIXIN_TABLE="$1/table.md" LAIXIN_KB="$1/kb" LAIXIN_BOARD="$1/board" "$2" stats 2>/dev/null)"
  grep -q "格数不足 1 行" <<< "$out" && grep -q "· 三格片" <<< "$out" && grep -q "产品 1(A/B/C 轨)/ 工具 1 / 其他 1" <<< "$out"' _ "$T1S" "$LANE"
{ sed -n "/^wd_fuel()/,/^}/p" "$LANE"; sed -n "/^wd_fuel_advice()/,/^}/p" "$LANE"; sed -n "/^wd_nudge_text()/,/^}/p" "$LANE"; sed -n "/^ev_selfwrite_pending()/,/^}/p" "$LANE"; } > "$T137/f.sh"
t "#137:wd_fuel 认可空闲轨 ready/可自写/待认领 P;忙轨 ready、verify/工具等待窗、relay outbox 都不算;总表不可读朝告警侧" bash -c '
  source "$1/f.sh"; SESSION=s; TABLE="$1/table.md"; : > "$TABLE"; EV_PENDING="$1/pending"; RELAY_OUTBOX="$1/outbox"; : > "$EV_PENDING"; : > "$RELAY_OUTBOX"
  ev_next_ready(){ :; }; win_exists(){ return 1; }; lane_busy(){ return 1; }; tmux(){ :; }; stat(){ printf "mtime\n"; }; cmd_stats(){ printf "ready=0 selfwrite=0 design=0 pending=0\n"; }
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
t "#夜间断链:可自写 fixture 进入 wd_fuel,nudge 给三桶事实+默认建议+收方判断" bash -c '
  source "$1/f.sh"; TABLE="$1/table"; : > "$TABLE"; EV_PENDING="$1/pending"; : > "$EV_PENDING"; STAMP=1
  stat(){ printf "%s\n" "$STAMP"; }; cmd_stats(){ printf "ready=0 selfwrite=1 design=0 pending=0 short=0 selfwrite_product=1 selfwrite_tool=0 selfwrite_other=0\n"; }
  ev_next_ready(){ :; }; win_exists(){ return 1; }; lane_busy(){ return 1; }
  wd_fuel >/dev/null; out="$(wd_nudge_text 900)"
  grep -q "可自写(产品):1件" <<< "$WD_FUEL" && grep -qF "三桶读数: ready=0 / 可自写=产品1·工具0·其他0(派工席只看产品格) / 待认领=0" <<< "$out" &&
    grep -qF "默认建议:可自写**产品**格非空通常适合起写单" <<< "$out" &&
    grep -qF "若你判断另有更优动作,照你的判断办并留痕。" <<< "$out" &&
    ! grep -qE "同一轮完成|fresh\\+send|立刻|必须" <<< "$out"' _ "$T137"
# ── #186(2026-08-29 方案窗口第三十七任):可自写按**轨列分格**判,派工席只对「产品」格负责 ────────
#   实撞=看门狗连催派工窗口 6 次「可自写=37 建议起写单」,而 stats 新判据(6b29398)实测 产品 0 / 工具 33 / 其他 4。
#   根因:wd_fuel 的 case 只有 `selfwrite=*` 分支,而 `selfwrite_product=` 第 10 字符是 `_` 不是 `=`
#   ⇒ 落不进任何分支、**被静默丢弃 ⛔ 报错**。数据源里有产品格,看门狗没取 ——「修了一半,两半在读数面同形」。
#   🔴 三向缺一不可:①阳性(功能对)②阴性(反例不误催)③降级(探针坏掉倒向安全的一侧)。
t "#186 阴性:产品 0 / 工具 33 ⇒ ⛔ 判为可自写燃料、⛔ 建议派工席起写单(工具格归 11B 线)" bash -c '
  source "$1/f.sh"; TABLE="$1/t186"; : > "$TABLE"; EV_PENDING="$1/p186"; : > "$EV_PENDING"
  stat(){ printf "1\n"; }; ev_next_ready(){ :; }; win_exists(){ return 1; }; lane_busy(){ return 1; }
  cmd_stats(){ printf "ready=0 selfwrite=37 design=2 pending=0 short=0 selfwrite_product=0 selfwrite_tool=33 selfwrite_other=4\n"; }
  WD_STATS_TABLE_MTIME=""; wd_fuel >/dev/null
  [ -z "$WD_FUEL" ] || { echo "阴性态不应有燃料:$WD_FUEL"; exit 1; }
  [ "${WD_FUEL_SELFWRITE:-0}" -eq 0 ] || exit 2
  ! grep -q "起写单" <<< "$(wd_fuel_advice)" || exit 3
  grep -qF "可自写=产品0·工具33·其他4" <<< "$(wd_nudge_text 900)"' _ "$T137"
# ⚠️ 本条专抓一个只在**阳性向**暴露的 bug:降级标记曾用 ${WD_STATS_SW_DEGRADED:+…} 拼接,而非降级态写的是
#   字符串 "0"(非空)⇒ `:+` 恒触发 ⇒ 有产品格时也标「降级」。阴性向 WD_FUEL 为空、降级向标记本就该有,
#   两向都看不见它。⇒ 断言必须含「**不带**降级标记」这一句 ⛔ 只断言「有燃料」。
t "#186 阳性:产品 2 ⇒ 判为燃料且建议起写单;⛔ 误带降级标记(该标记只在无产品格时出现)" bash -c '
  source "$1/f.sh"; TABLE="$1/t186b"; : > "$TABLE"; EV_PENDING="$1/p186b"; : > "$EV_PENDING"
  stat(){ printf "1\n"; }; ev_next_ready(){ :; }; win_exists(){ return 1; }; lane_busy(){ return 1; }
  cmd_stats(){ printf "ready=0 selfwrite=5 design=0 pending=0 short=0 selfwrite_product=2 selfwrite_tool=3 selfwrite_other=0\n"; }
  WD_STATS_TABLE_MTIME=""; wd_fuel >/dev/null
  grep -qF "可自写(产品):2件" <<< "$WD_FUEL" || { echo "阳性未判燃料:$WD_FUEL"; exit 1; }
  ! grep -q "降级" <<< "$WD_FUEL" || { echo "误带降级标记:$WD_FUEL"; exit 2; }
  grep -q "起写单" <<< "$(wd_fuel_advice)"' _ "$T137"
t "#186 降级:机器行**不含** selfwrite_product ⇒ 回落合计并**照常催** ⛔ 静默;降级态显式标出" bash -c '
  source "$1/f.sh"; TABLE="$1/t186c"; : > "$TABLE"; EV_PENDING="$1/p186c"; : > "$EV_PENDING"
  stat(){ printf "1\n"; }; ev_next_ready(){ :; }; win_exists(){ return 1; }; lane_busy(){ return 1; }
  cmd_stats(){ printf "ready=0 selfwrite=7 design=0 pending=0\n"; }
  WD_STATS_TABLE_MTIME=""; wd_fuel >/dev/null
  grep -qF "可自写(产品):7件" <<< "$WD_FUEL" || { echo "降级未回落合计(静默了):$WD_FUEL"; exit 1; }
  grep -q "降级按合计" <<< "$WD_FUEL" || exit 2
  grep -qF "无产品格,降级按合计" <<< "$(wd_nudge_text 900)"' _ "$T137"
# 🔴 第四载体:ev_selfwrite_pending 是**每拍都在跑的活判定**(lane 轨空闲告警),口径必须与 wd_fuel 同步。
#   上一轮 P0 的教训逐字记在该函数注释里:三份文字改完、第四份活逻辑照旧 ⇒ 三份全绿而行为不变。
# ── accept-preflight(M1 影子版)首批测试(2026-08-29 方案窗口第三十七任;此前**零测试**)────────────
#   缺口本身值得记:一个即将在七步第 5 步转正、成为验收组成部分的程序,一条测试都没有。
#   ⚠️ 全部用**不存在的候选 commit** ⇒ 在 `worktree add` 那步即停,**⛔ 触发全量**(跑一次 9 分钟)。
APFT="$(mktemp -d)"
# 实撞:省略可选的 prompt 直接给 --repo ⇒ 旧解析 `PROMPT=$3` + 无条件 `shift 3` 把旗标吃掉,
#   REPO 静默退回 dirname($0)/..;从**发布版**调用时那是 releases 目录(非 git 仓)⇒ 整单「未判」1 秒返回。
t "accept-preflight:省略 prompt 时 --repo 与 --evidence-dir 仍生效(⛔ 被位置参数 \$3 吃掉)" bash -c '
  out="$("$1" 片X deadbeef00 --repo "$3" --evidence-dir "$2/ev" 2>&1)"
  grep -q "最终 main 基点: unknown" <<< "$out" && { echo "--repo 未生效(基点 unknown)"; exit 1; }
  grep -qF "证据路径: $2/ev" <<< "$out" || { echo "--evidence-dir 未生效"; exit 2; }' _ "$APF" "$APFT" "$(cd "$(dirname "$0")/.." && pwd)"
# 🔴 失败要**显式** ⛔ 静默出一张整单「未判」的事实单——那与「真的判不出」在事实单上完全同形。
t "accept-preflight:仓路径判不出 ⇒ 显式报错并 exit 2 ⛔ 静默用非仓路径出「未判」单" bash -c '
  mkdir -p "$2/fake/bin"; cp "$1" "$2/fake/bin/"
  out="$(cd / && "$2/fake/bin/accept-preflight" 片X deadbeef00 2>&1)"; rc=$?
  [ $rc -eq 2 ] || { echo "退出码=$rc,应为 2"; exit 1; }
  grep -q "仓路径判不出" <<< "$out" || { echo "无显式报错:$out"; exit 2; }
  ! grep -q "【验收事实单】" <<< "$out" || { echo "判不出却仍出了事实单"; exit 3; }' _ "$APF" "$APFT"
# 三态硬规则(§九之三 通则 3):只许 成立 / 不成立 / 未判,「未判」必须显式写出 ⛔ 写成绿或零。
t "accept-preflight:四行只出三态之一,且未给 prompt 时硬边界/绊线为「未判」⛔ 当未命中/当绿" bash -c '
  out="$("$1" 片X deadbeef00 --repo "$3" --evidence-dir "$2/ev2" 2>&1)"
  grep -qE "^硬边界: 未判" <<< "$out" && grep -qE "^绊线: 未判" <<< "$out" || { echo "未判未显式"; exit 1; }
  grep -qF "⛔ 当未命中" <<< "$out" && grep -qF "⛔ 当绿" <<< "$out" || exit 2
  for ln in 基点 全量 硬边界 绊线; do
    grep -E "^$ln: " <<< "$out" | grep -qE "^$ln: (成立|不成立|未判|命中|未命中)" || { echo "$ln 行非三态"; exit 3; }
  done
  grep -q "影子运行:本单 ⛔ 算替代" <<< "$out"' _ "$APF" "$APFT" "$(cd "$(dirname "$0")/.." && pwd)"
# ── 测试入口按仓可配(七步第 3 步在途③;2026-08-29 方案窗口第三十七任)──────────────────────
#   原实现把入口 `bash tests/run.sh` 与结果解析 `^结果:N 过 / M 败` **双双硬编码成工具仓形态**,
#   历史回放跨不到别的仓(钓不钓基座仓无 tests/run.sh、输出是 unittest 风格,两处都对不上)。
#   ⚠️ 用真 commit + 假测试命令 ⇒ worktree 真建、全量不真跑,几秒完事。
# ── merge-guard 自认仓(2026-08-29 方案窗口第三十七任;派工窗口合钓不钓片时实撞)──────────────
#   实撞:钓不钓片 commit 在 ~/钓不钓-基座,而本命令只在 $DEFAULT_DIR(产品仓)解析 ⇒ 必 fail-closed。
#   fail-closed 本身对,缺的是它不会去已登记仓里找。⛔ 靠卡里写一句 LAIXIN_REPO=…(忘了的表现与「真判不了」同形)。
t "merge-guard 自认仓:目标只在某个已登记仓解析得出 ⇒ 改用该仓并**显式告知** ⛔ 静默换" bash -c '
  out="$("$1" merge-guard 264792e7 2>&1)" || true
  grep -q "自认仓" <<< "$out" || { echo "未自认仓:$(head -1 <<< "$out")"; exit 1; }
  grep -q "基座仓" <<< "$out" || exit 2
  grep -q "代码库=.*钓不钓-基座" <<< "$out" || exit 3' _ "$LANE"
# 🔴 反向锚:加了自认仓 ⛔ 放宽 fail-closed —— 一个都不命中时仍须拒判。
t "merge-guard 反向:全部已登记仓都解析不出 ⇒ 仍 fail-closed ⛔ 当作安全" bash -c '
  out="$("$1" merge-guard deadbeef00c0ffee 2>&1)"; rc=$?
  [ $rc -ne 0 ] || { echo "应拒判却退 0"; exit 1; }
  grep -q "判不了" <<< "$out" && grep -q "⛔ 当作安全" <<< "$out"' _ "$LANE"
# 多仓命中不自动挑(「挑了一个」与「挑对了那个」在输出里同形);难造真夹具,锚代码分支。
t "merge-guard:多仓命中 ⇒ 报错要求显式 LAIXIN_REPO ⛔ 自动挑一个" bash -c '
  d="$(sed -n "/^cmd_merge_guard()/,/^}$/p" "$1")"
  grep -q "个已登记仓都解析得出" <<< "$d" && grep -qF "⛔ 自动挑一个" <<< "$d" &&
  grep -q "KNOWN_REPO_ENTRIES" <<< "$d"' _ "$LANE"
APFC="$(mktemp -d)"; APFREPO="$(cd "$(dirname "$0")/.." && pwd)"; APFCAND="$(git -C "$APFREPO" rev-parse --short HEAD)"
t "accept-preflight:--test-cmd 覆盖入口,且结果行仍按既有格式解析" bash -c '
  out="$("$1" 片X "$4" --repo "$3" --evidence-dir "$2/e1" --test-cmd "echo \"结果:7 过 / 0 败\"" 2>&1)"
  grep -qE "^全量: 成立" <<< "$out" || { echo "未判成立:$(grep ^全量: <<< "$out")"; exit 1; }
  grep -qF "passed=7 failed=0" <<< "$out" || exit 2' _ "$APF" "$APFC" "$APFREPO" "$APFCAND"
# 🔴 判据反向锚:仓**没有**显式声明 judge=rc 时,解析不出必须是「未判」⛔ 因为退出码是 0 就判绿。
#   「未判」在三态硬规则里的存在理由正是**判不出就说判不出**;默认按 rc 定论 = 把未判偷偷变成绿。
t "accept-preflight:未声明 judge=rc 时,无计数即使 rc=0 也判「未判」⛔ 当绿" bash -c '
  out="$("$1" 片X "$4" --repo "$3" --evidence-dir "$2/e2" --test-cmd "true" 2>&1)"
  grep -qE "^全量: 未判" <<< "$out" || { echo "应未判,实得:$(grep ^全量: <<< "$out")"; exit 1; }
  grep -qF "⛔ 当绿" <<< "$out" || exit 2' _ "$APF" "$APFC" "$APFREPO" "$APFCAND"
t "accept-preflight:仓内 11b/test-entry.conf 声明 cmd+judge=rc ⇒ 按退出码定论(跨仓回放所需)" bash -c '
  git -C "$3" worktree add -f --detach "$2/wt" "$4" >/dev/null 2>&1 || exit 9
  mkdir -p "$2/wt/11b"; printf "cmd=true\njudge=rc\n" > "$2/wt/11b/test-entry.conf"
  out="$("$1" 片X "$4" --repo "$2/wt" --evidence-dir "$2/e3" 2>&1)"
  git -C "$3" worktree remove --force "$2/wt" >/dev/null 2>&1
  grep -qE "^全量: 成立" <<< "$out" || { echo "conf 未生效:$(grep ^全量: <<< "$out")"; exit 1; }
  grep -qF "仓声明 judge=rc" <<< "$out" || exit 2' _ "$APF" "$APFC" "$APFREPO" "$APFCAND"
rm -rf "$APFC"
rm -rf "$APFT"
t "#186 第四载体:ev_selfwrite_pending 按**产品格** ⇒ 产品0/工具33 时判「有意空闲」(返 1)⛔ 对产品轨告警" bash -c '
  source "$1/f.sh"; TABLE="$1/t186d"; : > "$TABLE"; EV_PENDING="$1/p186d"; : > "$EV_PENDING"
  stat(){ printf "1\n"; }; ev_next_ready(){ :; }; win_exists(){ return 1; }; lane_busy(){ return 1; }
  cmd_stats(){ printf "ready=0 selfwrite=37 design=2 pending=0 short=0 selfwrite_product=0 selfwrite_tool=33 selfwrite_other=4\n"; }
  WD_STATS_TABLE_MTIME=""; ev_selfwrite_pending && { echo "产品0仍判非空(会对产品轨误告警)"; exit 1; }
  cmd_stats(){ printf "ready=0 selfwrite=5 design=0 pending=0 short=0 selfwrite_product=2 selfwrite_tool=3 selfwrite_other=0\n"; }
  WD_STATS_TABLE_MTIME=""; ev_selfwrite_pending || { echo "产品2却判为空(漏告警)"; exit 2; }
  cmd_stats(){ printf "ready=0 selfwrite=7 design=0 pending=0\n"; }
  WD_STATS_TABLE_MTIME=""; ev_selfwrite_pending || { echo "降级态应回落合计并判非空 ⛔ 静默"; exit 3; }' _ "$T137"
t "#夜间断链:同一 TABLE mtime 连跑 wd_fuel 只调一次 stats,mtime 变化才重跑" bash -c '
  source "$1/f.sh"; TABLE="$1/table"; : > "$TABLE"; EV_PENDING="$1/pending"; : > "$EV_PENDING"; STAMP=1; COUNT="$1/count"
  stat(){ printf "%s\n" "$STAMP"; }; cmd_stats(){ echo run >> "$COUNT"; printf "ready=0 selfwrite=1 design=0 pending=0\n"; }
  ev_next_ready(){ :; }; win_exists(){ return 1; }; lane_busy(){ return 1; }
  wd_fuel >/dev/null; wd_fuel >/dev/null; STAMP=2; wd_fuel >/dev/null
  [ "$(wc -l < "$COUNT" | tr -d " ")" = 2 ]' _ "$T137"
t "#夜间断链:wd_loop 使用事实型 nudge,料断档有单次 fuelgap 闸与三桶日志" bash -c '
  w="$(sed -n "/^wd_loop()/,/^}$/p" "$1")"
  grep -q "wd_nudge_text" <<< "$w" && grep -q "料断档:缺设计" <<< "$w" && grep -q "fuelgap" <<< "$w" && grep -q "燃料读数 ready=" <<< "$w"' _ "$LANE"
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
echo "== M 轨机动窗 m-up(codex terra/xhigh 显式钉定;件毕即收;各件独立 worktree;双向自证)=="
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
t "m-up --dry:起动串显式钉 terra/xhigh(⛔ 吃全局默认)" bash -c '
  l="$(grep "起动串:" <<< "$1")"; [ -n "$l" ] || exit 1
  grep -q "BU_NAME=" <<< "$l" && grep -q "BU_CDP_URL=" <<< "$l" && grep -q " codex " <<< "$l" &&
  grep -q -- "-m gpt-5.6-terra" <<< "$l" && grep -q "model_reasoning_effort=\"xhigh\"" <<< "$l"' _ "$MUP_DRY"
tout "m-up --dry:配型读数显式" "配型=gpt-5.6-terra xhigh(显式钉入)" echo "$MUP_DRY"
tout "m-up --dry:交付契约=记录/M轨-<件名>-报告.md 末行【交付完成】M轨-<件名>" "M轨-测试件-报告.md 末行【交付完成】M轨-测试件" echo "$MUP_DRY"
tout "m-up --dry:窗名 m-<slug>,BU 以 m 开头,端口落验收段 93xx-99xx" "窗口=m-测试件" echo "$MUP_DRY"
t "m-up 点名指令:含任务单路径/worktree/四要件/红线(⛔ push/merge/reset/dmsg/起新窗)/⛔ 自收/按件轻量复核/⛔ 借 M 轨绕片级闸门" bash -c '
  b="$(sed -n "/^cmd_mup()/,/^}$/p" "$1")"
  for k in "任务单(先通读" "工作目录=本 worktree" "四要件" "⛔ git push" "⛔ laixin-lane dmsg" "⛔ 起任何新窗口" "你 ⛔ 自收" "轻量复核" "⛔ 借 M 轨绕" "机动窗"; do
    grep -qF "$k" <<< "$b" || { echo "缺:$k"; exit 1; }
  done' _ "$LANE"
t "m-up:自证①先于派单(模型≠钉定配型 ⇒ die 且不 paste 任务单)" bash -c '
  b="$(sed -n "/^cmd_mup()/,/^}$/p" "$1")"
  a=$(grep -n "m_self_attest_model" <<< "$b" | head -1 | cut -d: -f1); p=$(grep -n "laixin-mmsg" <<< "$b" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$p" ] && [ "$a" -lt "$p" ] && grep -q "自证①失败" <<< "$b" &&
  grep -qF "\$M_CODEX_MODEL \$M_CODEX_EFFORT" <<< "$b"' _ "$LANE"
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
t "account-switch:写开关后同步本进程 CLAUDE_LAUNCHER;在班 dispatch 走 --handover，⛔ 等收班条后 --fresh" bash -c '
  b="$(sed -n "/^cmd_account_switch()/,/^}$/p" "$1")"
  grep -qF "echo \"\$to\" > \"\$sw\"; CLAUDE_LAUNCHER=\"\$to\"" <<< "$b" || { echo "未同步变量"; exit 1; }
  s1=$(grep -nF "echo \"\$to\" > \"\$sw\"" <<< "$b" | head -1 | cut -d: -f1); s2=$(grep -nF "d_out=\"\$(cmd_dispatch --handover" <<< "$b" | head -1 | cut -d: -f1)
  [ -n "$s1" ] && [ -n "$s2" ] && [ "$s1" -lt "$s2" ] || { echo "顺序 $s1 $s2"; exit 2; }
  ! grep -q "cmd_dmsg --from" <<< "$b" && ! grep -q "sleep 20" <<< "$b" &&
  grep -q "继任 dispatch 已起" <<< "$b" && grep -q "前任未被回收" <<< "$b"' _ "$LANE"
t "dispatch 交接:成功路径先通知前任、改排空名，再起继任；新活/旧活分权明文" bash -c '
  T="$(mktemp -d)"; sed -n "/^cmd_dispatch_handover()/,/^}$/p" "$1" > "$T/f.sh"; source "$T/f.sh"
  DISPATCH_WIN=dispatch; SESSION=x; CLAUDE_LAUNCHER=claude; HOME="$T"; TRACE="$T/trace"
  dispatch_alive(){ return 0; }; dispatch_drain_window(){ return 0; }; ev_deliver(){ echo "event:$*" >> "$TRACE"; }
  tmux(){ echo "tmux:$*" >> "$TRACE"; return 0; }; cmd_dispatch(){ echo "dispatch:$*" >> "$TRACE"; echo "继任已起"; }
  board(){ echo "board:$*" >> "$TRACE"; }; caller_src(){ echo test; }; die(){ echo "$*" >&2; exit 1; }
  out="$(cmd_dispatch_handover /tmp/work)" || exit 1
  grep -q "event:消息" "$TRACE" && grep -q "rename-window.*dispatch-drain-" "$TRACE" && grep -q "dispatch:--fresh --dir /tmp/work" "$TRACE" &&
  grep -q "dispatch 接新活" <<< "$out" && grep -q "盯完旧活" <<< "$out"
  rc=$?; rm -rf "$T"; exit $rc' _ "$LANE"
t "dispatch 交接:继任起窗失败必须杀半窗、恢复旧 dispatch 与派工权" bash -c '
  T="$(mktemp -d)"; sed -n "/^cmd_dispatch_handover()/,/^}$/p" "$1" > "$T/f.sh"; source "$T/f.sh"
  DISPATCH_WIN=dispatch; SESSION=x; CLAUDE_LAUNCHER=claude; HOME="$T"; TRACE="$T/trace"
  dispatch_alive(){ return 0; }; dispatch_drain_window(){ return 0; }; ev_deliver(){ :; }
  tmux(){ echo "tmux:$*" >> "$TRACE"; return 0; }; cmd_dispatch(){ return 9; }; win_exists(){ return 0; }
  lock_renew(){ echo "lock:$*" >> "$TRACE"; }; board(){ echo "board:$*" >> "$TRACE"; }; caller_src(){ echo test; }; die(){ echo "$*" >&2; exit 1; }
  ( cmd_dispatch_handover /tmp/work ) >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && grep -q "kill-window.*:dispatch" "$TRACE" && grep -q "rename-window.*dispatch-drain-.* dispatch" "$TRACE" && grep -q "lock:dispatch" "$TRACE"
  ok=$?; rm -rf "$T"; exit $ok' _ "$LANE"
t "排空窗 send:继任在班且持权时可收尾旧活，但不夺锁；继任不在则拒绝" bash -c '
  T="$(mktemp -d)"; sed -n "/^lock_touch_send()/,/^}$/p" "$1" > "$T/f.sh"; source "$T/f.sh"
  DISPATCH_WIN=dispatch; BAD="$T/bad"; whoami_window(){ echo dispatch-drain-1; }; lock_holder(){ echo dispatch; }; lock_write(){ touch "$BAD"; }; die(){ return 7; }
  dispatch_alive(){ return 0; }; lock_touch_send || exit 1; [ ! -e "$BAD" ] || exit 2
  dispatch_alive(){ return 1; }; lock_touch_send >/dev/null 2>&1; [ $? -ne 0 ]; rc=$?; rm -rf "$T"; exit $rc' _ "$LANE"
t "交接期事件:事实旁路排空窗，主动消息只给继任" bash -c '
  e="$(sed -n "/^ev_deliver()/,/^}$/p" "$1")"
  grep -q "dispatch_drain_window" <<< "$e" && grep -qF "[ \"\$kind\" != \"消息\" ]" <<< "$e" && grep -q "交接期旁路" <<< "$e"' _ "$LANE"
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
# #108-fix3:8b 触发面也须认倒装(方案窗口交班条实际写法)。⛔ 把新分支加在「接班…第N任)」之后——
#   上一行那条断言是**字面锚且带闭合括号**,新分支插在它后面会让固定串失配(本轮实撞,1123/1)。
t "#108-fix3 doctor 8b 触发面含倒装分支「(交班|封班|收班)…第N任」,且既有接班分支仍在末尾" bash -c '
  d="$(sed -n "/^cmd_doctor()/,/^}$/p" "$1")"
  grep -qF "|(交班|封班|收班)[^|]{0,24}第[一二三四五六七八九十]+任|" <<< "$d" &&
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
# #108①-fix3:前任交班条为**倒装**形态 ⇒ 视为「有交班条」归 ②态,⛔ 报 ①态「无交班条」。
#   ⛔ 只测「认出来了」:①态与 ②态**处置相反**(①先补交班条 / ②直接盘点),报错族比漏报更贵。
printf '| 08-29 03:37 | 方案窗口 | 接班 方案窗口 第三十七任 y |\n| 08-29 03:34 | 方案窗口 | 🔄 **交班 方案窗口第三十六任 x → 第三十七任 y |\n' > "$TMP108/inv.md"
t "#108①-fix3:前任交班条为倒装语序 ⇒ ⛔ 报①态(有交班条,归②态)" bash -c '
  source "$1/f.sh"; [ -z "$(handover_missing_pred "$1/inv.md" "$1/inv.md" "$1/page.md")" ]' _ "$TMP108"
# 反向锚:前任**真的**没有交班条时,①态仍须报(⛔ 因加倒装分支而漏报)
printf '| 08-29 03:37 | 方案窗口 | 接班 方案窗口 第三十七任 y |\n| 08-29 03:20 | 方案窗口 | 🟢 A 轨解卡(方案窗口第三十六任晨间第一件) |\n' > "$TMP108/noh.md"
t "#108①-fix3 反向:前任真无交班条 ⇒ 仍报①态(提及型⛔当交班条)" bash -c '
  source "$1/f.sh"; [ "$(handover_missing_pred "$1/noh.md" "$1/noh.md" "$1/page.md")" = "方案窗口 第三十六任" ]' _ "$TMP108"
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
sed -n "/^seat_name_pick()/,/^}/p" "$LANE" > "$TB4/sl.sh"; sed -n "/^seat_liveness()/,/^}/p" "$LANE" >> "$TB4/sl.sh"
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
  grep -q "^## 一 四个核对" "$1/skills/laixin-kickoff/SKILL.md" &&
  grep -q "^## 四 负面清单" "$1/skills/laixin-kickoff/SKILL.md" &&
  grep -q "档案-kickoff卡原文-20260828.md" "$1/skills/laixin-kickoff/SKILL.md"' _ "$(cd "$(dirname "$0")/.." && pwd)"
t "kickoff 卡防回胖(≤90 行且 ≤5000 bytes;2026-08-28 创始人定:一分钟卡,加一条先删一条)" bash -c '
  f="$1/skills/laixin-kickoff/SKILL.md"; [ "$(wc -l < "$f" | tr -d " ")" -le 90 ] && [ "$(wc -c < "$f" | tr -d " ")" -le 5000 ]' _ "$(cd "$(dirname "$0")/.." && pwd)"
t "acceptance 验收卡防回胖(≤90 行且 ≤5000 bytes;2026-08-29 创始人「测试那块按方案改」=闸线确认)" bash -c '
  f="$1/skills/laixin-acceptance/SKILL.md"; [ "$(wc -l < "$f" | tr -d " ")" -le 90 ] && [ "$(wc -c < "$f" | tr -d " ")" -le 5000 ]' _ "$(cd "$(dirname "$0")/.." && pwd)"
t "acceptance 卡:机器契约末行形态在卡上(【验收回执】通过 / 打回 <类型:方向性|工程>)" bash -c '
  f="$1/skills/laixin-acceptance/SKILL.md"; grep -q "【验收回执】通过" "$f" && grep -q "【验收回执】打回 <类型:方向性|工程>" "$f" && grep -q "所基于的main commit" "$f"' _ "$(cd "$(dirname "$0")/.." && pwd)"
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
        (u'--model claude-opus-5', '方案窗口模型钉死'),
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

# ── 分支命名闸(2026-08-27;按 worktree 四仓分流，⛔ 按 prompt 所在 KB) ───────────────
TBN="$(mktemp -d)"; TOOLROOT="$TBN/home/Developer/laixin-pipeline"; TOOLWT="$TBN/tool-wt"
BASE="$TBN/home/钓不钓-基座"
mkdir -p "$TBN/kb/索引" "$TBN/repo" "$TOOLROOT" "$TBN/home/钓不钓" "$BASE" "$TBN/unknown"
printf '裁定池\n' > "$TBN/kb/索引/wiki-裁定池总表.md"; printf '红线\n' > "$TBN/kb/索引/wiki-红线清单.md"
git init -q -b main "$TOOLROOT"; git -C "$TOOLROOT" config user.email t@t; git -C "$TOOLROOT" config user.name t
printf 'x\n' > "$TOOLROOT/x"; git -C "$TOOLROOT" add x; git -C "$TOOLROOT" commit -qm init; git -C "$TOOLROOT" worktree add -q -b lint "$TOOLWT"
printf '**worktree**:`%s`\n**分支**:`v02-frontend-x`\n' "$TBN/repo" > "$TBN/product-good.md"
printf '**worktree**:`%s`\n**分支**:`mvp-x-y`\n' "$TBN/repo" > "$TBN/product-bad.md"
printf '**worktree**:`%s`\n**分支**:`tool-x`\n' "$TOOLWT" > "$TBN/tool-good.md"
printf '**worktree**:`%s`\n**分支**:`v01-x-y`\n' "$TOOLWT" > "$TBN/tool-bad.md"
printf '**worktree**:`%s`\n**分支**:`mvp-x-y`\n' "$TBN/home/钓不钓" > "$TBN/fish-good.md"
printf '**worktree**:`%s`\n**分支**:`v01-x-y`\n' "$TBN/home/钓不钓" > "$TBN/fish-bad.md"
printf '**worktree**:`%s`\n**分支**:`mvp-x-y`\n' "$BASE" > "$TBN/base-good.md"
printf '**worktree**:`%s`\n**分支**:`v01-x-y`\n' "$BASE" > "$TBN/base-bad.md"
printf '**worktree**:`%s`\n**分支**:`v01-x-y`\n' "$TBN/unknown" > "$TBN/unknown.md"
printf '没有分支声明的宪法头 prompt\n【交付完成】x y\n' > "$TBN/nodecl.md"
t "prompt-lint 按 worktree 四仓分流:四种正确名过、跨仓体例红、未知仓显式提示、未声明仍只提示" bash -c '
  run(){ env HOME="$1/home" LAIXIN_KB="$1/kb" LAIXIN_REPO="$1/repo" "$2" prompt-lint "$1/$3.md" 2>&1; }
  for f in product-good tool-good fish-good base-good; do out="$(run "$1" "$2" "$f")"; rc=$?; [ "$rc" -eq 0 ] && ! grep -qE "分支名不合规|分支名仓判别未命中" <<< "$out" || { echo "$f:$out"; exit 1; }; done
  out="$(env HOME="$1/home" LAIXIN_KB="$1/kb" LAIXIN_REPO="$1/home/钓不钓-基座" "$2" prompt-lint "$1/base-good.md" 2>&1)"; rc=$?; [ "$rc" -eq 0 ] && ! grep -qE "分支名不合规|分支名仓判别未命中" <<< "$out" || { echo "base-override:$out"; exit 4; }
  for f in product-bad tool-bad fish-bad base-bad; do out="$(run "$1" "$2" "$f")"; rc=$?; [ "$rc" -ne 0 ] && grep -q "❌ 分支名不合规" <<< "$out" || { echo "$f:$out"; exit 2; }; done
  out="$(run "$1" "$2" unknown)"; rc=$?; [ "$rc" -eq 0 ] && grep -q "⚠️ 分支名仓判别未命中" <<< "$out" || { echo "$out"; exit 3; }
  out="$(run "$1" "$2" nodecl)"; grep -q "⚠️ prompt 未见「分支」" <<< "$out" && ! grep -q "❌ 分支名不合规" <<< "$out"' _ "$TBN" "$LANE"
git init -q -b main "$BASE"; git -C "$BASE" config user.email t@t; git -C "$BASE" config user.name t
printf 'base\n' > "$BASE/x"; git -C "$BASE" add x; git -C "$BASE" commit -qm init
git -C "$BASE" checkout -qb mvp-fusion-stock-selfcheck-repair
printf 'fourth\n' >> "$BASE/x"; git -C "$BASE" add x; git -C "$BASE" commit -qm fourth
BASE_COMMIT="$(git -C "$BASE" rev-parse HEAD)"
printf '交付\n【交付完成】mvp-fusion-stock-selfcheck-repair %s\n' "$BASE_COMMIT" > "$TBN/base-delivery.md"
printf '交付\n【交付完成】main 0000000000000000000000000000000000000000\n' > "$TBN/missing-delivery.md"
t "verify-from 在第四仓找到 commit 后按该仓核分支与 main" bash -c '
  out="$(env HOME="$1/home" LAIXIN_REPO="$1/repo" "$2" verify-from "$1/base-delivery.md" --dry 2>&1)"
  grep -q "片名=base-delivery" <<< "$out" && grep -q "仓库=$1/home/钓不钓-基座" <<< "$out" && ! grep -q "在仓库解析不到" <<< "$out"' _ "$TBN" "$LANE"
t "verify-from 假 commit 仍拒绝并逐仓列出搜索路径" bash -c '
  out="$(env HOME="$1/home" LAIXIN_REPO="$1/repo" "$2" verify-from "$1/missing-delivery.md" --dry 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && grep -q "产品仓:$1/repo" <<< "$out" && grep -q "工具仓:$1/home/Developer/laixin-pipeline" <<< "$out" && grep -q "钓不钓仓:$1/home/钓不钓" <<< "$out" && grep -q "基座仓:$1/home/钓不钓-基座" <<< "$out"' _ "$TBN" "$LANE"
t "kickoff 卡:分支命名指针在(照版本流卡 A-4 为单点源;2026-08-28 缩编后在 §三 机器代人一句 ⛔ 编号条)" bash -c 'grep -q "分支名照版本流卡 A-4 为单点源" "$1/skills/laixin-kickoff/SKILL.md"' _ "$(cd "$(dirname "$0")/.." && pwd)"
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
  grep -q "tmux new-window -d -t \"=\$SESSION\" -n \"\$cw\"" <<< "$u" && ! grep -q "nohup" <<< "$u" && grep -q "/json/version" <<< "$u" && grep -q "EV_DIR/cdp" <<< "$u" &&
  grep -q "tmux kill-window -t \"=\$SESSION:\$cw\"" <<< "$d" && grep -q "cdp_sweep \"\$p\"" <<< "$d" && grep -q "rm -f \"\$EV_DIR/cdp/" <<< "$d"' _ "$LANE"
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
t "#158-bis ctx_seat_tokens:交接期两个会话同名 dispatch 时按 tmux 席位 PID 取继任" bash -c '
  T="$(mktemp -d)"; mkdir -p "$T/.claude-official/sessions" "$T/.claude-official/projects/-Users-pingxia"
  sed -n "/^ctx_seat_tokens()/,/^}$/p" "$1" > "$T/f.sh"; source "$T/f.sh"
  printf "%s\n" '\''{"name":"dispatch","sessionId":"oldold11-session"}'\'' > "$T/.claude-official/sessions/111.json"
  printf "%s\n" '\''{"name":"dispatch","sessionId":"newnew22-session"}'\'' > "$T/.claude-official/sessions/222.json"
  printf "%s\n" '\''{"message":{"usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'\'' > "$T/.claude-official/projects/-Users-pingxia/oldold11.jsonl"
  printf "%s\n" '\''{"message":{"usage":{"input_tokens":200,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'\'' > "$T/.claude-official/projects/-Users-pingxia/newnew22.jsonl"
  session_seats(){ echo "222 $T/.claude-official dispatch"; }
  out="$(HOME="$T" ctx_seat_tokens dispatch)"; rc=$?; rm -rf "$T"; [ "$rc" -eq 0 ] && [ "$out" = 200 ]' _ "$LANE"
t "#158-bis 采样行第 5 列=席位自身耗量(读不到落 ?,⛔ 落 0)" bash -c '
  seg="$(sed -n "/^ctx_sample_scan()/,/^}$/p" "'"$LANE"'")"
  grep -q "ctx_seat_tokens dispatch" <<< "$seg" && grep -q "\${seat:-?}" <<< "$seg"'
t "cmd_ctx 传 CTX_ABS_MIN 并分三态报(硬阈/准备区/提示态待校准);statusline 同读单点源 ctx-abs-min;ev_loop 新增行扫描接了 ctx_sample_scan" bash -c '
  x="$(sed -n "/^cmd_ctx()/,/^}$/p" "$1")"; grep -q "CTX_ABS_MIN=\"\$(ctx_abs_min)\" python3" <<< "$x" && grep -q "下限\*\*待实测校准,当前仅提示\*\*" <<< "$x" && grep -q "绝对余量 {rem:,} < 下限" <<< "$x" &&
  grep -q "ctx-abs-min" "$2" && grep -q "LAIXIN_CTX_ABS_MIN" "$2" &&
  e="$(sed -n "/^ev_loop()/,/^}$/p" "$1")"; grep -q "ctx_sample_scan" <<< "$e"' _ "$LANE" "$(cd "$(dirname "$0")/.." && pwd)/contrib-statusline.py"
rm -rf "$TCX"

# ── 套件零副作用:真实派工权锁(开跑时在 ⇒ 跑完仍在;内容允许变,在班 dispatch/看门狗会续期)──
# 🔴 **2.4b 有意保留的例外,⛔ 后人当漏网补掉**:2.4b 把「读真实环境」的断言迁去了 doctor/看门狗
#   (理由=套件必须封闭)。**本条不迁**,因为它是**元检查**:它验的是「**套件自己有没有弄脏真环境**」,
#   而它的全部价值恰恰在于**读的是真的** —— 换夹具就等于让它去检查一把假锁,永远通过。
#   ⇒ 判准:被测对象是"外部世界"的断言归 doctor;被测对象是"本套件自身行为"的断言留在这里。
#   ⚠️ 它带一个合法的 ℹ️ 分支(开跑时无真锁 ⇒ 无对象不计)⇒ **本套件的「零跳过」不是无条件的**。
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
t "#164 11c-seat terra 席显式钉 terra/xhigh(⛔ 被名字误导、实际吃全局默认)" bash -c '
  seg="$(sed -n "/^  *terra)/,/;;/p" "$(dirname "'"$LANE"'")/laixin-11c-seat")"
  grep -q -- "-m gpt-5.6-terra" <<< "$seg" && grep -q "xhigh" <<< "$seg"'
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
t "#165 工具件 Codex 独立钉 terra/xhigh ⛔ 误用验收 codex_launch_cmd" bash -c '
  seg="$(sed -n "/^cmd_tool_up()/,/^}/p" "'"$LANE"'" | sed "s/#.*//")"
  grep -qF -- "-m \$TOOL_CODEX_MODEL" <<< "$seg" && grep -qF "model_reasoning_effort=\\\"\$TOOL_CODEX_EFFORT\\\"" <<< "$seg" &&
  grep -qF "LAIXIN_NATIVE_CODEX_MODEL=%q LAIXIN_NATIVE_CODEX_EFFORT=%q" <<< "$seg" && ! grep -q "codex_launch_cmd" <<< "$seg"'
# ⚠️ 判据必须**剥注释**再扫:本函数注释里有意写着反引号包的样例(`claude-fable-5[1m]` 等),
#   而互指注释是本仓惯例 ⇒ 该适配的是判据(今日第二次撞同族,前一次是 dry_win_clash 的 ensure_session)。
t "#165 点名指令(**代码部分**)零反引号〔病灶:反引号在 $(cat <<EOF) 里被求值,首火实撞 run.sh: command not found + grep usage〕" bash -c '
  seg="$(sed -n "/^cmd_tool_up()/,/^}/p" "'"$LANE"'" | sed "s/#.*//")"; ! grep -q "\`" <<< "$seg"' 
# 守护: 11B-工具窗沙盒动作清单
t "#165 工具窗沙盒动作清单:五面+两向判据共用单个 msg,删任一签名真红" bash -c '
  note_ok(){
    local file="$1" seg note other want
    seg="$(sed -n "/^cmd_tool_up()/,/^}/p" "$file")"
    note="$(sed -n "/沙盒内已知做不了的动作清单/,/提交纪律/p" <<< "$seg")"
    for want in \
      "tmux socket 创建被拒" "error creating /private/tmp/tmux-501/lxte (Operation not permitted)" \
      "git index 元数据不可写" "index.lock'"'"': Operation not permitted" \
      "tool-versions 账写入被拒" "/Users/pingxia/.laixin-events.d/tool-versions: Operation not permitted" \
      "沙盒代理端口不可达" "Failed to connect to 127.0.0.1 port 7890 after 0 ms" \
      "worktree FETCH_HEAD 元数据只读" "FETCH_HEAD'"'"': Operation not permitted" \
      "逐字引用对应清单条目" "当轮完整原始串" "结论逐字写「沙盒阻断」" \
      "仍按 prompt 的 〇-ter" "端口 / 路径 / 文件名 / 整条命令" \
      "File name too long" "No such file or directory" \
      "代理项只报告;禁止尝试本机 7896" "禁止改代理/PAC/IP/凭据"; do
      grep -Fq "$want" <<< "$note" || return 1
    done
    ! grep -Fq "\`" <<< "$note" && ! grep -Fq "\$(" <<< "$note" || return 1
    grep -q "printf.*\\\$msg.*native_run/brief.txt" <<< "$seg" || return 1
    grep -q "printf.*\\\$msg.*laixin-toolmsg" <<< "$seg" || return 1
    [ "$(grep -c "沙盒内已知做不了的动作清单" <<< "$seg")" -eq 1 ] || return 1
    other="$(sed -n "/^cmd_prompt_up()/,/^}/p" "$file")"
    ! grep -Fq "沙盒内已知做不了的动作清单" <<< "$other"
  }
  T="$(mktemp -d)"; note_ok "'"$LANE"'" || { rm -rf "$T"; exit 1; }
  sed "/error creating \/private\/tmp\/tmux-501\/lxte (Operation not permitted)/d" "'"$LANE"'" > "$T/lane"
  note_ok "$T/lane" && { rm -rf "$T"; exit 2; }
  rm -rf "$T"'
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
  out="$(LAIXIN_TOOL_ENGINE= LAIXIN_SWITCH_DIR="$T/switch" "'"$LANE"'" tool-up t1652 --prompt "$T/p.md" --dir "$(cd "$(dirname "'"$LANE"'")/.." && pwd)" --dry 2>&1 || true)"
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
  [ "$rc" -eq 0 ] && grep -q "codex exec --json --sandbox workspace-write -C" <<< "$out" &&
  grep -q -- "-m gpt-5.6-terra" <<< "$out" && grep -q "model_reasoning_effort=\"xhigh\"" <<< "$out" && [ ! -e "$1/tmux-called" ]' _ "$N165"
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
# 守护: 11B-三个探针面选错
C3P="$(mktemp -d)"; sed -n "/^native_bu_self_check()/,/^}/p" "$LANE" > "$C3P/f.sh"
python3 - "$C3P" <<'PY'
import json, os, sys

root = sys.argv[1]
started = {"phase":"tool_started", "item_type":"command_execution", "exit_code":None,
           "aggregated_output":""}
good = {"phase":"tool_finished", "item_type":"command_execution", "exit_code":0,
        "aggregated_output":"lane-a\nhttp://127.0.0.1:9231\n"}
ready = {"phase":"notice", "item_type":"agent_message", "item":{"type":"agent_message", "text":"READY"}}
settled = {"phase":"settled", "exit_code":0}
cases = {
    "historical": [started, good, ready, settled],
    "later-command": [started, {**good, "aggregated_output":""}, good, ready, settled],
    "missing-ready": [started, good, settled],
    "not-ready": [started, good, {**ready, "item":{**ready["item"], "text":"NOT READY"}}, settled],
    "wrapped-ready": [started, good, {**ready, "item":{**ready["item"], "text":"READY now"}}, settled],
    "wrong-bu": [started, {**good, "aggregated_output":"lane-b\nhttp://127.0.0.1:9231\n"}, ready, settled],
    "failed-command": [started, {**good, "exit_code":1}, ready, settled],
}
for name, rows in cases.items():
    run = os.path.join(root, name)
    os.makedirs(run)
    with open(os.path.join(run, "events.jsonl"), "w") as out:
        for row in rows:
            out.write(json.dumps(row, ensure_ascii=False) + "\n")
PY
t "三探针 C 阳性2/2:历史顺序与首 command 空、后续正确均成功" bash -c '
  source "$1/f.sh"; native_bu_self_check "$1/historical" lane-a 9231 && native_bu_self_check "$1/later-command" lane-a 9231' _ "$C3P"
t "三探针 C 阴性3/5:缺 READY、NOT READY、带后缀 READY 均失败" bash -c '
  source "$1/f.sh"; ! native_bu_self_check "$1/missing-ready" lane-a 9231 && ! native_bu_self_check "$1/not-ready" lane-a 9231 && ! native_bu_self_check "$1/wrapped-ready" lane-a 9231' _ "$C3P"
t "三探针 C 阴性5/5:BU 错值或 command 非成功 finished 均失败" bash -c '
  source "$1/f.sh"; ! native_bu_self_check "$1/wrong-bu" lane-a 9231 && ! native_bu_self_check "$1/failed-command" lane-a 9231' _ "$C3P"
rm -rf "$C3P"
t "#165-4 tmux 回收杀掉 native 进程后，read 不得把旧账读成 running" bash -c '
  T="$(mktemp -d)"; sed -n "/^tool_native_status()/,/^}/p" "'"$LANE"'" > "$T/f.sh"; source "$T/f.sh"
  board(){ printf "| 00-00 00:00 | %s | %s |\\n" "$1" "$2" >> "$T/board"; }
  mkdir -p "$T/run"; printf "running stale-thread\\n" > "$T/run/status"; printf tool-test > "$T/run/window"; printf codex > "$T/run/engine"
  sleep 30 & p=$!; kill "$p"; wait "$p" 2>/dev/null || true; printf "%s\\n" "$p" > "$T/run/pid"
  out="$(tool_native_status read "$T/run")"; grep -q "^failed 1 process_gone" <<< "$out" && grep -qx "failed 1 process_gone" "$T/run/status" && awk -F"|" "\$3 ~ /^ tool-native \$/ && \$4 ~ /process_gone/ { found=1 } END { exit !found }" "$T/board"; rc=$?; rm -rf "$T"; exit "$rc"'

# ══ 2.8 原生事件:封闭白名单去判开放集合(2026-08-29 生产实撞,值守例 64)══════════════
# 病灶:codex 的 `item.updated`(todo_list 每更新一发)不在白名单 ⇒ reject(unknown_type)
#   ⇒ 写 protocol-error ⇒ finalize 判整次运行 failed —— 而 19:16 lane-b 那车
#   **result.event phase=settled、cli_exit=0、成果就在 worktree**(证据 status=failed 1 protocol_unknown)。
#   任务越大 todo 更新越多 ⇒ **越必命中,⛔ 偶发**;打掉的是合并关口。
# ⇒ 两层:①白名单补已知新类型;②**未知类型只记 notice ⛔ 判失败**,且**中间事件 ⛔ 否决已到达的终态**。
echo "== 2.8. 原生未知事件类型:notice ⛔ 判失败;终态 ⛔ 被中间事件否决 =="
N28="$(mktemp -d)"
sed -n "/^tool_native_status()/,/^}/p" "$LANE" > "$N28/tns.sh"
mk28(){ # <名> <phase> <cli噪声:有|无> —— 造一份 finalize 夹具
  local d="$N28/$1"; mkdir -p "$d"
  printf 'x\n' > "$d/accepted"; printf 'tool-test\n' > "$d/window"; printf 'codex\n' > "$d/engine"
  python3 -c "
import json,sys
e={'phase':sys.argv[2],'raw_type':'turn.completed','usage':{}}
if sys.argv[2]=='failed': e.update({'error':{'message':'boom'},'error_message':'boom','raw_type':'turn.failed'})
open(sys.argv[1],'w').write(json.dumps(e,ensure_ascii=False))" "$d/result.event" "$2"
  [ "$3" = 有 ] && printf 'unknown_type\n' > "$d/protocol-error" || : > "$d/protocol-error"
  printf '%s' "$d"
}
fin28(){ # <夹具目录> <cli_rc> → stdout=status
  bash -c 'set -uo pipefail; board(){ :; }; source "$1/tns.sh"
    LAIXIN_TOOL_NATIVE_ENGINE=codex tool_native_status finalize "$2" tool-test 1 /tmp "$3" >/dev/null 2>&1
    cat "$2/status" 2>/dev/null' _ "$N28" "$1" "$2"
}
# ⚠️ 必须 export -f:用例跑在 `bash -c` **子 shell** 里,顶层函数不被继承 ⇒ 「命令不存在」返回 127,
#   而期望失败的对照写作 `! fn`,127 会被取反成**绿**——判据根本没跑却报过(本仓 2.4a 首跑实撞过一次)。
#   同理**顶层变量也不随子 shell 走**:mk28/fin28 体内引用 $N28,不 export 会在 set -u 下直接炸
#   ——函数与变量要一起导,只导一半和没导一样(本块首跑实撞 7 红)。
export N28; export -f mk28 fin28

t "2.8 阳性:终态 settled + cli_exit=0 + 有协议噪声 ⇒ settled 且噪声**可见**(⛔ 被中间事件否决 ⛔ 静默吞)" bash -c '
  d="$(mk28 pos settled 有)"; [ "$(fin28 "$d" 0)" = "settled 0 protocol_notice" ]'
t "2.8 阴性:终态 settled + cli_exit=0 + **零噪声** ⇒ 干净 settled(⛔ 平白多出 protocol_notice)" bash -c '
  d="$(mk28 clean settled 无)"; [ "$(fin28 "$d" 0)" = "settled 0" ]'
t "2.8 阴性:终态 settled 但 **cli_exit≠0** ⇒ ⛔ 降级,仍红(宽容 ⛔ 越界成放行)" bash -c '
  d="$(mk28 rcbad settled 有)"; grep -q "^failed " <<< "$(fin28 "$d" 1)"'
t "2.8 阴性:**无终态**(result.event 缺)+ 有噪声 ⇒ 仍红 ⛔ settled(没有终态就是没跑完)" bash -c '
  d="$(mk28 noterm settled 有)"; rm -f "$d/result.event"; grep -q "^failed " <<< "$(fin28 "$d" 0)"'
# 🔴 降级必须**按理由分档**(本片首跑当场被既有绊线 #165-3 抓到):最初写成「任何 protocol-error +
#   终态 settled + cli_exit=0 都降级」,把 `invalid_json` 也吞了 —— badjson 夹具发一行坏 JSON 后
#   仍到达成功终态、CLI 退 0 ⇒ **流里出现损坏行不再让运行失败**,修一个洞开一个更大的。
#   ⇒ 只对**开放集合类**(协议升级会新增的,当刻=unknown_type)降级;**损坏类**照旧判红。
t "2.8 阴性:损坏类理由(invalid_json)+ 终态 settled + cli_exit=0 ⇒ **仍红**(⛔ 把坏流降级成成功)" bash -c '
  d="$(mk28 corrupt settled 有)"; printf "invalid_json\n" > "$d/protocol-error"
  grep -q "^failed " <<< "$(fin28 "$d" 0)"'
t "2.8 阴性:开放集合类**混进**一条损坏类 ⇒ 仍红(判据取全称 ⛔ 存在——⛔ 让坏行搭便车)" bash -c '
  d="$(mk28 mixed settled 有)"; printf "unknown_type\ninvalid_json\n" > "$d/protocol-error"
  grep -q "^failed " <<< "$(fin28 "$d" 0)"'
t "2.8 阳性复核:纯 unknown_type(多行)⇒ 仍降级为 settled + notice" bash -c '
  d="$(mk28 multiunk settled 有)"; printf "unknown_type\nunknown_type\n" > "$d/protocol-error"
  [ "$(fin28 "$d" 0)" = "settled 0 protocol_notice" ]'

t "2.8 阴性:真 turn.failed 且零噪声 ⇒ 仍红且理由=turn_failed(⛔ 把宽容未知类型做成什么都不红)" bash -c '
  d="$(mk28 tf failed 无)"; [ "$(fin28 "$d" 0)" = "failed 1 turn_failed" ]'
t "2.8 对照:修前判序(噪声非空即红)在同一夹具上必红——绊线分得开成败" bash -c '
  d="$(mk28 ctl settled 有)"
  naive(){ [ -s "$1/protocol-error" ] && echo "failed 1 protocol_unknown" || echo "settled 0"; }
  [ "$(naive "$d")" = "failed 1 protocol_unknown" ] || exit 1
  [ "$(fin28 "$d" 0)" = "settled 0 protocol_notice" ]'

# ── filter 层:未知类型走 notice ⛔ reject ────────────────────────────────────────
P28="$(mktemp -d)"; mkdir -p "$P28/run"
printf 'th-1\n' > "$P28/run/bound"; printf 'th-1\n' > "$P28/run/accepted"
parse28(){ # <raw行> → 只跑 python 过滤器本体,看它 emit 什么 mode
  bash -c 'set -uo pipefail
    sed -n "/^tool_native_parse() {/,/^}/p" "$1" > "$2/tnp.sh"; source "$2/tnp.sh"
    board(){ :; }
    tool_native_parse "$2/run" tool-test 1 1 /tmp "$3" >/dev/null 2>&1 || true
    printf "protocol-error=[%s] events=%s\n" "$(cat "$2/run/protocol-error" 2>/dev/null | tr "\n" " ")" "$(grep -c . "$2/run/events.jsonl" 2>/dev/null || echo 0)"' _ "$LANE" "$P28" "$1"
}
export P28 LANE; export -f parse28
t "2.8 filter:item.updated ⇒ 记 notice,**protocol-error 保持空**(⛔ reject)" bash -c '
  rm -f "$1/run/protocol-error" "$1/run/events.jsonl"
  o="$(LAIXIN_TOOL_NATIVE_ENGINE=codex parse28 "{\"type\":\"item.updated\",\"item\":{\"type\":\"todo_list\"}}")"
  grep -q "protocol-error=\[\]" <<< "$o"' _ "$P28"
t "2.8 filter:**没见过的新类型** ⇒ 同样只记 notice(⛔ reject)——白名单判开放集合的根本半边" bash -c '
  rm -f "$1/run/protocol-error" "$1/run/events.jsonl"
  o="$(LAIXIN_TOOL_NATIVE_ENGINE=codex parse28 "{\"type\":\"turn.whatever.new\"}")"
  grep -q "protocol-error=\[\]" <<< "$o"' _ "$P28"
t "2.8 filter 阴性:非法 JSON 仍 reject(⛔ 把「宽容未知类型」做成「什么都不红」)" bash -c '
  rm -f "$1/run/protocol-error" "$1/run/events.jsonl"
  o="$(LAIXIN_TOOL_NATIVE_ENGINE=codex parse28 "{not json")"
  grep -q "invalid_json" <<< "$o"' _ "$P28"
rm -rf "$N28" "$P28"

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

# ②-bis 写单窗 print 通道(2026-08-27 创始人「全部局4」令;用例内显式钉 transport ⛔ 吃机器开关——测试密闭性规矩)
tout "显式 --transport print ⇒ dry 报 print" "transport=print" \
  "$LANE" prompt-up t2p --pack "$PK" --transport print --dry
tout "显式 --transport tui ⇒ dry 报 tui(回退路径)" "transport=tui" \
  "$LANE" prompt-up t2p --pack "$PK" --transport tui --dry
tout "env LAIXIN_LANE_TRANSPORT=print ⇒ dry 报 print(写单窗归 lane 面 ⛔ 第三开关面)" "transport=print" \
  env LAIXIN_LANE_TRANSPORT=print "$LANE" prompt-up t2p --pack "$PK" --dry
"$LANE" prompt-up t2p --pack "$PK" --transport nope --dry >/dev/null 2>&1; rc2p=$?
t "未知 transport ⇒ 非零退出〔rc=${rc2p}〕" [ "$rc2p" -ne 0 ]
sgrep "print 分支配型经 LAIXIN_NATIVE_CODEX_MODEL 钉入(⛔ 吃全局默认)" 'LAIXIN_NATIVE_CODEX_MODEL=%q LAIXIN_NATIVE_CODEX_EFFORT=%q LAIXIN_NATIVE_WRITABLE_ROOTS=%q LAIXIN_BOARD_SRC=prompt-native'
sgrep "print 分支沙盒可写根透传(KB 交付面)" 'sandbox_workspace_write.writable_roots=[$_wr_json]'
sgrep "native_run_start 透传模型参数到 codex exec" 'model_args+=(-m "$LAIXIN_NATIVE_CODEX_MODEL")'
sgrep "print 分支走隔离 server(照 tool-up 同法)" 'die "$w print 隔离 tmux server 起窗失败;默认载体已回收"'
# transport 是写单窗的运行账，不是 dry 文案；真走 cmd_prompt_up 的两条分支，以隔离桩代替 tmux/CLI。
PTB="$(mktemp -d)"; PTBF="$PTB/prompt-ledger.sh"
sed -n "/^native_transport_set()/,/^}/p" "$LANE" > "$PTBF"
sed -n "/^cmd_prompt_up()/,/^}/p" "$LANE" >> "$PTBF"
run_prompt_transport(){
  local transport="$1"
  env HOME="$PTB/home" bash -c '
    T="$1"; F="$2"; transport="$3"; source "$F"
    KB="$T/kb"; EV_DIR="$T/events-$transport"; SESSION=prompt-ledger; BOARD="$T/board.md"; DEFAULT_DIR="$T/repo"; TOOL_REPO="$T/tool"
    LANE_SWITCH_DIR="$T/sw"; CLAUDE_LAUNCHER=claude; TOOL_CLAUDE_MODEL=claude; HEADLESS_SETTINGS="$T/headless.json"
    PROMPT_LANE_MODEL=gpt-5.6-sol; PROMPT_LANE_EFFORT=xhigh
    mkdir -p "$KB" "$EV_DIR" "$DEFAULT_DIR" "$TOOL_REPO" "$LANE_SWITCH_DIR" "$HOME"; printf "底稿\n" > "$T/pack.md"
    pwin(){ printf "prompt-ledger\n"; }; cdp_port_verify(){ printf "9555\n"; }; lane_mcp_off_flags(){ :; }
    agent_launch_cmd(){ printf "%s" "$3"; }; codex_service_tier_flag(){ :; }; lane_transport_resolve(){ printf "%s\n" "${1:-tui}"; }
    ensure_session(){ :; }; oneshot_port_clash(){ :; }; native_tmux_start(){ :; }; tool_native_status(){ printf "running fixture\n"; }
    tmux(){ :; }; vwait_ready_codex(){ :; }; m_self_attest_model(){ printf "gpt-5.6-sol xhigh\n"; }; confirm_briefed(){ :; }
    board(){ :; }; caller_src(){ printf "test\n"; }; sleep(){ :; }
    cmd_prompt_up ledger --pack "$T/pack.md" --transport "$transport" >/dev/null
    [ "$(cat "$EV_DIR/native/prompt-ledger/transport")" = "$transport" ]' _ "$PTB" "$PTBF" "$transport"
}
t "prompt-up print:原生根账 transport=print(回退此写入即红)" run_prompt_transport print
t "prompt-up tui:原生根账 transport=tui(与 lane 同法，⛔ 留旧 print 账)" run_prompt_transport tui
rm -rf "$PTB"

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

# ── #172 开发轨终端态事件:真实函数 + 隔离 native 账夹具(停车/崩溃不能再静默)──
echo "== 开发轨终端态事件 =="
N172="$(mktemp -d)"; F172="$N172/events.sh"
for fn in last_contract_line ev_scan_deliveries ev_unsettled ev_last_get ev_last_set ev_same_contract_mode ev_prompt_report_dir ev_prompt_piece_name ev_report_candidates ev_prompt_report_path ev_terminal_report_kind ev_terminal_report_ready ev_terminal_deliver ev_native_terminal_scan ev_loop; do
  sed -n "/^${fn}()/,/^}/p" "$LANE" >> "$F172"
done

t "停车报告只认新标记或精确历史末行(正文/错拼不误报)" env N172="$N172" F172="$F172" bash -c '
  source "$F172"; KB="$N172/kb"; mkdir -p "$KB/4-开发层/记录"
  printf "正文\\n【交付停车】tool-a 缺裁定\\n" > "$KB/4-开发层/记录/new.md"
  printf "正文\\n无完成信号:本报告为停车报告,未使用 \`【交付完成】\` 标记\\n" > "$KB/4-开发层/记录/legacy.md"
  printf "【交付停车】在正文\\n普通末行\\n" > "$KB/4-开发层/记录/body-only.md"
  printf "正文\\n【交付 停车】tool-a\\n" > "$KB/4-开发层/记录/misspelled.md"
  out="$(ev_scan_deliveries)"
  grep -qF "$KB/4-开发层/记录/new.md|" <<< "$out" && grep -qF "$KB/4-开发层/记录/legacy.md|" <<< "$out" && [ "$(ev_terminal_report_kind "$KB/4-开发层/记录/legacy.md")" = parking ] && ! grep -qE "body-only|misspelled" <<< "$out"'

t "native settled/failed/running/bootstrap:一次事件且不重复刷看板" env N172="$N172" F172="$F172" bash -c '
  source "$F172"; T="$N172/native"; EV_DIR="$T/events"; EV_PROMPT_DIR="$EV_DIR/prompts"; mkdir -p "$EV_PROMPT_DIR" "$T/run-a" "$T/run-b" "$T/run-c" "$T/kb/4-开发层/记录" "$T/kb/4-开发层/prompt"
  lane_native_root(){ printf "%s/native/lane-%s\\n" "$EV_DIR" "$1"; }
  native_print_active(){ return 0; }
  board(){ printf "%s\\n" "$2" >> "$T/board"; }
  ev_deliver(){ printf "%s|%s\\n" "$1" "$2" >> "$T/delivered"; }
  tool_native_status(){ case "$1" in read) cat "$2/status" ;; esac; }
  mkdir -p "$(lane_native_root a)" "$(lane_native_root b)" "$(lane_native_root c)"
  printf "%s\\n" "$T/run-a" > "$(lane_native_root a)/current"; printf "settled fixture\\n" > "$T/run-a/status"
  printf "%s\\n" "$T/missing-prompt.md" > "$EV_PROMPT_DIR/lane-a"
  ev_native_terminal_scan; ev_native_terminal_scan
  # 指针在、指向的 prompt 不在 ⇒ 未判「无路径」⛔ 断言「无合法报告」(那是关于报告的话,这里连路径都没推出)
  [ "$(grep -c "已 settled、报告路径未判" "$T/delivered")" -eq 1 ] && grep -q "指向的 prompt 不可读" "$T/delivered" && [ "$(wc -l < "$T/board" | tr -d " ")" -eq 1 ]
  printf "%s\\n" "$T/run-b" > "$(lane_native_root b)/current"; printf "failed fixture\\n" > "$T/run-b/status"; touch "$T/run-b/alerted"
  printf "正文\\n【交付完成】b abcdef0\\n" > "$T/kb/4-开发层/记录/b.md"
  printf "4. 交付报告落盘 %s\\n" "$T/kb/4-开发层/记录/b.md" > "$T/kb/4-开发层/prompt/b-prompt.md"
  printf "%s\\n" "$T/kb/4-开发层/prompt/b-prompt.md" > "$EV_PROMPT_DIR/lane-b"
  ev_native_terminal_scan; ev_native_terminal_scan
  [ "$(grep -c "开发轨崩溃" "$T/delivered")" -eq 1 ] && [ "$(wc -l < "$T/board" | tr -d " ")" -eq 1 ]
  printf "%s\\n" "$T/run-c" > "$(lane_native_root c)/current"; printf "running fixture\\n" > "$T/run-c/status"
  printf "正文\\n【交付完成】c abcdef0\\n" > "$T/kb/4-开发层/记录/c.md"
  printf "4. 交付报告落盘 %s\\n" "$T/kb/4-开发层/记录/c.md" > "$T/kb/4-开发层/prompt/c-prompt.md"
  printf "%s\\n" "$T/kb/4-开发层/prompt/c-prompt.md" > "$EV_PROMPT_DIR/lane-c"
  ev_native_terminal_scan; rm -f "$EV_PROMPT_DIR/lane-c"; printf "settled fixture\\n" > "$T/run-c/status"; ev_native_terminal_scan
  [ ! -e "$T/run-c/terminal-event" ] && [ ! -e "$T/run-c/terminal-report" ]'

run_terminal_tick(){ # <events source> <dead=0|1> <complete|parking> → 真实 ev_loop 一拍；删除接线应超时无投递
  local source_file="$1" dead="$2" marker="$3"
  local root="$N172/tick-${dead}-${marker}" one_tick="$N172/tick-${dead}-${marker}.sh"
  rm -rf "$root"; mkdir -p "$root"
  sed 's/^  while true; do$/  for _terminal_one_tick in 1; do/' "$source_file" > "$one_tick"
  env ROOT172="$root" F172="$one_tick" MARKER172="$marker" bash -c '
    source "$F172"; T="$ROOT172"; EV_DIR="$T/events"; EV_PROMPT_DIR="$EV_DIR/prompts"; EV_SEEN="$EV_DIR/seen"; EV_SETTLING="$EV_DIR/settling"; EV_LAST="$EV_DIR/last"; EV_HB="$EV_DIR/hb"; EV_BOARD_POS="$EV_DIR/board.pos"; EV_VAULT="$T/vault"; KB="$T/kb"; BOARD="$T/board"; EV_TICK=60; EV_STALL=360; EV_PENDING="$T/pending"; EV_SPOOL="$T/spool"; RELAY_OUTBOX="$T/outbox"; RELAY_OUTBOX_D="$T/outbox.d"
    mkdir -p "$EV_PROMPT_DIR" "$EV_DIR/native/lane-a" "$T/run" "$KB/4-开发层/记录" "$KB/4-开发层/prompt" "$EV_VAULT"; : > "$BOARD"; printf "keep|hash\\n" > "$EV_SEEN"
    report="$KB/4-开发层/记录/tick.md"; printf "正文\\n" > "$report"
    if [ "$MARKER172" = parking ]; then printf "【交付停车】tick 缺裁定\\n" >> "$report"; else printf "【交付完成】tick abcdef0\\n" >> "$report"; fi
    printf "4. 交付报告落盘 %s\\n" "$report" > "$KB/4-开发层/prompt/tick-prompt.md"
    printf "%s\\n" "$KB/4-开发层/prompt/tick-prompt.md" > "$EV_PROMPT_DIR/lane-a"; printf "%s\\n" "$T/run" > "$EV_DIR/native/lane-a/current"; printf "settled fixture\\n" > "$T/run/status"
    lane_native_root(){ printf "%s/native/lane-%s\\n" "$EV_DIR" "$1"; }; native_print_active(){ return 0; }; tool_native_status(){ cat "$2/status"; }; ev_log(){ :; }; board(){ :; }; loop_self_gen(){ :; }; loop_gen_record(){ :; }; loop_reload_due(){ return 1; }; wd_alive(){ return 0; }; ev_hb_cutoff(){ date +%s; }; dispatch_alive(){ return 1; }; tmux(){ return 0; }
    sleep(){ :; }
    ev_deliver(){ printf "%s|%s\\n" "$1" "$2" > "$T/delivered"; }
    ev_loop'
  local rc=$?
  if [ "$dead" = 1 ]; then
    [ "$rc" -eq 0 ] && [ ! -e "$root/delivered" ]
  elif [ "$marker" = parking ]; then
    [ "$rc" -eq 0 ] && grep -qF "【事件】开发轨停车报告落盘" "$root/delivered" && [ -f "$root/run/terminal-report" ]
  else
    [ "$rc" -eq 0 ] && grep -qF "【事件】交付落盘" "$root/delivered" && [ -f "$root/run/terminal-report" ]
  fi
}

t "settled 完成报告在同一 tick 投既有交付事件(绕过去抖)" run_terminal_tick "$F172" 0 complete
t "settled 停车报告在同一 tick 投停车事件" run_terminal_tick "$F172" 0 parking
sed '/^[[:space:]]*ev_native_terminal_scan$/d' "$F172" > "$N172/events-without-terminal-scan.sh"
t "反事实:删去终态接线后新报告留在去抖,本拍无投递" run_terminal_tick "$N172/events-without-terminal-scan.sh" 1 complete

# ── 交付报告路径推导:少一跳解引用 + 双根因(2026-08-29 08:40 融合五 / 10:00 4c 各发一次错读数)──
# 三条病灶叠在一起,症状与「开发轨真的没写报告」**完全同形**,所以带着绿测试在生产上恒错:
#   首因 少一跳解引用 —— 指针文件存的是 prompt **路径**,却被当正文喂给推导 ⇒ 每片恒推不出;
#   (a) prompt 只给目录 + 命名规则(融合五)⇒ 无完整路径可抓;
#   (b) prompt 写 `~/…`(4c 系列)⇒ 从 `/` 起锚推出缺 $HOME 的路径,格式对、文件不存在。
# ⚠️ 旧夹具把「指针内容 = 报告路径」写死,等于把 bug 的契约写进了测试——上面三条既有用例已同步改成真实契约。
R172="$N172/report-path"; mkdir -p "$R172/kb/4-开发层/记录" "$R172/kb/4-开发层/prompt"
cat > "$R172/kb/4-开发层/prompt/p-dir.md" <<'EOPD'
---
type: development-prompt
piece: 测试片-甲
---
# 测试项目:测试片-甲 · 开发 prompt
4. **交付报告落盘** `~/kb/4-开发层/记录/`(一片一文件),**末行行首** `【交付完成】<分支> <commit>`;
EOPD
printf '正文\n【交付完成】jia abcdef0\n' > "$R172/kb/4-开发层/记录/proj-测试片-甲-交付报告.md"
cat > "$R172/kb/4-开发层/prompt/p-tilde.md" <<'EOPT'
---
type: development-prompt
piece: 测试片-乙
---
4. **交付报告落盘** `~/kb/4-开发层/记录/proj-测试片-乙-交付报告.md`(**唯一路径**);
EOPT
printf '正文\n【交付完成】yi abcdef0\n' > "$R172/kb/4-开发层/记录/proj-测试片-乙-交付报告.md"
cat > "$R172/kb/4-开发层/prompt/p-ambig.md" <<'EOPA'
---
type: development-prompt
piece: 测试片-丙
---
4. **交付报告落盘** `~/kb/4-开发层/记录/`(一片一文件);
EOPA
printf '正文\n【交付完成】bing abcdef0\n' > "$R172/kb/4-开发层/记录/proj-测试片-丙-交付报告.md"
printf '正文\n写单产物\n' > "$R172/kb/4-开发层/记录/写单-测试片-丙-报告.md"
cat > "$R172/kb/4-开发层/prompt/p-invalid.md" <<'EOPI'
---
type: development-prompt
piece: 测试片-丁
---
4. **交付报告落盘** `~/kb/4-开发层/记录/`(一片一文件);
EOPI
printf '正文\n【交付完成】ding abcdef0\n### 验收观察\n契约行后面还有正文\n' > "$R172/kb/4-开发层/记录/proj-测试片-丁-交付报告.md"
# 修前实现原样留档,作为「绊线能分成败」的常驻对照(⛔ 用 git show main:,合入后 main 就是修后版)
cat > "$R172/pre.sh" <<'EOPRE'
pre_report_path(){
  local prompt="$1" paths count
  [ -r "$prompt" ] || return 1
  paths="$(grep -oE '/[^[:space:]`]*4-开发层/记录/[^[:space:]`]*\.md' "$prompt" 2>/dev/null | sort -u)"
  [ -n "$paths" ] || return 1
  count="$(wc -l <<< "$paths" | tr -d ' ')"
  [ "$count" = 1 ] || return 2
  printf '%s\n' "$paths"
}
EOPRE

t "① 只给目录+命名规则 ⇒ 按片名通配命中唯一实存报告(融合五 形态)" env R172="$R172" F172="$F172" bash -c '
  source "$F172"
  out="$(ev_prompt_report_path "$R172/kb/4-开发层/prompt/p-dir.md")" || exit 1
  [ "$out" = "$R172/kb/4-开发层/记录/proj-测试片-甲-交付报告.md" ] && [ -f "$out" ]'

t "② ~/ 前缀展开成 \$HOME 且推出的文件真存在(4c 形态)" env R172="$R172" F172="$F172" HOME="$R172" bash -c '
  source "$F172"
  out="$(ev_prompt_report_path "$R172/kb/4-开发层/prompt/p-tilde.md")" || exit 1
  case "$out" in "$HOME"/*) ;; *) exit 1 ;; esac
  [ -f "$out" ] && [ "$(ev_terminal_report_kind "$out")" = complete ]'

t "③ 两份候选 ⇒ 事件写「未判:多义」并列出两条,⛔ 写成「无合法报告」" env R172="$R172" F172="$F172" bash -c '
  source "$F172"; T="$R172/ev3"; EV_DIR="$T/events"; EV_PROMPT_DIR="$EV_DIR/prompts"
  mkdir -p "$EV_PROMPT_DIR" "$EV_DIR/native/lane-a" "$T/run"
  lane_native_root(){ printf "%s/native/lane-%s\n" "$EV_DIR" "$1"; }
  native_print_active(){ return 0; }; board(){ :; }
  ev_deliver(){ printf "%s\n" "$2" >> "$T/delivered"; }
  tool_native_status(){ cat "$2/status"; }
  printf "%s\n" "$T/run" > "$(lane_native_root a)/current"; printf "settled fixture\n" > "$T/run/status"
  printf "%s\n" "$R172/kb/4-开发层/prompt/p-ambig.md" > "$EV_PROMPT_DIR/lane-a"
  ev_native_terminal_scan
  grep -q "报告路径未判:多义" "$T/delivered" \
    && grep -q "写单-测试片-丙-报告.md" "$T/delivered" \
    && grep -q "proj-测试片-丙-交付报告.md" "$T/delivered" \
    && ! grep -q "无合法报告" "$T/delivered"'

t "④ 报告实存但契约行不在末尾 ⇒ 事件出 判定=invalid + 末行,⛔ 报路径未判(08:40 融合五 真形态)" env R172="$R172" F172="$F172" bash -c '
  source "$F172"; T="$R172/ev4"; EV_DIR="$T/events"; EV_PROMPT_DIR="$EV_DIR/prompts"
  mkdir -p "$EV_PROMPT_DIR" "$EV_DIR/native/lane-a" "$T/run"
  lane_native_root(){ printf "%s/native/lane-%s\n" "$EV_DIR" "$1"; }
  native_print_active(){ return 0; }; board(){ :; }
  ev_deliver(){ printf "%s\n" "$2" >> "$T/delivered"; }
  tool_native_status(){ cat "$2/status"; }
  printf "%s\n" "$T/run" > "$(lane_native_root a)/current"; printf "settled fixture\n" > "$T/run/status"
  printf "%s\n" "$R172/kb/4-开发层/prompt/p-invalid.md" > "$EV_PROMPT_DIR/lane-a"
  ev_native_terminal_scan
  grep -q "预期报告路径=$R172/kb/4-开发层/记录/proj-测试片-丁-交付报告.md" "$T/delivered" \
    && grep -q "报告判定=invalid" "$T/delivered" && grep -q "末行=契约行后面还有正文" "$T/delivered" \
    && ! grep -q "路径未判" "$T/delivered"'

t "⑤ 对照:少一跳解引用(拿指针当正文)⇒ 推不出——首因绊线" env R172="$R172" F172="$F172" bash -c '
  source "$F172"; P="$R172/kb/4-开发层/prompt/p-dir.md"; ptr="$R172/ptr-lane-a"
  printf "%s\n" "$P" > "$ptr"
  ev_prompt_report_path "$P" >/dev/null || exit 1
  ! ev_prompt_report_path "$ptr" >/dev/null 2>&1'

t "⑥ 对照:修前推导对 ①② 必红(①推不出 ②推出但文件不存在)" env R172="$R172" HOME="$R172" bash -c '
  source "$R172/pre.sh"
  ! pre_report_path "$R172/kb/4-开发层/prompt/p-dir.md" >/dev/null 2>&1 || exit 1
  out="$(pre_report_path "$R172/kb/4-开发层/prompt/p-tilde.md")" || exit 1
  case "$out" in "$HOME"/*) exit 1 ;; esac
  [ ! -f "$out" ]'


rm -rf "$N172"


# ── 并发闸:运行器自取互斥锁(2026-08-29 值守窗「配合问题第 1 例」)────────────────────
# 被替掉的是各窗「跑套件前先 pgrep 自核」这一步:该判据两种实现各自在**放行方向**失效且不可见
# (pgrep 遇非法字节 ⇒ 报错 + stdout 空 ⇒ 假零;ps|grep ⇒ 把提到该串的外壳算成在跑 ⇒ 假阳性)。
# ── 要料链(§八 发车规矩;08-29 实撞:融合五 08:57 合入 → 4c 09:46:22 发车,中间 49 分钟 ready=0
#    在等题,而那段时间没有任何一处会说出「下一片没有」)────────────────────────────────────
# ── 三轨 --dir 必填守卫(2026-08-29 值守第 12 例)──────────────────────────────────────
# 病灶:`up` 的 `dir="$DEFAULT_DIR"` 静默回落到来信主树,而必填守卫只装在 C 轨 ⇒ 漏传 --dir
# 会把 A/B 轨起在另一个产品仓,而「起对仓」与「起错仓」在起窗输出上完全同形。
echo "== 三轨 --dir 必填守卫 =="
D21=lx21-nonexist
tfail "--dir 必填:up a 不带 ⇒ 拒(⛔ 静默落默认仓)" "up a 必须带 --dir" \
  env LAIXIN_SESSION="$D21" "$LANE" up a
tfail "--dir 必填:up b 不带 ⇒ 拒" "up b 必须带 --dir" \
  env LAIXIN_SESSION="$D21" "$LANE" up b
# 守卫必须同时装在 fresh:内部 fresh→up 透传 --dir,但只装一处就又是「一个门」
tfail "--dir 必填:fresh a 不带 ⇒ 拒(守卫 ⛔ 只装 up 一处)" "fresh a 必须带 --dir" \
  env LAIXIN_SESSION="$D21" LAIXIN_LANE_TRANSPORT=tui "$LANE" fresh a
tfail "--dir 必填:fresh b 不带 ⇒ 拒" "fresh b 必须带 --dir" \
  env LAIXIN_SESSION="$D21" LAIXIN_LANE_TRANSPORT=tui "$LANE" fresh b
# ⭐ 阳性对照:给了 --dir 就必须**走过守卫**继续往下判——否则「守卫太紧」与「守卫生效」同形
tfail "--dir 阳性对照:带 --dir 即越过守卫,改报目录不存在(⛔ 卡在必填这一关)" "目录不存在" \
  env LAIXIN_SESSION="$D21" "$LANE" up a --dir /nope-xyz-2026
tout "--dir 报错给候选:next-worktree 在第一位" "1) laixin-lane next-worktree" \
  env LAIXIN_SESSION="$D21" "$LANE" up a
tout "--dir 报错给候选:来信主树明写仅来信片" "仅来信片" \
  env LAIXIN_SESSION="$D21" "$LANE" up a
tout "--dir 报错给候选:列现有 worktree(实时算 ⛔ 硬编码)" "3) 现有 worktree" \
  env LAIXIN_SESSION="$D21" "$LANE" up a
t "--dir 必填:被拒时零 tmux 副作用(窗口未动)" bash -c '! tmux has-session -t lx21-nonexist 2>/dev/null'
# ⭐ 对照:回落源头已从 cmd_up 里去掉——留着它,守卫写了也会被默认值绕过
t "--dir 对照:cmd_up 内不再预置 DEFAULT_DIR(静默回落的源头)" bash -c '
  body="$(sed -n "/^cmd_up() {/,/^}/p" "$1")"
  ! grep -q "local dir=\"\$DEFAULT_DIR\"" <<< "$body" &&
  grep -q "lane_dir_required_die up" <<< "$body"' _ "$LANE"
t "--dir 对照:cmd_fresh 内守卫不再只对 c 轨" bash -c '
  body="$(sed -n "/^cmd_fresh() {/,/^}/p" "$1")"
  ! grep -q "lane\" = \"c\" \] && \[ -z \"\$_hasdir\"" <<< "$body" &&
  grep -q "lane_dir_required_die fresh" <<< "$body"' _ "$LANE"

echo "== 要料链:料仓深度<2 推事实 =="
FW="$(mktemp -d)"; FWF="$FW/fn.sh"
for fn in ev_next_ready wd_fuelwant_target wd_fuelwant_lane_enabled wd_fuelwant_deliver wd_fuel_want; do
  sed -n "/^${fn}()/,/^}/p" "$LANE" >> "$FWF"
done
grep '^ev_ready_count()' "$LANE" >> "$FWF"    # 单行函数:范围 sed 会吞到下一个行首 } ⇒ 用 grep 取
cat > "$FW/env.sh" <<'EOENV'
source "$FWF"
EV_DIR="$FW/ev"; WD_FUELWANT_DIR="$EV_DIR/fuelwant"; WD_LOG="$FW/wd.log"
WD_FUELWANT_MIN="${WD_FUELWANT_MIN:-2}"; DISPATCH_WIN=dispatch; SESSION=s
LANE_SWITCH_DIR="$FW/switch"; TABLE="$FW/table.md"
# 🔴 每个用例自带干净状态:env.sh 由每条用例各自 source ⇒ 重置放这里就等于逐例隔离。
#    ⛔ 共用一份 delivered/标记:上一例留下的标记会让下一例「本该出事件」变成零事件,
#    而计数类断言(累计 N 条)在前几例又恰好蒙对 ⇒ 表现为「前面几条绿、后面几条红」,
#    看起来像后面的实现有问题,实则是夹具串味(本件重跑实撞 5 红,全在靠后的用例)。
rm -rf "$EV_DIR" "$LANE_SWITCH_DIR" "$FW/delivered" "$FW/board" "$FW/wd.log"
mkdir -p "$EV_DIR" "$LANE_SWITCH_DIR"; : > "$FW/delivered"
# ⚠️ case 候选的 `|` 必须是**源码里的字面**:来自 ${…} 展开的 | 只是普通字符,
#    `${FW_WINS:-lane-a|lane-b}` 会变成匹配字符串 "lane-a|lane-b" ⇒ 恒不命中 ⇒ 全轨判未启用
#    ⇒ 期望出事件的用例全红、期望零事件的用例照常绿(本件首跑实撞的正是这个方向)。改用空格成员判定。
win_exists(){ case " ${FW_WINS:-lane-a lane-b} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
board(){ printf '%s\n' "$2" >> "$FW/board"; }
ev_deliver(){ printf '%s\n' "$2" >> "$FW/delivered"; }
wd_fuel(){ WD_STATS_SW_PRODUCT="$FW_SW"; WD_STATS_DG_PRODUCT="${FW_DG:-0}"; WD_STATS_READY="${FW_GREADY:-0}"; return 0; }
fw_table(){ # <B轨ready条数> [A轨ready条数=3] —— A 默认 3 条保持 ok、不干扰对 B 的判读;
            # 要证明「A 也被评估」的用例必须把 A 压到 0,否则 A 恒 ok ⇒ 评了与没评零事件同形
  { echo "## 排队"; echo "| 片 | 轨 | 内容 | 状态 |"; echo "|---|---|---|---|"
    i=0; while [ "$i" -lt "${2:-3}" ]; do i=$((i+1)); echo "| a$i | A | x | prompt ready |"; done
    i=0; while [ "$i" -lt "$1" ];      do i=$((i+1)); echo "| b$i | B | x | prompt ready |"; done
  } > "$TABLE"; }
fw_b(){ grep -c "要料:lane-b" "$FW/delivered" 2>/dev/null || echo 0; }  # 投给 B 轨的**要料**事件条数
EOENV

t "要料:B 轨深度 0<2 ⇒ 恰一条,正文带轨名与三桶实数" env FW="$FW" FWF="$FWF" FW_SW=0 FW_DG=2 bash -c '
  source "$FW/env.sh"; fw_table 0
  wd_fuel_want
  [ "$(fw_b)" -eq 1 ] || exit 1
  grep -q "要料:lane-b 料仓深度 0<2(本轨 ready 0 · 跨轨 ready 0 · 跨轨可自写产品 0);缺设计 2" "$FW/delivered"'

t "要料:同一状态第二拍零新事件(状态转移单次 ⛔ 时间窗)" env FW="$FW" FWF="$FWF" FW_SW=0 bash -c '
  source "$FW/env.sh"; fw_table 0
  wd_fuel_want; wd_fuel_want; wd_fuel_want
  [ "$(fw_b)" -eq 1 ]'

t "要料:标记记下进入时刻与当时深度(尺 6「料齐→发车延迟」可直接算)" env FW="$FW" FWF="$FWF" FW_SW=0 bash -c '
  source "$FW/env.sh"; fw_table 0; wd_fuel_want
  m="$(cat "$WD_FUELWANT_DIR/b")"
  [ "${m%%|*}" = low ] || exit 1
  ts="$(cut -d"|" -f2 <<< "$m")"; [[ "$ts" =~ ^[0-9]+$ ]] || exit 1
  grep -q "depth=0|ready=0|sw_product=0" <<< "$m"'

t "要料:深度回到 ≥2 ⇒ 清标记并落「要料解除」(阴性:深度 2 零事件)" env FW="$FW" FWF="$FWF" FW_SW=0 bash -c '
  source "$FW/env.sh"; fw_table 0; wd_fuel_want
  before="$(fw_b)"
  fw_table 2; wd_fuel_want
  [ ! -f "$WD_FUELWANT_DIR/b" ] || exit 1
  grep -q "要料解除:lane-b" "$WD_LOG" || exit 1
  [ "$(fw_b)" -eq "$before" ]'

t "要料:深度 1→2→1 ⇒ 恰两次(再跌再报)" env FW="$FW" FWF="$FWF" FW_SW=0 bash -c '
  source "$FW/env.sh"
  fw_table 1; wd_fuel_want
  fw_table 2; wd_fuel_want
  fw_table 1; wd_fuel_want
  [ "$(fw_b)" -eq 2 ]'

t "要料:燃料读不到 ⇒ 事件写「未判」⛔ 写成要料 ⛔ 当有料/无料" env FW="$FW" FWF="$FWF" FW_SW="?" bash -c '
  source "$FW/env.sh"; fw_table 0; wd_fuel_want
  grep -q "未判:燃料读不到 —— lane-b" "$FW/delivered" || exit 1
  grep -q "可自写产品=读不出(原值 ?)" "$FW/delivered" || exit 1
  ! grep -q "要料:lane-b" "$FW/delivered"'

t "要料 对照:朴素判据「深度=0 才报」在深度 1 上零输出、本闸报——绊线能分成败" env FW="$FW" FWF="$FWF" FW_SW=0 bash -c '
  source "$FW/env.sh"; fw_table 1
  naive(){ [ "$(( $(ev_ready_count B) + FW_SW ))" -eq 0 ]; }
  naive && exit 1                       # 朴素:深度 1 ⇒ 不报
  wd_fuel_want; [ "$(fw_b)" -eq 1 ]'    # 本闸:报

t "要料:lane-c 未起 ⇒ 不评估且清掉陈标记" env FW="$FW" FWF="$FWF" FW_SW=0 bash -c '
  source "$FW/env.sh"; fw_table 0
  mkdir -p "$WD_FUELWANT_DIR"; printf "low|1|x|depth=0|ready=0|sw_product=0\n" > "$WD_FUELWANT_DIR/c"
  wd_fuel_want
  [ ! -f "$WD_FUELWANT_DIR/c" ] || exit 1
  ! grep -q "lane-c" "$FW/delivered" 2>/dev/null'

t "要料:无窗且不在开关的轨 ⇒ 零事件(⛔ 对不存在的席位喊话)" env FW="$FW" FWF="$FWF" FW_SW=0 FW_WINS="lane-b" bash -c '
  source "$FW/env.sh"; fw_table 0; wd_fuel_want
  grep -q "lane-b" "$FW/delivered" || exit 1
  ! grep -q "lane-a" "$FW/delivered"'

t "要料:开关 lanes-enabled 点名 ⇒ 无窗的轨也评估(轨该在却暂时没窗)" env FW="$FW" FWF="$FWF" FW_SW=0 FW_WINS="lane-b" bash -c '
  source "$FW/env.sh"; fw_table 0 0
  wd_fuel_want; [ "$(grep -c "lane-a" "$FW/delivered")" -eq 0 ] || exit 1   # 无窗又没点名 ⇒ 零
  printf "a\n" > "$FW/switch/lanes-enabled"
  rm -rf "$WD_FUELWANT_DIR"                                                 # 让它重判 ⛔ 被上一拍标记挡住
  wd_fuel_want
  grep -q "要料:lane-a" "$FW/delivered"'

t "要料:投递目标可配;配的窗不在 ⇒ 回落派工并在正文说明 ⛔ 静默丢" env FW="$FW" FWF="$FWF" FW_SW=0 bash -c '
  source "$FW/env.sh"; fw_table 0
  [ "$(wd_fuelwant_target)" = dispatch ] || exit 1          # 默认=派工
  printf "prompt-writer\n" > "$FW/switch/fuelwant-target"
  [ "$(wd_fuelwant_target)" = prompt-writer ] || exit 1     # 开关生效
  wd_fuel_want                                             # 该窗不在 ⇒ 回落
  grep -q "回落派工窗口" "$FW/delivered"'

t "要料 挂点:wd_fuel_want 排在「全轨在跑=正常等待」的 continue **之前**" bash -c '
  b="$(sed -n "/^wd_loop() {/,/^}/p" "$1")"
  w=$(grep -n "wd_fuel_want || true" <<< "$b" | head -1 | cut -d: -f1)
  c=$(grep -n "lane_busy a && lane_busy b && .* then continue; fi" <<< "$b" | head -1 | cut -d: -f1)
  [ -n "$w" ] && [ -n "$c" ] && [ "$w" -lt "$c" ]' _ "$LANE"


rm -rf "$FW"

# ── 料仓读数写回断言范围 + 路线图指路(值守例 16;2026-08-29)────────────────────────
# 病灶:机器实际断言=「排队节里没有一行命中料仓词表」,说出口却是干净的「没料」⇒ 派工花一整轮否定它。
# ⚠️ 单里原诊断(分桶器词表漏认「前置已解」⇒ B3 归不进桶)在真数据上**不成立**:B3 那行在
#   `## 进行中` 的路线图子表里(列=序|片|状态|依赖,无轨列),分桶器只扫排队节 ⇒ 结构性读不到;
#   且排队节 85 行里产品轨 **0 行** ⇒ 未归桶行全部归桶,产品格仍是 0。故改法落在**说清断言范围**。
echo "== 料仓断言范围与路线图指路 =="
BK="$(mktemp -d)"
cat > "$BK/table.md" <<'EOBK'
## 进行中(= 轨道占用)

### 🛤️ 片序与依赖链

| 序 | 片 | 状态 | 依赖 |
|---|---|---|---|
| 1 | ~~甲片~~ | ✅ **已合入 `abc1234`** | — |
| 2 | **乙片** | 🟢 **前置已解**(射程已重出) | ~~甲片合入~~ ✅ 已达成 |
| 3 | **丙片** | 候 乙片 | 乙片(前置**已解除**) |

## 排队(测试)

| 片 | 轨 | 内容 | 发车状态 |
|---|---|---|---|
| 产品待写片 | B | x | 待写 |
| 工具待写片 | 工具轨 | x | 待写 |
| 怪状态产品片 | A | x | 候起件 |
| 怪状态工具片 | 工具轨 | x | 候起件 |
EOBK
BKM="$(env LAIXIN_TABLE="$BK/table.md" "$LANE" stats --machine 2>/dev/null)"   # EV_PENDING 无 env 覆盖,缺文件时 pending 自落 0

tout "断言范围:machine 首行带 unparsed 与 unparsed_product" "unparsed=2 unparsed_product=1" \
  bash -c 'printf "%s\n" "${1%%$'"'"'\n'"'"'*}"' _ "$BKM"
tout "路线图:只计状态格「前置已解」那一行(已合入 ⛔ 计)" "roadmap_writable=1" \
  bash -c 'printf "%s\n" "${1%%$'"'"'\n'"'"'*}"' _ "$BKM"
# ⭐ 判据只看状态格 ⛔ 依赖格:丙片状态是「候 乙片」而依赖格里写着「已解除」——看依赖格会把一个
#   明确在等的片报成可写。这条正是「两列同权」在别处成立、在这里**不**成立的地方。
t "路线图 对照:依赖格含「已解除」但状态在等 ⇒ ⛔ 计(⛔ 两列同权)" bash -c '
  grep -q "^#roadmap-writable 乙片" <<< "$1" && ! grep -q "丙片" <<< "$1" && ! grep -q "甲片" <<< "$1"' _ "$BKM"
t "断言范围 对照:名字**另起行** ⛔ 混进计数行(片名带空格会被词分割切碎)" bash -c '
  first="${1%%$'"'"'\n'"'"'*}"; ! grep -q "roadmap-writable" <<< "$first" && grep -q "^#roadmap-writable " <<< "$1"' _ "$BKM"
t "断言范围:轨列与状态格是两列——状态归不了桶仍能算出产品轨 1 行" bash -c '
  grep -q "unparsed=2 unparsed_product=1" <<< "${1%%$'"'"'\n'"'"'*}"' _ "$BKM"

# 要料链侧四条反向探针(stub wd_fuel 控三个数)
BF="$BK/fn.sh"
for fn in ev_next_ready wd_fuelwant_target wd_fuelwant_lane_enabled wd_fuelwant_deliver wd_fuel_want; do
  sed -n "/^${fn}()/,/^}/p" "$LANE" >> "$BF"
done
grep '^ev_ready_count()' "$LANE" >> "$BF"
cat > "$BK/env.sh" <<'EOBE'
source "$BF"
EV_DIR="$BK/ev"; WD_FUELWANT_DIR="$EV_DIR/fuelwant"; WD_LOG="$BK/wd.log"; WD_FUELWANT_MIN=2
DISPATCH_WIN=dispatch; SESSION=s; LANE_SWITCH_DIR="$BK/switch"; TABLE="$BK/t2.md"
rm -rf "$EV_DIR" "$LANE_SWITCH_DIR" "$BK/delivered" "$BK/wd.log"; mkdir -p "$EV_DIR" "$LANE_SWITCH_DIR"; : > "$BK/delivered"
win_exists(){ [ "$1" = lane-b ]; }; board(){ :; }
ev_deliver(){ printf '%s\n' "$2" >> "$BK/delivered"; }
wd_fuel(){ WD_STATS_SW_PRODUCT=0; WD_STATS_DG_PRODUCT=0; WD_STATS_READY="${BK_GREADY:-0}"
           WD_STATS_UNPARSED="$BK_UNP"; WD_STATS_UNPARSED_PROD="$BK_UNPP"
           WD_STATS_ROADMAP_W="$BK_RMW"; WD_STATS_ROADMAP_NAMES="$BK_RMN"; }
printf '## 排队\n| 片 | 轨 | 内容 | 状态 |\n|---|---|---|---|\n' > "$TABLE"
EOBE

t "断言范围:未归桶**产品轨**>0 ⇒ 推「未判:料仓读数被污染」⛔ 报干净的深度" \
  env BK="$BK" BF="$BF" BK_UNP=5 BK_UNPP=2 BK_RMW=0 BK_RMN="" bash -c '
  source "$BK/env.sh"; wd_fuel_want
  grep -q "未判:料仓读数被污染" "$BK/delivered" &&
  grep -q "未归桶行里有 2 行在\*\*产品轨\*\*上" "$BK/delivered" &&
  ! grep -q "【事件】要料:lane-b" "$BK/delivered"'

t "断言范围:未归桶但**产品轨 0** ⇒ 照报深度,句中带未归桶行数(⛔ 未判把真信号淹掉)" \
  env BK="$BK" BF="$BF" BK_UNP=39 BK_UNPP=0 BK_RMW=0 BK_RMN="" bash -c '
  source "$BK/env.sh"; wd_fuel_want
  grep -q "【事件】要料:lane-b" "$BK/delivered" &&
  grep -q "排队节未归桶 39 行(其中产品轨 0 行)" "$BK/delivered" &&
  ! grep -q "未判" "$BK/delivered"'

t "断言范围:零未归桶 ⇒ 句中**不出现**未归桶字样(⛔ 恒挂一个 0 让人麻木)" \
  env BK="$BK" BF="$BF" BK_UNP=0 BK_UNPP=0 BK_RMW=0 BK_RMN="" bash -c '
  source "$BK/env.sh"; wd_fuel_want
  grep -q "【事件】要料:lane-b" "$BK/delivered" && ! grep -q "未归桶" "$BK/delivered"'

t "路线图指路:排队节产品 0 而路线图有可写片 ⇒ 句子能看出「料在别处」" \
  env BK="$BK" BF="$BF" BK_UNP=0 BK_UNPP=0 BK_RMW=1 BK_RMN="乙片" bash -c '
  source "$BK/env.sh"; wd_fuel_want
  grep -q "路线图子表可写片 1(乙片)" "$BK/delivered" &&
  grep -q "未登排队节" "$BK/delivered" &&
  grep -q "登进排队节并带轨" "$BK/delivered" &&
  grep -q "料仓深度 0<2" "$BK/delivered"'   # ⛔ 计入深度:深度仍是 0

# ⭐ 射程标记(值守 13:45:22 实撞):同句里 ready 是**本轨**、可自写产品是**跨轨合计**,
#   不标射程时「本轨 0、跨轨 ≥1」并存的当刻收方看不出后半句是哪一层 ⇒ 只能再跑一轮核实。
t "射程标记:本轨 ready 0 而跨轨 ≥1 ⇒ 句中必须出现跨轨数(⛔ 只写一个光秃秃的 ready)" \
  env BK="$BK" BF="$BF" BK_UNP=0 BK_UNPP=0 BK_RMW=0 BK_RMN="" BK_GREADY=1 bash -c '
  source "$BK/env.sh"; wd_fuel_want
  grep -q "本轨 ready 0 · 跨轨 ready 1 · 跨轨可自写产品 0" "$BK/delivered"'

t "射程标记 对照:三个数都标了射程,句中零裸 ready(⛔ 无标记的旧写法)" \
  env BK="$BK" BF="$BF" BK_UNP=0 BK_UNPP=0 BK_RMW=0 BK_RMN="" BK_GREADY=1 bash -c '
  source "$BK/env.sh"; wd_fuel_want
  ! grep -qE "\(ready [0-9]" "$BK/delivered"'

rm -rf "$BK"

echo "== 并发闸:运行器自取互斥锁 =="
LK="$(mktemp -d)"; LKF="$LK/fn.sh"; LKSELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
for fn in tests_lock_acquire tests_lock_release; do
  sed -n "/^${fn}()/,/^}/p" "$LKSELF" >> "$LKF"
done

t "并发闸:首取成功,锁里写下自己的存活 pid 与起时" env LKF="$LKF" LK="$LK" bash -c '
  source "$LKF"; L="$LK/a"
  tests_lock_acquire "$L" || exit 1
  [ -d "$L" ] && [ "$(cat "$L/pid")" = "$$" ] && kill -0 "$(cat "$L/pid")" 2>/dev/null && [ -s "$L/started" ]'

tfail "并发闸:持有者活着 ⇒ 第二实例被拒,并报是谁从几点在跑" "另一实例 pid" env LKF="$LKF" LK="$LK" bash -c '
  source "$LKF"; L="$LK/b"; ready="$LK/holder-ready"
  env LKF="$LKF" L="$L" READY="$ready" bash -c "source \"\$LKF\"; tests_lock_acquire \"\$L\" || exit 1; printf \"%s\\n\" \"\$\$\" > \"\$READY\"; /bin/sleep 1" & holder=$!
  while [ ! -s "$ready" ]; do /bin/sleep 0.01; done
  tests_lock_acquire "$L"; rc=$?; printf "%s\n" "$TESTS_LOCK_MSG"
  wait "$holder"; exit $rc'

t "并发闸:锁目录无 pid ⇒ 自动取到,不留永久占用" env LKF="$LKF" LK="$LK" bash -c '
  source "$LKF"; L="$LK/c"; mkdir -p "$L"
  tests_lock_acquire "$L" || exit 1
  [ "$(cat "$L/pid")" = "$$" ] && kill -0 "$(cat "$L/pid")" 2>/dev/null'

t "并发闸:陈旧 pid(持有者已不在)直接重取到" env LKF="$LKF" LK="$LK" bash -c '
  source "$LKF"; L="$LK/d"; mkdir -p "$L"
  ( exit 0 ) & dead=$!; wait "$dead" 2>/dev/null
  printf "%s\n" "$dead" > "$L/pid"; printf "09:00:00\n" > "$L/started"
  tests_lock_acquire "$L" || exit 1
  [ "$(cat "$L/pid")" = "$$" ] && kill -0 "$(cat "$L/pid")" 2>/dev/null'

t "并发闸:release 只放自己那把,新实例随即能取到" env LKF="$LKF" LK="$LK" bash -c '
  source "$LKF"; L="$LK/e"; tests_lock_acquire "$L" || exit 1
  tests_lock_release "$L"
  env LKF="$LKF" L="$L" bash -c "source \"\$LKF\"; tests_lock_acquire \"\$L\" || exit 1; [ \"\$(cat \"\$L/pid\")\" = \"\$\$\" ] && kill -0 \"\$(cat \"\$L/pid\")\" 2>/dev/null"
'

t "并发闸:release 传别的锁不会放掉自己的锁" env LKF="$LKF" LK="$LK" bash -c '
  source "$LKF"; L="$LK/e-own"; other="$LK/e-other"; tests_lock_acquire "$L" || exit 1
  mkdir -p "$other"; printf "1\n" > "$other/pid"; tests_lock_release "$other"
  env LKF="$LKF" L="$L" bash -c "source \"\$LKF\"; tests_lock_acquire \"\$L\""; rc=$?
  tests_lock_release "$L"; [ "$rc" -ne 0 ]'

t "并发闸:陈旧 pid 下两实例并发,只容一人持锁" env LKF="$LKF" LK="$LK" bash -c '
  source "$LKF"; L="$LK/f"; mkdir -p "$L"
  ( exit 0 ) & dead=$!; wait "$dead" 2>/dev/null; printf "%s\n" "$dead" > "$L/pid"
  racer(){
    env LKF="$LKF" L="$L" bash -c "source \"\$LKF\"; tests_lock_acquire \"\$L\"; rc=\$?; if [ \"\$rc\" -eq 0 ]; then printf \"owner=%s\\n\" \"\$\$\"; /bin/sleep 0.2; fi; exit \"\$rc\""
  }
  racer > "$LK/racer-a" 2>&1 & a_job=$!; racer > "$LK/racer-b" 2>&1 & b_job=$!
  wait "$a_job"; a_rc=$?; wait "$b_job"; b_rc=$?
  [ "$a_rc" -eq 0 ] || [ "$b_rc" -eq 0 ] || exit 1
  [ "$a_rc" -ne 0 ] || [ "$b_rc" -ne 0 ] || exit 1
  owner="$(sed -n "s/^owner=//p" "$LK/racer-a" "$LK/racer-b")"
  [ -n "$owner" ] && [ "$(cat "$L/pid")" = "$owner" ]'

t "并发闸 对照:无 pid 看似空闲时,本闸实际取到并写下自己" env LKF="$LKF" LK="$LK" bash -c '
  source "$LKF"
  naive(){ [ -d "$1" ] || return 0; [ -n "$(cat "$1/pid" 2>/dev/null)" ] || return 0; return 1; }
  L="$LK/g"; mkdir -p "$L"
  naive "$L" || exit 1
  tests_lock_acquire "$L" && [ "$(cat "$L/pid")" = "$$" ]'

t "并发闸 真跑:本次自测此刻确实握着真锁(pid=自己)" env TL="$TESTS_LOCK" SELFPID="$$" bash -c '
  [ -d "$TL" ] && [ "$(cat "$TL/pid" 2>/dev/null)" = "$SELFPID" ]'

rm -rf "$LK"


# ── accept-preflight ④ 绊线行实做 + ② 全量行归态(2026-08-29 兑现窗B;替代表 M1 ② 与 ⑤(b))──
#   在此之前:绊线行只做「签名解析」⇒ 永远输出未判,而卷首 :11 早写着「拆修法复跑」;
#   全量行在 judge=rc 下把 **rc≠0 一律写成「不成立」** ⇒「代码真红」与「解释器基线不符」同形。
#   ⚠️ 用**微型合成仓**(两个文件、两个 commit),全量真跑但只有 1–2 个用例,秒级完事。
#   🔴 夹具**落临时脚本再调** ⛔ `source <(…)`(bash 3.2 下函数不落地且不报错,第六发坑)。
echo "== 8b. accept-preflight:绊线拆修法复跑 + 全量行归态 =="
APFX="$(mktemp -d)"
cat > "$APFX/mkfix.sh" <<'MKFIX'
#!/bin/bash
# mkfix.sh <目标目录> <基线前缀,如 "Python 3.14."> [恒真|坏签名]
set -e
d="$1"; base="$2"; mode="${3:-}"
mkdir -p "$d/tests" "$d/11b"
printf 'def add(a, b):\n    return abs(a) + abs(b)\n' > "$d/lib.py"
printf 'import unittest\nfrom lib import add\nclass T(unittest.TestCase):\n    def test_add_basic(self):\n        self.assertEqual(add(1, 2), 3)\n' > "$d/tests/test_lib.py"
if [ "$mode" = 无关红 ]; then
  # 它在**基线 commit 里就存在**(⛔ 本片新增),且在基点上真红、候选上转绿
  # ⇒ 红条集合里混进一个不属于本片新增 def 集合的名字。
  printf '\n    def test_pre_existing_red_not_added_by_this_slice(self):\n        self.assertEqual(add(-7, -8), -15)\n' >> "$d/tests/test_lib.py"
fi
printf 'cmd=PY="$(command -v python3)"; V="$("$PY" --version 2>&1)"; echo "ENTRY_VERSION=$V"; case "$V" in "%s"*) echo "ENTRY_GUARD=ok" ;; *) echo "ENTRY_GUARD=interpreter_baseline_mismatch got=$V"; exit 91 ;; esac; "$PY" -m unittest discover -s tests -v\njudge=rc\n' "$base" > "$d/11b/test-entry.conf"
git -C "$d" init -q -b main .
git -C "$d" add -A; git -C "$d" -c user.name=f -c user.email=f@x commit -qm base
git -C "$d" checkout -qb fix
printf 'def add(a, b):\n    return a + b\n' > "$d/lib.py"
[ "$mode" = ERROR红 ] && printf 'def added_helper():\n    return 7\n' >> "$d/lib.py"
if [ "$mode" = 多绊线 ]; then
  # 本片**新增两条**绊线,两条在基点都以断言失败红、在候选都绿 ⇒ 旧规则 nfail>1 会误判未判
  printf '\n    def test_add_negative_regression(self):\n        self.assertEqual(add(-1, -2), -3)\n\n    def test_add_mixed_regression(self):\n        self.assertEqual(add(-5, 3), -2)\n' >> "$d/tests/test_lib.py"
elif [ "$mode" = ERROR红 ]; then
  # 新增两条:一条断言红,一条在基点**AttributeError**(候选才有 added_helper)⇒ 非断言红
  printf '\n    def test_add_negative_regression(self):\n        self.assertEqual(add(-1, -2), -3)\n\n    def test_needs_added_helper(self):\n        import lib\n        self.assertEqual(lib.added_helper(), 7)\n' >> "$d/tests/test_lib.py"
elif [ "$mode" = 恒真模块名 ]; then
  # 点名的那条**恒真**(没守住缺陷),而**同模块另一条**在基点上真红。
  # ⇒ 拿模块名当签名会 grep 到后者的 FAIL 而误判「成立」;拿真函数名则正确判「不成立」。
  printf '\n    def test_add_negative_regression(self):\n        self.assertTrue(True)\n\n    def test_other_in_same_module_fails_on_base(self):\n        self.assertEqual(add(-5, -6), -11)\n' >> "$d/tests/test_lib.py"
elif [ "$mode" = 恒真 ]; then
  printf '\n    def test_add_negative_regression(self):\n        self.assertTrue(True)\n' >> "$d/tests/test_lib.py"
else
  printf '\n    def test_add_negative_regression(self):\n        self.assertEqual(add(-1, -2), -3)\n' >> "$d/tests/test_lib.py"
fi
git -C "$d" add -A; git -C "$d" -c user.name=f -c user.email=f@x commit -qm fix
git -C "$d" checkout -q main
case "$mode" in
  坏签名)
    printf '回归断言点名:test_this_id_is_not_in_this_branch\n' > "$d/prompt.md" ;;
  恒真模块名)
    printf '回归断言点名:`tests.test_lib.T.test_add_negative_regression`\n' > "$d/prompt.md" ;;
  模块名)
    # 真报告的形态:`模块.类.方法` 点分 unittest id —— **模块段排在方法段前面**。
    # 老代码在同一 token 内先扫到 test_lib,又因 diff 头有 `+++ b/tests/test_lib.py`
    # 被 grep -qF 放行 ⇒ 模块名夺魁。这一档就是那个缺陷的密封复现。
    printf '回归断言点名:`tests.test_lib.T.test_add_negative_regression`(见 tests/test_lib.py)\n' > "$d/prompt.md" ;;
  只模块名)
    printf '改动落在 tests/test_lib.py;回归覆盖见该模块 tests.test_lib\n' > "$d/prompt.md" ;;
  *)
    printf '回归断言点名:test_add_negative_regression\n' > "$d/prompt.md" ;;
esac
MKFIX
chmod +x "$APFX/mkfix.sh"
APFBASE="Python $(python3 --version 2>&1 | sed -E 's/Python ([0-9]+\.[0-9]+)\..*/\1./')"

t "APF 绊线 阳性:真缺陷片 ⇒ **成立**(基点+tests 恰一条断言失败红 · 候选绿)" bash -c '
  set -e; d="$2/pos"; "$2/mkfix.sh" "$d" "$3"
  out="$("$1" 片 "$(git -C "$d" rev-parse --short fix)" "$d/prompt.md" --repo "$d" --evidence-dir "$d/ev" 2>&1)"
  grep -qE "^绊线: 成立" <<< "$out" || { grep "^绊线" <<< "$out"; exit 1; }
  grep -qF "恰这一条以断言失败变红" <<< "$out"' _ "$APF" "$APFX" "$APFBASE"

t "APF 绊线 阴性①:断言改恒真(不拆也绿)⇒ **不成立** ⛔ 任意变红都算成立" bash -c '
  set -e; d="$2/neg1"; "$2/mkfix.sh" "$d" "$3" 恒真
  out="$("$1" 片 "$(git -C "$d" rev-parse --short fix)" "$d/prompt.md" --repo "$d" --evidence-dir "$d/ev" 2>&1)"
  grep -qE "^绊线: 不成立" <<< "$out" || { grep "^绊线" <<< "$out"; exit 1; }
  grep -qF "不拆也绿" <<< "$out"' _ "$APF" "$APFX" "$APFBASE"

t "APF 绊线 阴性②:签名点名本分支没动过的 id ⇒ **未判** ⛔ 绿" bash -c '
  set -e; d="$2/neg2"; "$2/mkfix.sh" "$d" "$3" 坏签名
  out="$("$1" 片 "$(git -C "$d" rev-parse --short fix)" "$d/prompt.md" --repo "$d" --evidence-dir "$d/ev" 2>&1)"
  grep -qE "^绊线: 未判" <<< "$out" || { grep "^绊线" <<< "$out"; exit 1; }
  grep -qF "无真实函数签名" <<< "$out"
  grep -qF "patch 内无 def" <<< "$out"' _ "$APF" "$APFX" "$APFBASE"

t "APF 全量 阴性③:解释器基线不符(rc=91)⇒ **未判**且行内带 ENTRY_GUARD ⛔ 写不成立" bash -c '
  set -e; d="$2/neg3"; "$2/mkfix.sh" "$d" "Python 9.99."
  out="$("$1" 片 "$(git -C "$d" rev-parse --short fix)" "$d/prompt.md" --repo "$d" --evidence-dir "$d/ev" 2>&1)"
  grep -qE "^全量: 未判" <<< "$out" || { grep "^全量" <<< "$out"; exit 1; }
  grep -E "^全量" <<< "$out" | grep -qF "ENTRY_GUARD=interpreter_baseline_mismatch"' _ "$APF" "$APFX"

t "APF 全量:「不成立」只留给 failed>0 的真红(计数可解析时)" bash -c '
  set -e; d="$2/neg4"; "$2/mkfix.sh" "$d" "$3"
  # 把入口换成会输出「结果:N 过 / M 败」且 M>0 的形态 ⇒ 唯一该判「不成立」的那一类
  printf "cmd=echo \"结果:3 过 / 2 败\"; exit 1\njudge=count\n" > "$d/11b/test-entry.conf"
  out="$("$1" 片 "$(git -C "$d" rev-parse --short fix)" "$d/prompt.md" --repo "$d" --evidence-dir "$d/ev2" 2>&1)"
  grep -qE "^全量: 不成立" <<< "$out" || { grep "^全量" <<< "$out"; exit 1; }
  grep -E "^全量" <<< "$out" | grep -qF "真红"' _ "$APF" "$APFX" "$APFBASE"

t "APF 全量:passed=0 failed=0(一个测试都没跑)⇒ **未判** ⛔ 当绿" bash -c '
  set -e; d="$2/neg5"; "$2/mkfix.sh" "$d" "$3"
  printf "cmd=echo \"结果:0 过 / 0 败\"; exit 0\njudge=count\n" > "$d/11b/test-entry.conf"
  out="$("$1" 片 "$(git -C "$d" rev-parse --short fix)" "$d/prompt.md" --repo "$d" --evidence-dir "$d/ev3" 2>&1)"
  grep -qE "^全量: 未判" <<< "$out" || { grep "^全量" <<< "$out"; exit 1; }
  grep -qF "一个测试都没跑" <<< "$out"' _ "$APF" "$APFX" "$APFBASE"

# ── 5.1b:绊线签名选取(2026-08-29 兑现窗B;值守 M1 第四组实撞 19e2abfe)────────────
#   病灶:报告里的签名是 `模块.类.方法` 点分 id,老代码在同一 token 内**先扫到模块段**,
#   又被 `grep -qF` 在 diff 头 `+++ b/tests/<模块>.py` 上放行 ⇒ **模块名夺魁压过真函数**,
#   拆修法复跑被无关红搅浑 ⇒ 未判。下面 6 条把「选对了」与「选错了」分开。
echo "== 8c. accept-preflight:绊线签名选取(①真 def ②排模块名 ③给理由 ④空则未判 ⑤报告来源)=="

t "APF 签名 阳性:同时提模块名与真函数名 ⇒ **选中函数名**并给理由(⛔ 模块名夺魁)" bash -c '
  set -e; d="$2/sig1"; "$2/mkfix.sh" "$d" "$3" 模块名
  out="$("$1" 片 "$(git -C "$d" rev-parse --short fix)" "$d/prompt.md" --repo "$d" --evidence-dir "$d/ev" 2>&1)"
  grep -qF "签名=test_add_negative_regression" <<< "$out" || { grep "^绊线" <<< "$out"; exit 1; }
  grep -qF "新增**的 def" <<< "$out" || { echo "未写选它的理由"; exit 2; }
  grep -qF "test_lib(**模块/包段**" <<< "$out" || { echo "未写模块名为何落选"; exit 3; }' _ "$APF" "$APFX" "$APFBASE"

t "APF 签名 假阳对照:模块名当签名会 grep 到**同模块另一条**的 FAIL ⇒ 误判「成立」;真函数名 ⇒ 正确判「不成立」" bash -c '
  # 这条钉的是本缺陷**最坏的那一面**:它不止把判据搅成未判,还能**放行**一个没守住缺陷的片。
  # 点名的 test_add_negative_regression 是恒真的(不拆也绿 ⇒ 应判不成立);
  # 同模块的 test_other_in_same_module_fails_on_base 在基点真红 ⇒ 模块名签名会捡到它的 FAIL。
  set -e; d="$2/sig2"; "$2/mkfix.sh" "$d" "$3" 恒真模块名
  out="$("$1" 片 "$(git -C "$d" rev-parse --short fix)" "$d/prompt.md" --repo "$d" --evidence-dir "$d/ev" 2>&1)"
  grep -qF "签名=test_add_negative_regression" <<< "$out" || { grep "^绊线" <<< "$out"; exit 1; }
  grep -qE "^绊线: 不成立" <<< "$out" || { grep "^绊线" <<< "$out"; exit 2; }
  grep -qF "不拆也绿" <<< "$out"' _ "$APF" "$APFX" "$APFBASE"

t "APF 签名 阴性:只提模块名 ⇒ **未判**并写明「无真实函数签名」⛔ 拿模块名当签名" bash -c '
  set -e; d="$2/sig4"; "$2/mkfix.sh" "$d" "$3" 只模块名
  out="$("$1" 片 "$(git -C "$d" rev-parse --short fix)" "$d/prompt.md" --repo "$d" --evidence-dir "$d/ev" 2>&1)"
  grep -qE "^绊线: 未判" <<< "$out" || { grep "^绊线" <<< "$out"; exit 1; }
  grep -qF "无真实函数签名" <<< "$out"
  grep -qF "test_lib(**模块/包段**" <<< "$out" || { echo "未逐条写落选理由"; exit 2; }' _ "$APF" "$APFX" "$APFBASE"

t "APF ⑤(a) 省 --report ⇒ 按片名**推导**报告路径并写明来源 ⛔ 静默少读一半" bash -c '
  set -e; d="$2/sig5"; "$2/mkfix.sh" "$d" "$3" 只模块名; mkdir -p "$d/rec"
  # 推导目标存在,且只有它带真函数名 ⇒ 读到了才可能选中
  # ⛔ 反引号:本行在 bash -c 单引号里,双引号中的反引号会被当命令替换真跑一次
  printf "回归断言点名:tests.test_lib.T.test_add_negative_regression\n" > "$d/rec/片-交付报告.md"
  out="$(LAIXIN_RECORDS_DIR="$d/rec" "$1" 片 "$(git -C "$d" rev-parse --short fix)" "$d/prompt.md" --repo "$d" --evidence-dir "$d/ev" 2>&1)"
  grep -qF "按片名推导" <<< "$out" || { echo "未写明来源是推导"; exit 2; }
  grep -qF "签名=test_add_negative_regression" <<< "$out" || { grep "^绊线" <<< "$out"; exit 3; }' _ "$APF" "$APFX" "$APFBASE"

t "APF ⑤(b) 省 --report 且推导路径不存在 ⇒ 写明**不存在**、只来自 prompt ⛔ 装作读过" bash -c '
  set -e; d="$2/sig6"; "$2/mkfix.sh" "$d" "$3" 只模块名
  out="$(LAIXIN_RECORDS_DIR="$d/nowhere" "$1" 片 "$(git -C "$d" rev-parse --short fix)" "$d/prompt.md" --repo "$d" --evidence-dir "$d/ev" 2>&1)"
  grep -qF "**不存在**" <<< "$out" || { echo "未写明推导路径不存在"; exit 2; }
  grep -qF "只来自 prompt" <<< "$out" || { echo "未写明本单签名只来自 prompt"; exit 3; }' _ "$APF" "$APFX" "$APFBASE"

# ── 5.1b 收窄:多绊线(2026-08-29 调度批准并入;替代表 ②「**别的**测试红」的射程更正)────
#   本片自己新增的 def ⛔「别的测试」。旧规则下「一片立两条绊线」必然撞 nfail>1 判未判(实撞 19e2abfe)。
echo "== 8d. accept-preflight:多绊线收窄(红条集合 ⊆ 本片新增 def ⇒ 成立) =="

t "APF 多绊线 阳性:两条红**全是本片新增的 def**、全断言红、候选全绿 ⇒ **成立**并逐条列名" bash -c '
  set -e; d="$2/mt1"; "$2/mkfix.sh" "$d" "$3" 多绊线
  out="$("$1" 片 "$(git -C "$d" rev-parse --short fix)" "$d/prompt.md" --repo "$d" --evidence-dir "$d/ev" 2>&1)"
  grep -qE "^绊线: 成立" <<< "$out" || { grep "^绊线" <<< "$out"; exit 1; }
  grep -qF "**多绊线**" <<< "$out" || { echo "未走多绊线分支"; exit 2; }
  grep -qF "test_add_negative_regression" <<< "$out" && grep -qF "test_add_mixed_regression" <<< "$out" || { echo "未逐条列名"; exit 3; }' _ "$APF" "$APFX" "$APFBASE"

t "APF 多绊线 阴性①:红条里混进**本片没新增**的测试 ⇒ **未判「归因不唯一(无关红:名)」**⛔ 算成立" bash -c '
  # test_pre_existing_red_not_added_by_this_slice 在**基线 commit 里就有**,基点红候选绿;
  # 它不在本片新增 def 集合里 ⇒ 归因不唯一。⛔ 因为「反正都是红、反正候选都绿」就放行。
  set -e; d="$2/mt2"; "$2/mkfix.sh" "$d" "$3" 无关红
  out="$("$1" 片 "$(git -C "$d" rev-parse --short fix)" "$d/prompt.md" --repo "$d" --evidence-dir "$d/ev" 2>&1)"
  grep -qE "^绊线: 未判" <<< "$out" || { grep "^绊线" <<< "$out"; exit 1; }
  grep -qF "无关红:test_pre_existing_red_not_added_by_this_slice" <<< "$out" || { echo "未点名无关红"; exit 2; }' _ "$APF" "$APFX" "$APFBASE"

t "APF 多绊线 阴性②:红条里有**非断言红**(基点 AttributeError)⇒ **未判**并写明是 ERROR ⛔ 算绊线守住" bash -c '
  # 本档由更早那条 `nerr>0` 分支接住(⑥ 其余照旧,⛔ 改它);新分支里的同名判据是兜底。
  # 判据钉的是**可观察行为**:非断言红一律未判,且事实单上写明它是 ERROR ⛔ 说成断言失败。
  set -e; d="$2/mt3"; "$2/mkfix.sh" "$d" "$3" ERROR红
  out="$("$1" 片 "$(git -C "$d" rev-parse --short fix)" "$d/prompt.md" --repo "$d" --evidence-dir "$d/ev" 2>&1)"
  grep -qE "^绊线: 未判" <<< "$out" || { grep "^绊线" <<< "$out"; exit 1; }
  grep -E "^绊线" <<< "$out" | grep -qF "ERROR" || { echo "未写明红的是 ERROR"; exit 2; }
  grep -E "^绊线" <<< "$out" | grep -qF "⛔ 断言失败" || { echo "未写明它 ⛔ 断言失败"; exit 3; }' _ "$APF" "$APFX" "$APFBASE"

rm -rf "$APFX"

# ── 5.2 M-d 派工交接包 lint(2026-08-29 兑现窗B;方案-席位健康与自愈 §三 M-d)────────────
#   料写在交接包里而没登排队节 ⇒ stats **忠实地**报 ready=0:读数没错,是排队行不存在,
#   而这两者在读数面**完全同形**(08-29 实撞:三片前置已解、两轨空 52 分钟而 ready=0)。
echo "== 8e. handover-lint:派工交接包未登排队节(只报 ⛔ 拒) =="
HVX="$(mktemp -d)"; HVL="$(cd "$(dirname "$0")/.." && pwd)/bin/handover-lint"
mkdir -p "$HVX/4-开发层"
cat > "$HVX/table.md" <<'HVTBL'
## 进行中(路线图子表在这一节,⛔ 当已登队)

| 序 | 片 | 状态 | 依赖 |
|---|---|---|---|
| 1 | 测试:只在路线图的片-丁 | 前置已解,可写 | 无 |

## 排队(测试用)

### 子标题(真表排队节里有 5 个,⛔ 被当成换节)

| 片 | 轨 | 内容 | 发车状态 |
|---|---|---|---|
| **测试:已登队片-甲** | **B 轨** | x | prompt 已写,待发 |
| **测试:无轨片-乙** |  | x | ready |
| **测试:撞前缀片-丙一二三四五六七八** | **A 轨** | x | 待写 |
| **测试:撞前缀片-丙一二三四五六七九** | **A 轨** | x | 待写 |
HVTBL

t "M-d 阳性:交接包列 2 片、排队节无行 ⇒ 报 2 且逐条列名与交接包行号" bash -c '
  set -e; d="$2"; f="$d/4-开发层/交接包-派工-测试.md"
  printf "# 派工交接包\n\n- **测试:没登队的片-戊** ready 待发\n- **测试:也没登队的片-己** 待写\n" > "$f"
  out="$("$1" --table "$d/table.md" "$f" 2>&1)"
  grep -qF "有料 2 片**未登排队节**" <<< "$out" || { echo "$out"; exit 1; }
  grep -qF "测试:没登队的片-戊" <<< "$out" && grep -qF "测试:也没登队的片-己" <<< "$out" || exit 2
  grep -qE "第 3 行" <<< "$out" || { echo "未给交接包行号"; exit 3; }' _ "$HVL" "$HVX"

t "M-d 阴性①:片**已登排队节且带轨** ⇒ 不报(⛔ 把登过队的也报,噪声会淹掉真提示)" bash -c '
  set -e; d="$2"; f="$d/4-开发层/交接包-派工-测试2.md"
  printf "# 派工交接包\n\n- **测试:已登队片-甲** ready 待发\n" > "$f"
  out="$("$1" --table "$d/table.md" "$f" 2>&1)"
  [ -z "$out" ] || { echo "本该零输出,实得:$out"; exit 1; }' _ "$HVL" "$HVX"

t "M-d 阴性②:交接包只有**空态句**(零待验/无待发片/未ready)⇒ 真·零输出" bash -c '
  # 真库实测这类写法 10+ 处(「零在飞·零待验」「无待发片」「通道未ready」)。不挡掉它们,
  # **每一份交接包都稳定产出一段噪声**,而噪声的代价正是把真提示淹掉。
  set -e; d="$2"; f="$d/4-开发层/交接包-派工-测试3.md"
  printf "# 派工交接包\n\n本窗在手件 0,现场已清,无待发片;零待验、未ready 的也没有。\n" > "$f"
  out="$("$1" --table "$d/table.md" "$f" 2>&1)"
  [ -z "$out" ] || { echo "本该零输出,实得:$out"; exit 1; }' _ "$HVL" "$HVX"

t "M-d 阴性②-bis:**未被否定**的状态词且抽不到片名 ⇒ 仍报(⛔ 否定判据抑制过头)" bash -c '
  # 与上一条成对:否定判据只许挡**紧邻**的空态句,⛔ 把正常的「说了 ready 却没写片名」也吃掉——
  # 被吃掉的行是静默消失的,那正是本件要根治的形态。
  set -e; d="$2"; f="$d/4-开发层/交接包-派工-测试3b.md"
  printf "# 派工交接包\n\n- 这一行说了 ready 但没写任何片名。\n" > "$f"
  out="$("$1" --table "$d/table.md" "$f" 2>&1)"
  grep -qF "抽不到片名" <<< "$out" || { echo "本该报抽不到片名,实得:$out"; exit 1; }' _ "$HVL" "$HVX"

t "M-d 阴性③:片名**撞前缀** ⇒ **未判并列候选** ⛔ 当已登队、⛔ 当未登队" bash -c '
  set -e; d="$2"; f="$d/4-开发层/交接包-派工-测试4.md"
  printf "# 派工交接包\n\n- **测试:撞前缀片-丙一二三四五六** ready 待发\n" > "$f"
  out="$("$1" --table "$d/table.md" "$f" 2>&1)"
  grep -qF "**未判**" <<< "$out" || { echo "$out"; exit 1; }
  grep -qF "排队节候选:" <<< "$out" || { echo "未列候选"; exit 2; }
  grep -qF "未登排队节" <<< "$out" && { echo "撞前缀被当成未登队"; exit 3; }
  exit 0' _ "$HVL" "$HVX"

t "M-d 阴性④:提交路径**不含派工交接包** ⇒ 零动作零输出(⛔ 对每次提交都说话)" bash -c '
  set -e; d="$2"
  printf "x\n" > "$d/4-开发层/交接包-兑现窗B-测试.md"     # 交接包但**不是派工线**
  printf "y\n" > "$d/4-开发层/随便一个文件.md"
  out="$("$1" --table "$d/table.md" "$d/4-开发层/交接包-兑现窗B-测试.md" "$d/4-开发层/随便一个文件.md" 2>&1)"
  [ -z "$out" ] || { echo "本该零输出,实得:$out"; exit 1; }' _ "$HVL" "$HVX"

t "M-d 阴性⑤:排队节**有行但轨列空** ⇒ 仍报(⛔ 只看有没有行:无轨的行量不出轨深度)" bash -c '
  set -e; d="$2"; f="$d/4-开发层/交接包-派工-测试5.md"
  printf "# 派工交接包\n\n- **测试:无轨片-乙** ready 待发\n" > "$f"
  out="$("$1" --table "$d/table.md" "$f" 2>&1)"
  grep -qF "轨列为空" <<< "$out" || { echo "$out"; exit 1; }' _ "$HVL" "$HVX"

t "M-d 绊线:排队节内的 ### 子标题 ⛔ 被当成换节(⛔ 「本节空」与「我没读到」同形)" bash -c '
  # 首版实撞:按 startswith("##") 判换节 ⇒ 真表 93 行读成 0 行,而 0 行看起来完全正常。
  set -e; d="$2"; f="$d/4-开发层/交接包-派工-测试6.md"
  printf "# 派工交接包\n\n- **测试:已登队片-甲** ready 待发\n" > "$f"
  # 甲在 ### 子标题**之后**;若子标题被当换节,甲就读不到 ⇒ 会被误报未登队
  out="$("$1" --table "$d/table.md" "$f" 2>&1)"
  grep -qF "未登排队节" <<< "$out" && { echo "### 子标题把排队节截断了"; exit 1; }
  exit 0' _ "$HVL" "$HVX"

t "M-d 判据漂移绊线:状态词与 stats 分桶器两处必须一致(⛔ 各自漂移后同形)" bash -c '
  # 两处各写一份的代价:漂移后「两处口径一致」与「两处口径已经不同」在读数面同形。
  set -e; lane="$2"; hl="$1"
  for lit in "'"'"'ready'"'"' in st.lower()" "'"'"'prompt 已写'"'"' in st" "'"'"'待写'"'"' in st"; do
    grep -qF "$lit" "$lane" || { echo "分桶器里找不到判据:$lit ⇒ 它改了,handover-lint 要跟着改"; exit 1; }
  done
  grep -qF "prompt 已写" "$hl" && grep -qF "待写" "$hl" || { echo "handover-lint 少了状态词"; exit 2; }
  exit 0' _ "$HVL" "$LANE"

t "M-d 挂钩:kb-commit 里真接上了 handover-lint(⛔ 只看脚本自己能跑)" bash -c '
  set -e
  sed -n "/^cmd_kb_commit/,/^}/p" "$1" | grep -qF "handover-lint" || { echo "kb-commit 未接线"; exit 1; }
  sed -n "/^cmd_kb_commit/,/^}/p" "$1" | grep -qF "readlink -f" || { echo "未解软链:发布版下找不到兄弟文件"; exit 2; }' _ "$LANE"

rm -rf "$HVX"

# ══ 2.4-① 席位健康:**看得见**(M-a 判态 · M-c 的 doctor/statusline 两个落点 · M-e ③)═══════
# 📌 本片按 pingxia-47 2026-08-29 排期切为可发布两片,边界=**风险**⛔ 工作量:
#   片①(本片)对外界**零动作** —— 只判态、落态文件、在 doctor 与所有窗的状态栏显出来;判错了
#     最多是屏幕上一行字。片②「说出来 + 自愈」才开始 board/桌面通知/代跑 handover。
#   ⇒ 片①先合先发,片②随后各自全量绿、各自看板条(47 明令:⛔ 为了切片缩阴性)。
# 失败样本=2026-08-29 12:40→13:29 开发轨空转 2h25m:派工席过硬口、继任未起,而**没有任何一环
#   负责发现**。判据必须能区分成败 ⇒ 四个态各一条阳性 + 每条改判各一条阴性。
echo "== 2.4a-seat. M-a 席位态判定(纯函数,喂三路串;⛔ 碰真锁/真窗)=="
T24="$(mktemp -d)"
sed -n "/^seat_state_judge()/,/^}/p" "$LANE" > "$T24/judge.sh"
# 判定与取数分离 ⇒ judge 单独可跑;⛔ 依赖顶层变量(套件 set -u,顶层变量不随函数抽取走)
jd(){ bash -c 'source "$1/judge.sh"; seat_state_judge "$2" "$3" "$4"' _ "$T24" "$2" "$3" "$4"; }
A_OK="ctx=30.0 hb=5 n=1 sid=s1 why="
A_HI="ctx=83.7 hb=5 n=1 sid=s1 why="
B_OK="holder=dispatch lockage=20 drain=— ndisp=1"
C_OK="nsess=1"

t "M-a 在班:持有者在 · ctx 低 · 无排空窗" bash -c '
  source "$1/judge.sh"; grep -q "^state=在班|" <<< "$(seat_state_judge "$2" "$3" "$4")"' _ "$T24" "$A_OK" "$B_OK" "$C_OK"

t "M-a 排空无继任:ctx≥硬口 且 无 dispatch-drain-*(=08-29 12:40 实撞形态)" bash -c '
  source "$1/judge.sh"; o="$(seat_state_judge "$2" "$3" "$4")"
  grep -q "^state=排空无继任|" <<< "$o" && grep -q "继任未起" <<< "$o"' _ "$T24" "$A_HI" "$B_OK" "$C_OK"

t "M-a 阴性:ctx≥硬口 但**继任已起**(有 drain 窗)⇒ 在班 ⛔ 排空无继任" bash -c '
  source "$1/judge.sh"; grep -q "^state=在班|" <<< "$(seat_state_judge "$2" "holder=dispatch lockage=20 drain=dispatch-drain-20260829-165337 ndisp=1" "$3")"' _ "$T24" "$A_HI" "$C_OK"

t "M-a 缺:派工权无持有者" bash -c '
  source "$1/judge.sh"; grep -q "^state=缺|" <<< "$(seat_state_judge "$2" "holder=— lockage=999999 drain=— ndisp=0" "$3")"' _ "$T24" "$A_OK" "$C_OK"

t "M-a 缺:持有者在但锁心跳已过期(残锁 ⛔ 当在班)" bash -c '
  source "$1/judge.sh"; o="$(seat_state_judge "$2" "holder=someone lockage=99999 drain=— ndisp=1" "$3")"
  grep -q "^state=缺|" <<< "$o" && grep -q "心跳已过期" <<< "$o"' _ "$T24" "$A_OK" "$C_OK"

t "M-a 未判:A 路读不出 ⇒ 未判 ⛔ 归在班 ⛔ 归缺(方案 §三 逐字)" bash -c '
  source "$1/judge.sh"; o="$(seat_state_judge "ctx=? hb=? n=0 sid=— why=A路读不出:无 agentName=dispatch 的 transcript" "$2" "$3")"
  grep -q "^state=未判|" <<< "$o" && grep -q "A路读不出" <<< "$o"' _ "$T24" "$B_OK" "$C_OK"

# ── 🔴 「心跳<60s」改判的两侧(方案 v1.2;pingxia-47 2026-08-29 采纳,两侧各钉一条)────────
#   实测三条促成改判:① sessions/*.json 的 updatedAt **不是心跳**,比 transcript 还陈旧
#   (dispatch 185s vs 32s;pingxia-cc 22 小时 vs 34 分钟);② transcript mtime 测的是「最后一次
#   对话」⛔「还活着」——**活着且健康的 relay 席实测已 789s 没动**;③ 照 60s 落地会把「安静等事件」
#   判成非在班,而那是 #137 已裁的健康态,且 M-c 要在**所有窗**显红 ⇒ 噪声随正常运行增长。
t "M-a 改判阴性①:席位安静 789s(远超原 60s)但窗还在 ⇒ **仍在班**(⛔ 把健康的安静判成故障)" bash -c '
  source "$1/judge.sh"; grep -q "^state=在班|" <<< "$(seat_state_judge "ctx=30.0 hb=789 n=1 sid=s1 why=" "$2" "$3")"' _ "$T24" "$B_OK" "$C_OK"

t "M-a 改判阳性②:transcript 陈旧≥2700s **且** B 路无 dispatch 窗 ⇒ 未判(读到的是死席旧档)" bash -c '
  source "$1/judge.sh"; o="$(seat_state_judge "ctx=83.7 hb=3000 n=1 sid=s1 why=" "holder=dispatch lockage=20 drain=— ndisp=0" "$2")"
  grep -q "^state=未判|" <<< "$o" && grep -q "死席旧档" <<< "$o"' _ "$T24" "$C_OK"

t "M-a 改判阴性③:transcript 陈旧但**窗还在** ⇒ ⛔ 未判(两条须同时成立;⛔ 单凭陈旧就弃判)" bash -c '
  source "$1/judge.sh"; ! grep -q "^state=未判|" <<< "$(seat_state_judge "ctx=30.0 hb=3000 n=1 sid=s1 why=" "$2" "$3")"' _ "$T24" "$B_OK" "$C_OK"

# ── 三路交叉(:967 根因面:**不是读不到,是读到了假的**)───────────────────────────
t "M-a 不一致:C 路会话面 2 个 dispatch 而 B 路无排空窗 ⇒ mismatch 非空(继任可能在别处)" bash -c '
  source "$1/judge.sh"; o="$(seat_state_judge "ctx=83.7 hb=5 n=2 sid=s1 why=" "$2" "nsess=2")"
  m="${o##*|mismatch=}"; [ -n "$m" ] && grep -q "别的会话面" <<< "$m"' _ "$T24" "$B_OK"

# 🔴 阴性:**交接刚做完**的真形态(2026-08-29 发布后真机实撞,原判据在这里假报了 45 分钟)——
#   A 的 n 数「最近 stale 秒内动过的 transcript」含**已结束会话**那一份,C 数「当刻活会话」,
#   两者量的不是同一种东西 ⇒ ⛔ 拿它们比相等。实撞读数:A=2(919d492c 龄 0s 活 · 285bf9cc 龄 1995s 已结束)
#   而 C=1,同刻 tmux 只有一个 dispatch 窗、确实只有一个派工角色。
#   ⚠️ 错的方向尤其坏:mismatch 会拦住 M-b 自愈 ⇒ 等于每次交接后自愈静默失效 45 分钟。
t "M-a 阴性:交接刚做完(A 面 2 份 transcript · C 面 1 个活会话)⇒ **⛔ 报不一致**" bash -c '
  source "$1/judge.sh"; o="$(seat_state_judge "ctx=30.0 hb=5 n=2 sid=s1 why=" "$2" "nsess=1")"
  m="${o##*|mismatch=}"; [ -z "$m" ]' _ "$T24" "$B_OK"

t "M-a 不一致②:tmux 有 dispatch 窗而会话面 0 个 dispatch 会话 ⇒ 点名空壳窗" bash -c '
  source "$1/judge.sh"; o="$(seat_state_judge "ctx=30.0 hb=5 n=1 sid=s1 why=" "$2" "nsess=0")"
  grep -q "空壳窗" <<< "$o"' _ "$T24" "$B_OK"

t "M-a 阴性:会话面 0 个且 tmux 也没有 dispatch 窗 ⇒ ⛔ 报空壳窗(那是「缺」⛔ 不一致)" bash -c '
  source "$1/judge.sh"; o="$(seat_state_judge "ctx=30.0 hb=5 n=1 sid=s1 why=" "holder=dispatch lockage=20 drain=— ndisp=0" "nsess=0")"
  ! grep -q "空壳窗" <<< "$o"' _ "$T24"

t "M-a 交接期零误报(真机 16:55 样本:n=2 · nsess=2 · drain 在)⇒ 在班且 mismatch 空" bash -c '
  source "$1/judge.sh"
  o="$(seat_state_judge "ctx=9.9 hb=4 n=2 sid=919d492c why=" "holder=dispatch lockage=26 drain=dispatch-drain-20260829-165337 ndisp=1" "nsess=2")"
  grep -q "^state=在班|" <<< "$o" && [ -z "${o##*|mismatch=}" ]' _ "$T24"

t "M-a 对照:朴素判据「只看 ctx≥75 就报」在「ctx 高 + 继任已起」上会误报,本闸不报——绊线分得开成败" bash -c '
  source "$1/judge.sh"
  naive(){ [ "${1%%.*}" -ge 75 ]; }                       # 朴素判据:只看占比
  naive 83.7 || exit 1                                     # 它确实会报
  grep -q "^state=在班|" <<< "$(seat_state_judge "$2" "holder=dispatch lockage=20 drain=dispatch-drain-x ndisp=1" "$3")"' _ "$T24" "$A_HI" "$C_OK"

# ── 三路信源必须读**不同的字节**(结构断言;共用信源=假一致,:967 形态)───────────────
t "M-a 独立性:A 路(transcript)体内 ⛔ 出现 派工权锁 / sessions —— 那是 B/C 的料" bash -c '
  b="$(sed -n "/^seat_read_a()/,/^}/p" "$1" | grep -v "^[[:space:]]*#")"; [ -n "$b" ] || exit 9
  ! grep -qE "DISPATCH_LOCK|lock_holder|lock_age|/sessions/" <<< "$b"' _ "$LANE"
t "M-a 独立性 阳性对照:同一判据喂一段**真的读锁**的代码 ⇒ 必红(证明剥注释没把判据剥成永远绿)" bash -c '
  fake="seat_read_a(){\n  x=\"\$(lock_holder)\"\n}"
  b="$(printf "%b" "$fake" | sed -n "/^seat_read_a()/,/^}/p" | grep -v "^[[:space:]]*#")"
  grep -qE "DISPATCH_LOCK|lock_holder|lock_age|/sessions/" <<< "$b"'
t "M-a 独立性:B 路(锁+tmux)体内 ⛔ 读 transcript" bash -c '
  b="$(sed -n "/^seat_read_b()/,/^}/p" "$1" | grep -v "^[[:space:]]*#")"; [ -n "$b" ] || exit 9
  ! grep -qE "jsonl|projects/" <<< "$b"' _ "$LANE"
t "M-a 独立性:C 路(会话面)体内 ⛔ 碰锁 ⛔ 碰 transcript" bash -c '
  b="$(sed -n "/^seat_read_c()/,/^}/p" "$1" | grep -v "^[[:space:]]*#")"; [ -n "$b" ] || exit 9
  ! grep -qE "DISPATCH_LOCK|lock_holder|lock_age|jsonl" <<< "$b"' _ "$LANE"

# ── A 路真跑(夹具 transcript;证明 agent-name 定位与末尾回读都真的在工作)──────────────
SA="$(mktemp -d)"; mkdir -p "$SA/proj"
mkj(){ # <文件> <agentName|-> <tokens>
  { [ "$2" = "-" ] || printf '{"type":"agent-name","agentName":"%s"}\n' "$2"
    printf '{"type":"user"}\n'
    printf '{"message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$3"
  } > "$1"; }
mkj "$SA/proj/aaa.jsonl" dispatch 500000
mkj "$SA/proj/bbb.jsonl" relay    900000
mkj "$SA/proj/ccc.jsonl" -        900000
t "M-a A路真跑:按 agentName 认出 dispatch 并算出占比(⛔ 认成同目录里 relay/无名的那两份)" bash -c '
  b="$(sed -n "/^seat_read_a()/,/^}/p" "$1")"; eval "$b"
  o="$(LAIXIN_CTX_PROJ="$2/proj" LAIXIN_CTX_WINDOW=1000000 seat_read_a dispatch)"
  grep -q "ctx=50.0 " <<< "$o" && grep -q "sid=aaa" <<< "$o" && grep -q "n=1 " <<< "$o" && grep -q "why=$" <<< "$o"' _ "$LANE" "$SA"
t "M-a A路阴性:目录里没有该席位的 transcript ⇒ why 非空(⛔ 返 ctx=0 让闸门看着「还早」)" bash -c '
  b="$(sed -n "/^seat_read_a()/,/^}/p" "$1")"; eval "$b"
  o="$(LAIXIN_CTX_PROJ="$2/proj" seat_read_a no-such-seat)"
  grep -q "ctx=? " <<< "$o" && grep -q "why=A路读不出" <<< "$o"' _ "$LANE" "$SA"
t "M-a A路阴性:有 agent-name 但**无 usage 记录** ⇒ 仍算读不出 ⛔ 当 0%" bash -c '
  b="$(sed -n "/^seat_read_a()/,/^}/p" "$1")"; eval "$b"
  d="$(mktemp -d)"; printf "{\"type\":\"agent-name\",\"agentName\":\"dispatch\"}\n{\"type\":\"user\"}\n" > "$d/x.jsonl"
  o="$(LAIXIN_CTX_PROJ="$d" seat_read_a dispatch)"; rm -rf "$d"
  grep -q "why=A路读不出:transcript 无 usage 记录" <<< "$o"' _ "$LANE"

# ── A 路的扫描必须**有界**(2026-08-29 自查实撞:全扫 880 份 / 3.1 GB 单次 7 秒,而看门狗每 60s
#   跑一次 ⇒ 开销随 transcript 历史单调上涨。这一类「今天够快、明天不够」在读数面与「一直够快」同形)。
t "M-a A路:按 mtime 排序并截断(⛔ 全扫;开销 ⛔ 随历史积累涨)" bash -c '
  b="$(sed -n "/^seat_read_a()/,/^}/p" "$1" | grep -v "^[[:space:]]*#")"
  grep -q "getmtime" <<< "$b" && grep -q "SEAT_SCAN_MAX" <<< "$b"' _ "$LANE"
t "M-a A路 阳性:夹具 30 份而目标是**最新**的一份 ⇒ 照样找到(截断 ⛔ 误伤正常情形)" bash -c '
  b="$(sed -n "/^seat_read_a()/,/^}/p" "$1")"; eval "$b"
  d="$(mktemp -d)"; i=0
  while [ $i -lt 30 ]; do i=$((i+1)); printf "{\"type\":\"agent-name\",\"agentName\":\"other$i\"}\n{\"message\":{\"usage\":{\"input_tokens\":1}}}\n" > "$d/f$i.jsonl"; done
  printf "{\"type\":\"agent-name\",\"agentName\":\"dispatch\"}\n{\"message\":{\"usage\":{\"input_tokens\":400000}}}\n" > "$d/zz.jsonl"
  o="$(LAIXIN_CTX_PROJ="$d" LAIXIN_CTX_WINDOW=1000000 seat_read_a dispatch)"; rm -rf "$d"
  grep -q "ctx=40.0 " <<< "$o" && grep -q "sid=zz" <<< "$o"' _ "$LANE"
t "M-a A路 对照:把窗口压到 2 而目标排在更旧处 ⇒ **读不出**(证明截断真的生效 ⛔ 是个摆设)" bash -c '
  b="$(sed -n "/^seat_read_a()/,/^}/p" "$1")"; eval "$b"
  d="$(mktemp -d)"
  printf "{\"type\":\"agent-name\",\"agentName\":\"dispatch\"}\n{\"message\":{\"usage\":{\"input_tokens\":400000}}}\n" > "$d/old.jsonl"
  sleep 1
  for n in n1 n2 n3; do printf "{\"type\":\"agent-name\",\"agentName\":\"x\"}\n" > "$d/$n.jsonl"; done
  o="$(SEAT_SCAN_MAX=2 LAIXIN_CTX_PROJ="$d" seat_read_a dispatch)"; rm -rf "$d"
  grep -q "why=A路读不出" <<< "$o"' _ "$LANE"
rm -rf "$SA"

echo "== 2.4c-seat. M-c 席位态对所有窗可见(statusline;夹具态文件,零真实渲染依赖)=="
SC="$(mktemp -d)"; SLPY="$(cd "$(dirname "$0")/.." && pwd)/contrib-statusline.py"
SCIN='{"context_window":{"used_percentage":30}}'
scline(){ printf '%s' "$SCIN" | LAIXIN_SEAT_STATE="$SC/s" python3 "$SLPY" | sed 's/\x1b\[[0-9;]*m//g'; }
export -f scline 2>/dev/null || true
scmk(){ printf 'ts=%s\nstate=%s\nt=%s\nkeepalive=%s\nmismatch=%s\n' "${1}" "$2" "$3" "${4:-on}" "${5:-}" > "$SC/s"; }

t "M-c 态文件不存在 ⇒ 状态栏**零输出**(本机没跑流水线,⛔ 加噪)" bash -c '
  o="$(printf "%s" "$3" | LAIXIN_SEAT_STATE="$1/nope" python3 "$2" | sed "s/\x1b\[[0-9;]*m//g")"
  ! grep -q "派工席" <<< "$o"' _ "$SC" "$SLPY" "$SCIN"

t "M-c 在班 ⇒ 仍留通过态标记(#50:「没有报警」与「没有这项检查」不得同形)" bash -c '
  printf "ts=%s\nstate=在班\nt=0\nkeepalive=on\n" "$(date +%s)" > "$1/s"
  printf "%s" "$3" | LAIXIN_SEAT_STATE="$1/s" python3 "$2" | sed "s/\x1b\[[0-9;]*m//g" | grep -q "派工席 ✓"' _ "$SC" "$SLPY" "$SCIN"

t "M-c 非在班 ⇒ 红行带态与持续分钟(所有窗都看得见,⛔ 只显本窗自己)" bash -c '
  printf "ts=%s\nstate=排空无继任\nt=900\nkeepalive=on\n" "$(date +%s)" > "$1/s"
  o="$(printf "%s" "$3" | LAIXIN_SEAT_STATE="$1/s" python3 "$2")"
  grep -q "派工席:排空无继任 15m" <<< "$(sed "s/\x1b\[[0-9;]*m//g" <<< "$o")" && grep -q $'"'"'\033\[1;31m'"'"' <<< "$o"' _ "$SC" "$SLPY" "$SCIN"

t "M-c 三路不一致 ⇒ 红行上带出来(⛔ 只在看板里)" bash -c '
  printf "ts=%s\nstate=排空无继任\nt=900\nkeepalive=on\nmismatch=X\n" "$(date +%s)" > "$1/s"
  printf "%s" "$3" | LAIXIN_SEAT_STATE="$1/s" python3 "$2" | sed "s/\x1b\[[0-9;]*m//g" | grep -q "三路不一致"' _ "$SC" "$SLPY" "$SCIN"

# 🔴 判据钉**形态与下界** ⛔ 钉精确秒数(2026-08-29 实撞,窗 B 的跑先红、我这边同轮侥幸绿):
#   原写法断言「读数陈旧 **9999s**」,而 `ts=$(date +%s)-9999` 与 statusline 的 `int(time.time())`
#   是**两次独立读时钟**,跨一个秒边界就变 10000 ⇒ 忽红忽绿,踩本套件首行那条自律
#   (「会因环境忽红忽绿的测试比没有测试更糟」)。
#   ⚠️ 判准比「别写死时间」更准:危险的不是判据里有时间,是**两侧各自读一次时钟、而断言钉的是
#     两次读数之差的精确值**。本片同族已全扫,只此一条(hb=789/3000 是喂纯函数的固定串;
#     t=900 是夹具固定字段;ts=$(date +%s) 那几条阈值 300s,容得下一秒抖动)。
t "M-c 读数陈旧 ⇒ 显式报陈旧秒数(**看门狗死了**与「态一直是在班」在屏幕上必须不同形)" bash -c '
  printf "ts=%s\nstate=在班\nt=0\nkeepalive=on\n" "$(( $(date +%s) - 9999 ))" > "$1/s"
  o="$(printf "%s" "$3" | LAIXIN_SEAT_STATE="$1/s" python3 "$2" | sed "s/\x1b\[[0-9;]*m//g")"
  n="$(sed -n "s/.*读数陈旧 \([0-9][0-9]*\)s.*/\1/p" <<< "$o")"
  [ -n "$n" ] || { echo "没报出秒数:[$o]"; exit 1; }
  # 下界=夹具设定值;上界给足宽容(跨秒边界只会多几秒,多出一大截就是真出了别的问题)
  [ "$n" -ge 9999 ] && [ "$n" -le 10060 ]' _ "$SC" "$SLPY" "$SCIN"

t "M-c 态文件坏(缺 ts)⇒ 报「不可解析」⛔ 报一个十几亿秒的数(那长得像计算 bug,会把人引到错方向)" bash -c '
  printf "garbage\n" > "$1/s"
  o="$(printf "%s" "$3" | LAIXIN_SEAT_STATE="$1/s" python3 "$2" | sed "s/\x1b\[[0-9;]*m//g")"
  grep -q "态文件不可解析" <<< "$o" && ! grep -qE "读数陈旧 [0-9]{9,}s" <<< "$o"' _ "$SC" "$SLPY" "$SCIN"

t "M-c 保活奉令关闭 ⇒ 暗色标注 ⛔ 红(关闭态下的红不可行动,会训练人忽略红)" bash -c '
  printf "ts=%s\nstate=缺\nt=300\nkeepalive=off\n" "$(date +%s)" > "$1/s"
  o="$(printf "%s" "$3" | LAIXIN_SEAT_STATE="$1/s" python3 "$2")"
  grep -q "保活已关闭" <<< "$(sed "s/\x1b\[[0-9;]*m//g" <<< "$o")" && ! grep -q $'"'"'\033\[1;31m派工席'"'"' <<< "$o"' _ "$SC" "$SLPY" "$SCIN"

t "M-c 席位段异常 ⛔ 带死整条状态栏(拆掉 import os ⇒ ctx 行仍在 且 席位段显形)" bash -c '
  d="$(mktemp -d)"; sed "/^import os$/d" "$1" > "$d/sl.py"
  o="$(printf "%s" "{\"context_window\":{\"used_percentage\":30}}" | python3 "$d/sl.py" | sed "s/\x1b\[[0-9;]*m//g")"
  rm -rf "$d"
  grep -q "30%" <<< "$o" || { echo "整条状态栏没了:[$o]"; exit 1; }
  grep -q "席位态:读取异常(NameError)" <<< "$o"' _ "$SLPY"
t "M-c statusline ⛔ 裸 except(2026-08-29 实撞:裸 except 把「配置没设」与「代码坏了」吞成同一个结果)" bash -c '
  b="$(sed -n "/^def seat_line/,/^def main/p" "$1")"; [ -n "$b" ] || exit 9
  ! grep -qE "except\s*:|except Exception\s*:" <<< "$b"' _ "$SLPY"

# ── cmd_seat_state 的人读面(⛔ 只测好路径:本件自查实撞——坏文件时 bash 算术抛
#   `operand expected` 到 stderr,而命令**照样退 0** ⇒ 「坏了」与「好了」在退出码上同形)────
t "seat-state 坏态文件 ⇒ **非零退出**且点名 ⛔ 当健康(⛔ 抛算术错却退 0)" bash -c '
  d="$(mktemp -d)"; printf "garbage\n" > "$d/s"
  o="$(LAIXIN_SEAT_STATE="$d/s" "$1" seat-state 2>&1)"; rc=$?
  rm -rf "$d"
  [ "$rc" -ne 0 ] || { echo "坏文件竟退 0"; exit 1; }
  grep -q "席位态文件损坏" <<< "$o" && ! grep -q "operand expected" <<< "$o"' _ "$LANE"
t "seat-state 好态文件 ⇒ 退 0 并报**读数龄**(陈旧与新鲜必须分得开)" bash -c '
  d="$(mktemp -d)"; printf "ts=%s\nstate=在班\nt=0\nkeepalive=on\n" "$(date +%s)" > "$d/s"
  o="$(LAIXIN_SEAT_STATE="$d/s" "$1" seat-state 2>&1)"; rc=$?
  rm -rf "$d"; [ "$rc" -eq 0 ] && grep -q "读数龄" <<< "$o" && grep -q "新鲜" <<< "$o"' _ "$LANE"
# ── doctor §9b:M-c 的第三个落点。⛔ 只测「有这一节」——要测的是它**分不分得开成败**。
t "doctor §9b:态文件不存在 ⇒ ⚠️ 警告并明说「读不到 ⛔ 当健康」(⛔ 报绿 ⛔ 整节消失)" bash -c '
  o="$(LAIXIN_SEAT_STATE=/nope/nope/x "$1" doctor 2>&1)"
  grep -q "9b. 派工席态" <<< "$o" || { echo "整节不见了"; exit 1; }
  seg="$(sed -n "/== 9b/,/^== /p" <<< "$o")"
  grep -q "⚠️" <<< "$seg" && grep -q "读不到 ⛔ 当健康" <<< "$seg" && ! grep -q "✅" <<< "$seg"' _ "$LANE"

t "doctor §9b:排空无继任 + 三路不一致 ⇒ ❌ 红行 且 点名不一致(计入错误数)" bash -c '
  d="$(mktemp -d)"
  printf "ts=%s\nstate=排空无继任\nt=900\nkeepalive=on\nctx=83.7\nwhy=ctx 83.7%% ≥ 硬口\nmismatch=C路会话面有 2 个 dispatch\n" "$(date +%s)" > "$d/s"
  o="$(LAIXIN_SEAT_STATE="$d/s" "$1" doctor 2>&1)"; rm -rf "$d"
  seg="$(sed -n "/== 9b/,/^== /p" <<< "$o")"
  grep -q "❌" <<< "$seg" && grep -q "排空无继任" <<< "$seg" && grep -q "C路会话面有 2 个 dispatch" <<< "$seg"' _ "$LANE"

t "doctor §9b:在班 ⇒ ✅ 通过态**可见**(#50:「没有报警」与「没有这项检查」不得同形)" bash -c '
  d="$(mktemp -d)"
  printf "ts=%s\nstate=在班\nt=0\nkeepalive=on\nctx=30.0\nwhy=\nmismatch=\n" "$(date +%s)" > "$d/s"
  o="$(LAIXIN_SEAT_STATE="$d/s" "$1" doctor 2>&1)"; rm -rf "$d"
  seg="$(sed -n "/== 9b/,/^== /p" <<< "$o")"
  grep -q "✅ 派工席在班" <<< "$seg" && ! grep -qE "❌|⚠️" <<< "$seg"' _ "$LANE"

t "seat-state 态文件不存在 ⇒ 明说「读不到 ⛔ 等于席位健康」(⛔ 静默零输出)" bash -c '
  o="$(LAIXIN_SEAT_STATE=/nope/nope/x "$1" seat-state 2>&1)"
  grep -q "读不到 ⛔ 等于席位健康" <<< "$o"' _ "$LANE"
rm -rf "$SC"

echo "== 2.4d-seat. 单点源 · wd_loop 挂点 · M-e 文案(结构绊线)=="
# 🔴 阈值单点源(pingxia-47 明令 ⛔ 各抄一份):权威=顶层 SEAT_HB_STALE;seat_liveness 体内写
#   `${SEAT_HB_STALE:-2700}` 的回退字面量是给「函数体被抽出来单跑」用的(本套件有 6 处抽它),
#   顶层变量不随抽取走、裸引用会在 set -u 下静默炸 ⇒ 与 GATE_HARD/GATE_WARN 同一家法:
#   **两处常量 + 绊线钉同步**,漂移由机器抓 ⛔ 靠自觉。
t "单点源:seat_liveness 的陈旧线走 SEAT_HB_STALE(⛔ 再写裸 2700)" bash -c '
  b="$(sed -n "/^seat_liveness()/,/^}/p" "$1")"
  grep -q "SEAT_HB_STALE:-2700" <<< "$b" && ! grep -qE "lt 2700 " <<< "$b"' _ "$LANE"
t "单点源:顶层 SEAT_HB_STALE 的默认值 == seat_liveness 里的回退字面量(漂移必红)" python3 -c '
import re,sys
s=open(sys.argv[1],encoding="utf-8").read()
top=re.search(r"^SEAT_HB_STALE=\"\$\{LAIXIN_SEAT_HB_STALE:-(\d+)\}\"",s,re.M)
fb=re.findall(r"\$\{SEAT_HB_STALE:-(\d+)\}",s)
assert top, "找不到顶层 SEAT_HB_STALE"
assert fb, "找不到任何回退字面量"
assert set(fb)=={top.group(1)}, "陈旧线漂移:顶层=%s 回退=%s" % (top.group(1), set(fb))
' "$LANE"
t "单点源:SEAT_GATE_HARD 默认值 == cmd_ctx 的硬闸门 == statusline.py 的 GATE_HARD(三处)" python3 -c '
import re,sys,os
s=open(sys.argv[1],encoding="utf-8").read()
g=re.search(r"^SEAT_GATE_HARD=\"\$\{LAIXIN_SEAT_GATE_HARD:-(\d+)\}\"",s,re.M); assert g,"找不到 SEAT_GATE_HARD"
hard=set(re.findall(r"pct>=(\d+): print\(\"\N{LARGE RED CIRCLE}", s)); assert len(hard)==1, hard
assert g.group(1)==hard.pop(), "闸门线漂移:SEAT_GATE_HARD 与 cmd_ctx 不一致"
# 2.4b:同上,改读**仓内**单点源 ⇒ 天然封闭
sl=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(sys.argv[1]))),"contrib-statusline.py")
if os.path.exists(sl):
    m=re.search(r"GATE_HARD\s*=\s*(\d+)",open(sl,encoding="utf-8").read())
    assert m and m.group(1)==g.group(1), "闸门线漂移:SEAT_GATE_HARD 与仓内 contrib-statusline.py 不一致"
' "$LANE"

# ── wd_loop 挂点:位置本身就是判据(挂错=机制在该生效的时候不生效)────────────────────
t "wd_loop:M-a 判态挂在**保活闸门之前**(关闭态也照写态文件——停更的文件与「一直健康」同形)" bash -c '
  b="$(sed -n "/^wd_loop()/,/^}/p" "$1")"
  a="$(grep -n "seat_state_tick" <<< "$b" | head -1 | cut -d: -f1)"
  g="$(grep -n "if dispatch_keepalive_off; then" <<< "$b" | head -1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$g" ] && [ "$a" -lt "$g" ]' _ "$LANE"
t "wd_loop:M-a 判态是**子 shell 隔离**调用(#44:保命循环里裸调用会被 die 无声带死宿主)" bash -c '
  b="$(sed -n "/^wd_loop()/,/^}/p" "$1")"
  grep -qE "^\s*\( seat_state_tick \)" <<< "$b"' _ "$LANE"
# ── 5.3 judge-scan:判据扫描器(2026-08-29 兑现窗B;清单权威=11B raw 采集分析档 §十)────
#   首行依据:「刚写完或刚引用某条判据的人,在下一个动作里违反它」当日 8 次 4 个主体
#   ⇒ **判据靠人执行不可靠**。定位=**防回归**(新增位置即红)⛔ 清存量。
#   三条硬前置(例49):每条配阴性对照 · 报告可追到位置 · 判不了显式未判。
echo "== 8f. judge-scan:判据扫描器(J1/J2/J4/J7/J9;阳性报 · 阴性不报 · 可追到行) =="
JSX="$(mktemp -d)"; JS="$(cd "$(dirname "$0")/.." && pwd)/bin/judge-scan"

t "judge-scan J1 阳性:grep -c 不带 -a ⇒ 报,且**可追到文件与行**" bash -c '
  set -e; d="$2/j1p"; mkdir -p "$d/bin"
  printf "#!/bin/bash\nn=\$(grep -c foo \"\$f\")\n" > "$d/bin/x"
  out="$("$1" --repo "$d" --only J1 2>&1)" && rc=0 || rc=$?
  grep -qF "bin/x:2" <<< "$out" || { echo "$out"; exit 1; }
  [ "$rc" = 1 ] || { echo "有阳性时退出码应为 1,实得 $rc"; exit 2; }' _ "$JS" "$JSX"

t "judge-scan J1 阴性:带 -a 的写法 · **注释行里的写法** ⇒ 不报" bash -c '
  set -e; d="$2/j1n"; mkdir -p "$d/bin"
  printf "#!/bin/bash\nn=\$(grep -ac foo \"\$f\")\nm=\$(grep -a -c foo \"\$f\")\n# 反例:grep -c foo \"\$f\"\n" > "$d/bin/x"
  out="$("$1" --repo "$d" --only J1 2>&1)" && rc=0 || rc=$?
  grep -qF "零新增阳性" <<< "$out" || { echo "$out"; exit 1; }
  [ "$rc" = 0 ] || { echo "无阳性时退出码应为 0,实得 $rc"; exit 2; }' _ "$JS" "$JSX"

t "judge-scan J2 阳性:[ -L ] 之后不核终点 ⇒ 报" bash -c '
  set -e; d="$2/j2p"; mkdir -p "$d/bin"
  printf "#!/bin/bash\nif [ -L \"\$p\" ]; then\n  ok \"是软链\"\nfi\n" > "$d/bin/x"
  out="$("$1" --repo "$d" --only J2 2>&1)" || true
  grep -qF "bin/x:2" <<< "$out" || { echo "$out"; exit 1; }' _ "$JS" "$JSX"

t "judge-scan J2 阴性:**修后 doctor §1 的写法**(核了 -f 与 -ef)⇒ 不报" bash -c '
  # 阴性样本逐字取自清单指定的「修后」形态:核终点存在性(-f)与身份(-ef)。
  set -e; d="$2/j2n"; mkdir -p "$d/bin"
  printf "#!/bin/bash\nif [ -L \"\$e/skills/\$s\" ]; then\n  if [ ! -f \"\$e/skills/\$s/SKILL.md\" ]; then\n    bad \"断链\"\n  elif [ ! \"\$e/skills/\$s/SKILL.md\" -ef \"\$H/.codex/skills/\$s/SKILL.md\" ]; then\n    bad \"非单点源\"\n  fi\nfi\n" > "$d/bin/x"
  out="$("$1" --repo "$d" --only J2 2>&1)" || true
  grep -qF "零新增阳性" <<< "$out" || { echo "$out"; exit 1; }' _ "$JS" "$JSX"

t "judge-scan J2 阴性-bis:核终点的代码被**注释挤出窗口**时仍不报(例49 实撞)" bash -c '
  # 清单明训:扫描须**剔除注释行**再看窗口,否则注释会把核终点的代码挤出去 ⇒ 假阳性。
  set -e; d="$2/j2n2"; mkdir -p "$d/bin"
  { printf "#!/bin/bash\nif [ -L \"\$p\" ]; then\n"; for i in 1 2 3 4 5 6 7 8; do printf "  # 注释第 %s 行\n" "\$i"; done; printf "  [ -f \"\$p/SKILL.md\" ] || bad 断链\nfi\n"; } > "$d/bin/x"
  out="$("$1" --repo "$d" --only J2 2>&1)" || true
  grep -qF "零新增阳性" <<< "$out" || { echo "$out"; exit 1; }' _ "$JS" "$JSX"

t "judge-scan J4 阳性:裸 except 之后 pass ⇒ 报" bash -c '
  set -e; d="$2/j4p"; mkdir -p "$d/bin"
  printf "import os\ntry:\n    os.stat(\"x\")\nexcept:\n    pass\n" > "$d/bin/y.py"
  out="$("$1" --repo "$d" --only J4 2>&1)" || true
  grep -qF "bin/y.py:4" <<< "$out" || { echo "$out"; exit 1; }' _ "$JS" "$JSX"

t "judge-scan J4 阴性:①except 之后有输出 ②**带类型的 except + continue**(正常控制流)⇒ 不报" bash -c '
  # ② 是首跑实撞的假阳性面:第一版扫所有 except,把 `except IOError: continue` 报了 4 处。
  set -e; d="$2/j4n"; mkdir -p "$d/bin"
  printf "import os, sys\ntry:\n    os.stat(\"x\")\nexcept Exception as e:\n    sys.stderr.write(\"读不到 %%r\\n\" %% (e,))\nfor f in []:\n    try:\n        open(f)\n    except IOError:\n        continue\n" > "$d/bin/y.py"
  out="$("$1" --repo "$d" --only J4 2>&1)" || true
  grep -qF "零新增阳性" <<< "$out" || { echo "$out"; exit 1; }' _ "$JS" "$JSX"

t "judge-scan J7 阳性:[ -d <p>/.git ] ⇒ 报(worktree 的 .git 是文件不是目录)" bash -c '
  set -e; d="$2/j7p"; mkdir -p "$d/bin"
  printf "#!/bin/bash\n[ -d \"\$repo/.git\" ] || die 不是仓\n" > "$d/bin/x"
  out="$("$1" --repo "$d" --only J7 2>&1)" || true
  grep -qF "bin/x:2" <<< "$out" || { echo "$out"; exit 1; }' _ "$JS" "$JSX"

t "judge-scan J7 阴性:git rev-parse --git-dir(既认目录也认文件)⇒ 不报" bash -c '
  set -e; d="$2/j7n"; mkdir -p "$d/bin"
  printf "#!/bin/bash\ngit -C \"\$repo\" rev-parse --git-dir >/dev/null 2>&1 || die 不是仓\n" > "$d/bin/x"
  out="$("$1" --repo "$d" --only J7 2>&1)" || true
  grep -qF "零新增阳性" <<< "$out" || { echo "$out"; exit 1; }' _ "$JS" "$JSX"

t "judge-scan J9 阳性:tests/ 下拿 HEAD:<f> 比对作闸 ⇒ 报(**-C 带空格也要认出**)" bash -c '
  # 首跑漏报面:真阳性那行是 `-C "$(dirname "$2")/.."`,原正则 `-C \S+` 挡住了它。
  set -e; d="$2/j9p"; mkdir -p "$d/bin" "$d/tests"
  printf "#!/bin/bash\ngit -C \"\$(dirname \"\$2\")/..\" show HEAD:contrib-statusline.py 2>/dev/null | diff -q - \"\$a\" >/dev/null\n" > "$d/tests/run.sh"
  out="$("$1" --repo "$d" --only J9 2>&1)" || true
  grep -qF "tests/run.sh:2" <<< "$out" || { echo "$out"; exit 1; }' _ "$JS" "$JSX"

t "judge-scan J9 阴性:release 动作里 git show HEAD:<f> **写进发布目录**(取内容 ⛔ 比对)⇒ 不报" bash -c '
  # 清单三层收窄第一层的假阳性面:同一语法写进发布目录是**正确写法**。
  set -e; d="$2/j9n"; mkdir -p "$d/bin"
  printf "#!/bin/bash\ngit -C \"\$repo\" show \"HEAD:bin/laixin-lane\" > \"\$tmp\" 2>/dev/null\n" > "$d/bin/x"
  out="$("$1" --repo "$d" --only J9 2>&1)" || true
  grep -qF "零新增阳性" <<< "$out" || { echo "$out"; exit 1; }' _ "$JS" "$JSX"

t "judge-scan J9 阴性-bis:bin/ 里比 HEAD 但**只作提示**(release_stale)⇒ 不报" bash -c '
  set -e; d="$2/j9n2"; mkdir -p "$d/bin"
  printf "#!/bin/bash\ngit -C \"\$repo\" show \"HEAD:bin/\$b\" > \"\$c\" 2>/dev/null && cmp -s \"\$c\" \"\$f\" || _stale=0\n" > "$d/bin/x"
  out="$("$1" --repo "$d" --only J9 2>&1)" || true
  grep -qF "零新增阳性" <<< "$out" || { echo "$out"; exit 1; }' _ "$JS" "$JSX"

t "judge-scan 硬前置③:未实现/判不了的条目**显式列出** ⛔ 静默缺席" bash -c '
  set -e; d="$2/j0"; mkdir -p "$d/bin"; printf "#!/bin/bash\ntrue\n" > "$d/bin/x"
  out="$("$1" --repo "$d" 2>&1)" || true
  grep -qF "未判 / 本批未实现" <<< "$out" || { echo "$out"; exit 1; }
  for j in J3 J5 J6 J8; do grep -qF "  $j " <<< "$out" || { echo "缺 $j 的未判行"; exit 2; }; done
  grep -qF "judge-scan\` **自己不在射程**" <<< "$out" || { echo "未写出自排除这条射程缺口"; exit 3; }' _ "$JS" "$JSX"

t "judge-scan 射程判不出 ⇒ 显式报错并 exit 2 ⛔ 静默扫空射程出「零阳性」" bash -c '
  set -e; d="$2/empty"; mkdir -p "$d"
  out="$("$1" --repo "$d" 2>&1)" && rc=0 || rc=$?
  [ "$rc" = 2 ] || { echo "应 exit 2,实得 $rc"; exit 1; }
  grep -qF "与「真的零阳性」完全同形" <<< "$out" || { echo "$out"; exit 2; }' _ "$JS" "$JSX"

t "judge-scan 基线闸:已知存量放行、**新增即红**(防回归的判据本身)" bash -c '
  set -e; d="$2/base"; mkdir -p "$d/bin"
  printf "#!/bin/bash\nn=\$(grep -c foo \"\$f\")\n" > "$d/bin/x"
  "$1" --repo "$d" --only J1 --write-baseline > "$d/base.txt"
  out="$("$1" --repo "$d" --only J1 --baseline "$d/base.txt" 2>&1)" && rc=0 || rc=$?
  [ "$rc" = 0 ] || { echo "存量应被基线放行,实得 rc=$rc:$out"; exit 1; }
  printf "m=\$(grep -c bar \"\$g\")\n" >> "$d/bin/x"
  out2="$("$1" --repo "$d" --only J1 --baseline "$d/base.txt" 2>&1)" && rc2=0 || rc2=$?
  [ "$rc2" = 1 ] || { echo "新增应变红,实得 rc=$rc2:$out2"; exit 2; }
  grep -qF "bin/x:3" <<< "$out2" || { echo "新增未追到行:$out2"; exit 3; }' _ "$JS" "$JSX"

t "judge-scan 真仓闸:射程内**零新增阳性**(基线放行已知存量;新代码再犯即红)" bash -c '
  # ⚠️ 仓路径**在 run.sh 作用域求值后当参数传入** ⛔ 在 body 里用 `$0` 推:
  #   body 跑在 `bash -c ... _ <args>` 里,**`$0` 是 `_`** ⇒ `dirname "$0"/..` 推出的是运行目录的
  #   父目录、不是仓 ⇒ judge-scan 判「射程判不出」exit 2,这条恒红。仓里既有写法(APF 那几条)
  #   正是先在 run.sh 作用域求值再传参,本条首版没照抄,实撞一次(2026-08-29,且合了红)。
  set -e; repo="$2"
  out="$("$1" --repo "$repo" --baseline "$repo/tests/judge-scan-baseline.txt" 2>&1)" && rc=0 || rc=$?
  [ "$rc" = 0 ] || { echo "$out"; exit 1; }' _ "$JS" "$(cd "$(dirname "$0")/.." && pwd)"

rm -rf "$JSX"

# ── 5.4 accept-preflight:事实单回显 --repo 解析到的是什么(2026-08-29 兑现窗B)────────
#   立据=本窗自己的实撞:5.1b 回放把 --repo 指向克隆仓、并把它的 main 退回合入前,
#   事实单看起来**四条件齐全**,而它描述的**根本不是 main**;当时靠回报人用文字补了一句
#   ⇒ **判据能不能区分成败,⛔ 靠回报人恰好诚实**(通则 A:结论不带基点时,对的基点与错的基点同形;
#   例77:以回显判「已生效」时,回显须实测**对象侧**状态 ⛔ 发送侧痕迹)。
echo "== 8g. accept-preflight:--repo 回显与「非 main 副本」标注 =="
APR="$(mktemp -d)"; APRB="$(cd "$(dirname "$0")/.." && pwd)/bin/accept-preflight"
# 🔴 夹具**落临时脚本再调** ⛔ 写成 shell 函数 —— 测试体跑在 `bash -c` 子进程里,
#   函数不随之继承(与第六发坑同族:bash 3.2 下 `source <(…)` 函数不落地且不报错)。
cat > "$APR/mkapr.sh" <<'MKAPR'
#!/bin/bash
# mkapr.sh <目录> —— 密封小仓:main 上两个提交
set -e
d="$1"; mkdir -p "$d"; git -C "$d" init -q -b main .
printf 'x\n' > "$d/a.txt"; git -C "$d" add -A
git -C "$d" -c user.name=t -c user.email=t@t commit -qm c1
printf 'y\n' >> "$d/a.txt"; git -C "$d" add -A
git -C "$d" -c user.name=t -c user.email=t@t commit -qm c2
MKAPR
chmod +x "$APR/mkapr.sh"

t "APF 回显 阳性:--repo 在**非 main 分支**上 ⇒ 事实单显著标注「非 main 副本」" bash -c '
  # 若它红了:说明事实单在描述一个不是 main 的仓时**没说出来** ⇒ 读者会把分支上的读数当 main 的结论
  #(本窗 5.1b 实撞的正是这一族,只是那次是克隆仓而非分支)。
  set -e; d="$2/pos-branch"; "$2/mkapr.sh" "$d"; git -C "$d" checkout -qb feat/x
  out="$("$1" 片 "$(git -C "$d" rev-parse --short HEAD)" --repo "$d" --test-cmd true --evidence-dir "$d/ev" 2>&1)" || true
  grep -qF "非 main 副本" <<< "$out" || { echo "$out" | head -6; exit 1; }
  grep -qF "feat/x" <<< "$out" || { echo "未回显分支名"; exit 2; }
  grep -qF "⛔ 读成 main 的验收结论" <<< "$out" || { echo "未写明该怎么读"; exit 3; }' _ "$APRB" "$APR"

t "APF 回显 阳性:--repo 的 **main 落后其 origin/main** ⇒ 标注(重放 5.1b 那次的真实形态)" bash -c '
  # 若它红了:说明「克隆仓 + main 被退回」这一形态仍然静默 —— 而那正是本件的立据:
  # 分支名叫 main、HEAD 也在它自己的 main 历史里,**只判分支名抓不到它**。
  set -e; src="$2/src"; "$2/mkapr.sh" "$src"
  clone="$2/pos-behind"; git clone -q "$src" "$clone"
  git -C "$clone" checkout -q -B main HEAD~1        # 把克隆仓的 main 退回一个提交
  out="$("$1" 片 "$(git -C "$clone" rev-parse --short HEAD)" --repo "$clone" --test-cmd true --evidence-dir "$clone/ev" 2>&1)" || true
  grep -qF "落后其 origin/main" <<< "$out" || { echo "$out" | head -6; exit 1; }
  grep -qF "main 被退回或已陈旧" <<< "$out" || exit 2' _ "$APRB" "$APR"

t "APF 回显 同刻绿对照:--repo 就在 main 且不落后 ⇒ **无标注**(证明当刻站在会标注的形态上)" bash -c '
  # 若它红了:说明标注是**恒亮**的 —— 那样上面两条阳性就什么也没证明(全亮=没有分辨力)。
  # ⚠️ 合法例外集:仓在 main 但**落后其 origin/main** 时**应当**标注,故本夹具用无 origin 的裸仓。
  set -e; d="$2/neg-main"; "$2/mkapr.sh" "$d"
  out="$("$1" 片 "$(git -C "$d" rev-parse --short HEAD)" --repo "$d" --test-cmd true --evidence-dir "$d/ev" 2>&1)" || true
  grep -qF "非 main 副本" <<< "$out" && { echo "在 main 上却报了非 main:"; echo "$out" | head -6; exit 1; }
  grep -qF "分支=main" <<< "$out" || { echo "未回显分支名"; exit 2; }
  exit 0' _ "$APRB" "$APR"

t "APF 回显 阴性:--repo 解析不出 ⇒ 归**未判** ⛔ 归 main ⛔ 静默" bash -c '
  # 若它红了:说明「这不是个仓」被读成了「这是 main」或干脆不出声 —— 三态硬规则里
  # 「未判」的存在理由正是判不出就说判不出。
  set -e; d="$2/neg-norepo"; mkdir -p "$d"
  out="$("$1" 片 deadbeef --repo "$d" --test-cmd true --evidence-dir "$d/ev" 2>&1)" || true
  grep -qF "分支=读不到" <<< "$out" || { echo "$out" | head -6; exit 1; }
  grep -qF "**未判**" <<< "$out" || { echo "未归未判"; exit 2; }
  grep -qF "⛔ 当成 main" <<< "$out" || { echo "未写明 ⛔ 当成 main"; exit 3; }' _ "$APRB" "$APR"

t "APF 回显:仓路径**按解析后的绝对路径**回显(⛔ 回显调用者传进来的相对写法)" bash -c '
  # 若它红了:说明事实单回显的是**发送侧的字面**而非**对象侧的实际路径**(例77 那一族),
  # 读者据它判「我扫的是哪个仓」会判错。
  set -e; d="$2/abs"; "$2/mkapr.sh" "$d"
  # ⚠️ 期望值要用**解析后**的路径:macOS 的 mktemp -d 给的是 /var/...(软链),
  #   而回显的是 pwd -P 解析后的 /private/var/... —— 拿未解析的去比会红,而红的是**测试**不是实现。
  dabs="$(cd "$d" && pwd -P)"
  out="$(cd "$2" && "$1" 片 "$(git -C "$d" rev-parse --short HEAD)" --repo ./abs --test-cmd true --evidence-dir "$d/ev" 2>&1)" || true
  grep -qF "仓路径(--repo 解析后): $dabs" <<< "$out" || { echo "$out" | head -3; exit 1; }
  grep -qF "./abs" <<< "$out" && { echo "回显了相对写法"; exit 2; }
  exit 0' _ "$APRB" "$APR"

rm -rf "$APR"

echo
echo "结果:$PASS 过 / $FAIL 败"
[ "$FAIL" -eq 0 ]
