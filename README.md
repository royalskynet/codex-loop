# codex-loop

[繁體中文](README.zh-TW.md)

A bounded plan → execute → audit loop for coding agents, with [Codex CLI](https://github.com/openai/codex) as the planner and auditor. Codex writes a work order, an executor agent implements it in a git worktree, the main session reruns the acceptance commands itself, and Codex audits the diff. Every finding gets a ruling; a gate decides mechanically whether another round is needed.

It is a sibling of [dsloop](https://github.com/royalskynet/dsloop), which uses DeepSeek V4 Pro through opencode. The flow is the same; the planner, the token-saving rules and the helper script are Codex-specific.

It ships as a Claude Code slash command (`/codex-loop`) plus one helper script (`bin/codex-plan`).

## Why

Two things make agent loops expensive:

1. **The planner re-reads the whole repo and its own config every round.** codex-loop starts Codex without your user config and rules (`--ignore-user-config --ignore-rules`), gives it a map instead of files (paths + line ranges), reuses one Codex session across rounds, tiers the reasoning effort, and keeps anything checkable mechanically (lint, exit codes, mutation checks) away from the model.
2. **Loops take many rounds to converge.** codex-loop splits behaviour changes into a tests-first order and an implementation order, requires a negative-control line in every acceptance block, sweeps a whole defect class in the first audit, and stops after two failures on the same item instead of retrying blindly.

Measured on codex-cli 0.163.0 with a one-line prompt: 19,217 tokens with the author's config loaded, 8,450 without it (56% less). The figure depends on how large your own config and rules are; `codex-plan` prints `tokens used` after every call so you can check yours.

## Flow

```
goal ──► Codex plans (wheel first) ──► main session reviews work order ──► deep-lint
            ▲                                                                  │
            │                                                                  ▼
     gate exit 10                                        [spec review if locks / dedup /
     (accepts remain)                                     state machine / outbound sends]
            │                                                                  │
            │                                                                  ▼
  rule on findings ◄── Codex audits diff ◄── main session reruns wo-verify ◄── deep-run in worktree
            │
            ▼
     gate exit 0 → converged
```

| Role | Who | Does |
| --- | --- | --- |
| Planner + auditor | Codex CLI (`codex exec`, read-only sandbox) | Runs wheel for existing solutions, writes work orders, audits diffs |
| Main session | Claude Code | Rules on work orders and findings, reruns acceptance itself; writes no product code |
| Executor | `deep-run` | Implements the work order in a worktree |

Full rules: [commands/codex-loop.en.md](commands/codex-loop.en.md).

## Requirements

| Tool | Source | Without it |
| --- | --- | --- |
| Claude Code | [claude.com/claude-code](https://claude.com/claude-code) | No `/codex-loop` command; you can still follow the steps by hand |
| Codex CLI, logged in | [openai/codex](https://github.com/openai/codex) | `codex-plan` exits 2 |
| audit-devil | [royalskynet/audit-devil](https://github.com/royalskynet/audit-devil) | No audit or gate step; the loop cannot decide convergence |
| deep-run | [royalskynet/deepclaude-flash](https://github.com/royalskynet/deepclaude-flash) | No executor; swap in any agent that takes a work order and a worktree |
| deep-lint, wo-verify | [royalskynet/orchestrator](https://github.com/royalskynet/orchestrator) | `codex-plan` fails at lint (set `CODEXLOOP_LINT=true` to skip); rerun the acceptance block by hand instead of `wo-verify` |
| wheel skill (optional) | [royalskynet/wheel-it](https://github.com/royalskynet/wheel-it) | The planner falls back to checking installed tools and the repo's existing scripts |

## Install

```bash
git clone https://github.com/royalskynet/codex-loop.git
cd codex-loop
ln -s "$PWD/commands/codex-loop.en.md" ~/.claude/commands/codex-loop.md   # or codex-loop.md for the Chinese version
ln -s "$PWD/bin/codex-plan" ~/.local/bin/codex-plan                         # any directory on PATH
```

Point audit-devil at Codex with the same token-saving flags (once):

```bash
audit-devil config --preset cmd --cmd 'codex exec --skip-git-repo-check -s read-only --ignore-user-config --ignore-rules -c model_reasoning_effort=medium -c model_verbosity=low -C {material} -'
```

audit-devil's built-in `--preset codex` also works but loads your Codex config and uses `high` effort, which costs more per call.

## Use

In Claude Code:

```
/codex-loop <plan or goal file> [--repo <path>] [--max-rounds N]
```

Planning step on its own:

```bash
codex-plan prompt.md <repo>/.audit-devil/r1.md <repo>
```

Codex runs in a read-only sandbox with the repo as its working directory; the work order is the last message, which `codex-plan` saves with `-o`. On exit it prints `codex rc`, the session id and `tokens used` to stderr.

`codex-plan` exit codes: `0` work order written and lint passed; `2` bad arguments, empty prompt, missing repo or no codex; `3` the model wrote no work order; anything else is the lint exit code.

| Variable | Default | Purpose |
| --- | --- | --- |
| `CODEXLOOP_EFFORT` | `medium` | `model_reasoning_effort` for the planning call (`low` for rework tickets) |
| `CODEXLOOP_MODEL` | unset (Codex default) | Planning model, passed as `-m` |
| `CODEXLOOP_SESSION` | unset | Continue a Codex session (`codex exec resume`): a session id, or `last` for the most recent one in this repo |
| `CODEXLOOP_FULL_CONFIG` | `0` | `1` loads your Codex config and rules (more tokens) |
| `CODEXLOOP_LINT` | `deep-lint` | Work-order linter; `true` skips it |

Gate exit codes (from `audit-devil gate`): `0` converged, `10` accepts remain → back to planning, `3` undecided findings, `4` accept count flat for 3 rounds → last attempt, then stop.

## Prior art

Token and round-count rules borrow from: [aider architect mode and repo map](https://aider.chat/docs/repomap.html), [OpenHands context condenser](https://openhands.dev/blog/openhands-context-condensensation-for-more-efficient-ai-agents), [GitHub spec-kit](https://github.com/github/spec-kit) (clarify step), [SWE-agent cost limits](https://swe-agent.com/latest/reference/model_config/).

## Tests

```bash
bash tests/codex_plan_test.sh
```

Uses a fake `codex` and linter; no model is called.

## License

MIT
