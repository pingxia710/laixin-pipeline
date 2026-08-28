#!/bin/bash
# #44 绊线驱动——在隔离沙盒里跑真实的 wd_loop/cmd_relay(零真实 tmux/进程副作用:
# tmux 是函数桩;ev_alive 桩为活 ⇒ 永远不会走到 cmd_events 的 pgrep/pkill)。
# 用法:bash wd44-driver.sh <mech|beat|guard|fuelgap> <laixin-lane 路径>
#   mech  : 机理自证——函数内 die(exit)穿透 `>/dev/null 2>&1 ||兜底` 直接杀宿主(兜底行不执行)
#   beat  : fixture=「relay 已死 + 常态拓扑 outside=2」,跑真 wd_loop ≥2 拍,输出宿主生死+看板
#   guard : 首起路径(无豁免旗)直接调真 cmd_relay --fresh,输出 rc 与守卫报文(守卫必须照旧拦)
#   manual-src : (#45)手工/在班窗口调用起窗成功路径,输出看板——来源必须随真实调用方,⛔「看门狗」
#   fuelgap : 夜间断链 fixture=全轨空闲且 ready/selfwrite/pending=0、design>0,跑真 wd_loop ≥2 拍
#   ka-hold    : (P0 2026-08-28)保活关闭态 fixture=派工席死 + 关闭标记在,跑真 wd_loop ≥3 拍
#                输出 DISPATCH_CALLS(必须 0)与看板(关闭条必须恰 1 条、零「派工窗口不在」)
#   ka-restore : 关闭态跑 2 拍 → **运行中清标记** → 再跑 ≥2 拍;证明抑制 ⛔ 把自愈整个打死
#                输出 CALLS_HELD(必须 0)/ CALLS_AFTER(必须 ≥1)与「保活已恢复」条
#   ka-capped  : 上限=1 的达上限 fixture,跑 ≥4 拍;达上限告警必须**恰 1 条**(回退成每拍一条即 ≥3)
# 绊线判据(由 run.sh 断言,修复回退即变红):
#   - beat 必须 HOST=alive(回退子 shell 隔离 ⇒ 守卫/超时 die 杀宿主 ⇒ HOST=dead)
#   - beat 看板必须有「中继重生失败」大声条(回退大声报 ⇒ 缺条)
#   - beat 看板不得含「起窗中止」(回退 --resurrect 豁免 ⇒ 常态拓扑被自家守卫拦死,死因末行即它)
#   - guard 必须 GUARD_RC 非零且报「起窗中止」(豁免若泄漏进首起路径 ⇒ 守卫失守)
MODE="${1:?mode(mech|beat|guard|fuelgap)}"; LANE="${2:?laixin-lane 路径}"

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
# #136/#137(2026-08-22)引入的循环内新依赖:自换代四函数 + 燃料判据;对之前的代码同样可跑(缺则不抽)
for fn in loop_self_gen loop_gen_record loop_reload_due loop_gen_label wd_fuel wd_fuel_advice wd_nudge_text dispatch_keepalive_off; do
  grep -q "^${fn}()" "$LANE" && sed -n "/^${fn}()/,/^}/p" "$LANE" >> "$TMPD/fns.sh"
done

# —— fixture 桩(全部指向沙盒;定义在 source 之后 ⇒ 覆盖顺带抽进来的真实小函数) ——
write_stubs() {  # 落成文件供本进程与 guard 模式的子 bash 共用
  cat > "$TMPD/stubs.sh" <<'STUBS'
tmux()        { return 0; }     # 所有 tmux 调用惰性化;capture 输出为空
outside_sessions() { echo 2; }  # 常态拓扑:tmux 外=创始人窗口+方案窗口
CLAUDE_LAUNCHER="${CLAUDE_LAUNCHER:-claude}"   # #75:顶层变量不被 fns.sh 抽取,set -u 下会静默退出 ⇒ 测试侧补齐
relay_alive() { return 1; }     # fixture:relay 已死(演练=杀掉它的 claude)
ev_alive()    { return 0; }     # 事件总线活着 ⇒ wd_loop 不会碰 cmd_events(pgrep/pkill 隔离)
rival_relay_sessions(){ :; }    # 2026-08-23 守卫按身份:沙盒默认无 relay 名会话(guard 模式内另覆盖为有)
dispatch_alive(){ return 0; }
rival_holds_dispatch(){ return 1; }   # 沙盒默认无对手持有派工权(ka-* 模式专用;beat/fuelgap 走不到该分支)
quota_sentinel_tick(){ :; }           # 额度哨兵惰性化(不读真仪表盘)
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
# #136/#137:wd_loop 启动即读 TABLE mtime、记 gen 文件;沙盒里给空表与沙盒 EV_DIR(set -u 下缺它们宿主会静默退出)
#   ⚠️ guard 模式在独立子 bash 里 source 本文件,TMPD 不在其环境(set -u 下裸 $TMPD 即死)⇒ 自备沙盒目录
_SB="${TMPD:-$(mktemp -d)}"; TABLE="$_SB/table.md"; : > "$TABLE"; EV_DIR="$_SB/ev"; mkdir -p "$EV_DIR"; EV_PENDING="$EV_DIR/pending"; RELAY_OUTBOX="$EV_DIR/outbox"
DISPATCH_KEEPALIVE_OFF="${DISPATCH_KEEPALIVE_OFF:-$_SB/keepalive.off}"   # 顶层变量不被 fns.sh 抽取 ⇒ 测试侧补齐(同 CLAUDE_LAUNCHER);必须排在 _SB 之后,set -u 下引用未定义变量当场死
ev_next_ready(){ :; }
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
unset LAIXIN_BOARD_SRC LAIXIN_WINDOW 2>/dev/null || true   # 外部环境不得污染来源判定

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
  guard)   # 真双中继:tmux 外有会话名 relay 的 claude 会话 ⇒ 必拦(2026-08-23 守卫改按身份判别;常态拓扑的 outside=2 不再是拦的理由)
    rc=0
    out="$(bash -c '
      set -euo pipefail
      source "'"$TMPD"'/fns.sh"
      source "'"$TMPD"'/stubs.sh"
      rival_relay_sessions(){ printf "99999 relay\n"; }
      BOARD_F=/dev/null; HEADLESS_SETTINGS=/dev/null; RELAY_ENABLED=/dev/null; WD_LOG=/dev/null
      cmd_relay --fresh' 2>&1)" || rc=$?
    echo "GUARD_RC=$rc"
    echo "$out"
    ;;
  guard-ok)   # 常态拓扑:tmux 外 2 个会话(方案窗口+11B 归口)但无一名为 relay ⇒ 守卫放行,死因只会是沙盒起不了真 claude(启动超时),⛔ 起窗中止
    rc=0
    out="$(bash -c '
      set -euo pipefail
      source "'"$TMPD"'/fns.sh"
      source "'"$TMPD"'/stubs.sh"
      rival_relay_sessions(){ :; }
      BOARD_F=/dev/null; HEADLESS_SETTINGS=/dev/null; RELAY_ENABLED=/dev/null; WD_LOG=/dev/null
      cmd_relay --fresh' 2>&1)" || rc=$?
    echo "GUARD_RC=$rc"
    echo "$out"
    ;;
  manual-src)
    vwait_ready(){ return 0; }   # 就绪成功 ⇒ 走到「起窗成功」的 board 条目
    sleep(){ :; }                # 成功路径的 sleep 全旁路(含 15s 验尸子 shell,不留孤儿不拖慢)
    cmd_relay --fresh --force-rival >/dev/null 2>&1 || echo "MANUAL_RC=$?"
    LAIXIN_WINDOW="方案窗口" cmd_relay --fresh --force-rival >/dev/null 2>&1 || echo "MANUAL2_RC=$?"
    echo "--- board ---"; cat "$BOARD_F" 2>/dev/null || echo "(空)"
    ;;
  fuelgap)
    relay_enabled(){ return 1; }
    loop_reload_due(){ return 1; }
    lane_busy(){ return 1; }
    # #186(2026-08-29):夹具须带轨列三格——真实 stats 自 6b29398 起就输出它们。
    #   ⛔ 停在旧四字段:那会让本条一直跑**降级路径**,而降级路径与正常路径的日志/判据都不同,
    #   于是「测的是哪条路」和「口径对不对」在绿灯面同形。降级路径由 #186 降级向那条专测。
    cmd_stats(){ printf 'ready=0 selfwrite=0 design=2 pending=0 short=0 selfwrite_product=0 selfwrite_tool=0 selfwrite_other=0\n'; }
    wd_nudge(){ printf '%s\n' "$1" >> "$TMPD/nudge.txt"; }
    export WD_INTERVAL=1
    wd_loop >/dev/null 2>&1 &
    WPID=$!
    sleep 3
    kill "$WPID" 2>/dev/null || true
    wait "$WPID" 2>/dev/null || true
    fuelgap_count="$(grep -c '料断档:缺设计 2 件' "$BOARD_F" 2>/dev/null || true)"
    nudge_count=0
    if [ -f "$TMPD/nudge.txt" ]; then nudge_count="$(wc -l < "$TMPD/nudge.txt" | tr -d ' ')"; fi
    echo "FUELGAP_COUNT=$fuelgap_count"
    echo "NUDGE_COUNT=$nudge_count"
    echo "--- watchdog ---"; cat "$WD_LOG" 2>/dev/null || echo "(空)"
    echo "--- nudge ---"; cat "$TMPD/nudge.txt" 2>/dev/null || echo "(空)"
    ;;
  ka-hold)   # P0(2026-08-28):保活关闭态 ⇒ 对派工席完全惰性(零拉起零告警),且关闭条按状态转移只出声一次
    relay_enabled(){ return 1; }
    loop_reload_due(){ return 1; }
    dispatch_alive(){ return 1; }          # 派工席死:没有闸门时它每拍都会被拉起(这正是回退后的行为)
    cmd_dispatch(){ echo call >> "$TMPD/calls.txt"; }
    : > "$DISPATCH_KEEPALIVE_OFF"          # 奉令关闭标记在
    export WD_INTERVAL=1
    wd_loop >/dev/null 2>&1 &
    WPID=$!
    sleep 4
    kill "$WPID" 2>/dev/null || true; wait "$WPID" 2>/dev/null || true
    calls=0; [ -f "$TMPD/calls.txt" ] && calls="$(wc -l < "$TMPD/calls.txt" | tr -d ' ')"
    echo "DISPATCH_CALLS=$calls"
    echo "HOLD_BOARD_COUNT=$(grep -c '派工席保活已关闭' "$BOARD_F" 2>/dev/null || true)"
    echo "NOTIN_BOARD_COUNT=$(grep -c '派工窗口不在' "$BOARD_F" 2>/dev/null || true)"
    echo "--- board ---"; cat "$BOARD_F" 2>/dev/null || echo "(空)"
    ;;
  ka-restore)   # P0:抑制 ⛔ 把自愈整个打死——运行中清标记后,意外死亡必须重新被拉起
    relay_enabled(){ return 1; }
    loop_reload_due(){ return 1; }
    dispatch_alive(){ return 1; }
    cmd_dispatch(){ echo call >> "$TMPD/calls.txt"; }
    : > "$DISPATCH_KEEPALIVE_OFF"
    export WD_INTERVAL=1
    wd_loop >/dev/null 2>&1 &
    WPID=$!
    sleep 3
    held=0; [ -f "$TMPD/calls.txt" ] && held="$(wc -l < "$TMPD/calls.txt" | tr -d ' ')"
    rm -f "$DISPATCH_KEEPALIVE_OFF"        # 运行中恢复保活(等同 laixin-lane keepalive on)
    sleep 3
    kill "$WPID" 2>/dev/null || true; wait "$WPID" 2>/dev/null || true
    after=0; [ -f "$TMPD/calls.txt" ] && after="$(wc -l < "$TMPD/calls.txt" | tr -d ' ')"
    echo "CALLS_HELD=$held"
    echo "CALLS_AFTER=$after"
    echo "RESTORE_BOARD_COUNT=$(grep -c '派工席保活已恢复' "$BOARD_F" 2>/dev/null || true)"
    echo "--- board ---"; cat "$BOARD_F" 2>/dev/null || echo "(空)"
    ;;
  ka-capped)   # P0:单事故单告警——上限=1,跑 ≥4 拍;达上限告警必须**恰 1 条**(回退成每拍一条即 ≥3,变红)
    relay_enabled(){ return 1; }
    loop_reload_due(){ return 1; }
    dispatch_alive(){ return 1; }
    cmd_dispatch(){ echo call >> "$TMPD/calls.txt"; }
    rm -f "$DISPATCH_KEEPALIVE_OFF"
    export WD_INTERVAL=1 WD_MAX_RESTART=1
    wd_loop >/dev/null 2>&1 &
    WPID=$!
    sleep 6
    kill "$WPID" 2>/dev/null || true; wait "$WPID" 2>/dev/null || true
    echo "CAPPED_BOARD_COUNT=$(grep -c '停止自动重起等人工介入' "$BOARD_F" 2>/dev/null || true)"
    echo "CAPPED_LOG_COUNT=$(grep -c '已达重起上限' "$WD_LOG" 2>/dev/null || true)"
    echo "--- board ---"; cat "$BOARD_F" 2>/dev/null || echo "(空)"
    ;;
  *) echo "未知 mode:$MODE" >&2; exit 2 ;;
esac
