#!/usr/bin/env python3
"""copy-audit — 词表覆盖率审计(11B 优化 #28,复盘页 §六,方案窗口第十任收班盘点,创始人已批)。

动机(2026-08-18 夜班失败样本,立项依据):一任之内 5+ 次「实现先于登记」逐个撞——
`refunded` 键退化兜底串、协作页「下一步」槽 14 句 10 句零命中、审核台区题词三个只登一个、
核稿打回句硬编码、加入按钮正面句未登——每次一轮停车或请词。本工具把这类债从
「等片撞」改为「一次审计清账」:扫 copy/映射源导出项的中文字符串值,按角色归表核词表命中,
产出三列清单给方案窗口批量判读。

检查器设计三约束(AGENTS.md,新检查器必须过一遍):
① 状态感知:词表行记录了历史状态——`~~删除线~~` 是标废,引用块(`>`)是规则/案底叙述。
   命中若全部落在删除线内 ⇒ 单独归「仅删线行命中」⛔ 算正常命中(标废词还在用是另一种病,
   必须看得见);命中行若是引用块行则带「(引用块)」标注,判读归人。
② 失效降级 ⛔ 反向:数据源读不到 / 收录判别式扫到 0 文件 / 采集到 0 条中文值,一律
   自曝报错退出(exit 1),⛔ 产出一份空清单冒充「全部达标」;零命中本身不改退出码——
   本工具是审计报告不是闸门,若把零命中做成非零退出,失效面(词表措辞微调)会反向
   逼人改实现值凑匹配。
③ 噪声与目标行为同向:被鼓励的行为=「登记进词表」。登记越勤,命中越多、清单越干净——
   误报(零命中但其实无需登记,如 dev 告警/纯内部键)不随登记勤快而增长,只随
   「新增未登记文案」增长,与要治的病同向。分级输出(#15 同则,⛔ 拿误报换漏报):
   零命中≠自动缺陷,工具 ⛔ 下缺陷结论,判读权在方案窗口。

数据源与判别式:
- 来信仓一律 `git show <ref>:` 读(默认 ref=main),零 worktree 依赖,⛔ 碰业务仓工作区;
- copy/映射源收录判别式**照抄** 知识库/4-开发层/tools/laixin_consumption.py docstring
  (⛔ 另造):① glob `*-copy.ts`/`*-label.ts`/`*-badge.ts`;② 形态规则:存在顶层
  `export const X: …Record<…> = {…}` 注解映射导出。frontend/src/lib 非递归,*.ts;
- 归表(角色→词表):文件内权威声明注释(「wiki-消费者词汇表」/「wiki-供给侧词汇表」,
  consumer-copy.ts / supply-copy.ts 首行即此)> 文件名含 consumer/supply > 默认供给侧
  (status-label.ts / order-tagging.ts 等按 #28 立项口径归供给侧)。归表失效可见不静默:
  零命中时顺手核它表,plain 命中标「仅它表命中」——归错表表现为成簇它表标注,不是假绿;
- 匹配:码点级包含匹配(实现值整串 ∈ 词表某行;模板串按 `${…}` 切段,各段去首尾空白后
  须同行全命中)。⛔ 语义归一化——不匹配就进零命中给人判读。

用法:laixin-lane copy-audit [--ref R]   或独立:python3 copy_audit.py [--ref R]
环境:LX_REPO/LAIXIN_REPO(默认 ~/来信平台)、LX_KB/LAIXIN_KB(默认知识库路径)。
输出:markdown 三列清单(来源文件:键 | 实现值 | 词表命中)+ 统计,写 stdout。
"""
from __future__ import annotations

import argparse
import datetime
import os
import re
import subprocess
import sys

VERSION = "1.0.0"

# ---- 收录判别式(照抄 laixin_consumption.py,⛔ 另造) ----
MAPPING_GLOB_SUFFIXES = ("-copy.ts", "-label.ts", "-badge.ts")
RECORD_EXPORT_RE = re.compile(r"^export const \w+[^=\n]*\bRecord<", re.M)
EXPORT_RE = re.compile(r"^export (?:const|function|let|var) (\w+)")

CJK_RE = re.compile(r"[\u3400-\u9fff\uf900-\ufaff]")
STRIKE_RE = re.compile(r"~~.*?~~")
LIB_DIR = "frontend/src/lib"

CONSUMER_TABLE = "索引/wiki-消费者词汇表.md"
SUPPLY_TABLE = "索引/wiki-供给侧词汇表.md"
TABLE_NAMES = {"consumer": "消费者词汇表", "supply": "供给侧词汇表"}


def die(msg: str) -> "None":
    print(f"copy-audit: ❌ {msg}(失效自曝,⛔ 出空报告冒充达标——三约束②)", file=sys.stderr)
    sys.exit(1)


def git(repo: str, *args: str) -> str:
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if r.returncode != 0:
        die(f"git {' '.join(args[:2])} 失败:{r.stderr.strip().splitlines()[0] if r.stderr.strip() else '未知错误'}")
    return r.stdout


def is_mapping_source(name: str, text: str) -> bool:
    if name.endswith(MAPPING_GLOB_SUFFIXES):
        return True
    return bool(RECORD_EXPORT_RE.search(text))


# ---- TS 字符串采集(字符级扫描:跳注释;',",` 三类;模板串 ${…} 段替 \x00) ----

def scan_strings(text: str):
    """返回 [(line, col, display, match_text)]。display=源文切片(含 ${…} 原文),
    match_text=同串但 ${…} 替为 \\x00 段界。行注释/块注释内不采。"""
    out = []
    i, n, line, bol = 0, len(text), 1, 0
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            bol = i + 1
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            if j < 0:
                break
            seg = text[i : j + 2]
            if "\n" in seg:
                line += seg.count("\n")
                bol = i + seg.rfind("\n") + 1
            i = j + 2
            continue
        if c in ('"', "'"):
            sline, scol = line, i - bol
            i += 1
            buf = []
            while i < n and text[i] != c:
                if text[i] == "\\" and i + 1 < n:
                    buf.append(text[i : i + 2])
                    i += 2
                    continue
                if text[i] == "\n":  # 未闭合,容错止于行尾
                    break
                buf.append(text[i])
                i += 1
            i += 1
            s = "".join(buf)
            out.append((sline, scol, s, s))
            continue
        if c == "`":
            sline, scol = line, i - bol
            i += 1
            disp, match = [], []
            while i < n and text[i] != "`":
                if text[i] == "\\" and i + 1 < n:
                    disp.append(text[i : i + 2])
                    match.append(text[i : i + 2])
                    i += 2
                    continue
                if text[i] == "$" and i + 1 < n and text[i + 1] == "{":
                    depth, j = 1, i + 2
                    while j < n and depth:
                        if text[j] == "{":
                            depth += 1
                        elif text[j] == "}":
                            depth -= 1
                        elif text[j] in ('"', "'", "`"):
                            q = text[j]
                            j += 1
                            while j < n and text[j] != q:
                                if text[j] == "\\":
                                    j += 1
                                j += 1
                        j += 1
                    seg = text[i:j]
                    disp.append(seg)
                    match.append("\x00")
                    if "\n" in seg:
                        line += seg.count("\n")
                        bol = i + seg.rfind("\n") + 1
                    i = j
                    continue
                if text[i] == "\n":
                    line += 1
                    bol = i + 1
                disp.append(text[i])
                match.append(text[i])
                i += 1
            i += 1
            out.append((sline, scol, "".join(disp), "".join(match)))
            continue
        i += 1
    return out


def cjk_segments(match_text: str):
    """匹配用分段:按 ${…}(\\x00)切,去首尾空白,只留含 CJK 的段。"""
    return [s for s in (seg.strip() for seg in match_text.split("\x00")) if s and CJK_RE.search(s)]


def attribute_key(lines: list, export_at: list, sline: int, scol: int) -> str:
    """键归因:同行属性键 > 同行 export 声明名 > 最近顶层导出名@行号。"""
    prefix = lines[sline - 1][:scol] if sline - 1 < len(lines) else ""
    ctx = export_at[sline - 1] if sline - 1 < len(export_at) else ""
    m = re.search(r"([A-Za-z_$][\w$]*)\s*:\s*$", prefix)
    if m:
        return f"{ctx}.{m.group(1)}" if ctx and ctx != m.group(1) else m.group(1)
    m = re.match(r"\s*export\s+(?:const|let|var)\s+([A-Za-z_$][\w$]*)", prefix)
    if m:
        return m.group(1)
    return f"{ctx}@L{sline}" if ctx else f"@L{sline}"


def collect_values(fname: str, text: str):
    """[(key, display, segments)] 该文件全部含中文字符串值。"""
    lines = text.split("\n")
    export_at, cur = [], ""
    for ln in lines:
        m = EXPORT_RE.match(ln)
        if m:
            cur = m.group(1)
        export_at.append(cur)
    out = []
    for sline, scol, disp, match_text in scan_strings(text):
        segs = cjk_segments(match_text)
        if not segs:
            continue
        out.append((attribute_key(lines, export_at, sline, scol), disp, segs))
    return out


def file_role(basename: str, text: str):
    """归表:声明注释 > 文件名 > 默认供给侧。返回 (roles 元组, 依据)。"""
    has_c, has_s = "wiki-消费者词汇表" in text, "wiki-供给侧词汇表" in text
    if has_c and has_s:
        return ("consumer", "supply"), "双声明"
    if has_c:
        return ("consumer",), "声明"
    if has_s:
        return ("supply",), "声明"
    if "consumer" in basename:
        return ("consumer",), "文件名"
    if "supply" in basename:
        return ("supply",), "文件名"
    return ("supply",), "默认"


# ---- 词表匹配 ----

def line_hit(segs, vline: str):
    """None=不命中;否则 (kind, is_quote)。kind: plain=有删线外命中,struck=全部落删线内。"""
    spans = [(m.start(), m.end()) for m in STRIKE_RE.finditer(vline)]
    all_struck = True
    for seg in segs:
        occ = [m.start() for m in re.finditer(re.escape(seg), vline)]
        if not occ:
            return None
        outside = any(
            not any(a <= p and p + len(seg) <= b for a, b in spans) for p in occ
        )
        if outside:
            all_struck = False
    kind = "struck" if (spans and all_struck) else "plain"
    return (kind, vline.lstrip().startswith(">"))


def best_hit(segs, vocab_lines):
    """全表扫,取最优:plain 非引用块 > plain 引用块 > struck。返回 (kind,lineno,quote)|None。"""
    best = None  # (rank, lineno, kind, quote)
    for idx, vline in enumerate(vocab_lines, 1):
        h = line_hit(segs, vline)
        if h is None:
            continue
        kind, quote = h
        rank = 0 if (kind == "plain" and not quote) else (1 if kind == "plain" else 2)
        if best is None or rank < best[0]:
            best = (rank, idx, kind, quote)
            if rank == 0:
                break
    return None if best is None else (best[2], best[1], best[3])


def md_cell(s: str) -> str:
    return s.replace("|", "\\|").replace("\n", "⏎")


def main() -> int:
    ap = argparse.ArgumentParser(prog="copy-audit", add_help=True)
    ap.add_argument("--ref", default="main", help="来信仓 git ref(默认 main)")
    ap.add_argument("--repo", default=os.environ.get("LX_REPO") or os.environ.get("LAIXIN_REPO") or os.path.expanduser("~/来信平台"))
    ap.add_argument("--kb", default=os.environ.get("LX_KB") or os.environ.get("LAIXIN_KB") or os.path.expanduser("~/Obsidian/项目入口/来信平台/知识库"))
    args = ap.parse_args()

    commit = git(args.repo, "rev-parse", "--short", args.ref).strip()

    # 词表(读取时刻入报告头,失效自曝)
    vocab, vocab_read = {}, {}
    for role, rel in (("consumer", CONSUMER_TABLE), ("supply", SUPPLY_TABLE)):
        path = os.path.join(args.kb, rel)
        try:
            with open(path, encoding="utf-8") as fh:
                vocab[role] = fh.read().split("\n")
        except OSError as e:
            die(f"词表读不到:{path}({e.strerror})")
        vocab_read[role] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # 收录(判别式,零结果探针自证)
    listing = [
        ln for ln in git(args.repo, "ls-tree", "--name-only", args.ref, "--", LIB_DIR + "/").splitlines()
        if ln.endswith(".ts")
    ]
    if not listing:
        die(f"{args.ref}:{LIB_DIR} 下扫不到 .ts 文件——先自证 repo/ref({args.repo} @ {args.ref})")
    sources = []  # (basename, text, roles, basis)
    for path in sorted(listing):
        text = git(args.repo, "show", f"{args.ref}:{path}")
        base = os.path.basename(path)
        if not is_mapping_source(base, text):
            continue
        roles, basis = file_role(base, text)
        sources.append((base, text, roles, basis))
    if not sources:
        die(f"收录判别式在 {len(listing)} 个 .ts 中命中 0 个映射源——判别式或数据源异常")

    rows, per_file = [], {}
    n_hit = n_zero = n_struck = n_other = n_quote = 0
    for base, text, roles, basis in sources:
        values = collect_values(base, text)
        per_file[base] = [len(values), 0, roles, basis]  # [总, 零命中, roles, basis]
        for key, disp, segs in values:
            hit = None
            for role in roles:
                h = best_hit(segs, vocab[role])
                if h and (hit is None or (h[0] == "plain" and hit[1][0] != "plain")):
                    hit = (role, h)
                if h and h[0] == "plain":
                    break
            if hit and hit[1][0] == "plain":
                n_hit += 1
                role, (kind, lineno, quote) = hit
                note = "(引用块)" if quote else ""
                if quote:
                    n_quote += 1
                cell = f"{TABLE_NAMES[role]}:L{lineno}{note}"
            elif hit:  # 仅删线行命中(三约束①:标废词还在用要看得见,⛔ 算正常命中)
                n_struck += 1
                role, (kind, lineno, quote) = hit
                cell = f"🔶仅删线行命中 {TABLE_NAMES[role]}:L{lineno}"
            else:
                n_zero += 1
                per_file[base][1] += 1
                cell = "⚠️零命中"
                for role in ("consumer", "supply"):  # 归表失效可见不静默(它表 plain 命中标注)
                    if role in roles:
                        continue
                    h = best_hit(segs, vocab[role])
                    if h and h[0] == "plain":
                        n_other += 1
                        cell = f"⚠️零命中(仅它表命中:{TABLE_NAMES[role]}:L{h[1]})"
                        break
            rows.append((base, key, disp, cell))

    total = len(rows)
    if total == 0:
        die(f"收录 {len(sources)} 个映射源却采集到 0 条中文值——扫描器或数据源异常")

    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"# 词表覆盖率审计(#28 copy-audit)\n")
    print(f"- 工具:copy_audit.py v{VERSION} | 数据源:`git show {args.ref}:{LIB_DIR}`({args.ref}@{commit},零 worktree 依赖)| 生成 {now}")
    print(f"- 词表:wiki-消费者词汇表.md(读取 {vocab_read['consumer']})/ wiki-供给侧词汇表.md(读取 {vocab_read['supply']})")
    print(f"- 收录判别式=laixin_consumption.py docstring(glob *-copy/-label/-badge + Record 形态,⛔ 另造);归表=声明注释>文件名>默认供给侧")
    print(f"- ⚠️ 判读须知(#15 同则):零命中≠自动缺陷(可能是 dev 告警文案/纯内部键);仅删线行命中=标废词仍在用的嫌疑;本工具 ⛔ 下缺陷结论,判读权在方案窗口\n")
    print("## 清单\n")
    print("| 来源文件:键 | 实现值 | 词表命中 |")
    print("|---|---|---|")
    for base, key, disp, cell in rows:
        print(f"| {md_cell(base)}:{md_cell(key)} | {md_cell(disp)} | {cell} |")
    print("\n## 统计\n")
    print(f"- 总数 {total} | 命中 {n_hit}(其中引用块命中 {n_quote})| 仅删线行命中 {n_struck} | 零命中 {n_zero}(其中仅它表命中 {n_other})")
    dist = ",".join(
        f"{b} {v[1]}/{v[0]}(归{'+'.join(TABLE_NAMES[r] for r in v[2])},{v[3]})"
        for b, v in sorted(per_file.items())
    )
    print(f"- 按文件(零命中/总):{dist}")
    return 0  # 审计报告非闸门:零命中不改退出码(三约束②,详见头注)


if __name__ == "__main__":
    sys.exit(main())
