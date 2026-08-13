# sprig-broker

Keeps `claude` sessions alive across client disconnects, so a remote session
survives a dropped SSH link and its in-flight turn is not lost. See the
"Detach and reattach: the session broker" section of [../DESIGN.md](../DESIGN.md)
for the design and rationale.

This is **Stage 1**: the broker core, provable in a shell with no Emacs in the
loop. One daemon per user holds each session's stdin open, spools its stdout to
a file, and fans that stream out to attached clients.

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

./sprig-broker list          # sessions as JSON
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

- Multiplexing polish, spool trim, and re-adopting live children on a daemon
  restart (falling back to `--resume` by session id).
- Deployment and discovery on a remote host (`systemd --user` unit or a
  `setsid` launcher), and a version handshake on attach.
- Sprig transport integration: a remote session runs
  `ssh HOST sprig-broker attach SESSION` in place of `exec claude`.
