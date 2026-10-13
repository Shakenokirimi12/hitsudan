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
py=/usr/bin/python3

# 依頼のファイル名（キー）は hitsudan-mcp の sessionKey が決める:
#   環境変数 CLAUDE_CODE_SESSION_ID があればそれ、無ければプロジェクトの絶対パス
#   （CLAUDE_PROJECT_DIR、無ければ起動ディレクトリ）の SHA-256 先頭 16 桁に cwd- を付けたもの。
#   パスはシンボリックリンクを解決してから使う（/tmp と /private/tmp を同じものにする）。
#   MCP 側は realpath(3)、こちらは os.path.realpath で、どちらも /private を残す。
# フック側で同じ値が手に入る保証は無い（環境変数が渡るか、stdin の session_id と
# 一致するか、cd で cwd がずれていないか）。そこで候補を順に作り、実際に依頼ファイルが
# あるものを使う。どれも無ければ、待つべき依頼は無い。
input=""
[[ -t 0 ]] || input=$(cat)
key=$(print -r -- "$input" | $py -c '
import hashlib, json, os, re, sys
try: hook = json.load(sys.stdin)
except Exception: hook = {}
safe = lambda s: re.sub(r"[^A-Za-z0-9_-]", "_", s)
digest = lambda p: "cwd-" + hashlib.sha256(p.encode()).hexdigest()[:16]
candidates = [safe(s) for s in (os.environ.get("CLAUDE_CODE_SESSION_ID"), hook.get("session_id")) if s]
dirs = [p for p in (os.environ.get("CLAUDE_PROJECT_DIR"), hook.get("cwd"), os.getcwd()) if p]
# 解決後を先に試す。解決前は、パスを解決しない古い MCP サーバが出した依頼のため。
candidates += [digest(os.path.realpath(p)) for p in dirs] + [digest(p) for p in dirs]
for k in candidates:
    if os.path.isfile(os.path.join(sys.argv[1], "requests", k + ".json")):
        print(k); break
' "$root" 2>/dev/null)
[[ -n "$key" ]] || exit 0

req="$root/requests/$key.json"
reply="$root/replies/$key.json"
lock="$root/requests/$key.lock"
woke_file="$root/requests/$key.woke"

[[ -f "$req" ]] || exit 0

# 1 回の起動で必要な値をまとめて読む:
#   返信の seq / 依頼時の seq / 掲示期限（epoch 秒）/ 同期で待っている MCP の pid
state_of() { $py -c '
import json, sys
def load(p):
    try: return json.load(open(p))
    except Exception: return {}
r, q = load(sys.argv[1]), load(sys.argv[2])
print(int(r.get("seq", -1)), int(q.get("seq", 1 << 62)), int(q.get("until", 0)), int(q.get("waiter", 0)))
' "$reply" "$req" 2>/dev/null || echo "-1 0 0 0"; }

# ハーネスの timeout（1830 秒）より先に自分で終わる。request_board の掲示期限も
# 1800 秒が上限なので、依頼が出ている間はずっと見張れる。
deadline=$(( $(date +%s) + ${HITSUDAN_WAKE_TIMEOUT:-1800} ))

# 待ち役は 1 セッションにつき 1 つ。停止のたびに増やさない。
# mkdir は原子的なので、同時に起きた 2 つが両方とも取ることはない。
# 残っているロックは、その pid が本当にこのスクリプトとして生きているときだけ尊重する
# （pid は再利用されるので、kill -0 だけでは別のプロセスを掴みうる）。
# 死んだロックの奪取（rm → mkdir）は原子的でなく、2 つが同時に奪うと両方が取れたと
# 思いうる。そこで pid ファイルを「最後に書いた者が持ち主」とし、各自がループの
# たびに確かめて、自分でなくなったら黙って降りる。
#
# 生きている持ち主でも、見張りの期限（$lock/deadline）がこの依頼に足りなければ引き継ぐ。
# 持ち主の期限はそれが起動した時刻から数えるので、あとから出し直された依頼
# （until = 出した時刻 + 掲示期限）はそれより長く残りうる。そこで退いていると、
# 残りの時間を誰も見張らない。引き継ぎは pid を書くだけで、旧い持ち主は次の
# ループで自分のものでなくなったことに気づいて降りる。
if ! mkdir "$lock" 2>/dev/null; then
  holder=$(cat "$lock/pid" 2>/dev/null)
  # 取った直後で pid をまだ書いていないだけかもしれない。
  [[ -n "$holder" ]] || { sleep 1; holder=$(cat "$lock/pid" 2>/dev/null); }
  if [[ -n "$holder" ]] && ps -p "$holder" -o command= 2>/dev/null | grep -q board-wake; then
    read -r _ _ until _ <<< "$(state_of)"
    # 自分が見張れるのは自分の期限まで。依頼の期限が読めないときは、引き継いでも
    # 長く見張れる保証が無いので持ち主に任せる（さもないと停止のたびに奪い合う）。
    (( until > 0 )) || exit 0
    needed=$deadline
    (( until < deadline )) && needed=$until
    held=$(cat "$lock/deadline" 2>/dev/null)
    [[ "$held" == <-> ]] || held=0
    (( needed > held )) || exit 0
    # 旧い持ち主が終わり際にロックを消していても書けるように。
    mkdir -p "$lock" 2>/dev/null
  else
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || exit 0
  fi
fi
# 期限を先に書く。pid を見て持ち主を判断した者が、古い期限を読まないように。
claim() { { print $deadline > "$lock/deadline"; print $$ > "$lock/pid"; } 2>/dev/null; }
claim
owns_lock() { [[ "$(cat "$lock/pid" 2>/dev/null)" == "$$" ]]; }
# 奪われたあとに抜けるときは、相手のロックを消さない。
trap 'owns_lock && rm -rf "$lock"' EXIT

while (( $(date +%s) < deadline )); do
  # ロックを別の待ち役に奪われていたら、そちらに任せて降りる。ただしロックごと
  # 無くなっているのは、引き継いだ直後に旧い持ち主の終了処理が消したとき。
  # そのまま降りると誰も見張らないので、原子的に取り直す。
  if ! owns_lock; then
    [[ ! -e "$lock" ]] && mkdir "$lock" 2>/dev/null || exit 0
    claim
  fi
  # 回収済み・取り下げ済みなら黙って終わる。
  if [[ ! -f "$req" ]]; then rm -f "$woke_file"; exit 0; fi
  read -r current asked until waiter <<< "$(state_of)"
  if (( current > asked )); then
    # wait_for_board が同期で待っている間は、返信はそちらが受け取る。
    # ここで起こすと同じ返信で二重に起きる。
    if (( waiter > 0 )) && ps -p "$waiter" -o comm= 2>/dev/null | grep -q hitsudan-mcp; then
      sleep 2; continue
    fi
    # 同じ返信で二度は起こさない。伝えたのに回収されないまま停止するたび
    # 叩き起こしていては、ただの妨害になる。毎回読み直すのは、引き継ぎの直前に
    # 旧い持ち主が起こしていることがあるため。
    woke=$(cat "$woke_file" 2>/dev/null)
    [[ "$woke" == <-> ]] || woke=-1
    if (( current == woke )); then exit 0; fi
    # 引き継ぎの瞬間は旧い持ち主と新しい持ち主が同じ返信を同時に見うる。起こす権利は
    # mkdir で 1 つだけにする（ロックの中に置くので、ロックと一緒に片付く）。
    mkdir "$lock/woke-$current" 2>/dev/null || exit 0
    echo "$current" > "$woke_file"
    print -u2 "筆談ボードに手書きが届きました。mcp__hitsudan__collect_board で回収して、内容に応じて続けてください。"
    exit 2
  fi
  # 掲示期限を過ぎた依頼はアプリがボードから下ろしている。もう返信は来ない。
  if (( until > 0 && $(date +%s) > until )); then exit 0; fi
  sleep 2
done
exit 0
