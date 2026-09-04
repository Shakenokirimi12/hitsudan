#!/bin/zsh
# Stop フック（asyncRewake）用。
#
# MCP は外部からセッションを起こせない（sampling 未実装、CLI にも注入口なし）が、
# ハーネス側の asyncRewake は終了コード 2 でモデルを起こす。応答を終えたあとも
# バックグラウンドで手書きを待ち、届いた瞬間にセッションを叩き起こす。
#
#   exit 0 … 何も起きなかった（起こさない）
#   exit 2 … 手書きが届いた（stderr の文面がモデルに渡る）

root="$HOME/.hitsudan"
label="${PWD:t}"
req="$root/requests/$label.json"
lock="$root/requests/$label.wait"

[[ -f "$req" ]] || exit 0

# 待ち役は 1 セッションにつき 1 つ。停止のたびに増やさない。
if [[ -f "$lock" ]]; then
  if kill -0 "$(cat "$lock" 2>/dev/null)" 2>/dev/null; then exit 0; fi
fi
echo $$ > "$lock"
trap 'rm -f "$lock"' EXIT

seq_of() { /usr/bin/python3 -c "import json,sys
try: print(json.load(open(sys.argv[1])).get('seq', 0))
except Exception: print(0)" "$1" 2>/dev/null || echo 0; }

asked=$(seq_of "$req")
deadline=$(( $(date +%s) + ${HITSUDAN_WAKE_TIMEOUT:-1800} ))

while (( $(date +%s) < deadline )); do
  # 回収済み・取り下げ済みなら黙って終わる。
  [[ -f "$req" ]] || exit 0
  if (( $(seq_of "$root/board.json") > asked )); then
    print -u2 "筆談ボードに手書きが届きました。mcp__hitsudan__collect_board で回収して、内容に応じて続けてください。"
    exit 2
  fi
  sleep 2
done
exit 0
