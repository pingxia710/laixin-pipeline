#!/usr/bin/env python3
"""Claude Code 状态栏:实时显示上下文占比,不依赖模型的自我报告。

起因(2026-08-13):方案窗口两次向创始人报"上下文占比",两次都是**估的**,
第二次还声称"这次是实测读数"——实测 41.7% 时报 66%,实测 52.1% 时报 68.2%。
⇒ 与其要求模型自律,不如让这个数字**直接显示在人的屏幕上,不经过模型**。

数据来源:Claude Code 通过 stdin 传入的 `context_window.used_percentage`,
由 Claude Code 自己计算,**不是解析 transcript 猜出来的**。

⚠️ 设计原则(来自同一天的教训):**兜底不许静默**。
拿不到占比时显示 `ctx ?`,⛔ 绝不显示 `0%` —— 否则"真的是 0%"和"根本没拿到"
在屏幕上长得一模一样,而这正是今天反复踩的那一族错误。
"""
import json
import os
import sys
import time

# ── 交班闸门(与 laixin-lane ctx 保持一致;改这里要同步改那边)────────────
GATE_HARD = 75   # 硬口:继任必须已起；前任继续排空在手
GATE_WARN = 70   # 起交接:新活归继任，前任不弃在手

R = "\033[0m"
DIM = "\033[2m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[1;31m"


def human(n):
    if not isinstance(n, (int, float)):
        return "?"
    if n >= 1_000_000:
        return f"{n / 1_000_000:.2f}".rstrip("0").rstrip(".") + "M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(int(n))



# ── 2.4 M-c:席位态对**所有窗**可见 ───────────────────────────────────────────
# 病灶(2026-08-29 12:40→13:29):派工席过硬口且无继任,**外窗没有任何输入面**——方案窗口
#   (唯一面对创始人的窗口)不知道派工席空着,直到创始人来问。dmsg 只到派工席(正是缺的那一席),
#   状态栏只显本窗自己 ⇒ 谁都看得见自己的 ctx,没人看得见流水线的心脏停了。
# ⇒ 席位态文件由看门狗每拍写,**每个窗**的状态栏都读它。
#
# 🔴 三条失效方向,逐条朝安全侧(本文件 docstring「兜底不许静默」的同一条纪律):
#   ① 文件**不存在** ⇒ 不显示任何东西。理由=这台机器上流水线没在跑(本状态栏也装在非流水线窗口),
#      对它们喊「派工席未判」是纯噪声;⛔ 与「读数陈旧」混为一谈。
#   ② 文件在但**读数陈旧** ⇒ 显式报陈旧秒数。**看门狗死了**正是这个形态,而「态一直是在班」与
#      「没人再更新这个态」在屏幕上本来完全同形——那是本件要防的第二种假绿。
#   ③ 态=在班 ⇒ 仍留一个**暗色对勾**(#50:「没有报警」与「没有这项检查」不得同形)。
#   ④ 奉令关闭保活(keepalive=off)⇒ 暗色标注 ⛔ 红:关闭态下红是**不可行动的**,而不可行动的红
#      会训练人忽略红(与 0.8 段「零告警」同口径)。
def seat_line():
    """→ 状态栏片段(str)或 None。⛔ 裸 except —— 2026-08-29 实撞:裸 except 把
    「配置没设」(正常)与「代码坏了」(事故)吞成同一个结果,那道闸一次都没执行过。"""
    path = os.environ.get("LAIXIN_SEAT_STATE") or os.path.expanduser(
        "~/.laixin-events.d/seat-state.dispatch")
    try:
        with open(path, encoding="utf-8") as fh:
            kv = dict(l.rstrip("\n").split("=", 1) for l in fh if "=" in l)
    except (OSError, ValueError):
        return None                      # ① 不存在/不可读/格式坏:本机没跑流水线,⛔ 加噪
    # ts 缺失/不是数 与 ts 太旧 是**两回事**:前者=文件坏,后者=看门狗停了,处置方向不同。
    #   ⛔ 合成一条——把缺失当 0 会算出十几亿秒,那个数长得像**计算 bug** 而不是坏文件,
    #   读的人会去追错方向(本文件 2026-08-29 刚因「两种原因吞成同一个结果」出过事)。
    raw_ts = (kv.get("ts") or "").strip()
    if not raw_ts.isdigit():
        return f"{YELLOW}派工席 态文件不可解析(缺 ts;⛔ 当健康){R}"
    state = kv.get("state") or "?"
    age = int(time.time()) - int(raw_ts)
    if age > int(os.environ.get("LAIXIN_SEAT_STALE_SECS") or 300):
        return f"{YELLOW}派工席 读数陈旧 {age}s(看门狗可能没在跑){R}"   # ②
    if (kv.get("keepalive") or "on") == "off":
        return f"{DIM}派工席 {state}(保活已关闭){R}"                                        # ④
    if state == "在班":
        return f"{DIM}派工席 ✓{R}"                                                          # ③
    t = kv.get("t") or "?"
    try:
        t = f"{int(t) // 60}m"
    except (TypeError, ValueError):
        pass
    mism = "  ⚠️ 三路不一致" if (kv.get("mismatch") or "").strip() else ""
    return f"{RED}派工席:{state} {t}{R}{RED}{mism}{R}"


# ── 2.4b:发布链一致性对**所有窗**可见 ─────────────────────────────────────────────
# 与 seat_line 同族、同纪律:文件不存在 ⇒ 零输出(本机没跑流水线,⛔ 加噪);读数陈旧 ⇒ 显式报;
#   ok ⇒ 留暗色通过态标记(#50:「没有报警」与「没有这项检查」不得同形);drift ⇒ 红。
# 🔴 它存在的理由:2.4b 把 5 条真环境断言从 tests 迁进 doctor/看门狗,而 doctor 要人去跑。
#   状态栏是**唯一不需要谁想起来**的可见面 —— 少了它,这道闸就只剩「但愿有人跑 doctor」。
def release_line():
    path = os.environ.get("LAIXIN_RELEASE_STATE") or os.path.expanduser(
        "~/.laixin-events.d/release-chain.state")
    try:
        with open(path, encoding="utf-8") as fh:
            kv = dict(l.rstrip("\n").split("=", 1) for l in fh if "=" in l)
    except (OSError, ValueError):
        return None
    raw_ts = (kv.get("ts") or "").strip()
    if not raw_ts.isdigit():
        return f"{YELLOW}发布链 态文件不可解析(缺 ts;⛔ 当健康){R}"
    age = int(time.time()) - int(raw_ts)
    # 陈旧线按「每 N 拍一次」放宽:默认 60s×10×3
    if age > int(os.environ.get("LAIXIN_RELEASE_STALE_SECS") or 1800):
        return f"{YELLOW}发布链 读数陈旧 {age}s(看门狗可能没在跑){R}"
    v = kv.get("verdict") or "?"
    if v == "ok":
        return f"{DIM}发布链 ✓{R}"
    if v == "drift":
        return f"{RED}🔴 发布链脱节:{(kv.get('why') or '').strip()[:60]}{R}"
    return f"{YELLOW}发布链 未判:{(kv.get('why') or '').strip()[:50]}{R}"

def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        # 连 JSON 都没拿到:显式说坏了,不装作正常
        print(f"{DIM}statusline: 输入不是合法 JSON{R}")
        return

    parts = []

    model = (d.get("model") or {}).get("display_name")
    if model:
        parts.append(f"{DIM}{model}{R}")

    # 多窗口并存时,认得出"这是哪个会话"本身就是价值
    # (laixin-lane ctx 曾因 mtime 排序取错会话,判据是身份不是时间)
    sid = d.get("session_name") or (d.get("session_id") or "")[:8]
    if sid:
        parts.append(f"{DIM}{sid}{R}")

    cw = d.get("context_window") or {}
    pct = cw.get("used_percentage")
    used = cw.get("total_input_tokens")
    size = cw.get("context_window_size")

    if isinstance(pct, (int, float)):
        filled = max(0, min(10, int(pct // 10)))
        bar = "▓" * filled + "░" * (10 - filled)
        if pct >= GATE_HARD:
            color, tail = RED, "  ⛔ 继任须已起；本窗只排空在手"
        elif pct >= GATE_WARN:
            color, tail = YELLOW, "  ⚠ 起交接；新活归继任"
        else:
            color, tail = GREEN, ""
        # 2026-08-23 双阈(与 bin/laixin-lane ctx_abs_min 同读单点源:env LAIXIN_CTX_ABS_MIN > ~/.laixin-lane-switch/ctx-abs-min;无值=提示态,这里不加噪)
        # 🔴 2026-08-29 实撞:本段用了 os.* 而文件只 import json/sys ⇒ 每次抛 NameError,
        #    又被下面那个裸 `except Exception: pass` **当场吞掉** ⇒ 这道闸**一次都没执行过**。
        #    后果:2026-08-23 双阈裁定「占比为主 + 绝对余量叠加为硬阈」当刻只有一阈在跑,
        #    而屏幕上「余量充足」与「这道闸根本没跑」完全同形。
        #    ⇒ 修法两半:补 import os;**把 except 收窄**——
        #      · 配置缺失 / 格式不对(OSError/ValueError)= 正常,静默;
        #      · 代码级异常(NameError/AttributeError/TypeError…)= 事故,**必须显形**。
        #    这正是本文件 docstring 自己写的「兜底不许静默」:它对 ctx 那一半做对了,
        #    对这一段做反了——把「配置没设」与「代码坏了」吞成同一个结果。
        _abs_err = ""
        try:
            _am = (os.environ.get("LAIXIN_CTX_ABS_MIN") or "").strip()
            if not _am:
                _p = os.path.expanduser("~/.laixin-lane-switch/ctx-abs-min")
                if os.path.isfile(_p): _am = open(_p).read().strip()
            if _am.isdigit() and int(_am) > 0 and isinstance(used, (int, float)) and isinstance(size, (int, float)) and size - used < int(_am):
                color, tail = RED, f"  ⛔ 绝对余量 {int(size-used):,} < 下限 {int(_am):,}:交班"
        except (OSError, ValueError):
            pass                      # 读不到开关文件 / 内容不是数字:配置态,⛔ 加噪
        except Exception as exc:      # 代码级异常:说出来 ⛔ 装作闸跑过了
            _abs_err = f"{YELLOW}绝对余量闸:读取异常({type(exc).__name__}){R}"
        detail = f" ({human(used)}/{human(size)})" if used and size else ""
        parts.append(f"{color}{bar} {pct:.0f}%{R}{DIM}{detail}{R}{color}{tail}{R}")
        if _abs_err: parts.append(_abs_err)
    else:
        # ⛔ 关键:拿不到就说拿不到,绝不填 0
        parts.append(f"{YELLOW}ctx ?{R}{DIM}(本次输入无 context_window 字段){R}")

    # 🔴 seat_line 的**代码级异常必须显形,且 ⛔ 带死整条状态栏**(2026-08-29 本片实撞:
    #    seat_line 用了 os,而 2.4a 那条「拆掉 import os」的对照绊线一跑,NameError 从这里
    #    直穿出去 ⇒ **整条状态栏一个字都不打印** —— 屏幕全空与「本窗没问题」在人眼里同形,
    #    而 ctx 闸门那半边本来是好的,被我这段连坐了)。⇒ 与绝对余量闸同款:窄捕不吞,宽捕显形。
    try:
        _seat = seat_line()
    except Exception as exc:
        _seat = f"{YELLOW}席位态:读取异常({type(exc).__name__}){R}"
    if _seat:
        parts.append(_seat)

    try:
        _rel = release_line()
    except Exception as exc:          # 同 seat_line:代码级异常显形 ⛔ 静默 ⛔ 带死整条状态栏
        _rel = f"{YELLOW}发布链:读取异常({type(exc).__name__}){R}"
    if _rel:
        parts.append(_rel)

    cost = (d.get("cost") or {}).get("total_cost_usd")
    if isinstance(cost, (int, float)) and cost > 0:
        parts.append(f"{DIM}${cost:.2f}{R}")

    print(f"{DIM} · {R}".join(parts))


if __name__ == "__main__":
    main()
