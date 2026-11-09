#!/usr/bin/env bash
# codex-plan 的分支測試：用假 codex／假 lint，不呼叫真模型。
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo"
# 假 codex：記下參數；FAKE_WRITE=1 時把工單寫到 -o 指定的路徑（FAKE_FENCE=1 則包圍欄）；模擬 codex 的 stderr 表頭與 token 行
cat > "$tmp/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$(dirname "$0")/../args"
cat > "$(dirname "$0")/../stdin"
out=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
if [ "${FAKE_WRITE:-0}" = 1 ] && [ -n "$out" ]; then
  if [ "${FAKE_FENCE:-0}" = 1 ]; then printf '```markdown\n輪子：設定\n## 任務\nx\n```\n' > "$out"
  else printf '輪子：設定\n## 任務\nx\n' > "$out"; fi
fi
printf 'session id: sess-123\n--------\ntokens used\n4,321\n' >&2
exit "${FAKE_RC:-0}"
EOF
chmod +x "$tmp/bin/codex"
printf 'do it\n' > "$tmp/p.md"
fail=0
check() { [ "$2" = "$3" ] && echo "ok   $1" || { echo "FAIL $1: want $3 got $2"; fail=1; }; }
plan() { PATH="$tmp/bin:$PATH" "$here/bin/codex-plan" "$tmp/p.md" "$tmp/out/t.md" "$tmp/repo"; }
run() { CODEXLOOP_LINT="$1" FAKE_WRITE="$2" plan >/dev/null 2>&1; echo $?; }
nargs() { grep -cx -- "$1" "$tmp/args"; }

check "寫出工單且 lint 過 → 0" "$(run true 1)" 0
check "沒寫出工單 → 3" "$(run true 0)" 3
check "lint 不過 → lint 的 rc" "$(run false 1)" 1
check "參數不足 → 2" "$("$here/bin/codex-plan" a b >/dev/null 2>&1; echo $?)" 2
check "prompt 空 → 2" "$(: > "$tmp/e.md"; PATH="$tmp/bin:$PATH" "$here/bin/codex-plan" "$tmp/e.md" "$tmp/t.md" "$tmp/repo" >/dev/null 2>&1; echo $?)" 2
check "repo 不存在 → 2" "$(PATH="$tmp/bin:$PATH" "$here/bin/codex-plan" "$tmp/p.md" "$tmp/t.md" "$tmp/nope" >/dev/null 2>&1; echo $?)" 2

run true 1 >/dev/null
check "預設唯讀沙箱" "$(nargs read-only)" 1
check "預設不載入使用者 config（省 token）" "$(nargs --ignore-user-config)" 1
check "預設不載入規則檔" "$(nargs --ignore-rules)" 1
check "預設推理強度 medium" "$(nargs model_reasoning_effort=medium)" 1
check "沒設 session 不用 resume" "$(nargs resume)" 0
check "prompt 走 stdin 且含任務" "$(grep -c 'do it' "$tmp/stdin")" 1

CODEXLOOP_FULL_CONFIG=1 CODEXLOOP_EFFORT=high CODEXLOOP_MODEL=m1 CODEXLOOP_LINT=true FAKE_WRITE=1 plan >/dev/null 2>&1
check "FULL_CONFIG=1 → 不帶 --ignore-user-config" "$(nargs --ignore-user-config)" 0
check "EFFORT 有傳" "$(nargs model_reasoning_effort=high)" 1
check "MODEL 有傳" "$(nargs m1)" 1

CODEXLOOP_SESSION=sid9 CODEXLOOP_LINT=true FAKE_WRITE=1 plan >/dev/null 2>&1
check "session id → resume＋id" "$(nargs resume)$(nargs sid9)" 11
check "resume 仍唯讀" "$(nargs sandbox_mode=read-only)" 1
CODEXLOOP_SESSION=last CODEXLOOP_LINT=true FAKE_WRITE=1 plan >/dev/null 2>&1
check "session=last → --last" "$(nargs --last)" 1

out="$(CODEXLOOP_LINT=true FAKE_WRITE=1 plan 2>&1 >/dev/null)"
check "回報 session id" "$(printf '%s' "$out" | grep -c 'session id sess-123')" 1
check "回報 token 用量" "$(printf '%s' "$out" | grep -c 'tokens used 4,321')" 1

CODEXLOOP_LINT=true FAKE_WRITE=1 FAKE_FENCE=1 plan >/dev/null 2>&1
check "整張工單被圍欄包住 → 去圍欄" "$(head -1 "$tmp/out/t.md")" '輪子：設定'
check "去圍欄後行數正確" "$(wc -l < "$tmp/out/t.md" | tr -d ' ')" 3
# 退回修改：目標檔已存在時，跑的過程中它必須還在；沒寫出新工單時原檔不能被刪
printf 'OLD\n' > "$tmp/out/t.md"
CODEXLOOP_LINT=true FAKE_WRITE=0 plan >/dev/null 2>&1
check "沒寫出新工單 → 原檔保留" "$(cat "$tmp/out/t.md")" OLD
CODEXLOOP_LINT=true FAKE_WRITE=1 plan >/dev/null 2>&1
check "寫出新工單 → 覆蓋原檔" "$(head -1 "$tmp/out/t.md")" '輪子：設定'
check "不留 .new 殘檔" "$(ls "$tmp/out" | grep -c 'new$')" 0
exit $fail
