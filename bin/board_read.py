#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""board_read —— 看板读取的**唯一入口**:切逻辑行 + 粘行检出。

**⛔ 再长第二份**(2026-08-29 立)。任何要读看板的工具 —— `replay-six` · M9 四域组装器 ·
后来者 —— 一律 `import board_read` 走 `read_board()`,⛔ 自己再写一遍切行。

理由是这个盲区**静默**:切错了不抛错、不少行、不报警,只是让被粘在后面的那条事件
**从此不存在**。一处切行 ⇒ 修一次就全好;两处切行 ⇒ 修了一处,另一处继续无声吞事件,
而且没有任何一处会露出破绽。

## 两件事

1. **切逻辑行**:以 `| MM-DD HH:MM |` 开头的物理行起一条,其后不匹配的物理行折进同一条。
   ⛔ 按物理换行切 —— 2026-08-27 实撞:一条 log 正文里被注入了 79 个物理换行,
   按物理行切会把一条拆成 80 条并让行号全错。

2. **粘行检出**:同一物理行内出现**第 2 个及以后**的 `| MM-DD HH:MM |` 行首模式 ⇒ 报缺口 Q,
   并把各截**逐字**列出。

   成因(配合问题第 17 例,2026-08-29 实撞两次):`board()` 只保证自己**行尾**有换行,
   不保证自己写在**新行的开头** —— 任何直写看板而不留尾换行的动作,都会让**下一个**写入者
   的整条被粘到自己行尾。伤害落在下一个写入者身上,⛔ 落在肇事者身上。
   落盘形态(真机复现):`… 受害行正文 |` + `| 08-29 13:56 | 沙盒A | 正文 |` ⇒ 中间出现 `||`。
   当刻行为(修前实测):逻辑行数 2(粘行读成 1)· 被粘的那条在 replay-six 眼里**不存在**。

## ⛔ 自动拆(硬边界)

检出**只报不拆**:拆是**写盘动作**,归看板维护者。内存里也**⛔ 拆** —— 拆了就得给后半截一个
文件里并不存在的行号,而看板行号是 `--pred-line` / `--merge-line` 要拿去对文件的锚,
造一个对不上的行号等于造事实。所以:切行行为**一字不变**(粘行仍读成一条),只是**响亮地报**。

## 阴性(判据要能区分成败)

- 粘行 ⇒ 报缺口 Q **且**各截逐字可见;
- 正常行(含正文折了物理换行的多行条)⇒ **不报**;
- 末行无尾换行 ⇒ **不误报**(它是**下一次**粘行的火种,不是粘行本身;根治在 `board()` 写前补换行)。
"""

import io
import re
from datetime import datetime

# 行首(锚定):一条逻辑行由它起头
ROW_RE = re.compile(r"^\|\s*(\d{2})-(\d{2})\s+(\d{2}):(\d{2})\s*\|\s*([^|]*?)\s*\|\s*(.*)$")
# 行首模式(不锚定):用来在**行内**找第 2 个及以后的行首 ⇒ 粘行
ROW_HEAD_RE = re.compile(r"\|\s*\d{2}-\d{2}\s+\d{2}:\d{2}\s*\|")
TS_RE = re.compile(r"(20\d{2})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})")

# 缺口代号 Q(A–P 见 replay-six GAPS;Q 由本模块定义,读板者共用同一个码)
GLUE_GAP_CODE = "Q"
GLUE_GAP_DESC = ("看板物理行被粘(上一条无尾换行 ⇒ 下一条整条追加到它行尾),"
                 "被粘的那条对读板者**不存在**")


class BoardReadError(Exception):
    """看板读不到(路径/权限/IO)。调用方可给 on_error 改成自己的 die。"""


class Row(object):
    """一条看板逻辑行。"""

    __slots__ = ("lineno", "dt", "src", "body")

    def __init__(self, lineno, dt, src, body):
        self.lineno = lineno
        self.dt = dt          # datetime,分钟精度
        self.src = src        # 来源列
        self.body = body      # 正文(逻辑行,已把物理换行折进来)

    def sec(self):
        """条正文内与本行同日的首个秒级时刻(口径稿 §〇 规则 a)。"""
        for m in TS_RE.finditer(self.body):
            y, mo, d, hh, mm, ss = (int(x) for x in m.groups())
            if (mo, d) == (self.dt.month, self.dt.day):
                return datetime(y, mo, d, hh, mm, ss)
        return None


class Glue(object):
    """一处粘行:一个物理行里挤了 n 条(n ≥ 2)。segs 为**逐字**各截。"""

    __slots__ = ("lineno", "segs", "cuts")

    def __init__(self, lineno, segs, cuts):
        self.lineno = lineno
        self.segs = segs      # list[str],逐字,⛔ 截断
        self.cuts = cuts      # list[int],各粘接点在物理行内的字符位置


class Board(object):
    """读板结果。

    **故意不做成 list**(⛔ `__iter__` / `__len__`):调用方必须显式写 `.rows`,
    于是 `.glued` 就在同一个对象上、同一行代码的视线里 —— 新工具(M9)想继承这个盲区,
    得先主动把 `.glued` 视而不见,⛔ 无意识地漏掉。
    """

    __slots__ = ("rows", "glued", "path")

    def __init__(self, rows, glued, path):
        self.rows = rows      # list[Row]
        self.glued = glued    # list[Glue];空 = 阴性
        self.path = path

    def glue_report(self):
        """粘行报告(给人看的那一段)。无粘行返回 []。⛔ 在这里写盘。"""
        if not self.glued:
            return []
        out = ["== ⚠️ 看板粘行(缺口 %s):%d 处 —— ⛔ 自动拆,拆归看板维护者 =="
               % (GLUE_GAP_CODE, len(self.glued)),
               "   %s" % GLUE_GAP_DESC]
        for g in self.glued:
            n = len(g.segs)
            out.append("  物理行 %d 被粘成 %d 截;第 2 截起对读板者**不存在**"
                       "(已被折进第 1 截的正文里):" % (g.lineno, n))
            for i, seg in enumerate(g.segs, 1):
                out.append("    [%d/%d] 逐字:%s" % (i, n, seg))
            out.append("    判据:同一物理行内第 2 个及以后的 `| MM-DD HH:MM |` 行首模式,"
                       "粘接点字符位 %s" % ("、".join(str(c) for c in g.cuts)))
        out.append("  修法:在每个 [k≥2] 截**前**补一个换行,由看板维护者落盘"
                   "(本工具只读 ⛔ 写盘);根治在写方 `board()` 写前补换行。")
        return out


def find_glue(line, lineno):
    """在一个**物理行**里找粘行。返回 Glue 或 None。

    判据 = 行首模式在 `start > 0` 处再次出现。⛔ 只扫「本身就是行首的行」——
    火种(无尾换行的那条)可能是某条多行正文的**续行**,粘上来的事件一样静默消失,
    形态与后果完全相同。真库全量(12,9xx 行)实测该判据假阳性 0。
    """
    cuts = [m.start() for m in ROW_HEAD_RE.finditer(line) if m.start() > 0]
    if not cuts:
        return None
    segs = []
    prev = 0
    for c in cuts:
        segs.append(line[prev:c])
        prev = c
    segs.append(line[prev:])
    return Glue(lineno, segs, cuts)


def read_board(path, year=None, on_error=None):
    """读看板 ⇒ Board(rows, glued, path)。

    on_error:可选 callable(msg);不给则抛 BoardReadError。
    """
    if year is None:
        year = datetime.now().year
    try:
        with io.open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().split("\n")
    except IOError as e:
        msg = "看板读不到:%s(%s)" % (path, e)
        if on_error is not None:
            return on_error(msg)
        raise BoardReadError(msg)

    rows = []
    glued = []
    cur = None
    for i, ln in enumerate(lines, 1):
        g = find_glue(ln, i)
        if g is not None:
            glued.append(g)
        m = ROW_RE.match(ln)
        if m:
            mo, d, hh, mm, src, body = m.groups()
            cur = Row(i, datetime(year, int(mo), int(d), int(hh), int(mm)), src, body)
            rows.append(cur)
        elif cur is not None:
            cur.body += "\n" + ln
    return Board(rows, glued, path)

# ── 「⛔ 再长第二份」的机器闸(⛔ 靠注释自觉)────────────────────────────────────────
# 本模块与调用方放在**同一个目录**里(开发树 = bin/,发布态 = <hash>/,由 release 的
# helper 全集 + 兄弟脚本随行保证)。于是「有没有人另起炉灶自己切看板行」这件事可以**扫出来**:
# 同一行里既有 re.compile 又有 `MM-DD` + `HH:MM` 两段模式的,就是在自造行首正则。
# 判据在真 bin/(12 个文件)实测:只命中本文件自身,假阳性 0。
_SNIFF_NEEDLE = r"d\{2\}\)?\)?-\(?\\?d\{2\}.*d\{2\}\)?:\(?\\?d\{2\}"
_SNIFF = re.compile(_SNIFF_NEEDLE)
_SOLE_SPLITTER = "board_read.py"          # 唯一允许定义行首正则的文件


def find_second_splitter(dirpath):
    """扫同目录,找**第二份**切看板行的实现。返回 [(文件名, 行号, 该行)];空 = 阴性。

    给 replay-six / M9 的自测当闸:新工具想读看板,只有 import 本模块一条路;
    自己长一份 ⇒ 自测当场变红,⛔ 等它在某个夜里静默吞掉一条事件才被发现。
    """
    import os
    out = []
    try:
        names = sorted(os.listdir(dirpath))
    except OSError:
        return out
    for fn in names:
        if fn == _SOLE_SPLITTER:
            continue
        fp = os.path.join(dirpath, fn)
        if not os.path.isfile(fp):
            continue
        try:
            with io.open(fp, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except IOError:
            continue
        for i, ln in enumerate(text.split("\n"), 1):
            if "re.compile" in ln and _SNIFF.search(ln):
                out.append((fn, i, ln.strip()))
    return out
