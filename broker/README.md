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

## Live smoke test (from Emacs, over a real SSH host)

`test.sh` proves the wire; this proves the whole path, including the SSH hop
and the ship-on-first-use install. You need an SSH host with `python3` and
`claude` on its PATH. Nothing here is destructive: the broker installs under
`~/.local/share/sprig/` and its state under the host's `XDG_RUNTIME_DIR`.

1. Point Sprig at the host and turn the broker on:

   ```elisp
   (setq sprig-remotes '("you@host"))
   (setq sprig-use-broker t)
   ```

2. Start a remote session (`M-x sprig-status`, then `s n`, or open a review
   buffer on the host) and send a turn. First use ships the broker; confirm it
   landed:

   ```sh
   ssh you@host 'python3 ~/.local/share/sprig/sprig-broker version && \
                 python3 ~/.local/share/sprig/sprig-broker list'
   ```

   The turn's session should show in `list` with `"ended": false`.

3. **Simulate a dropped link.** Kill the session's transport without a clean
   teardown, so the SSH process dies the way a network drop would. Either pull
   the network briefly, or from a shell:

   ```sh
   pkill -f 'ssh.*sprig-broker open'
   ```

   Do this *while a long turn is running* to test the real prize: start a turn
   that takes a while (a big agent task), then kill the transport mid-turn.

4. **Reattach.** Back in the review buffer, send another message. Sprig
   reconnects on the next send (`sprig--ensure`), and because the session id is
   known it runs `open --session ID`, which attaches to the *same live process*
   rather than resuming a killed one. The in-flight turn from step 3 should
   have kept running on the host and its result be there, and `list` should
   still show the same session, not a new one.

5. Tidy up: `M-x sprig-status`, `d` on the session (or
   `ssh you@host 'python3 ~/.local/share/sprig/sprig-broker stop <id>'`).

If step 4 shows the turn survived the disconnect, the broker does its job.

## Not yet (later stages)

- A live end-to-end attach from Emacs over a real SSH link (the command
  construction, install, and resume/fork logic are unit-tested; the wire has
  been proven in the shell; the generated command string has been run against
  a real `claude` minus only the ssh hop; the two have not yet been run
  together over a real link, which the live smoke test above covers).
- Spool trim, and re-adopting live children on a daemon restart (falling back
  to `--resume` by session id).
- A navigator that shows detached-but-alive sessions and reattaches with a
  keystroke.
