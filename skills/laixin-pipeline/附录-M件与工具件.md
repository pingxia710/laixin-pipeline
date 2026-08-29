---
title: pipeline 卡附录 · M 件与工具件
type: appendix
date: 2026-08-29
---

# 附录 · M 件、11B/11C 工具件与中继件(**只在做该类件时读**)

> 出处:`laixin-pipeline` 卡 §9,2026-08-29 按创始人代拍「卡只放程序+指针,条件触发专项一律出去」移出(同 `laixin-acceptance` 附录法)。**内容原样 ⛔ 改一字。**


    laixin-lane m-up <件名> --task <任务单.md> --dir <worktree>
    laixin-lane m-down <件名>

    laixin-lane tool-up <件名> --prompt <开发prompt.md> --dir <工具仓worktree>
    laixin-lane tool-down <件名>

    laixin-lane relay-once <件名> --file <正文.md>
    laixin-lane rdown <件名>

- M 件只做非产品代码的执行类活；报告末行 【交付完成】M轨-...，按任务单轻量复核，不起验收窗。
- tool-up 只维护 11B/11C，自建分支，不提交 main；报告末行 【工具件完成】。
- Claude print 传输 `--engine claude --transport print`(**默认已是 `print`**,2026-08-27 起全切)。**回退开关保留,遇异常即回退并报方案侧**;解析顺序与回退跑 `--dry` 自看。沿革(no-go 解除 · 全切令 · 切后监控)见看板 2026-08-27 段。
- relay-once 是按件快查/书记，不替代常驻 relay；需要 relay-msg 代发时常驻 relay 必须在班。
- 等待这些窗口产出不构成派工燃料；各自的超时和回执由 events 管。
