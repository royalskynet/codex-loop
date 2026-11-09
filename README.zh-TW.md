# codex-loop

[English](README.md)

給 coding agent 用的有界「規劃 → 執行 → 審計」迴圈，規劃與審計由 [Codex CLI](https://github.com/openai/codex) 擔任。Codex 寫工單，執行代理在 git worktree 實作，主 session 自己重跑驗收指令，再由 Codex 審計 diff。每條審查發現都要裁決，gate 機械判定要不要再跑一輪。

這是 [dsloop](https://github.com/royalskynet/dsloop)（經 opencode 用 DeepSeek V4 Pro）的姊妹版。流程相同，規劃者、省 token 規則與輔助腳本是 Codex 專用的。

內容是一個 Claude Code 斜線指令（`/codex-loop`）加一支輔助腳本（`bin/codex-plan`）。

## 為什麼

agent 迴圈貴在兩件事：

1. **規劃者每輪重讀整個 repo 與自己的設定。** codex-loop 啟動 Codex 時不載入你的使用者設定與規則檔（`--ignore-user-config --ignore-rules`），給它地圖（路徑＋行號範圍）而不是整檔，跨輪續用同一個 Codex session，推理強度分級，能機械判斷的（lint、exit code、突變檢查）不交給模型。
2. **迴圈要跑很多輪才收斂。** codex-loop 把改行為的目標拆成先測試、後實作兩張單，每個驗收段必含一行負控制，首輪審計就窮舉整類缺口，同一條連敗 2 次就停，不盲試。

實測 codex-cli 0.163.0、一句話提示：載入作者自己的 config 用 19,217 token，不載入用 8,450（省 56%）。實際數字看你自己的 config 與規則檔多大；`codex-plan` 每次呼叫後會印 `tokens used`，可自行核對。

## 流程

```
目標 ──► Codex 規劃（先 wheel）──► 主 session 審工單 ──► deep-lint
            ▲                                                │
            │                                                ▼
     gate exit 10                           [碰到鎖／去重／狀態機／對外發送時先做規格審查]
     （還有 accept）                                           │
            │                                                ▼
  裁決審查條目 ◄── Codex 審 diff ◄── 主 session 重跑 wo-verify ◄── deep-run（worktree）
            │
            ▼
     gate exit 0 → 收斂
```

| 角色 | 誰 | 做什麼 |
| --- | --- | --- |
| 規劃＋審計 | Codex CLI（`codex exec`，唯讀沙箱） | 跑 wheel 找現成方案、寫工單、審 diff |
| 主 session | Claude Code | 裁決工單與審查條目、自己重跑驗收；不寫產品碼 |
| 執行 | `deep-run` | 在 worktree 實作工單 |

完整規則：[commands/codex-loop.md](commands/codex-loop.md)。

## 需求

| 工具 | 來源 | 沒有的話 |
| --- | --- | --- |
| Claude Code | [claude.com/claude-code](https://claude.com/claude-code) | 沒有 `/codex-loop` 指令；仍可照步驟手動做 |
| Codex CLI（已登入） | [openai/codex](https://github.com/openai/codex) | `codex-plan` 以 2 結束 |
| audit-devil | [royalskynet/audit-devil](https://github.com/royalskynet/audit-devil) | 沒有審計與 gate，無法判定收斂 |
| deep-run | [royalskynet/deepclaude-flash](https://github.com/royalskynet/deepclaude-flash) | 沒有執行者；可換成任何吃「工單＋worktree」的 agent |
| deep-lint、wo-verify | [royalskynet/orchestrator](https://github.com/royalskynet/orchestrator) | `codex-plan` 卡在 lint（設 `CODEXLOOP_LINT=true` 跳過）；改手動重跑驗收段代替 `wo-verify` |
| wheel skill（選用） | [royalskynet/wheel-it](https://github.com/royalskynet/wheel-it) | 規劃者退回只查本機已裝工具與 repo 既有腳本 |

## 安裝

```bash
git clone https://github.com/royalskynet/codex-loop.git
cd codex-loop
ln -s "$PWD/commands/codex-loop.md" ~/.claude/commands/codex-loop.md   # 英文版用 codex-loop.en.md
ln -s "$PWD/bin/codex-plan" ~/.local/bin/codex-plan                      # 任何在 PATH 上的資料夾
```

讓 audit-devil 用同樣的省 token 旗標呼叫 Codex（一次就好）：

```bash
audit-devil config --preset cmd --cmd 'codex exec --skip-git-repo-check -s read-only --ignore-user-config --ignore-rules -c model_reasoning_effort=medium -c model_verbosity=low -C {material} -'
```

audit-devil 內建的 `--preset codex` 也能用，但會載入你的 Codex 設定且用 `high` 強度，每次較貴。

## 使用

在 Claude Code：

```
/codex-loop <計畫或目標檔> [--repo <路徑>] [--max-rounds N]
```

單獨跑規劃步驟：

```bash
codex-plan prompt.md <repo>/.audit-devil/r1.md <repo>
```

Codex 在唯讀沙箱、以 repo 為工作目錄執行；工單就是最後一則訊息，由 `codex-plan` 用 `-o` 存檔。結束時往 stderr 印 `codex rc`、session id 與 `tokens used`。

`codex-plan` 結束碼：`0` 工單已寫出且 lint 通過；`2` 參數錯、prompt 空、repo 不存在或沒有 codex；`3` 模型沒寫出工單；其他值是 lint 的結束碼。

| 變數 | 預設 | 用途 |
| --- | --- | --- |
| `CODEXLOOP_EFFORT` | `medium` | 規劃呼叫的 `model_reasoning_effort`（退回改單可用 `low`） |
| `CODEXLOOP_MODEL` | 未設（用 Codex 預設） | 規劃模型，以 `-m` 傳入 |
| `CODEXLOOP_SESSION` | 未設 | 續用 Codex session（`codex exec resume`）：session id，或 `last`＝本 repo 最近一個 |
| `CODEXLOOP_FULL_CONFIG` | `0` | 設 `1` 才載入你的 Codex 設定與規則檔（較耗 token） |
| `CODEXLOOP_LINT` | `deep-lint` | 工單 linter；設 `true` 跳過 |

Gate 結束碼（來自 `audit-devil gate`）：`0` 收斂、`10` 還有 accept → 回規劃、`3` 有未裁決條目、`4` accept 數連 3 輪沒降 → 最後一搏，再不行就停。

## 借鏡

省 token 與少跑幾輪的規則借自：[aider architect mode 與 repo map](https://aider.chat/docs/repomap.html)、[OpenHands context condenser](https://openhands.dev/blog/openhands-context-condensensation-for-more-efficient-ai-agents)、[GitHub spec-kit](https://github.com/github/spec-kit)（clarify 步驟）、[SWE-agent 成本上限](https://swe-agent.com/latest/reference/model_config/)。

## 測試

```bash
bash tests/codex_plan_test.sh
```

用假的 `codex` 與 linter，不呼叫任何模型。

## 授權

MIT
