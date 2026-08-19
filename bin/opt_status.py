#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""opt-status(复盘页 #33)——按节独立统计优化条目销号率。

立项根因就是**统计陷阱本身**(2026-08-19 09:4x 创始人追问「优化是不是全做完在跑了」时中继实撞):
中继按行首数字扫全页统计,而复盘页存在**多套编号命名空间**——§三 主清单 1-33 与 §三之二 对策 11-16、
§五 待提升 17-20 **同号不同事**(#12 主清单=对话框签名 ✅ / §三之二=双窗口分工;#17 主清单=Codex
配置剪裁 ✅ / §五=裁定预检)。`grep '^12\\.'` 只命中首个 ⇒ **把已销号的读成未销号、把两套账混成一套**,
同时高估未决数与低估完成数;§四 经验原则与 §五之二 跟踪数(编号列表但**不是优化项**)也被误收。

所以本工具自己绝不许重蹈它要解决的毛病,设计遵 AGENTS.md 检查器三约束:

①**状态感知**:销号形态是 `~~标题~~ ✅ **已实施/已裁…**`,而判据**取「标题划线」⛔ 取「行内含 ✅」**。
  两个实撞理由(都是首版用「行内含 ✅」当场撞出来的):
   - **✅ 会出现在叙述里**:#33 自己那行就有三个 ✅——两个在「#12 主清单=对话框签名 ✅ / #17 …
     Codex 配置剪裁 ✅」这类**转述别的条目状态**的句子里,一个在代码格 `~~标题~~ ✅` 的举例里。
     裸数 ✅ 会把「正在讨论销号形态的条目」判成已销号(而它恰恰是本工具的立项条目本身);
   - **✅ 也用于标子项完成**:#6/#7/#17 都是「某个子件 ✅ 已定稿/已实施」而条目整体未闭,
     标题没划线。裸数 ✅ 会把它们全判成已销号 ⇒ **完成度虚高**,正是本条要防的方向。
  ⇒ 三档:**销号**=标题划线;**⚖️半销**=没划线但行内有 ✅(子件已完成,条目未闭)——**单列一档
  ⛔ 并进销号**;**未销**=两者皆无。含糊的那一档必须自己有名字,⛔ 就近归进好看的那一档。

②**失效必须降级,⛔ 反向**:本工具最危险的失效是**静默漏节/漏条** —— 漏掉的节越多,报告越像
  「优化都做完了」,恰好指向它要防的风险(高估完成度)。⇒ 三条硬规矩:
   - 节名白/黑名单**双向显式**:既不在白名单也不在黑名单的节 = **未知节**,大声报 + 退非零,
     ⛔ 默默跳过(默默跳过 = 新开的优化队列永远不进统计,而报告照样绿);
   - 白名单节解析出 0 条 ⇒ 显 `?` **不显 0**,并退非零(「一条都没有」与「没解析出来」外观相同,
     把后者读成前者就是空报告冒充达标);
   - 节内长得像条目却解析不了的行,单独列出 + 退非零,⛔ 悄悄丢掉。

③**噪声与目标行为同向**:未销条目列名(编号+标题首 40 字)不折叠——「把条目写详细」是被鼓励的行为,
  不能让它增加本工具的噪音;⛔ 因未销数>0 就改退出码(**报告非闸门**:统计是给人看的数,不是闸)。

⚠️ 与 #9「并发追加撞号」不同族:那是同一队列两窗口取同号(时序问题),本条是**多套队列共用一个
数字命名空间**(结构问题),重排编号治不了 ⇒ 只能按节独立统计。
"""
import os
import re
import sys

# ── 节配置(显式白/黑名单,⛔ 用「行首是数字」之类的形态判据推断) ──────────────
# key = 节标题去掉括注后的前缀(括注常被编辑,标题本体稳定);标题被改名 ⇒ 落进「未知节」大声报,
#       方向对(宁可报不知道,不可默默漏一整队)。
# start = 节内起算锚:该节在条目之前还有**别的**编号列表时必填。
#         实例:§三之二 前半是「数据先行」的根因 1-3(不是优化项),对策 11-16 在 `**对策(` 之后;
#         没有锚就会把根因 1-3 混进优化队列——正是本条要防的「非优化项混在里面」。
WHITE = [
    ("三、优化推动清单", None),
    ("三之二、「进度变慢」诊断", "**对策("),
    ("五、新拓扑首日复盘", "**待提升("),
    ("六、方案窗口第十任收班盘点", "**未消化摩擦 → 候选("),
    ("七、中继窗口入流水线托管", None),
    ("「145 行事件」四条", None),
]
BLACK = [
    "(页首)",                        # front-matter + H1,无条目
    "一、运行数据",
    "二、本轮固化的机制",
    "四、经验原则",                   # 编号列表但是经验原则,不是优化项
    "五、中继窗口 pingxia-79 收班盘点",  # 「摩擦 Top3」编号 1-3,不是优化项
    "五之二、成色校准与下一期跟踪数",     # 「跟踪数」编号 1-3,不是优化项
]

# 条目行:行首编号 + 可选 `-bis` + 可选括注 + `.` + 空白。
# `-bis` 与括注**必须认**:实例 `30-bis(登记位次序号 31 之实,置此防与 §六 序号再撞). **events…`
# 不是标准有序列表项;认不出就会被悄悄丢掉,而丢掉的恰好是「未销」的那一条(漏报方向错)。
ENTRY = re.compile(r"^(?P<num>\d{1,3}(?:-bis)?)(?:[（(][^）)]*[）)])?[.、]\s")
# 「长得像条目却没解析成功」的兜底探针:行首是数字但 ENTRY 不匹配 ⇒ 单独列出,⛔ 静默丢弃
SUSPECT = re.compile(r"^\d")
HEADING = re.compile(r"^(#{2,3})\s+(.*)$")
# 销号判据:编号之后(可夹 ⭐/🔴/⚖️ 等标记)紧跟删除线 ⇒ 标题已划线 = 已销号
STRUCK = re.compile(r"^\d{1,3}(?:-bis)?(?:[（(][^）)]*[）)])?[.、]\s*[⭐🔴⚖️✅\s]*~~")


def strip_paren(title):
    """去掉标题里第一个括注及其后内容,取稳定的标题本体。"""
    for ch in ("(", "("):
        i = title.find(ch)
        if i > 0:
            title = title[:i]
    return title.strip()


def clean_title(text):
    """条目标题:剥掉星标/删除线/加粗记号,保留原文用字(⛔ 连删除线内的原文一起吃掉——
    划线=已销号的案底,标题本体正在里面)。"""
    text = text.strip()
    text = re.sub(r"^[⭐🔴⚖️✅~*\s]+", "", text)
    text = text.replace("~~", "").replace("**", "")
    return text.strip()


def main():
    page = os.environ.get("LX_OPT_PAGE") or ""
    argv = sys.argv[1:]
    if "--page" in argv:
        page = argv[argv.index("--page") + 1]
    if not page:
        print("opt-status: 数据源失效自曝——没有页面路径(--page 或 LX_OPT_PAGE)", file=sys.stderr)
        return 2
    if not os.path.isfile(page):
        print(f"opt-status: 数据源失效自曝——复盘页读不到:{page}", file=sys.stderr)
        return 2
    try:
        lines = open(page, encoding="utf-8").read().splitlines()
    except OSError as e:                                    # 读不了要自曝,⛔ 静默出空报告
        print(f"opt-status: 数据源失效自曝——复盘页读取失败:{e}", file=sys.stderr)
        return 2

    # ── 按 ##/### 切节。### 也切:§五之二 是 ### 且挂在 §五 之下,不切就会把它的
    #    「跟踪数 1-3」并进 §五 的优化队列(非优化项混入,本条立项根因之二)。 ──
    sections, cur = [], ("(页首)", [])
    for ln in lines:
        m = HEADING.match(ln)
        if m:
            sections.append(cur)
            cur = (strip_paren(m.group(2)), [])
        else:
            cur[1].append(ln)
    sections.append(cur)

    white = dict(WHITE)
    rows, unknown, broken = [], [], []
    for name, body in sections:
        if name in BLACK:
            continue
        if name not in white:
            unknown.append(name)                            # ⛔ 默默跳过
            continue
        start = white[name]
        started = start is None
        total = sold = 0
        half, unsold = [], []
        for ln in body:
            if not started:
                if start and ln.startswith(start):
                    started = True
                continue
            m = ENTRY.match(ln)
            if not m:
                if SUSPECT.match(ln):
                    broken.append((name, ln[:60]))
                continue
            total += 1
            item = (m.group("num"), clean_title(ln[m.end():])[:40])
            if STRUCK.match(ln):        # 标题划线 = 销号(页面自己的案底约定)
                sold += 1
            elif "✅" in ln:            # 有 ✅ 没划线 = 子件完成、条目未闭 ⇒ ⛔ 并进销号
                half.append(item)
            else:
                unsold.append(item)
        rows.append((name, total, sold, half, unsold))

    print(f"优化完成度(源={page})")
    print("⚠️ 按节独立统计 ⛔ 全文按行首数字合并——各节是**各自的编号命名空间**,同号不同事。")
    print("   销号=标题划线;⚖️半销=有 ✅ 但标题没划线(子件完成、条目未闭)⛔ 并进销号;未销=两者皆无。")
    print()
    g_total = g_sold = g_half = 0
    degraded = False
    for name, total, sold, half, unsold in rows:
        if total == 0:
            # 「一条都没有」与「没解析出来」外观相同 ⇒ 显 ? 不显 0,并退非零
            print(f"{name}  共 ? / 销号 ? / 半销 ? / 未销 ?   ⚠️ 白名单节解析出 0 条——判为解析失效,⛔ 当作「全销号」")
            degraded = True
            continue
        g_total += total
        g_sold += sold
        g_half += len(half)
        print(f"{name}  共 {total} / 销号 {sold} / 半销 {len(half)} / 未销 {len(unsold)}")
        for num, title in half:
            print(f"    ⚖️ #{num}  {title}")
        for num, title in unsold:
            print(f"    #{num}  {title}")
    print()
    if rows and not degraded:
        print(f"合计  共 {g_total} / 销号 {g_sold} / 半销 {g_half} / 未销 {g_total - g_sold - g_half}"
              "   (⚠️ 跨节编号不可比,合计只作总量参考)")
    else:
        print("合计  ?  ——有节解析失效,合计不可信(⛔ 拿部分数冒充全量)")

    rc = 0
    if unknown:
        print()
        print("⛔ 未知节(既不在白名单也不在黑名单)——**它们没有进统计**,上面的数是不全的:")
        for n in unknown:
            print(f"    {n}")
        print("   新开的节请显式登记进 bin/opt_status.py 的 WHITE 或 BLACK;")
        print("   ⛔ 默默跳过:漏掉的节越多报告越像「优化都做完了」,失效方向恰好指向它要防的风险。")
        rc = 2
    if broken:
        print()
        print("⛔ 疑似条目但解析不了(⛔ 静默丢弃——丢掉的可能正是未销那条):")
        for n, s in broken:
            print(f"    [{n}] {s}")
        rc = 2
    if degraded:
        rc = 2
    # ⛔ 未销数不改退出码:**报告非闸门**(与 #28 copy-audit 同规矩)。
    return rc


if __name__ == "__main__":
    sys.exit(main())
