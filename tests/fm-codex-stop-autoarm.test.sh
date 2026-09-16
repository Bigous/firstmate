#!/usr/bin/env bash
# Exercise the registered Codex Stop hooks with real watcher processes and a
# deterministic queue transport. Native delivery is covered by the opt-in E2E.+# shellcheck disable=SC2016
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-stop-autoarm)
fm_git_identity fmtest fmtest@example.invalid
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/codex-harness"
cat > "$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
if [ "$*" = 'queue --help' ]; then exit 0; fi
[ "${QUEUE_FAIL:-0}" != 1 ] || exit 1
printf '%s\n' "$*" >> "$FM_HOME/queued"
SH
chmod +x "$FAKEBIN/codex"
export PATH="$FAKEBIN:$PATH"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/.codex"
  git init -q "$home"
  cp -R "$ROOT/bin" "$home/bin"
  cp "$ROOT/.codex/hooks.json" "$home/.codex/hooks.json"
  : > "$home/AGENTS.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/state/probe.check.sh"
  chmod 0700 "$home/state/probe.check.sh"
  FM_HOME="$home" "$home/bin/fm-check-register.sh" probe >/dev/null || fail registration
  printf '%s\n' "$home"
}

test_registered_stop_keeps_watch_and_delivers() {
  local home rc=0
  home=$(make_home registered)
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=99999 \
    "$FAKEBIN/codex-harness" -c '
      cd "$FM_HOME" || exit 1
      printf "%s\n" "$$" > state/.lock
      payload='"'"'{"session_id":"test-session","turn_id":"test-turn","stop_hook_active":false}'"'"'
      hook=$(jq -r '"'"'.hooks.Stop[].hooks[] | select(.async == true) | .command'"'"' .codex/hooks.json)
      [ -n "$hook" ] || { echo "no automatic Codex Stop owner"; exit 1; }
      printf "%s\n" "$payload" | bash -c "$hook" >hook.out 2>hook.err &
      owner=$!
      trap '"'"'kill "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true'"'"' EXIT
      for _ in $(seq 1 100); do
        [ -f state/.watch.lock/pid ] && break
        sleep 0.1
      done
      guard=$(jq -r '"'"'.hooks.Stop[].hooks[] | select(.async != true) | .command'"'"' .codex/hooks.json)
      printf "%s\n" "$payload" | bash -c "$guard" || exit 1
      sleep 2
      kill -0 "$(cat state/.watch.lock/pid)" || exit 1
      printf "done: native stop regression\n" > state/demo.status
      for _ in $(seq 1 200); do
        [ -s queued ] && break
        sleep 0.1
      done
      [ -s queued ] || { cat hook.err; exit 1; }
      grep -q -- "--thread test-session" queued || exit 1
      grep -q "demo.status" state/.wake-queue || exit 1
      wait "$owner" || exit 1
      [ "$(wc -l < queued)" -eq 1 ] || exit 1
    ' > "$home/result" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "registered Stop did not supervise and deliver: $(cat "$home/result")"
  pass "registered Codex Stop keeps a quiet watcher alive and queues one durable wake"
}

test_registered_stop_keeps_watch_and_delivers
