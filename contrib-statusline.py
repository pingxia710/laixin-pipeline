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
import sys

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
        try:
            _am = (os.environ.get("LAIXIN_CTX_ABS_MIN") or "").strip()
            if not _am:
                _p = os.path.expanduser("~/.laixin-lane-switch/ctx-abs-min")
                if os.path.isfile(_p): _am = open(_p).read().strip()
            if _am.isdigit() and int(_am) > 0 and isinstance(used, (int, float)) and isinstance(size, (int, float)) and size - used < int(_am):
                color, tail = RED, f"  ⛔ 绝对余量 {int(size-used):,} < 下限 {int(_am):,}:交班"
        except Exception:
            pass
        detail = f" ({human(used)}/{human(size)})" if used and size else ""
        parts.append(f"{color}{bar} {pct:.0f}%{R}{DIM}{detail}{R}{color}{tail}{R}")
    else:
        # ⛔ 关键:拿不到就说拿不到,绝不填 0
        parts.append(f"{YELLOW}ctx ?{R}{DIM}(本次输入无 context_window 字段){R}")

    cost = (d.get("cost") or {}).get("total_cost_usd")
    if isinstance(cost, (int, float)) and cost > 0:
        parts.append(f"{DIM}${cost:.2f}{R}")

    print(f"{DIM} · {R}".join(parts))


if __name__ == "__main__":
    main()
