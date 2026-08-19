#!/bin/bash
# #44 绊线驱动——在隔离沙盒里跑真实的 wd_loop/cmd_relay(零真实 tmux/进程副作用:
# tmux 是函数桩;ev_alive 桩为活 ⇒ 永远不会走到 cmd_events 的 pgrep/pkill)。
# 用法:bash wd44-driver.sh <mech|beat|guard> <laixin-lane 路径>
#   mech  : 机理自证——函数内 die(exit)穿透 `>/dev/null 2>&1 ||兜底` 直接杀宿主(兜底行不执行)
#   beat  : fixture=「relay 已死 + 常态拓扑 outside=2」,跑真 wd_loop ≥2 拍,输出宿主生死+看板
#   guard : 首起路径(无豁免旗)直接调真 cmd_relay --fresh,输出 rc 与守卫报文(守卫必须照旧拦)
# 绊线判据(由 run.sh 断言,修复回退即变红):
#   - beat 必须 HOST=alive(回退子 shell 隔离 ⇒ 守卫/超时 die 杀宿主 ⇒ HOST=dead)
#   - beat 看板必须有「中继重生失败」大声条(回退大声报 ⇒ 缺条)
#   - beat 看板不得含「起窗中止」(回退 --resurrect 豁免 ⇒ 常态拓扑被自家守卫拦死,死因末行即它)
#   - guard 必须 GUARD_RC 非零且报「起窗中止」(豁免若泄漏进首起路径 ⇒ 守卫失守)
MODE="${1:?mode(mech|beat|guard)}"; LANE="${2:?laixin-lane 路径}"

if [ "$MODE" = mech ]; then
  # 与生产同款 set 选项下,f 内 exit 越过 || 兜底直接终止宿主 bash ⇒ caught/after 都不该出现
  out="$(bash -c 'set -euo pipefail; die(){ echo x >&2; exit 1; }; f(){ die y; }; f >/dev/null 2>&1 || echo caught; echo after' 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && ! grep -q caught <<< "$out" && ! grep -q after <<< "$out"; then
    echo "MECH=host-dead-and-fallback-skipped"
  else
    echo "MECH=behavior-changed rc=$rc out=$out"
  fi
  exit 0
fi

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
set -euo pipefail   # 与生产脚本同款 set 选项(炸点机理依赖此语境)

# —— 抽真实函数(sed 落盘再 source,bash 3.2 对 source <() 静默失败) ——
for fn in die check_rival_relay relay_enabled cmd_relay wd_loop; do
  sed -n "/^${fn}()/,/^}/p" "$LANE" >> "$TMPD/fns.sh"
done
# caller_src 是 #45 引入的;尚不存在时给空壳,让本驱动对 #45 之前的代码也能跑
grep -q '^caller_src()' "$LANE" && sed -n '/^caller_src()/,/^}/p' "$LANE" >> "$TMPD/fns.sh" \
  || printf 'caller_src(){ echo 手工; }\n' >> "$TMPD/fns.sh"

# —— fixture 桩(全部指向沙盒;定义在 source 之后 ⇒ 覆盖顺带抽进来的真实小函数) ——
write_stubs() {  # 落成文件供本进程与 guard 模式的子 bash 共用
  cat > "$TMPD/stubs.sh" <<'STUBS'
tmux()        { return 0; }     # 所有 tmux 调用惰性化;capture 输出为空
outside_sessions() { echo 2; }  # 常态拓扑:tmux 外=创始人窗口+方案窗口
relay_alive() { return 1; }     # fixture:relay 已死(演练=杀掉它的 claude)
ev_alive()    { return 0; }     # 事件总线活着 ⇒ wd_loop 不会碰 cmd_events(pgrep/pkill 隔离)
dispatch_alive(){ return 0; }
dialog_sweep_win(){ return 1; }
pane_hash()   { echo H; }
lane_busy()   { return 0; }     # 两轨都忙 ⇒ 静默逻辑短路,专注 relay 分支
lock_holder() { echo dispatch; }
lock_age()    { echo 0; }
lock_renew()  { :; }
ensure_session(){ :; }
ensure_headless_settings(){ :; }
win_exists()  { return 1; }
vwait_ready() { return 1; }     # 沙盒起不了真 claude ⇒ 起窗必然走「启动超时」失败路径
board(){ printf '| %s | %s |\n' "$1" "$2" >> "$BOARD_F" 2>/dev/null || true; }
SESSION=lx-iso-44; RELAY_WIN=relay; DISPATCH_WIN=dispatch; WATCHDOG_WIN=watchdog
RELAY_DENY=("Bash(x)"); RELAY_BRIEF=brief; RELAY_CDP_PORT=0; RELAY_MODEL=m
STUBS
}
write_stubs
BOARD_F="$TMPD/board.md"; export BOARD_F
WD_LOG="$TMPD/wd.log"
HEADLESS_SETTINGS="$TMPD/h.json"
RELAY_ENABLED="$TMPD/relay.enabled"; : > "$RELAY_ENABLED"   # 托管标记在
source "$TMPD/fns.sh"
source "$TMPD/stubs.sh"

case "$MODE" in
  beat)
    export WD_INTERVAL=1
    wd_loop >/dev/null 2>&1 &
    WPID=$!
    sleep 4    # ≥2 拍:第一拍就撞 relay 重生
    if kill -0 "$WPID" 2>/dev/null; then echo "HOST=alive"; kill "$WPID" 2>/dev/null || true
    else echo "HOST=dead"; fi
    wait "$WPID" 2>/dev/null || true
    echo "--- board ---"; cat "$BOARD_F" 2>/dev/null || echo "(空)"
    ;;
  guard)
    rc=0
    out="$(bash -c '
      set -euo pipefail
      source "'"$TMPD"'/fns.sh"
      source "'"$TMPD"'/stubs.sh"
      BOARD_F=/dev/null; HEADLESS_SETTINGS=/dev/null; RELAY_ENABLED=/dev/null; WD_LOG=/dev/null
      cmd_relay --fresh' 2>&1)" || rc=$?
    echo "GUARD_RC=$rc"
    echo "$out"
    ;;
  *) echo "未知 mode:$MODE" >&2; exit 2 ;;
esac
