#!/usr/bin/env bash
# Drive a real `claude` session through the broker: attach, run a turn,
# detach (kill the client, session must live), reattach at a byte offset,
# run a second turn on the same process, then stop.  Exercises the whole
# Stage 1 risk surface with no Emacs in the loop.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
broker="$here/sprig-broker"

# Isolate everything (daemon, socket, spool) in a throwaway runtime dir so
# the test never touches a real broker.
export XDG_RUNTIME_DIR="$(mktemp -d /tmp/sprig-broker-test.XXXXXX)"
work="$XDG_RUNTIME_DIR"
fail=0
say() { printf '== %s\n' "$*"; }
ok()  { printf 'PASS %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

jget() { python3 -c 'import json,sys;print(json.load(sys.stdin)'"$1"')'; }

cleanup() {
  [ -n "${fifoA:-}" ] && exec 4>&- 2>/dev/null
  [ -n "${fifoB:-}" ] && exec 5>&- 2>/dev/null
  # Stop every session this test started, while its daemon is still up.
  for s in "${sid:-}" "${open_sid:-}" "${rsid:-}"; do
    [ -n "$s" ] && "$broker" stop "$s" >/dev/null 2>&1
  done
  # Kill ONLY this test's own daemon, by the pid we tracked when we started it.
  # The old code ran `pkill -f "sprig-broker daemon"', which killed every
  # sprig-broker on the box, a user's real brokered sessions included; and it
  # still leaked, because an auto-started daemon detaches with setsid and left
  # the shell no pid to match reliably.  Starting it ourselves fixes both.
  [ -n "${broker_pid:-}" ] && kill "$broker_pid" 2>/dev/null
  # A mid-test failure can orphan a hermetic sleeper child; it is unique to
  # this run's work dir, so match on that alone.
  pkill -f "$work/sleeper" 2>/dev/null
  rm -rf "$work"
  # The spawned claude sessions ran with --cwd "$work" and so logged under
  # the real config dir's projects/.  Remove that entry too, or every test
  # run would leave throwaway sessions in the user's navigator.
  local projects mangled
  projects="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  mangled="$(printf '%s' "$work" | sed 's#[/.]#-#g')"
  [ -n "$mangled" ] && rm -rf -- "$projects/$mangled"
}
trap cleanup EXIT

# Start this test's daemon ourselves, in its isolated XDG_RUNTIME_DIR, and track
# its pid so cleanup can stop exactly this one.  `run_daemon' runs in the
# foreground, so the backgrounded process IS the daemon and $! is its pid; an
# auto-start (a spawn with no daemon up) would instead setsid it away, leaving
# no pid to kill.  Every spawn below then finds this daemon already listening.
"$broker" daemon &
broker_pid=$!
sock="$XDG_RUNTIME_DIR/sprig-broker/control.sock"
for _ in $(seq 1 50); do [ -S "$sock" ] && break; sleep 0.1; done
if [ ! -S "$sock" ]; then bad "daemon did not come up"; exit 1; fi

# 1. Spawn a session on the daemon started above.
sid="$("$broker" spawn --cwd "$work" -- \
  -p --input-format stream-json --output-format stream-json --verbose)"
if [ -z "$sid" ]; then bad "spawn returned no session"; exit 1; fi
say "spawned session $sid"

# 2. Client A attaches over a FIFO we hold open, so its stdin does not EOF.
fifoA="$work/inA"; outA="$work/outA"; mkfifo "$fifoA"; : >"$outA"
"$broker" attach "$sid" <"$fifoA" >"$outA" 2>"$work/errA" &
clientA=$!
exec 4>"$fifoA"
say "client A attached (pid $clientA)"

send4() { printf '%s\n' "$1" >&4; }
send4 '{"type":"control_request","request_id":"init","request":{"subtype":"initialize","supportedDialogKinds":["ask_user_question"]}}'
send4 '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Reply with just the word ALPHA and nothing else."}]}}'

for _ in $(seq 1 60); do grep -q '"type":"result"' "$outA" && break; sleep 1; done
if grep -qi 'ALPHA' "$outA"; then ok "turn 1 replied ALPHA through client A"; else bad "no ALPHA in client A"; fi

# Byte offset to reattach from later (everything up to here is turn 1).
off="$("$broker" list | jget '["sessions"][0]["spool_size"]')"
cli_sid="$("$broker" list | jget '["sessions"][0]["cli_session_id"]')"
say "captured CLI session id: $cli_sid; reattach offset: $off"

# The broker should have dropped a .sprig-live marker beside the session log
# (written asynchronously just after the id appeared), so the navigator's own
# scan can see the session is held without a separate query.
projects="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
mangled="$(printf '%s' "$work" | sed 's#[/.]#-#g')"
marker="$projects/$mangled/$cli_sid.sprig-live"
for _ in $(seq 1 30); do [ -f "$marker" ] && break; sleep 0.1; done
if [ -f "$marker" ]; then ok "live marker written beside the log"; else bad "no .sprig-live marker beside the log"; fi
if grep -q 'control.sock' "$marker" 2>/dev/null; then ok "marker holds the broker socket path"; else bad "marker missing socket path"; fi

# 3. Client A DETACHES: kill it (a real disconnect kills the ssh/client).
kill "$clientA" 2>/dev/null; wait "$clientA" 2>/dev/null
exec 4>&-
say "client A killed; idling 6s with no client attached"
sleep 6

ended="$("$broker" list | jget '["sessions"][0]["ended"]')"
if [ "$ended" = "False" ]; then ok "session survived with no client attached"; else bad "session ended after detach"; fi

# 4. Client B REATTACHES at the offset (only turn 2 should replay) and,
#    to prove identity, addresses the session by its CLI session id.
fifoB="$work/inB"; outB="$work/outB"; mkfifo "$fifoB"; : >"$outB"
"$broker" attach "$cli_sid" --offset "$off" <"$fifoB" >"$outB" 2>"$work/errB" &
clientB=$!
exec 5>"$fifoB"
say "client B reattached by CLI session id (pid $clientB)"

printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Reply with just the word BETA and nothing else."}]}}' >&5
for _ in $(seq 1 60); do grep -q '"type":"result"' "$outB" && break; sleep 1; done

if grep -qi 'BETA' "$outB"; then ok "turn 2 replied BETA on the same process via client B"; else bad "no BETA in client B"; fi
if grep -qi 'ALPHA' "$outB"; then bad "client B replayed turn 1 (offset ignored)"; else ok "offset held: client B saw only turn 2, not ALPHA"; fi

# 5. Stop: closing stdin makes claude exit; the session leaves the list.
exec 5>&-; kill "$clientB" 2>/dev/null; wait "$clientB" 2>/dev/null
"$broker" stop "$sid" >/dev/null
for _ in $(seq 1 10); do
  n="$("$broker" list | jget '["sessions"].__len__()')"
  [ "$n" = "0" ] && break; sleep 1
done
if [ "${n:-1}" = "0" ]; then ok "stop removed the session"; else bad "session still listed after stop"; fi

# 6. `open`: the single verb Sprig runs. Fresh spawn (no --session) replays
#    from 0 so the init line lands; a reattach by CLI id gives the live tail.
fifoC="$work/inC"; outC="$work/outC"; mkfifo "$fifoC"; : >"$outC"
"$broker" open --cwd "$work" -- \
  -p --input-format stream-json --output-format stream-json --verbose \
  <"$fifoC" >"$outC" 2>"$work/errC" &
clientC=$!
exec 6>"$fifoC"
printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Reply with just the word GAMMA and nothing else."}]}}' >&6
for _ in $(seq 1 60); do grep -q '"type":"result"' "$outC" && break; sleep 1; done
if grep -q '"type":"system"' "$outC" && grep -q '"session_id"' "$outC"; then
  ok "open spawned and replayed the init line (session id present)"
else bad "open did not deliver the init line"; fi
if grep -qi 'GAMMA' "$outC"; then ok "open drove a turn on a freshly spawned session"; else bad "no GAMMA via open"; fi
open_sid="$("$broker" list | jget '["sessions"][0]["cli_session_id"]')"
exec 6>&-; kill "$clientC" 2>/dev/null; wait "$clientC" 2>/dev/null
"$broker" stop "$open_sid" >/dev/null 2>&1

# 7. attach-only refuses a session the broker does not hold (a stale marker),
#    so opening the navigator can never resurrect a dead session.
if "$broker" open --attach-only --no-start --session no-such-session -- -p 2>&1 | grep -q 'not held'; then
  ok "attach-only refuses an unheld session"; else bad "attach-only did not refuse an unheld session"; fi

# 8. The marker is gone once the session is stopped.
for _ in $(seq 1 30); do [ -f "$marker" ] || break; sleep 0.1; done
if [ ! -f "$marker" ]; then ok "live marker removed when the session stopped"; else bad "marker lingered after stop"; fi

# 8b. A resume names its session id up front (`--resume ID'), so the marker is
#     written at spawn from that id, without waiting for the session to stream.
#     Prove it with a program that emits nothing: no stream, yet a marker lands.
cat >"$work/sleeper" <<'EOF'
#!/bin/sh
# Emit nothing (so the broker keys liveness on the marker, not the stream) but
# keep stdout open, and block reading stdin so the session stays held; exit
# cleanly when the broker closes stdin on `stop'.
while IFS= read -r _; do :; done
EOF
chmod +x "$work/sleeper"
: >"$projects/$mangled/resume-fake-0001.jsonl"   # the log a resume would find
rmarker="$projects/$mangled/resume-fake-0001.sprig-live"
rsid="$("$broker" spawn --cwd "$work" --program "$work/sleeper" \
  -- -p --resume resume-fake-0001)"
for _ in $(seq 1 30); do [ -f "$rmarker" ] && break; sleep 0.1; done
if [ -f "$rmarker" ]; then ok "resume seeds the marker without a stream"; else bad "no marker for a resumed-but-idle session"; fi
"$broker" stop "$rsid" >/dev/null 2>&1

# 9. version prints without needing the daemon (used for the install check).
if [ "$("$broker" version)" = "2" ]; then ok "version prints the protocol version"; else bad "version wrong"; fi

echo
if [ "$fail" = "0" ]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit "$fail"
