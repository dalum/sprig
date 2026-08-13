# sprig-broker

Keeps `claude` sessions alive across client disconnects, so a remote session
survives a dropped SSH link and its in-flight turn is not lost. See the
"Detach and reattach: the session broker" section of [../DESIGN.md](../DESIGN.md)
for the design and rationale.

One daemon per user holds each session's stdin open, spools its stdout to a
file, and fans that stream out to attached clients. Sprig drives it behind the
opt-in `sprig-use-broker`: a remote session runs `python3 BROKER open ...` in
place of `exec claude`, and Sprig ships this script to the host on first use.

## Use

```sh
# Start a session (auto-starts the daemon on first use); prints its key.
sid=$(./sprig-broker spawn --cwd /some/project -- \
        -p --input-format stream-json --output-format stream-json --verbose)

# Attach: stdout is the raw claude stream-json, stdin is the turn input.
# Detaching (killing this process) leaves the session running.
./sprig-broker attach "$sid"

# Reattach later from a byte offset; addresses by broker key or CLI session id.
./sprig-broker attach "$sid" --offset 19936

# What Sprig runs: attach to a live session by id, else spawn a fresh one.
# A fresh spawn replays from 0 (the init line lands); a reattach gives the
# live tail only, since settled history is in the CLI's JSONL.
./sprig-broker open --session "$cli_id" --cwd /some/project -- \
        -p --input-format stream-json --output-format stream-json --verbose

./sprig-broker list          # sessions as JSON
./sprig-broker version       # protocol version (used for the install check)
./sprig-broker stop "$sid"   # close stdin (claude exits) and drop it
```

The daemon, socket, and per-session spools live under
`$XDG_RUNTIME_DIR/sprig-broker/` (or `/tmp/sprig-broker-$UID/`).

## Test

```sh
./test.sh
```

Drives a real `claude` session through attach, a turn, a detach (the session
must survive with no client), a reattach by CLI session id at an offset, a
second turn on the same process, and a stop. Runs in an isolated
`XDG_RUNTIME_DIR`, so it never touches a real broker.

## Not yet (later stages)

- A live end-to-end attach from Emacs over a real SSH link (the command
  construction, install, and resume/fork logic are unit-tested; the wire has
  been proven in the shell, but the two have not yet been run together).
- Spool trim, and re-adopting live children on a daemon restart (falling back
  to `--resume` by session id).
- A navigator that shows detached-but-alive sessions and reattaches with a
  keystroke.
