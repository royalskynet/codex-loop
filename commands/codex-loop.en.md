---
description: Codex runs /wheel for existing solutions, then plans → main session rules → deep executes → Codex audits and post-mortems → rulings feed the next round; gate mechanically decides convergence; token use kept low throughout
argument-hint: "<plan or goal file> [--repo <path>] [--max-rounds N]"
---

Goal: $ARGUMENTS

## 1. Roles

- Codex (`codex exec`, read-only sandbox): **plans** (writes work orders) and **audits**. Before planning it runs wheel to find existing methods and resources instead of building from scratch.
- Main session: rules on work orders and audit findings, reruns acceptance itself. **Writes neither product code nor work orders** (sole exception: the last attempt in section 4 after two failures); returns a substandard work order to Codex with reasons.
- deep: executes via `deep-run <workorder.md> <worktree>` (bare name, in the background).
- Second model: audit-devil with a Codex command, which audits, post-mortems and proposes optimisations (setup in 1.5).
- Without `--repo`, ask `git rev-parse --show-toplevel`; `--max-rounds` defaults to 6.

## 1.5 Saving tokens, running fewer rounds

Codex usage is charged to your OpenAI plan quota or API bill; whatever the main session or a script can do first stays off Codex.

**Saving tokens**
- **Do not load user config or rules** (the biggest single item): `codex-plan` passes `--ignore-user-config --ignore-rules` by default. Measured on codex-cli 0.163.0 with a one-line prompt: 19,217 → 8,450 tokens (56% less; the number depends on how big your config is). Set `CODEXLOOP_FULL_CONFIG=1` to load them.
- **Give the auditor the same flags**: the built-in `--preset codex` omits them. Save a custom command once:
  ```bash
  audit-devil config --preset cmd --cmd 'codex exec --skip-git-repo-check -s read-only --ignore-user-config --ignore-rules -c model_reasoning_effort=medium -c model_verbosity=low -C {material} -'
  ```
- **Tier the reasoning effort**: planning and rework tickets use `medium` (default) or `low` (`CODEXLOOP_EFFORT=low`); only the first audit and the spec review, which hunt for deep gaps, use `high`.
- **Keep only the final message**: the work order is taken from `-o` (the last message); no `--json`, the event stream is dropped. The read-only sandbox forbids writes, so the model does not spend tokens running tools to write the file.
- **Reuse one session per goal**: `CODEXLOOP_SESSION=<id|last> codex-plan …` (`codex exec resume`) so Codex skips files it has read. `codex-plan` prints the session id and `tokens used` on exit (on resume the figure looks cumulative for the session, so take the difference for one round).
- Main session runs `wheel_registry.py find` first: if there is a `[valid]` card, paste it into the prompt and tell Codex to cite it, not search again.
- Self-contained prompt: one-sentence goal, the previous round's accept items verbatim, paths plus line ranges for the relevant files, the acceptance commands. Say explicitly: read only the listed ranges, do not scan the repo, do not run tests (borrowed from aider's repo map: give a map, not whole files).
- Keep the prompt prefix fixed (rules, work-order format) and put what changes last, so the provider's prefix cache can hit.
- When returning a work order, send only which section failed and why, and ask for those sections to be rewritten, not the whole ticket.
- The audit bundle holds only this round's diff and the files it calls directly; `--note` states only what to audit; later rounds add a short summary of earlier findings instead of re-pasting old diffs (borrowed from the OpenHands condenser).
- Anything checkable mechanically (lint, exit codes, mutation checks) stays off Codex; the spec review runs only when step 2's condition fires.
- Record each round's `tokens used` (printed by `codex-plan`) in the ledger notes to see which step costs most.

**Fewer rounds**
- Tests first: split behaviour changes into two tickets, first "write tests only, must be red on the old code", then "change the implementation only, tests untouched". The executor may neither change the implementation without adding tests nor change tests to fit the implementation.
- Every acceptance block carries a line that fails when nothing was changed (negative control). If Codex cannot write one, the requirement is not clear yet; first have Codex list the ambiguities (borrowed from spec-kit clarify).
- The first audit's `--note` demands an exhaustive sweep of the defect class (does the same pattern recur elsewhere); later rounds audit only this round's diff and whether last round's accepts are fixed; newly found non-regression issues default to defer.
- `--max-rounds` and the two-failure rule in section 4 apply as written; no extra retries.

## 2. Steps per round

1. Codex plans and writes the work order `.audit-devil/<round>.md` (four sections: task / acceptance [one command per line, exit 0 passes] / untouched / prohibitions; the first line is `輪子:` = the first line of the wheel card):
   ```bash
   codex-plan <prompt.md> <repo>/.audit-devil/<round>.md <repo>   # this repo's bin/codex-plan; rc comes from deep-lint
   ```
   Write prompt.md per 1.5, opening with one fixed sentence: "First run wheel per its SKILL.md (if it is missing, at least check locally installed tools and the repo's existing scripts, tests and CI), put the wheel card in the work order; the work order's full text goes in the last message."
   The main session only reviews: was the wheel card actually researched (not recalled), can the acceptance fail, does the scope stay in bounds. If not, return it to Codex with reasons (does not count as a round).
2. `deep-lint <workorder>`; if it fails, fix the order, do not dispatch.
   - **Rule before dispatching**: if the order touches locks, dedup, state machines, fault injection or outbound sends, send it to a spec review first (does not count as a round):
     ```bash
     audit-devil bundle --root <repo> --file <workorder> --file <relevant live code…> \
       --note "<spec only: re-runs, missing preconditions, whether tests reach the branches>" --id spec-<round>
     audit-devil send <bundle> && audit-devil check <bundle>
     ```
     Fill in `verdict.md` finding by finding, then run `audit-devil gate <bundle>` (no `--ledger`, so it stays out of convergence stats). Exit 3 means rulings are incomplete: **do not go to step 3**; hand accepted findings to Codex to fold into the order, rerun `deep-lint`, then dispatch.
3. Open a worktree from main: `git worktree add <worktree> -b loop/<n> main`.
4. `deep-run <workorder.md> <worktree>` in the background; collect when it ends.
5. The main session reruns `wo-verify <workorder>` in the worktree itself; if it fails, give Codex the failure output to write the next fix order and go back to step 1.
6. On pass: `git merge --ff-only` into the main repo, then rerun `wo-verify <workorder>` there.
7. Audit:
   ```bash
   audit-devil bundle --root <repo> --diff <this round's range> \
     --note "<goal, summary of last round's rulings, ask for a post-mortem of last round's must-fixes plus optimisation proposals>"
   audit-devil send <bundle>
   audit-devil check <bundle>     # exit 1: fabricated items are rejected
   ```
8. Fill in `<bundle>/verdict.md` finding by finding (`decision:` = accept / reject / defer; reject and defer need a `reason:`).
9. `audit-devil gate <bundle> --ledger <repo>/.audit-devil/loop.tsv` and follow section 3 by exit code.

## 3. By gate exit code

| exit | Meaning | Action |
| --- | --- | --- |
| 0 | Converged, no accepts | Run the final acceptance; commit / push as the user directs |
| 10 | Accepts remain | Hand them to Codex as the next fix order, back to step 1 (reuse the session) |
| 3 | Findings undecided or missing reasons | Finish `verdict.md`, then rerun the gate |
| 4 | Accept count flat for 3 rounds | **Stop blind retries**: take the last attempt in section 4 |

## 4. Hard rules

- The same item failing twice → last attempt: the main session runs `/wheel` itself to find a different approach, rewrites the work order itself, dispatches deep **once**, and reruns acceptance itself. If it still fails, **stop** and write a summary (goal, what each round did with the original failure text, root-cause judgment, remaining gaps, suggested next step); dispatch no further executor.
- Codex plans the fix, the main session rules; the main session may send it back and does not accept everything as written.
- Acceptance never loosens an existing assertion.
- Mutation check: remove this round's fix and the matching test must fail.
- At `--max-rounds` stop and report the remaining items and the last ledger.

## 5. Closing report

- One line: converged / hit the cap / changed approach.
- High / accept trend per round: print `cat <repo>/.audit-devil/loop.tsv`.
- options: where the remaining defers go, whether to run another round.
