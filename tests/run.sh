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
  if echo "$out" | grep -q "$want"; then PASS=$((PASS+1)); echo "  ✅ $name";
  else FAIL=$((FAIL+1)); echo "  ❌ $name  (未见「${want}」,实际:$(echo "$out"|head -1))"; fi
}
tfail(){ # tfail <名字> <期望错误子串> <命令...> —— 命令须失败且报该错
  local name="$1"
  local want="$2"
  shift 2
  local out; out="$("$@" 2>&1)"; local rc=$?
  if [ $rc -ne 0 ] && echo "$out" | grep -q "$want"; then PASS=$((PASS+1)); echo "  ✅ $name";
  else FAIL=$((FAIL+1)); echo "  ❌ $name  (rc=$rc,输出:$(echo "$out"|head -1))"; fi
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
rm -rf "$TMPD"

echo "== 4. 配置外置(env 覆盖生效,默认不变) =="
tout "SESSION 可覆盖" "不存在" env LAIXIN_SESSION=lx-test-nonexist "$LANE" status
tout "ctx 分母可覆盖" "500,000" env LAIXIN_CTX_WINDOW=500000 "$LANE" ctx 3683f143

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
rm -rf "$TMPT"

echo
echo "结果:$PASS 过 / $FAIL 败"
[ "$FAIL" -eq 0 ]
