---
description: Codex 先 /wheel 找現成方法再規劃 → 主 session 裁決 → deep 執行 → Codex 驗收驗屍 → 裁決後打回的迴圈，gate 機械判定收斂，全程壓低 token
argument-hint: "<計畫或目標檔> [--repo <路徑>] [--max-rounds N]"
---

目標：$ARGUMENTS

## 1. 角色

- Codex（`codex exec`，唯讀沙箱）：**規劃**（寫工單）與**驗收**。規劃前先跑 wheel 找現成方法與資源，不自造。
- 主 session：裁決工單、裁決審查條目、自己重跑驗收。**不寫產品碼，也不寫工單**（唯一例外：第 4 節連敗 2 次的最後一搏）；工單不合格就退回 Codex 重寫並附理由。
- deep：`deep-run <工單.md> <worktree>` 執行（裸名、背景跑）。
- 第二模型：audit-devil 的 codex 型審查，負責驗收、驗屍、給優化方案（設定見 1.5）。
- `--repo` 未給就問 `git rev-parse --show-toplevel`；`--max-rounds` 預設 6。

## 1.5 省 token、少跑幾輪

Codex 的用量記在你的 OpenAI 方案額度或 API 帳單上；主 session 或腳本能先做的不交 Codex。

**省 token**
- **不載入使用者設定與規則檔**（最大單項）：`codex-plan` 預設帶 `--ignore-user-config --ignore-rules`。實測 codex-cli 0.163.0、一句話提示，用量 19,217 → 8,450 token（省 56%，數字隨你的 config 大小而變）。要載入就設 `CODEXLOOP_FULL_CONFIG=1`。
- **審查端也要同樣設定**：內建 `--preset codex` 不帶這兩個旗標，改存自訂指令一次即可：
  ```bash
  audit-devil config --preset cmd --cmd 'codex exec --skip-git-repo-check -s read-only --ignore-user-config --ignore-rules -c model_reasoning_effort=medium -c model_verbosity=low -C {material} -'
  ```
- **推理強度分級**：規劃與退回改單用 `medium`（預設）或 `low`（`CODEXLOOP_EFFORT=low`）；只有首輪送審、規格審查這種要找深層缺口的才用 `high`。
- **只收最後一則訊息**：工單取自 `-o`（最後一則訊息），不開 `--json`、事件流丟掉；唯讀沙箱不給寫檔，免得它花 token 跑工具寫檔。
- **同目標續用 session**：`CODEXLOOP_SESSION=<id|last> codex-plan …`（`codex exec resume`），Codex 不必重讀已讀過的檔；`codex-plan` 每次結束會印 session id 與 `tokens used`（resume 時看起來是 session 累計，單輪用量取差值）。
- 主 session 先跑 `wheel_registry.py find`：有 `[有效]` 卡就把卡貼進 prompt，叫 Codex 直接引用、不重查。
- prompt 自含：目標一句、上輪 accept 條目原文、相關檔的路徑＋行號範圍、驗收用的測試指令。明令只讀列出的範圍，不掃整個 repo、不跑測試（借 aider repo map：給地圖不給整檔）。
- prompt 前段固定（規則、工單格式），變動內容放最後，讓供應端前綴快取吃得到。
- 退回工單只送「哪段、為何不合格」，叫 Codex 改那幾段，不重寫整張。
- 送審 bundle 只放本輪 diff 與它直接呼叫的檔；`--note` 只寫要審的重點；多輪時附前幾輪 findings 的一段摘要，不重貼舊 diff（借 OpenHands condenser）。
- 機械能判的（lint、exit code、突變）不交 Codex；規格審查只在第 2 步條件觸發時才送。
- 每輪把 `codex-plan` 印的 `tokens used` 寫進 ledger 備註，看哪一步最貴。

**少跑幾輪**
- 測試先行：會改行為的目標拆兩張單，先「只寫測試、在舊碼上必須紅」，再「只改實作、測試不准動」。執行代理不能只改實作不補測試，也不能改測試遷就實作。
- 工單驗收必含「沒改的情況下會失敗」的那一行（負控制），Codex 寫不出來就代表需求還沒釐清，先回 Codex 補歧義清單（借 spec-kit clarify）。
- 實作單（writes 不含測試路徑）的驗收段第一行固定 `git checkout <base> -- <測試路徑>`：照 SWE-bench（v4.1.0 `swebench/harness/test_spec/python.py` L405–455）先把測試蓋回開工版本再跑，執行者改測試、刪測試、加 skip 都不影響判定。只限 worktree；在有別人未提交改動的主 repo 不用（會蓋掉）。測試單不加這行，改由審 diff 把關。
- 首輪送審 `--note` 要求窮舉同類缺口（同一模式在別處是否重犯）；後輪只審本輪 diff 與前輪 accept 是否修好，新挖的非回歸問題預設 defer。
- 輪數上限（`--max-rounds`）與連敗 2 次規則照第 4 節，不加碼重試。

## 2. 每輪步驟

1. Codex 規劃並寫工單 `.audit-devil/<輪次>.md`（四段：任務／驗收〔每行一條指令、exit 0 才算過〕／不動／禁止；開頭一行「輪子：」＝wheel 輪子卡首行）：
   ```bash
   codex-plan <prompt.md> <repo>/.audit-devil/<輪次>.md <repo>   # 本 repo 的 bin/codex-plan；rc 由 deep-lint 判
   ```
   prompt.md 照 1.5 寫，開頭固定一句：「先照 wheel SKILL.md 跑 wheel（找不到就至少查本機已裝工具與 repo 內既有腳本／測試／CI），把輪子卡寫進工單；工單全文放在最後一則訊息。」
   主 session 只審：輪子卡有沒有查過（不是訓練印象）、驗收能不能失敗、範圍有沒有越界。不合格→附理由叫 Codex 重寫（不計輪次）。
2. `deep-lint <工單>`；不通過就改工單，不派。
   - **先裁決才派**：工單碰到鎖、去重、狀態機、故障注入或對外發送，先送規格審查（不計輪次）：
     ```bash
     audit-devil bundle --root <repo> --file <工單> --file <相關現役碼…> \
       --note "<只審規格：重複執行、漏寫前提、測試打不打得到分支>" --id spec-<輪次>
     audit-devil send <bundle> && audit-devil check <bundle>
     ```
     逐條填 `verdict.md` 後跑 `audit-devil gate <bundle>`（不帶 `--ledger`，不進收斂統計）。exit 3＝還沒裁決完，**不准進第 3 步**；accept 條目交 Codex 改寫進工單，重跑 `deep-lint` 才派。
3. 從 main 開 worktree：`git worktree add <worktree> -b loop/<n> main`。
4. `deep-run <工單.md> <worktree>`，背景跑，結束再收件。
5. 收件後主 session 到 worktree 自己重跑 `wo-verify <工單>`；不過就把失敗輸出交 Codex 寫下一張修補工單，回第 1 步。
6. 過：`git merge --ff-only` 進主 repo，再在主 repo 重跑 `wo-verify <工單>`。
7. 送審：
   ```bash
   audit-devil bundle --root <repo> --diff <本輪範圍> \
     --note "<目標、上輪裁決摘要、要它驗屍前輪必修＋給優化方案>"
   audit-devil send <bundle>
   audit-devil check <bundle>     # exit 1：捏造的條目一律 reject
   ```
8. 逐條填 `<bundle>/verdict.md`（`decision:` = accept／reject／defer；reject／defer 必寫 `reason:`）。
9. `audit-devil gate <bundle> --ledger <repo>/.audit-devil/loop.tsv`，看 exit code 走第 3 節。

## 3. 依 gate exit code

| exit | 意義 | 動作 |
| --- | --- | --- |
| 0 | 收斂，無 accept | 跑最終驗收；commit／push 照使用者指示 |
| 10 | 還有 accept | accept 條目交 Codex 寫成下一張修補工單，回第 1 步（續用 session） |
| 3 | 有條目未裁決或缺理由 | 先補 `verdict.md`，再跑 gate |
| 4 | 連續 3 輪 accept 不降 | **停止盲試**：走第 4 節「連敗 2 次」的最後一搏 |

## 4. 硬規則

- 同一條連敗 2 次 → 最後一搏：主 session 親自跑 `/wheel` 找換法，自己改寫工單，派 deep **一次**，主 session 自己重跑驗收。仍失敗 → **停**，寫摘要總結回報（目標、各輪做法與失敗原文、根因判斷、剩餘缺口、建議下一步），不再派任何執行人。
- 修法由 Codex 規劃、主 session 裁決；主 session 可退回，不照單全收。
- 驗收不放寬既有斷言。
- 突變驗證：拿掉這輪的修正，對應測試必須 fail。
- `--max-rounds` 到頂就停，回報剩餘條目與最後一輪 ledger。

## 5. 收尾回報

- 一行結論（收斂／到頂／換方法）。
- 每輪 high／accept 走勢：印 `cat <repo>/.audit-devil/loop.tsv`。
- options：剩下的 defer 留哪、要不要再跑一輪。
