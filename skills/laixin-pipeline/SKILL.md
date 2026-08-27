---
name: laixin-pipeline
description: 来信平台 11B 开发流水线操作卡。派工、开发轨、验收、合并、事件响应、机动件与交班时使用；项目状态与事故史不进本卡。
---

# 来信开发流水线 · 当班操作卡

> 目标：方案窗口定方向，派工窗口组织流动，A/B/C 开发轨只实现，验收窗独立判定。
> **本卡只放指针 ⛔ 抄全文**。当班状态看执行总表；规则正文看协作流程；失败史看复盘页。

## 0. 先认角色

| 角色 | 负责 | 禁止 |
|---|---|---|
| 方案窗口 | 设计、裁定、11C 主持 | fresh/send/verify/merge |
| 派工窗口 dispatch | Gate2、发车、验收编排、ff-only 合并、台账 | 自验、代拍设计 |
| A/B/C 开发轨 | 按 prompt 实现、自证、交付报告 | 合并、push、改射程 |
| 一次性验收窗 | 独立复现、全量、回执 | 合并、动 lane |
| M/工具/中继窗 | 按任务单完成非产品件 | 借机绕片级闸门 |

同一时刻只能有一个派工权持有者；laixin-lane whoholds 是机器事实。窗口名、任次、通道一律查注册表，不从旧消息猜。

## 1. 接班最短路径

    laixin-lane doctor
    laixin-lane stats
    laixin-lane whoholds

随后只读：

1. ~/Obsidian/项目入口/来信平台/知识库/4-开发层/来信平台-执行总表.md 的“进行中”、当前验收与排队 ready 行；
2. 同目录 来信平台-流水线看板.md 末 20 行；
3. ~/Obsidian/项目入口/来信平台/知识库/log.md 末尾。

事件总线已独立常驻，接班不要自建 Monitor。doctor 有错先修通道；警告逐条判断归属，不把列表原样转发。

## 2. 常用命令

    laixin-lane fresh a
    laixin-lane fresh b --dir ~/来信平台-bN
    laixin-lane fresh c --dir ~/来信平台-cN
    laixin-lane send a "好的，接下来开发 <prompt绝对路径>"
    laixin-lane peek a 30

    laixin-lane verify-from "<交付报告绝对路径>" --prompt "<prompt绝对路径>" --to dispatch
    laixin-lane peek-v <片名> 40
    laixin-lane evidence <片名>
    laixin-lane merge-guard
    laixin-lane vdown <片名>

    LAIXIN_WINDOW=派工窗口 laixin-lane log "<结果>"
    laixin-lane kb-commit "<说明>" "<vault相对路径>"

- B/C 每片独立 worktree；C 轨 fresh 强制 --dir。
- 🔴 **全切 print 后 C 轨(kimi)起窗须带前缀**:`LAIXIN_LANE_TRANSPORT=tui laixin-lane fresh c --dir <worktree>` —— `bin/laixin-lane:542` 的守卫在 `transport=print` 且轨引擎非 codex 时**无条件拒**(带不带 `--dir` 都拒)。**这是过渡态**:终态=守卫改按轨解析(codex 轨 print / kimi 轨恒 tui,零前缀),已登 11B。
- send 后看落地校验；可疑时先 peek 至少 30 行，确认被吞再重发。
- MCP 默认关闭；只有 prompt 明确需要时在 fresh 加已有 --with-mcp。
- 不自行改模型、账号、专线或 credential 配置。

## 3. 派工循环

每次只做一轮：

1. 读执行总表当前在飞与 ready；
2. 先消费一条事实事件：交付、回执、写单、工具件；
3. 交付用 verify-from，回执用 evidence；
4. 空闲轨确有 ready 才 fresh + send + peek；
5. 写总表/看板的一条结果，结束本轮。

**无在飞分配且无 ready = 有意空闲**。记录一次即可，之后等待；不要为证明“还在等”重复发消息。
有在飞分配却长期无变化，或 ready/待认领交付长期未处理，才是事故。

## 4. 写 prompt 与 Gate2

prompt 起草默认走一次性写单窗：

    laixin-lane prompt-up <片名> --pack <方案底稿.md>
    laixin-lane peek-prompt <片名> 30
    laixin-lane prompt-down <片名>

写单交稿后，派工窗口做 Gate2，四项缺一不可：

1. 独立跑 laixin-lane prompt-lint <prompt>，不采信报告里的“已绿”；
2. 抽核实测表 2–3 条；
3. 发车当刻校准 main 基点、迁移号、worktree 号；
4. 扫在飞/已写未发片的文件面与口径冲突。

通过后顺序固定：kb-commit → 执行总表登记发车 → fresh → send → peek → 回收写单窗。缺料或缺裁定就把停车报告指针交方案窗口，派工方不补设计。

prompt 宪法头、测试矩阵、交付契约正文见：

- 4-开发层/prompt/来信平台-prompt宪法头模板.md
- Skill laixin-kickoff
- Skill laixin-version-flow

六条日常派工程序只认 4-开发层/来信平台-开发协作流程.md，卡内不复制正文：

- 先登记后发车 → “流水线纪律（派工操作程序权威）” > “1. 先登记后发车”；
- 台账八律 → “流水线纪律（派工操作程序权威）” > “2. 台账书写八律”；
- 整行移出 → “流水线纪律（派工操作程序权威）” > “3. 整行移出与移入”；
- 发车位 → “硬规则” > “发车位纪律”；
- 打回座位 → “挂起升级创始人” > “打回整改的座位裁决”；
- 扫存量 → “流水线纪律（派工操作程序权威）” > “4. 收方扫存量”。

## 5. 事件怎么处理

| 事件 | 当轮动作 |
|---|---|
| 【交付完成】 | 读报告全文 → verify-from |
| 【验收回执】 | 读回执 → evidence → 合并或打回 |
| 【写单完成】 | Gate2；通过才登记发车 |
| 【写单停车】 | 发缺口指针给方案窗口 |
| 【工具件完成】 | 按报告自证轻量复核 → tool-down，不走 verify |
| 【中转回复】 | 读路径全文；需要再判断才续问 |
| 材料合批 | 只通知事件列出的在飞目标 |
| lane 告警 | 先 peek；不要直接 fresh 打断后台任务 |

同一交付契约的正文补写由 events 静默记日志；同一验收回执正文更新仍通知，因为结论可能变化。事件给的是路径指针，不是正文。

## 6. 窗口通信

只让「需要对方判断」的消息走中继；事实类走落盘 + events，⛔ 占用中继那一跳。

| 场景 | Claude 席位 | Kimi/Codex 无协作工具席位 |
|---|---|---|
| 请方案窗口裁定 | SendMessage | laixin-lane relay-msg --to 方案窗口 "<短指针>" |
| 工程打回转开发轨 | 由派工窗口 SendMessage 协调后 send | laixin-lane relay-msg --to <目标> "<短指针>" 后由派工窗口 send |
| 向创始人报产品取舍 | SendMessage | laixin-lane relay-msg --to 创始人窗口 "<短指针>" |
| 询问 11C 机务 | SendMessage | laixin-lane relay-msg --to dispatch-11c "<短指针>" |
| 交班给继任 | SendMessage 一条接班令 | laixin-lane relay-msg --to <继任> "<接班令>" |

默认消息形态：动作 + 权威路径#内容锚 + commit。不复制正文，不发 ACK-only“收到/已阅”。只有仍会变化的关键 prompt/指令/回执才附 mtime、字节数与 commit。

- Claude 有 SendMessage 时直接用，不绕中继。
- 无 SendMessage 时，relay-msg 只负责出站代发；注入成功不等于转出，laixin-lane relay-msg --status 查销账。
- 中继没有向派工窗反向注入的能力；回复须落 【中转回复】，events 再投路径。
- 禁止给中继新增 send/dmsg 等价能力；**换个名字不改变它是同一个动作**。
- 别人主动找无协作工具席位时用 laixin-lane dmsg --from <来源> "<正文>"。

## 7. 独立验收与合并

验收标准以 Skill laixin-acceptance 为单点源。派工窗口只传片名、prompt、分支、commit、交付报告五项客观信息，不带预期结论。

通过回执到达后：

1. laixin-lane evidence <片名>：回执数字逐字可核；能独立复现的 git 事实可自己复现；
2. 确认回执所基于的 main 仍是当前 main；已前进则验收窗 rebase 后重跑；
3. laixin-lane merge-guard；
4. 仅 ff-only 合并；
5. 更新执行总表、看板、事实表并 kb-commit；
6. 向所有仍在跑的验收窗广播 main 前进短指针；
7. vdown 回收验收窗与闲置验收 worktree。

验收窗不 send 开发轨；打回也由派工窗口转发，避免两个窗口同时写一条 lane。

## 8. 打回、挂起与停车

- 工程打回：按回执逐条转整改；同一实现缺陷重复或累计触线时升级。
- 方向性打回/裁定缺口/红线争议：一次即挂起该片并报方案窗口。
- 文书缺项、prompt 判据缺口不冒充开发方实现缺陷。
- **挂起 ≠ 停工**：权威原文在 4-开发层/来信平台-开发协作流程.md 的“打回分类”；**本卡只放指针 ⛔ 抄全文**。
- prompt 要求外的新机制、射程与红线冲突：停车报告，不自行扩权。

上报分引擎仍是同一条：Claude 用 SendMessage；无协作工具席位用 laixin-lane relay-msg --to 方案窗口 "<路径#锚>"。事实落盘后不再另发一条确认消息。

## 9. M 件、11B/11C 工具件与中继件

    laixin-lane m-up <件名> --task <任务单.md> --dir <worktree>
    laixin-lane m-down <件名>

    laixin-lane tool-up <件名> --prompt <开发prompt.md> --dir <工具仓worktree>
    laixin-lane tool-down <件名>

    laixin-lane relay-once <件名> --file <正文.md>
    laixin-lane rdown <件名>

- M 件只做非产品代码的执行类活；报告末行 【交付完成】M轨-...，按任务单轻量复核，不起验收窗。
- tool-up 只维护 11B/11C，自建分支，不提交 main；报告末行 【工具件完成】。
- Claude print 传输 `--engine claude --transport print`(**默认已是 `print`**,2026-08-27 10:10:35 起)**no-go 已解除**(2026-08-27 方案侧裁;沿革=`f1427b8` 两前置闭环〔告警双向自证 + 隔离载体〕)。**已全切**(创始人 2026-08-27 直令「现在、立刻全切」,10:10:35 写 `lane-transport=print`;切前解析实测 `tui`、切后 `print`);**切后监控**=第一件真跑核「告警回传 + 运行可见」两面留读数(**⛔ 读成切的前置,它是切后监控**);**回退开关保留,遇异常即回退并报方案侧**。解析顺序与回退跑 `--dry` 自看。
- relay-once 是按件快查/书记，不替代常驻 relay；需要 relay-msg 代发时常驻 relay 必须在班。
- 等待这些窗口产出不构成派工燃料；各自的超时和回执由 events 管。

## 10. 上下文、交班、暂停

- Claude 派工席：65–75% 是准备区，≥75% 硬交班；写数字前当轮跑 laixin-lane ctx <session前8位>。
- Codex 开发/验收席自带翻页，不因占比高人工换班。
- Kimi 看自身 TUI context，不要用 laixin-lane ctx 读别人的数。
- 交班包只写当前在飞、待验、ready、挂起、第一动作与权威路径；继任未接稳前保持注册表“待接”。
- 给继任只发一条接班令，正文在交接包；完成前无需回复。
- 暂停时先收敛在飞与回执、写台账、确认恢复入口，最后才 laixin-lane halt。

## 11. 安全与诊断

- 禁止 git push、git reset --hard、在共享工作树 checkout/merge。
- 读窗口至少 30 行；短 tail 只看到提示符，不能判空闲。
- 进程/循环判活用 doctor、status 与工具内置探针，不用宽 pgrep -f。
- 自动机制交付必须有：真环境首火、能区分成功/失败的可运行绊线。
- 任何数字、时刻、commit、路径状态都在当轮实测；查不到写“未测”，不填占位。
- IP/专线入口与 credential/MCP 信任开关不在本卡授权面，禁止改。

## 12. 权威指针

- 当前状态：4-开发层/来信平台-执行总表.md
- 协作与打回规则：4-开发层/来信平台-开发协作流程.md
- 运行事件：4-开发层/来信平台-流水线看板.md
- 角色地址：4-开发层/来信平台-窗口角色注册表.md
- 验收：Skill laixin-acceptance
- prompt：Skill laixin-kickoff
- 版本与分支：Skill laixin-version-flow
- 方案窗口/11C 主持：Skill laixin-plan-window

遇到条文冲突，停在当前片，报“冲突的两个权威路径 + 内容锚 + 当前事实”，不自行挑一份。
