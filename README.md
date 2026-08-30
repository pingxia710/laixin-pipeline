# laixin-pipeline

**A multi-agent development pipeline that actually ran in production — and the failure log that shaped it.**

多 AI 并行开发流水线的实战工程化。不是框架，是一套在真实项目里跑出来的编排器 + 纪律卡 + 事故复盘。

---

## What this is

A `tmux`-based orchestrator that runs **Codex, Claude Code and Kimi as parallel workers** on the same repository, plus the operational discipline that keeps them from destroying each other's work.

It was built while shipping a real product (来信平台 / Laixin). Every rule in here exists because something broke first.

```
┌─────────────┐
│  dispatch   │  派工窗口 — assigns slices, watched by a watchdog that revives it
└──────┬──────┘
       │
   ┌───┴────┬─────────┐
   ▼        ▼         ▼
┌──────┐┌──────┐┌──────┐
│lane a││lane b││lane c│   parallel workers, each in its own git worktree
│codex ││codex ││ kimi │
└──────┘└──────┘└──────┘
       │
       ▼
┌─────────────┐
│  verify     │  一次性验收窗口 — spawned per slice, discarded after verdict
└─────────────┘   never the same agent that wrote the code
```

## Why it exists

Running one AI agent on a codebase is easy. Running **three at once** surfaces problems nobody writes about:

- two lanes editing the same file with no worktree isolation
- an agent reporting "done" for work it never did
- a dispatcher window dying at 3am with nothing to restart it
- `git add -A` in one window silently swallowing another window's in-flight fix
- a test suite that goes red **only when the machine is busy**

This repo is the accumulated answer to those.

## Components

| Path | What it does |
|---|---|
| `bin/laixin-lane` | 4k-line orchestrator: lane up/down/fresh, send, peek, per-slice verify windows, dispatch + relay windows, watchdog, context-budget gate |
| `bin/laixin-11c-topic` | Runs one isolated R1 blind review, freezes it, then runs R2 against R0 + frozen R1; supports resume without overwriting published notes |
| `bin/doccheck.py`, `bin/copy_audit.py`, `bin/opt_status.py` | Machine-checkable gates (docs, copy, optimization status) — rules become assertions, not prose |
| `contrib-statusline.py` | Context-budget statusline with hard/warn handover gates |
| `skills/laixin-kickoff` | Pre-flight card: stale branch base, reinventing existing mechanisms, ambiguous terminology, fake doors with no backend |
| `skills/laixin-acceptance` | Independent acceptance: **accepts no self-report, only reproducible evidence** |
| `skills/laixin-deploy` | Production release card built on one principle: *a failed deploy and a successful one look identical* — every step needs a criterion that tells them apart |
| `skills/laixin-pipeline` | The operating manual for the whole topology |
| `bin/laixin-11c-seat`, `bin/laixin-11c-trust`, `bin/laixin-11c-dispatch` | Legacy 11C roundtable launchers retained for history and compatibility; no longer the active discussion path |
| `tests/run.sh` | Tripwire tests — fixtures constructed so that reverting a fix turns them red |

## The operating layer: 11B and the repurposed 11C tooling

11B owns the pipeline. The old 11C name now labels a small topic-discussion conveyor; its historical roundtable records remain in the project's private knowledge base.

### 11B — the tool shop (`AGENTS.md`, `11b/`)

Owns this repository. Three tiers of commit rights, an explicit ban on `git add -A` (multiple windows share one worktree), and a rule that every bug fix ships with a tripwire test. `11b/` holds its shift-handover snapshots and briefings — what a window hands to its successor so the work survives a context reset.

### 11C — the serial topic orchestrator (`bin/laixin-11c-topic`)

The former multi-seat, codename-based roundtable was retired on 2026-08-30. Its launch and isolation lessons were reused for a smaller three-party flow: a human supplies intent, the plan window writes R0 and owns the final synthesis, and one fresh cross-review process writes R1 blind before seeing R0 and then writes an R2 comparison.

`bin/laixin-11c-topic` is deliberately only a control plane. It assembles an explicit R1 allowlist, invokes the native Codex or Claude CLI without write tools, rejects Codex runs that make any tool call, freezes the R1 hash, and publishes R1/R2 atomically. It never synthesizes the final plan or starts implementation. The legacy seat, trust and dispatch scripts remain in the repository as archived implementation evidence, not active entry points.

The retained lesson is input independence: a claimed blind review is not blind if R0, prior conversation, or another reply is present in the input surface. The current tool records the exact staged prompt and refuses to treat an unverified run as complete.

> The included material is written in Chinese. That's where the substance is; translating it would cost the precision that makes it useful.

## Hard-won lessons

The real value here is `AGENTS.md`. A few that cost the most:

> **A test suite that turns red when the machine is busy is worse than no tests — it teaches everyone to ignore red.**
>
> `set -o pipefail` + `echo "$out" | grep -q "$want"`: grep exits early on match, `echo` takes SIGPIPE (141), and pipefail reports the *successful match* as a failure. Load-dependent, so it looks like "all green when quiet, 9 innocent tests red when the pipeline is busy." Reproduced 20/20. Use a herestring — no pipe, no signal.

> **`--stat` is not a valid self-check for "did I swallow someone else's work".**
>
> When two windows edit the same file, that file appearing in your commit's file list is *completely unremarkable*. One commit here passed a `--stat` self-check while containing only two of its author's own lines. Claim every hunk, not every filename.

> **A criterion must evolve together with the thing it checks.**
>
> A checker left behind by a hardening change is more dangerous than a loose one: it parks a permanent red line in your acceptance run, so when something real breaks you can no longer tell the difference.

> **Three constraints for any checker you write**
> 1. *State-aware* — a line that records history contains both the old and the new state. Struck-through text, quote blocks and correction notes are deliberate design; a scanner that can't skip them ends up fighting the documentation culture (real hit: a placeholder lint flagging the very line that had just removed a placeholder).
> 2. *Fail soft, never inverted* — when the check itself breaks, its behaviour must not point at the exact risk it guards. (Real hit: a verify helper that, on failure, pushed people back to transcribing hashes by hand.)
> 3. *Noise must not scale with the desired behaviour* — if a checker's false positives grow with how thorough your board entries are, it will train the team to write worse board entries.

> **Shell will silently rewrite your content.** Backticks get evaluated. Heredocs swallow long scripts. Pipe exit codes get masked by the last stage. Under a Chinese locale, bash absorbs a trailing multi-byte character into the variable name (`$commit——` kills `set -u`). Verify *what arrived and the real exit code*, never *what you sent*.

## Status and caveats

**This is an internal tool published as-is, not a product.**

- Paths are hardcoded for one machine. `bin/laixin-lane` assumes a specific repo root, tmux session names and engine binaries.
- Docs, rules and commit discipline are written in Chinese — that's where the substance is, and translating it would cost the precision.
- The skill cards target Claude Code / Codex skill loaders.
- No support, no stability guarantee. Fork it and rip out what's useful — the orchestration patterns and the failure log travel; the paths don't.

If the multi-agent orchestration part is what you're after, `bin/laixin-lane` and `skills/laixin-pipeline/SKILL.md` are the two files to read first. If you just want the lessons, read `AGENTS.md`.

## License

MIT — see [LICENSE](LICENSE).
