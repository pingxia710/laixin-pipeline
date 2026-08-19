---
name: laixin-opc-business
description: "Manage and discuss the 来信-OPC业务 project: one-person company business strategy, AI agent/Codex/Claude Code industry intelligence, OPC OS, AI development workshop, AgentOps services, Web/mini-program/app product planning, Obsidian knowledge updates, and launchd intelligence reports. Use when the user says 启动来信OPC, 来信OPC, OPC业务, 一人公司业务, AI开发工坊, or asks to continue this business line."
---

# 来信-OPC业务

Use this skill for the 来信平台 OPC（一人公司 / One-Person Company）业务线.

## Paths

```bash
PROJECT=/Users/pingxia/来信-OPC业务
VAULT=/Users/pingxia/Documents/Obsidian\ Vault/项目入口/来信平台/OPC业务
SKILL=/Users/pingxia/.codex/skills/laixin-opc-business
```

Key files:

- Project root: `/Users/pingxia/来信-OPC业务`
- Local source folder: `/Users/pingxia/Desktop/来信2026`
- Local source inventory: `/Users/pingxia/来信-OPC业务/sources/laixin2026-local/inventory.md`
- Local source synthesis: `/Users/pingxia/来信-OPC业务/docs/来信2026-本地资料全量提炼.md`
- Latest intelligence report: `/Users/pingxia/来信-OPC业务/reports/latest.md`
- Business plan: `/Users/pingxia/来信-OPC业务/docs/业务落地方案-v0.1.md`
- Intelligence SOP: `/Users/pingxia/来信-OPC业务/docs/情报系统-SOP.md`
- AI development toolchain: `/Users/pingxia/来信-OPC业务/docs/AI大型互联网产品开发工具链-v0.1.md`
- Every-step memory rule: `/Users/pingxia/来信-OPC业务/docs/每一步记忆执行规则.md`
- Real 1.0 engineering app: `/Users/pingxia/来信-OPC业务/apps/real-1.0`
- Real 1.0 engineering record: `/Users/pingxia/来信-OPC业务/docs/真实1.0工程落地-2026-06-10.md`
- Real 1.0 local production preview: `/Users/pingxia/来信-OPC业务/docs/真实1.0-本地生产部署预演.md`
- Real 1.0 object storage record: `/Users/pingxia/来信-OPC业务/docs/真实1.0-对象存储接入.md`
- Real 1.0 production readiness gate: `/Users/pingxia/来信-OPC业务/docs/真实1.0-生产上线门禁.md`
- Real 1.0 GitHub remote CI bootstrap: `/Users/pingxia/来信-OPC业务/docs/真实1.0-GitHub远端CI.md`
- Real 1.0 remote backup record: `/Users/pingxia/来信-OPC业务/docs/真实1.0-远端备份与恢复.md`
- Real 1.0 payment reconciliation record: `/Users/pingxia/来信-OPC业务/docs/真实1.0-人工收款对账.md`
- Real 1.0 monitoring and alerting record: `/Users/pingxia/来信-OPC业务/docs/真实1.0-监控与告警.md`
- Real 1.0 production database operations record: `/Users/pingxia/来信-OPC业务/docs/真实1.0-生产数据库运维.md`
- Real 1.0 admin role permissions record: `/Users/pingxia/来信-OPC业务/docs/真实1.0-后台角色权限.md`
- Real 1.0 admin account management record: `/Users/pingxia/来信-OPC业务/docs/真实1.0-后台账号体系.md`
- Real 1.0 order assignment and row-level access record: `/Users/pingxia/来信-OPC业务/docs/真实1.0-订单分配与行级权限.md`
- Real 1.0 first-login forced password change record: `/Users/pingxia/来信-OPC业务/docs/真实1.0-首次登录强制改密.md`
- Real 1.0 provider response and scheduling record: `/Users/pingxia/来信-OPC业务/docs/真实1.0-服务者接单与排期.md`
- Real 1.0 provider capacity conflict record: `/Users/pingxia/来信-OPC业务/docs/真实1.0-服务者容量冲突检查.md`
- Real 1.0 admin invite activation record: `/Users/pingxia/来信-OPC业务/docs/真实1.0-后台邀请激活.md`
- Real 1.0 admin login lockout record: `/Users/pingxia/来信-OPC业务/docs/真实1.0-登录失败锁定.md`
- Real 1.0 admin password reset link record: `/Users/pingxia/来信-OPC业务/docs/真实1.0-后台密码重置链接.md`
- Real 1.0 admin notification outbox record: `/Users/pingxia/来信-OPC业务/docs/真实1.0-后台通知Outbox.md`
- Real 1.0 self-service password reset request record: `/Users/pingxia/来信-OPC业务/docs/真实1.0-自助找回密码申请.md`
- Real 1.0 email delivery adapter record: `/Users/pingxia/来信-OPC业务/docs/真实1.0-邮件投递适配.md`
- Project memory timeline: `/Users/pingxia/来信-OPC业务/memory/timeline.md`
- Project memory decisions: `/Users/pingxia/来信-OPC业务/memory/decisions.md`
- Project memory evidence: `/Users/pingxia/来信-OPC业务/memory/evidence.md`
- Project memory unresolved: `/Users/pingxia/来信-OPC业务/memory/unresolved.md`
- Obsidian home: `/Users/pingxia/Obsidian/项目入口/来信平台/OPC业务/00-首页.md`
- Knowledge base: `/Users/pingxia/Obsidian/项目入口/来信平台/OPC业务/知识库/`

## Start Workflow

When the user says `启动来信OPC`, asks for business discussion, or wants the next step:

1. Read `references/project-map.md`.
2. Read project memory before making claims or continuing work:
   ```bash
   sed -n '1,220p' /Users/pingxia/来信-OPC业务/memory/timeline.md
   sed -n '1,220p' /Users/pingxia/来信-OPC业务/memory/decisions.md
   sed -n '1,220p' /Users/pingxia/来信-OPC业务/memory/unresolved.md
   ```
3. Prefer the local `来信2026` materials first:
   ```bash
   cd /Users/pingxia/来信-OPC业务
   npm run extract:local
   sed -n '1,220p' docs/来信2026-本地资料全量提炼.md
   ```
4. Only run the external intelligence report when the user explicitly asks for market/latest research:
   ```bash
   cd /Users/pingxia/来信-OPC业务
   npm run collect:week
   sed -n '1,220p' reports/latest.md
   ```
5. Read the relevant Obsidian note under `OPC业务/知识库/`.
6. For real 1.0 engineering work, inspect `apps/real-1.0` and run focused validation:
   ```bash
   cd /Users/pingxia/来信-OPC业务
   npm run real1:verify
   npm run real1:e2e
   npm run real1:audit
   npm run real1:smoke
   npm run real1:readiness:local
   npm run real1:readiness:production
   npm run real1:github:check
   npm run real1:backup
   npm run real1:backup:verify
   npm run real1:backup:remote:plan
   npm run real1:backup:remote:check
   npm run real1:database:plan
   npm run real1:database:check
   npm run real1:database:restore-drill
   npm run real1:database:check-config
   npm run real1:monitoring:plan
   npm run real1:monitoring:check
   npm run real1:monitoring:check-config
   npm run real1:notifications:plan
   npm run real1:notifications:check-config
   npm run real1:docker:build
   npm run real1:docker:up
   npm run real1:docker:smoke
   npm run real1:docker:e2e
   ```
7. Start discussion from the current opportunity queue and local 来信 mechanics, not from generic AI-agent hype.

## Business Focus

Current recommended sequence:

1. P0: 来信2026 本地资料提炼
2. P0: 电商自动化样板
3. P0: 需求顾问工作台
4. P0: 服务者/商会工作台
5. P0: 订单状态和验收闭环
6. P0: 小程序轻入口
7. P0: 付费试运行
8. P0: 1.0 收费闭环
9. P0: 真实 1.0 工程切片
10. P0: 后台订单分配和服务者行级权限
11. P0: 后台账号安全和首次登录强制改密
12. P0: 服务者接单、拒单和单订单排期容量
13. P0: 服务者跨订单容量冲突检查
14. P0: 后台一次性邀请链接激活
15. P0: 后台登录失败锁定
16. P0: 后台密码重置链接
17. P0: 后台通知 outbox
18. P0: 自助找回密码申请队列
19. P0: 邮件投递适配和真实 SMTP 凭证验证
20. P0: 验证码、2FA、IP 限流和登录通知
21. P0: 真实客户试运行
22. P1: AgentOps 托管
23. P1: AI 交付质检与商会审核
24. P2: 完整 APP 产品入口

Default product order:

```text
Web first -> mini-program light entry -> APP only after repeat usage
```

## Hard Boundaries

- Do not modify `/Users/pingxia/来信平台/frontend` unless the user explicitly asks. It currently has unrelated worktree changes.
- Do not present automatic intelligence scores as final business truth; treat them as leads for human review.
- Do not promise fully automated companies. Keep human strategy, customer relationship, approval, and quality gates explicit.
- Do not start with a full APP. Validate Web/consulting/service workflow first.
- Do not call a static HTML/JS prototype a real 1.0 product. It is only a flow sandbox unless it has frontend, backend API, database, auth/roles, and persistent business data.
- Keep project truth in files: local project docs, Obsidian notes, and the canonical ledger.
- Save every meaningful step into project memory. Product judgment, architecture decisions, code changes, validation evidence, user corrections, unresolved risks, and next actions must be written to `memory/`.
- Treat memory writing as an engineering gate. Before work, read project memory; after work, update memory. If validation is not run, record it as not run. If validation fails, record the failure and next action instead of hiding it.
- If the user restates or corrects the memory policy, record that input itself in `memory/timeline.md` and `memory/evidence.md`; add a new decision only when the execution rule changes.

## Intelligence Commands

```bash
cd /Users/pingxia/来信-OPC业务
npm run extract:local
npm run collect:week
npm run collect:month
node --check scripts/collect-opc-intel.mjs
node --check scripts/extract-laixin2026-local.mjs
plutil -lint launchd/com.pingxia.laixin-opc-intel.plist
launchctl print gui/$(id -u)/com.pingxia.laixin-opc-intel
```

## Discussion Style

For business discussions, keep outputs grounded:

- Start with a decision: what to sell first, who buys it, why now.
- Convert ideas into demand cards, packages, or validation experiments.
- Use `可信度 / 可行性 / 紧迫性 / 验证成本` before entering development.
- End with the next concrete artifact: sales page, interview script, MVP spec, workflow template, or feature card.

## References

- `references/project-map.md`: paths, commands, state, evidence.
- `references/business-framework.md`: business model, customer segments, product route, discussion agenda.

## Handoff

After meaningful project changes:

1. Update `memory/timeline.md`, `memory/decisions.md`, `memory/evidence.md`, or `memory/unresolved.md` as appropriate.
2. Update Obsidian notes under `OPC业务/知识库/`.
3. Update `/Users/pingxia/Obsidian/项目入口/项目总台账.md` if status, paths, automation, or next actions changed.
4. Run `/Users/pingxia/.local/bin/project-ledger-check` after ledger edits.
5. In the final response, state which validations were actually run and which production gaps remain.
