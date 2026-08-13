#!/usr/bin/env python3
"""doccheck —— 设计文档的工程断言检查器。

起因(2026-08-13):方案窗口一天内三次在设计里"引用了不存在的东西",两次要等
下游读到才被发现,其中一次(结清清单"与商会-5 同判据,复用不新造")在被认错后
仍留在正文里,直到在飞的整改片正读着那份设计时才被顺带抓出。

⇒ 下游闸门接得住"判断错",接不住"文档里长期躺着一句错的话"——那要等有人恰好读到。

## 两条规则(为什么是这两条)

**规则 A(锚点存在性)**:文档里反引号包裹的代码标识符,去 main 里 grep,零命中即报。
**规则 B(断言无锚点)**:凡断言"复用既有/已有/现成/同判据/不新造"的句子,
                          **整句没有任何可 grep 的锚点** ⇒ 报"断言无证据"。

⚠️ **B 才是直击今天那三次错误的那条,A 抓不到它们**(它们全是中文描述,没有锚点)。
   这一点必须写在这里,否则下一个人会以为跑了 A 就安全了——
   **判据的射程要写明,不能让"跑过了"被当成"验到了"。**

## 已知射程之外(⛔ 本工具抓不到,别指望)

- **锚点存在、但结论错**。今天第三次错就是这形态:`ReassignmentExecute.reason_code`
  确实存在,错在"这里缺约束"——而真约束在服务层,schema 层结构上无法表达。
  ⇒ **要判"缺约束",只能人去核约束在哪一层。**
- 中文描述的事实断言(如"该接口已返回 X"),没有锚点也没有断言词时。
"""
import os
import re
import subprocess
import sys

REPO = os.path.expanduser("~/来信平台")
KB = os.path.expanduser("~/Obsidian/项目入口/来信平台/知识库")

# 断言"这东西已经有了"的词——命中这些词的句子,必须给得出证据
# ⚠️ 词表是本工具的射程本身。首版漏了"已生效"一族,导致对真实样本只命中 1/3
#    ——补词的依据是:凡"断言工程现状"的说法都要给锚点,不只是"复用既有"那一类。
CLAIM_WORDS = [
    "复用", "既有", "已有", "现成", "同一判据", "用同一", "不新造", "已存在", "沿用",
    "已生效", "已实现", "已返回", "已支持", "已落地", "已接入", "本就有", "早已",
]

# 工程名词:句子谈的是"代码里的东西"才检查;只谈裁定编号/机制名的不算
ENG_WORDS = ["接口", "端点", "字段", "表", "函数", "返回", "schema", "Schema", "值域",
             "枚举", "判据", "约束", "列", "载体", "实现", "机制"]

# 像代码的锚点:含下划线 / 点号路径 / 冒号行号 / 驼峰。⛔ 排除纯中文与普通英文词
ANCHOR = re.compile(r"^(?=.*[A-Za-z])[A-Za-z_][\w./:\-\[\]]*$")
CODEISH = re.compile(r"[_./]|[a-z][A-Z]")


def anchors_in(text):
    """取一段文本里所有像代码标识符的反引号内容。"""
    out = []
    for m in re.findall(r"`([^`]+)`", text):
        m = m.strip()
        if not (ANCHOR.match(m) and CODEISH.search(m) and len(m) > 3):
            continue
        # ⛔ 排除:目录(app/models/)、斜杠分隔的概念名(PayoutInstructed/Executed)
        if m.endswith("/") or ("/" in m and not re.search(r"\.(py|ts|tsx|md)", m)):
            continue
        out.append(m)
    return out


def exists_in_main(token):
    """锚点是否存在于 main。文件路径查文件,其余全库 grep。"""
    probe = token.split(":")[0]                       # app/x.py:123 → app/x.py
    if "/" in probe and probe.endswith(".py"):
        r = subprocess.run(["git", "show", f"main:{probe}"],
                           cwd=REPO, capture_output=True)
        return r.returncode == 0
    name = re.split(r"[.\[]", probe)[0]               # Foo.bar → Foo
    if len(name) < 4:
        return True                                   # 太短,不判(避免噪音)
    r = subprocess.run(["git", "grep", "-q", "-w", name, "main"],
                       cwd=REPO, capture_output=True)
    return r.returncode == 0


def sentences(line):
    return [s for s in re.split(r"[。;;\n]", line) if s.strip()]


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(KB, "3-方案层")
    bad_anchor, no_evidence = [], []

    for root, _, files in os.walk(target):
        for fn in sorted(files):
            if not fn.endswith(".md"):
                continue
            path = os.path.join(root, fn)
            rel = os.path.relpath(path, KB)
            if rel.startswith(".."):                  # 目标不在知识库下(如 fixture)
                rel = "/".join(path.rsplit("/", 2)[-2:])
            for i, line in enumerate(open(path, encoding="utf-8"), 1):
                if line.lstrip().startswith(">") and "⛔" in line:
                    continue                          # 已标作废的引用块,跳过
                for tok in set(anchors_in(line)):
                    if not exists_in_main(tok):
                        bad_anchor.append((rel, i, tok, line.strip()[:70]))
                for s in sentences(line):
                    if not any(w in s for w in CLAIM_WORDS) or anchors_in(s):
                        continue
                    # ⚠️ 首版在全库跑出 179 处,信号被淹没。根因:"复用 M-11 链路"这类
                    #    **引用设计概念**的句子与"断言代码现状"形态完全相同,靠句式分不开。
                    #    ⇒ 收窄:必须同时提到**工程名词**,才算在断言工程现状。
                    if not any(w in s for w in ENG_WORDS):
                        continue
                    if any(w in s for w in ("作废", "撤回", "不成立", "已改", "原写")):
                        continue                      # 认错留痕不算断言
                    no_evidence.append((rel, i, s.strip()[:88]))

    print("== ⛔ A. 锚点在 main 上不存在 ==")
    if not bad_anchor:
        print("  (无)")
    for rel, i, tok, ctx in bad_anchor[:40]:
        print(f"  {rel}:{i}  `{tok}`\n      {ctx}")
    print(f"\n== ⚠️ B. 断言『已经有了』却没给锚点(共 {len(no_evidence)} 处,列前 25)==")
    print("   ⇒ 这类句子无法被任何人一秒复核,今天三次设计错误里有两次是这个形态")
    for rel, i, s in no_evidence[:25]:
        print(f"  {rel}:{i}  {s}")
    print(f"\n小结:A {len(bad_anchor)} 处 · B {len(no_evidence)} 处")
    print("⚠️ 本工具抓不到「锚点存在但结论错」(如'这里缺约束'而真约束在另一层)——那只能人核。")


if __name__ == "__main__":
    main()
