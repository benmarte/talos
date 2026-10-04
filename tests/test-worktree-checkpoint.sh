#!/usr/bin/env bash
# test-worktree-checkpoint.sh -- `pipeline-worktree.sh checkpoint` and `handoff` (#419).
# Local bare origin, stub gh, inline stub runners; no real LLM, no network.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

WT="$TALOS_ROOT/scripts/pipeline-worktree.sh"
ORIGIN="$SANDBOX/origin.git"
HF_DIR="$SANDBOX/.talos/handoff"

git config user.email "test@talos"
git config user.name "talos test"
git symbolic-ref HEAD refs/heads/main
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git remote set-url origin "$ORIGIN"
printf '.talos/\n.claude/worktrees/\n' > .gitignore
printf 'base\n' > base.txt
git add .gitignore base.txt
git commit -q -m "root"
git push -q origin main
git fetch -q origin

# pj <file> <key>: print one key from a JSON file (python3 -I).
pj() { python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2], "<absent>"); print(json.dumps(v) if not isinstance(v, str) else v)' "$1" "$2"; }
# mode <path>: octal permission bits.
mode() { python3 -I -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
origin_ref() { git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/$1" 2>/dev/null || echo none; }
new_wt() {  # <n> <slug>: create a developer worktree, print its path
  bash "$WT" create "$1" "fix/issue-$1-$2" 2>/dev/null
}

# ── Usage and verb-name contract with the failover path (#418) ────────────────
assert_contains "$(bash "$WT" bogus 2>&1)" "checkpoint <n> [--local] [--runner R] [--model M] | handoff <n>" "usage line lists checkpoint and handoff"
bash "$WT" checkpoint >/dev/null 2>&1; assert_eq "2" "$?" "checkpoint with no <N> exits 2"
bash "$WT" checkpoint abc >/dev/null 2>&1; assert_eq "2" "$?" "checkpoint with a non-numeric <N> exits 2"
bash "$WT" checkpoint 5 --bogus </dev/null >/dev/null 2>&1; assert_eq "2" "$?" "checkpoint with an unknown flag exits 2"
bash "$WT" handoff >/dev/null 2>&1; assert_eq "2" "$?" "handoff with no <N> exits 2"
assert_contains "$(grep -n 'pipeline-worktree.sh" checkpoint' "$TALOS_ROOT/scripts/pipeline-agent.sh")" 'checkpoint "$TALOS_ISSUE_NUMBER"' "pipeline-agent.sh calls: checkpoint <N> with no flags (the shape accepted here)"

# ── Branch check, nothing staged on refusal ──────────────────────────────────
printf 'stray\n' > stray.txt
bash "$WT" checkpoint 42 </dev/null >/dev/null 2>"$SANDBOX/err"; rc=$?
assert_eq "1" "$rc" "on main: checkpoint refuses (exit 1)"
assert_contains "$(cat "$SANDBOX/err")" "nothing staged" "on main: the refusal says nothing was staged"
assert_eq "?? stray.txt" "$(git status --porcelain stray.txt)" "on main: nothing was staged or committed"
assert_eq "1" "$(git rev-list --count HEAD)" "on main: no commit was made"
rm -f stray.txt

W42="$(new_wt 42 widget)"
assert_eq "1" "$([ -d "$W42" ] && echo 1 || echo 0)" "setup: worktree for issue 42 created"
(cd "$W42" && bash "$WT" checkpoint 43 </dev/null >/dev/null 2>&1); assert_eq "1" "$?" "a branch for another issue (#43 on fix/issue-42-...) is refused"

# ── First checkpoint: new + modified files, commit, push, handoff ────────────
printf 'new file\n' > "$W42/feature.txt"
printf 'changed\n' >> "$W42/base.txt"
printf 'x\n' > "$W42/.talos/scratch"
OUT="$(cd "$W42" && printf '%s' '{"stage":"developer step 3","criteria_done":[1,2],"criteria_remaining":[3,4],"last_verify":{"cmd":"tests/run-tests.sh --for scripts/x.sh","rc":1,"failing":["test-x.sh:case-2"]},"decisions":["handoff lives outside the git tree"],"next_step":"fix case 2 then write the docs"}' | bash "$WT" checkpoint 42 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "checkpoint exits 0"
assert_contains "$OUT" "pushed" "checkpoint reports the push"
assert_eq "wip(#42): checkpoint" "$(git -C "$W42" log -1 --format=%s)" "commit subject is wip(#42): checkpoint"
assert_not_contains "$(git -C "$W42" log -1 --format=%B)" "skip ci" "the WIP commit has no [skip ci]"
assert_eq "$(git -C "$W42" rev-parse HEAD)" "$(origin_ref fix/issue-42-widget)" "the issue branch is on origin at the checkpoint commit"
assert_contains "$(git -C "$W42" show --name-only --format= HEAD)" "feature.txt" "git add -A: the new file is in the commit"
assert_not_contains "$(git -C "$W42" show --name-only --format= HEAD)" ".talos" "nothing under .talos/ is staged"
HF="$HF_DIR/42.json"
assert_file_exists "$HF" "handoff written at <repo-root>/.talos/handoff/42.json"
assert_eq "600" "$(mode "$HF")" "handoff file mode is 0600"
assert_eq "700" "$(mode "$HF_DIR")" "handoff directory mode is 0700"
assert_eq "$(git -C "$W42" rev-parse HEAD)" "$(pj "$HF" head)" "handoff head is the checkpoint commit"
assert_eq "fix/issue-42-widget" "$(pj "$HF" branch)" "handoff branch"
assert_eq "[3, 4]" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["criteria_remaining"])' "$HF")" "handoff criteria_remaining"
assert_eq "<absent>" "$(pj "$HF" runner)" "runner is absent when no flag or env gave it (never guessed)"
assert_eq "<absent>" "$(pj "$HF" model)" "model is absent when no flag or env gave it (never guessed)"
assert_eq "1" "$([ "$(wc -c < "$HF")" -le 8192 ] && echo 1 || echo 0)" "handoff is within the 8 KiB cap"
assert_eq "" "$(git -C "$W42" ls-tree -r --name-only origin/fix/issue-42-widget | grep '^\.talos' || true)" "no .talos path on the pushed branch"
assert_eq "" "$(git log --all --format=%H -- .talos)" "no commit anywhere ever contained a .talos path"

# ── handoff verb ─────────────────────────────────────────────────────────────
H="$(bash "$WT" handoff 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "handoff exits 0 from the main checkout"
assert_contains "$H" '"criteria_remaining":[3,4]' "handoff prints the validated JSON"
(cd "$W42" && bash "$WT" handoff 42 >/dev/null 2>&1); assert_eq "0" "$?" "handoff works from the issue worktree too"
bash "$WT" handoff 9999 >"$SANDBOX/out" 2>&1; rc=$?
assert_eq "1" "$rc" "handoff exits 1 when absent"
assert_eq "1" "$(wc -l < "$SANDBOX/out" | tr -d ' ')" "handoff absent: one line"

# ── Idempotent, ts refresh, field carry-over, runner/model flags ─────────────
sleep 1
TS1="$(pj "$HF" ts)"; N1="$(git -C "$W42" rev-list --count HEAD)"
(cd "$W42" && bash "$WT" checkpoint 42 --runner stubrun --model m-1 </dev/null >/dev/null 2>&1); assert_eq "0" "$?" "second checkpoint with no changes exits 0"
assert_eq "$N1" "$(git -C "$W42" rev-list --count HEAD)" "second checkpoint makes no commit"
assert_eq "1" "$([ "$(pj "$HF" ts)" != "$TS1" ] && echo 1 || echo 0)" "second checkpoint refreshes ts"
assert_eq "[3, 4]" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["criteria_remaining"])' "$HF")" "no stdin keeps the earlier fields (the failover caller passes none)"
assert_eq "stubrun" "$(pj "$HF" runner)" "--runner is recorded"
assert_eq "m-1" "$(pj "$HF" model)" "--model is recorded"
(cd "$W42" && TALOS_RUNNER=envrun bash "$WT" checkpoint 42 </dev/null >/dev/null 2>&1)
assert_eq "envrun" "$(pj "$HF" runner)" "TALOS_RUNNER fills runner when no flag is given"
assert_eq "<absent>" "$(pj "$HF" model)" "a model from an earlier run is not carried over"

# ── --local: commit, no push ─────────────────────────────────────────────────
printf 'more\n' > "$W42/local.txt"
BEFORE="$(origin_ref fix/issue-42-widget)"
OUT="$(cd "$W42" && bash "$WT" checkpoint 42 --local </dev/null 2>&1)"; rc=$?
assert_eq "0" "$rc" "--local exits 0"
assert_eq "$BEFORE" "$(origin_ref fix/issue-42-widget)" "--local does not push"
assert_eq "wip(#42): checkpoint" "$(git -C "$W42" log -1 --format=%s)" "--local still commits"
assert_eq "$(git -C "$W42" rev-parse HEAD)" "$(pj "$HF" head)" "--local refreshes the handoff head"
(cd "$W42" && bash "$WT" checkpoint 42 </dev/null >/dev/null 2>&1)
assert_eq "$(git -C "$W42" rev-parse HEAD)" "$(origin_ref fix/issue-42-widget)" "a later call without --local pushes the unpushed commit (no new commit needed)"

# ── Forbidden-file filter ────────────────────────────────────────────────────
printf 'S=1\n' > "$W42/.env"; printf 'k\n' > "$W42/deploy.key"; printf 'custom\n' > "$W42/corp-internal.txt"; printf 'ok\n' > "$W42/notes.txt"
cat > "$SANDBOX/cfg.json" <<'TALOS_w3n7x2c9vk5r'
{"merge": {"forbidden_files": "corp-internal.*"}}
TALOS_w3n7x2c9vk5r
(cd "$W42" && PIPELINE_CONFIG="$SANDBOX/cfg.json" bash "$WT" checkpoint 42 </dev/null >/dev/null 2>"$SANDBOX/err")
FILES="$(git -C "$W42" show --name-only --format= HEAD)"
assert_contains "$FILES" "notes.txt" "forbidden filter: an ordinary file is committed"
assert_not_contains "$FILES" ".env" "forbidden filter: .env is not committed"
assert_not_contains "$FILES" "deploy.key" "forbidden filter: *.key is not committed"
assert_not_contains "$FILES" "corp-internal.txt" "forbidden filter: a merge.forbidden_files entry is not committed"
assert_contains "$(cat "$SANDBOX/err")" "not staging path: .env" "forbidden filter: names the unstaged path on stderr"
assert_eq "1" "$([ -f "$W42/.env" ] && echo 1 || echo 0)" "forbidden filter: the file stays on disk"
rm -f "$W42/.env" "$W42/deploy.key" "$W42/corp-internal.txt"
# A consumer repo that does not gitignore .talos/ must still never commit it.
W49="$(new_wt 49 noignore)"
: > "$W49/.gitignore"; printf 'e\n' > "$W49/e.txt"
(cd "$W49" && bash "$WT" checkpoint 49 </dev/null >/dev/null 2>&1)
assert_contains "$(git -C "$W49" show --name-only --format= HEAD)" "e.txt" "un-ignored .talos: the work is committed"
assert_eq "" "$(git -C "$W49" ls-tree -r --name-only HEAD | grep '^\.talos' || true)" "un-ignored .talos: nothing under .talos/ is committed"
bash "$WT" remove 49 >/dev/null
# ── #436: checkpoint and check-pr-files read ONE list; both refuse each credential file ──
# Paths sit in separate directories so a case-insensitive filesystem cannot merge two of them.
CRED_PATHS=".npmrc
.pypirc
.git-credentials
credentials.json
deploy-credentials.json
deploy_credentials.json
.aws/credentials
.docker/config.json
n1/sub/.npmrc
n2/.pypirc
n3/.git-credentials
n4/credentials.json
n5/gcp-credentials.json
n6/gcp_credentials.json
home/.aws/credentials
home/.docker/config.json
up1/.ENV
up2/Credentials.JSON
up3/.AWS/Credentials
up4/.Docker/Config.JSON
up5/.NPMRC"
OK_PATHS="docs/credentials.md
src/key.ts
credentials-schema.json
test/fixtures/x.json
src/aws/credentials.ts"
W36="$(new_wt 36 creds)"
while IFS= read -r f; do
  mkdir -p "$W36/$(dirname "$f")"; printf 'secret\n' > "$W36/$f"
done <<< "$CRED_PATHS"
while IFS= read -r f; do
  mkdir -p "$W36/$(dirname "$f")"; printf 'fine\n' > "$W36/$f"
done <<< "$OK_PATHS"
(cd "$W36" && bash "$WT" checkpoint 36 </dev/null >/dev/null 2>"$SANDBOX/err")
COMMITTED="$(git -C "$W36" ls-tree -r --name-only HEAD)"
PUSHED="$(git -C "$ORIGIN" ls-tree -r --name-only refs/heads/fix/issue-36-creds)"
GATE="$(STUB_PR_FILES="$CRED_PATHS" bash "$TALOS_ROOT/scripts/pipeline-vcs.sh" check-pr-files 9 2>&1)"; GATE_RC=$?
assert_eq "1" "$GATE_RC" "check-pr-files refuses the whole credential list"
GATE_OK="$(STUB_PR_FILES="$OK_PATHS" bash "$TALOS_ROOT/scripts/pipeline-vcs.sh" check-pr-files 9 2>&1)"; GATE_OK_RC=$?
assert_eq "0" "$GATE_OK_RC" "check-pr-files allows the ordinary look-alikes"
while IFS= read -r f; do
  assert_not_contains "$COMMITTED" "$f" "checkpoint does not commit $f"
  assert_not_contains "$PUSHED" "$f" "checkpoint does not push $f"
  assert_contains "$GATE" "  $f" "check-pr-files refuses $f"
  assert_eq "1" "$([ -f "$W36/$f" ] && echo 1 || echo 0)" "the file stays on disk: $f"
done <<< "$CRED_PATHS"
while IFS= read -r f; do
  assert_contains "$COMMITTED" "$f" "checkpoint commits the ordinary file $f"
done <<< "$OK_PATHS"
bash "$WT" remove 36 >/dev/null

# ── #436: an empty pattern list fails checkpoint closed (nothing staged, committed or pushed) ──
# A copy of scripts/ whose pipeline-vcs.sh prints no patterns stands in for a broken verb.
STUB_SCRIPTS="$SANDBOX/scripts-no-patterns"
cp -R "$TALOS_ROOT/scripts" "$STUB_SCRIPTS"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_SCRIPTS/pipeline-vcs.sh"
W37="$(new_wt 37 closed)"
printf 'S=1\n' > "$W37/.env"; printf 'ok\n' > "$W37/fine.txt"
HEAD37="$(git -C "$W37" rev-parse HEAD)"
(cd "$W37" && bash "$STUB_SCRIPTS/pipeline-worktree.sh" checkpoint 37 </dev/null >/dev/null 2>"$SANDBOX/err"); rc=$?
assert_eq "1" "$rc" "empty forbidden-files patterns: checkpoint exits 1"
assert_contains "$(cat "$SANDBOX/err")" "could not resolve the forbidden-files patterns" "empty forbidden-files patterns: the reason is named on stderr"
assert_eq "$HEAD37" "$(git -C "$W37" rev-parse HEAD)" "empty forbidden-files patterns: nothing is committed"
assert_eq "" "$(git -C "$W37" diff --cached --name-only)" "empty forbidden-files patterns: nothing stays staged"
assert_eq "none" "$(origin_ref fix/issue-37-closed)" "empty forbidden-files patterns: nothing is pushed"
bash "$WT" remove 37 >/dev/null

# ── Rejected handoffs: nothing reaches the file, commit and push still done ──
ck() {  # <json>: run checkpoint 42 in W42 with that stdin; sets RC and ERR
  ERR="$(cd "$W42" && printf '%s' "$1" | bash "$WT" checkpoint 42 2>&1 >/dev/null)"; RC=$?
}
sum_hf() { cksum < "$HF"; }
SUM="$(sum_hf)"
# Credential shapes, assembled at run time so this file holds no literal token.
J="eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl"
for shape in "ghp_""abcdefghijklmnopqrstuvwxyz0123456789" "gho_""abcdefghijklmnopqrstuvwxyz0123456789" \
             "github_pat_""11ABCDEFG0abcdef" "glpat-""abcdefghij1234567890" "sk-""abcdef123456" "xoxb-""1234-abcd" \
             "AKIA""ABCDEFGHIJKLMNOP" "-----BEGIN"" RSA PRIVATE KEY" "$J" "Bearer"" abcdef123" "https://user:pw""d@host/x" \
             "password"" = hunter2" "api_key"": abc" "token""=abc" "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"; do
  before="$(git -C "$W42" rev-list --count HEAD)"
  printf 'w\n' >> "$W42/notes.txt"
  ck "{\"next_step\":\"$shape\"}"
  assert_eq "4" "$RC" "credential shape rejected with exit 4: ${shape:0:9}..."
  assert_eq "$SUM" "$(sum_hf)" "credential shape leaves the previous handoff unchanged: ${shape:0:9}..."
  assert_not_contains "$ERR" "$shape" "credential shape is not echoed to stderr: ${shape:0:9}..."
  assert_eq "$((before + 1))" "$(git -C "$W42" rev-list --count HEAD)" "the commit is still made when the handoff is rejected: ${shape:0:9}..."
done
ENVSECRET="hunter2hunter2-value"
ERR="$(cd "$W42" && printf '{"decisions":["uses %s here"]}' "$ENVSECRET" | MY_API_TOKEN="$ENVSECRET" bash "$WT" checkpoint 42 2>&1 >/dev/null)"; RC=$?
assert_eq "4" "$RC" "a value from a *TOKEN* environment variable is rejected"
assert_eq "$SUM" "$(sum_hf)" "env-value rejection leaves the file unchanged"
assert_not_contains "$(cat "$HF")" "$ENVSECRET" "the env value never reaches the file"
assert_contains "$ERR" "decisions" "the rejection names the failing field"
# Schema rejections.
ck '{"bogus":1}';                                           assert_eq "4" "$RC" "unknown key rejected"
ck '{"criteria_done":["a"]}';                               assert_eq "4" "$RC" "wrong element type rejected"
ck '{"next_step":["x"]}';                                   assert_eq "4" "$RC" "wrong field type rejected"
ck '{"next_step":"line1\nline2"}';                          assert_eq "4" "$RC" "newline in a string rejected"
ck '{"stage":"Developer!"}';                                assert_eq "4" "$RC" "stage outside [a-z0-9 :_-] rejected"
ck '{"last_verify":{"cmd":"x","rc":0,"failing":["a b"]}}';  assert_eq "4" "$RC" "failing name outside the charset rejected"
ck '{"last_verify":{"cmd":"x","rc":0,"output":"log"}}';     assert_eq "4" "$RC" "free-form command output is not accepted"
ck '{"decisions":["1","2","3","4","5","6","7","8","9"]}';   assert_eq "4" "$RC" "more than 8 decisions rejected"
ck "{\"next_step\":\"$(python3 -I -c 'print("x " * 101)')\"}"; assert_eq "4" "$RC" "next_step over 200 chars rejected"
ck "{\"next_step\":\"$(python3 -I -c 'print("ab " * 4000)')\"}"; assert_eq "4" "$RC" "input over 8 KiB rejected"
ck 'not json';                                              assert_eq "4" "$RC" "invalid JSON rejected"
assert_eq "$SUM" "$(sum_hf)" "no schema rejection touched the previous handoff"
assert_eq "" "$(ls -A "$HF_DIR" | grep '\.tmp$' || true)" "no temp file is left behind"
ck '{"last_verify":{"cmd":"tests/run-tests.sh --for a.sh","rc":2,"failing":["t.sh:case-1"]},"next_step":"go"}'
assert_eq "0" "$RC" "a valid update after the rejections is accepted"
assert_eq "go" "$(pj "$HF" next_step)" "valid update lands"

# ── Symlinked handoff directory is refused ───────────────────────────────────
mkdir -p "$SANDBOX/elsewhere"
mv "$HF_DIR" "$SANDBOX/hf-real"; ln -s "$SANDBOX/elsewhere" "$HF_DIR"
ck '{"next_step":"x"}'
assert_eq "4" "$RC" "a symlinked .talos/handoff is refused"
assert_eq "" "$(ls -A "$SANDBOX/elsewhere")" "nothing was written through the symlink"
rm "$HF_DIR"; mv "$SANDBOX/hf-real" "$HF_DIR"

# ── Stale handoffs ───────────────────────────────────────────────────────────
assert_eq "0" "$(bash "$WT" handoff 42 >/dev/null 2>&1; echo $?)" "fresh handoff is not stale"
W46="$(new_wt 46 stale)"
printf 'a\n' > "$W46/a.txt"; (cd "$W46" && bash "$WT" checkpoint 46 </dev/null >/dev/null 2>&1)
printf 'b\n' > "$W46/b.txt"; (cd "$W46" && bash "$WT" checkpoint 46 </dev/null >/dev/null 2>&1)
git -C "$W46" reset -q --hard HEAD~1
git -C "$W46" push -q -f origin HEAD:refs/heads/fix/issue-46-stale
bash "$WT" handoff 46 >"$SANDBOX/out" 2>&1; rc=$?
assert_eq "1" "$rc" "head not an ancestor of the branch: stale, exit 1"
assert_contains "$(cat "$SANDBOX/out")" "stale" "stale handoff says so, in one line"
git worktree remove --force "$W46"; git branch -q -D fix/issue-46-stale; git push -q origin :refs/heads/fix/issue-46-stale
printf '{"v":1}' > "$HF_DIR/46.json"
bash "$WT" handoff 46 >"$SANDBOX/out" 2>&1; assert_eq "1" "$?" "a handoff that fails the schema on read exits 1"
assert_contains "$(cat "$SANDBOX/out")" "invalid" "invalid handoff says so"
rm -f "$HF_DIR/46.json"

# ── Push failure: commit kept, handoff written, nothing reported as pushed ───
cat > "$ORIGIN/hooks/pre-receive" <<'TALOS_b6p1j8y4de0t'
#!/bin/sh
while read old new ref; do
  case "$ref" in *issue-43-*) echo "rejected by test hook" >&2; exit 1 ;; esac
done
TALOS_b6p1j8y4de0t
chmod +x "$ORIGIN/hooks/pre-receive"
W43="$(new_wt 43 refused)"
printf 'work\n' > "$W43/w.txt"
OUT="$(cd "$W43" && printf '{"stage":"developer step 3","criteria_remaining":[1],"next_step":"retry"}' | bash "$WT" checkpoint 43 2>/dev/null)"; rc=$?
assert_eq "3" "$rc" "push failure exits 3"
assert_not_contains "$OUT" " pushed" "push failure is not reported as pushed"
assert_eq "wip(#43): checkpoint" "$(git -C "$W43" log -1 --format=%s)" "push failure: the commit is kept locally"
assert_eq "none" "$(origin_ref fix/issue-43-refused)" "push failure: nothing on origin"
assert_file_exists "$HF_DIR/43.json" "push failure: the handoff is still written"
assert_eq "$(git -C "$W43" rev-parse HEAD)" "$(pj "$HF_DIR/43.json" head)" "push failure: the handoff names the local commit"
# Safety nets (replacing the issue's sweep AC; since #240 sweep removes by id).
OUT="$(bash "$WT" remove 43)"
assert_contains "$OUT" "reason: unpushed" "remove <N> preserves a worktree whose checkpoint push failed (unpushed)"
assert_eq "1" "$([ -d "$W43" ] && echo 1 || echo 0)" "the unpushed worktree is still there"
assert_file_exists "$HF_DIR/43.json" "a preserved worktree keeps its handoff"
bash "$WT" sweep 43 >/dev/null 2>&1
assert_eq "1" "$([ -d "$W43" ] && echo 1 || echo 0)" "sweep <N> keeps the worktree by id"
bash "$WT" sweep >/dev/null 2>&1
assert_eq "0" "$([ -d "$W43" ] && echo 1 || echo 0)" "a sweep that does not list <N> removes the worktree (since #240)"
assert_file_exists "$HF_DIR/43.json" "sweep does not delete the handoff"
assert_eq "" "$(git branch --list fix/issue-43-refused)" "documented gap, pinned: an unpushed local branch with no worktree is deleted by sweep"

# ── remove <N> deletes the handoff with the worktree ─────────────────────────
W44="$(new_wt 44 clean)"
printf 'c\n' > "$W44/c.txt"; (cd "$W44" && bash "$WT" checkpoint 44 </dev/null >/dev/null 2>&1)
assert_file_exists "$HF_DIR/44.json" "setup: handoff for 44"
bash "$WT" remove 44 >/dev/null
assert_eq "0" "$([ -d "$W44" ] && echo 1 || echo 0)" "remove <N> removed the worktree"
assert_file_absent "$HF_DIR/44.json" "remove <N> deleted .talos/handoff/44.json"
bash "$WT" remove 4444 >/dev/null; assert_eq "0" "$?" "remove with nothing to remove still exits 0"

# An unresolvable handoff directory must skip the delete with a note, never rm /<n>.json.
W50="$(new_wt 50 nodir)"
printf 'f\n' > "$W50/f.txt"; (cd "$W50" && bash "$WT" checkpoint 50 </dev/null >/dev/null 2>&1)
mkdir -p "$SANDBOX/shim"
cat > "$SANDBOX/shim/git" <<TALOS_g4r8w1y6zt3k
#!/bin/sh
# fails only the handoff-dir lookup (-C . rev-parse --git-common-dir)
[ "\$1" = "-C" ] && [ "\$2" = "." ] && [ "\$3" = "rev-parse" ] && [ "\$4" = "--git-common-dir" ] && exit 1
exec $(command -v git) "\$@"
TALOS_g4r8w1y6zt3k
chmod +x "$SANDBOX/shim/git"
OUT="$(PATH="$SANDBOX/shim:$PATH" bash "$WT" remove 50 2>&1)"; rc=$?
assert_eq "0" "$rc" "remove still exits 0 when the handoff directory cannot be resolved"
assert_contains "$OUT" "could not resolve the handoff directory" "remove says it skipped the handoff delete"
assert_eq "0" "$([ -d "$W50" ] && echo 1 || echo 0)" "remove still removed the worktree"
assert_file_exists "$HF_DIR/50.json" "the handoff was left in place, not deleted through a bad path"

# ── sweep leaves the handoff of a worktree it removes ────────────────────────
W45="$(new_wt 45 swept)"
printf 'd\n' > "$W45/d.txt"; (cd "$W45" && bash "$WT" checkpoint 45 </dev/null >/dev/null 2>&1)
bash "$WT" sweep 999 >/dev/null 2>&1
assert_eq "0" "$([ -d "$W45" ] && echo 1 || echo 0)" "sweep removed the clean pushed worktree"
assert_file_exists "$HF_DIR/45.json" "sweep does not delete handoffs"
assert_eq "0" "$(bash "$WT" handoff 45 >/dev/null 2>&1; echo $?)" "the surviving handoff is still valid (the branch is on origin)"

# ── Squash merge into the bare origin: one commit, no .talos path ────────────
BASE_N="$(git -C "$ORIGIN" rev-list --count main)"
W47="$(new_wt 47 squash)"
printf '1\n' > "$W47/one.txt"; (cd "$W47" && printf '{"stage":"developer step 4"}' | bash "$WT" checkpoint 47 >/dev/null 2>&1)
printf '2\n' > "$W47/two.txt"; (cd "$W47" && bash "$WT" checkpoint 47 </dev/null >/dev/null 2>&1)
assert_eq "2" "$(git -C "$W47" rev-list --count origin/main..HEAD)" "setup: the branch carries two WIP commits"
SQ="$SANDBOX/squash-clone"
git clone -q "$ORIGIN" "$SQ"
git -C "$SQ" config user.email t@t; git -C "$SQ" config user.name t
git -C "$SQ" merge -q --squash origin/fix/issue-47-squash >/dev/null
git -C "$SQ" commit -q -m "feat: squash (#47)"
git -C "$SQ" push -q origin HEAD:main
assert_eq "$((BASE_N + 1))" "$(git -C "$ORIGIN" rev-list --count main)" "squash: base gained exactly one commit"
assert_eq "" "$(git -C "$ORIGIN" ls-tree -r --name-only main | grep '\.talos' || true)" "squash: the base tree has no .talos/ path"
assert_eq "" "$(git -C "$ORIGIN" log --all --format=%H -- .talos)" "squash: no commit in the origin ever contained .talos"
assert_contains "$(git -C "$ORIGIN" ls-tree -r --name-only main)" "two.txt" "squash: the work itself is on base"

# ── Kill test: a stub runner is SIGKILLed mid-stage; a second one continues ──
W48="$(new_wt 48 killed)"
cat > "$SANDBOX/stub1.sh" <<'TALOS_f9k2s7m3qa8w'
#!/usr/bin/env bash
# stub runner 1: does work, checkpoints once, then is killed mid-stage.
cd "$1" || exit 1
printf 'half done\n' > half.txt
printf '%s' '{"stage":"developer step 3","criteria_done":[1],"criteria_remaining":[2,3],"next_step":"write the second test"}' | bash "$2" checkpoint 48 >/dev/null 2>&1
printf 'unsaved work\n' > unsaved.txt
kill -9 $$
TALOS_f9k2s7m3qa8w
{ bash "$SANDBOX/stub1.sh" "$W48" "$WT"; rc=$?; } 2>/dev/null
assert_eq "137" "$rc" "stub runner 1 died by SIGKILL"
assert_file_exists "$W48/unsaved.txt" "the killed stage left uncommitted work in its worktree"
# The failover path (what #418 calls): the same worktree, no stdin, no flags.
(cd "$W48" && bash "$WT" checkpoint 48 </dev/null >/dev/null 2>&1); assert_eq "0" "$?" "checkpoint after the kill exits 0"
cat > "$SANDBOX/stub2.sh" <<'TALOS_x5c1h8v2lr4n'
#!/usr/bin/env bash
# stub runner 2: starts on the same branch and reads the handoff, not the thread.
cd "$1" || exit 1
bash "$2" handoff 48
TALOS_x5c1h8v2lr4n
SEEN="$(bash "$SANDBOX/stub2.sh" "$W48" "$WT")"
assert_contains "$SEEN" '"criteria_remaining":[2,3]' "stub runner 2 sees the remaining criteria"
assert_contains "$SEEN" '"criteria_done":[1]' "stub runner 2 sees what is done (so it does not repeat it)"
assert_contains "$SEEN" '"next_step":"write the second test"' "stub runner 2 sees the next step"
assert_contains "$SEEN" "\"head\":\"$(git -C "$W48" rev-parse HEAD)\"" "stub runner 2 sees the checkpoint commit"
assert_contains "$(git -C "$W48" show --name-only --format= HEAD)" "unsaved.txt" "the failover checkpoint saved the killed stage's unsaved file"
assert_eq "$(git -C "$W48" rev-parse HEAD)" "$(origin_ref fix/issue-48-killed)" "and pushed it"

# ── Prose pins ───────────────────────────────────────────────────────────────
PIPE="$(cat "$TALOS_ROOT/skills/pipeline/SKILL.md")"
assert_contains "$PIPE" 'only when `bash scripts/pipeline-worktree.sh handoff <N>` exits 0' "pipeline skill: the handoff line is conditional on the verb's exit 0"
assert_contains "$PIPE" 'git diff origin/<BASE_BRANCH>...' "pipeline skill: the handoff line names the branch diff"
DEV="$(cat "$TALOS_ROOT/agents/developer.md")"
assert_contains "$DEV" 'bash scripts/pipeline-worktree.sh checkpoint <N>' "developer profile: names the checkpoint verb"
assert_contains "$DEV" '--local' "developer profile: --local in a fix round"
assert_contains "$DEV" 'never the full suite' "developer profile: a checkpoint never runs the full suite"

finish
