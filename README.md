# sprig

Sprig is an Emacs interface for **reviewing and steering** an LLM agent's work, aimed at breaking out of linear chat.

**The shape:** you never edit a transcript. A conversation is a read-only, **Magit-like review buffer** (built on `magit-section`) whose one job is to review and steer the agent efficiently: the agent's file edits render inline as a foldable diff, you mark what you care about, and single-key verbs send the agent instructions. The whole set of conversations is driven from a `sprig-status` navigator. There is no chat input line and no Markdown file to edit.

**The store is the CLI's own log.** A conversation *is* a `claude` session. The CLI already persists each session as a JSONL log under `~/.claude/projects/<cwd>/<id>.jsonl` on the host where it runs, so Sprig keeps no store of its own: history is replayed from that log, and it survives an Emacs restart because the session id names the file. The transport is a persistent **Claude Code session**, local or over **SSH**, via the `claude` CLI's stream-json protocol, so it uses whatever the CLI is logged in as (a Claude **Pro/Max subscription** works, no API key needed).

The agent runs with its normal tools. Sprig answers the CLI's interactive control requests over the same stream: when a tool needs approval that the CLI's own permission configuration does not already grant, Sprig prompts you (rather than the headless auto-deny), and it enables the interactive tools that stay dark otherwise, so `AskUserQuestion` renders as a choice and plan-mode approval works. Set `sprig-permission-function` to `always` to approve every escalation automatically and keep to pure after-the-fact review.

## How it works

Emacs runs one long-lived process per session, owned by its review buffer:

```
claude -p --input-format stream-json --output-format stream-json \
       --include-partial-messages --verbose
```

Sprig appends `--model`, `--append-system-prompt`, and `--resume` as configured. It writes a user-message JSON line to stdin; the CLI streams assistant token deltas back on stdout, which Sprig parses into a small backend-neutral event vocabulary and folds into the review buffer's model, re-rendering as the turn arrives. The session id is captured from the CLI; because the CLI names its own log file after it, that is all Sprig needs to replay the conversation later or resume it with `--resume`.

Because the whole protocol is plain stdio, running the session on a remote host is just prefixing the command with `ssh HOST`. Set `sprig-remote` and the session, and its logs, live there instead. The remote box is where `claude` must be installed and logged in. Sprig never touches git itself: an accept, reject, or commit is an *instruction sent to the agent*, which is what makes the remote path work from day one.

## Requirements

- Emacs 28.1+ (uses the built-in `json-parse-string` / `json-serialize`).
- `magit-section` 4.0+, for the review buffer. It is declared in the package headers, so `package.el` / straight install it (and its own deps) automatically.
- `claude` CLI v2.1+ on the machine that runs the session (local or the SSH host), logged in (`claude` then `/login`).
- `markdown-mode` is optional; when present, prose in the review buffer is fontified with its faces.

## Install

Put the three `.el` files on your `load-path`, then:

```elisp
(require 'sprig)

;; Run the session on a remote server over SSH:
(setq sprig-remote "you@your-server")   ;; nil = run locally
(setq sprig-model  "claude-opus-4-8")   ;; or nil for the CLI default

;; The navigator lists every session on the host; cap the first paint:
(setq sprig-status-max-sessions 30)
```

With `use-package` and a local checkout:

```elisp
(use-package sprig
  :load-path "~/Projects/sprig"
  :custom
  (sprig-remote "you@your-server")
  (sprig-model "claude-opus-4-8")
  (sprig-status-max-sessions 30))
```

## SSH tips

- Use key-based auth and an SSH `ControlMaster` so reconnects are instant:

  ```
  # ~/.ssh/config
  Host your-server
      User you
      ControlMaster auto
      ControlPath ~/.ssh/cm-%r@%h:%p
      ControlPersist 10m
  ```

- If `claude` isn't on the non-interactive `PATH` over SSH, set the full path:

  ```elisp
  (setq sprig-program "/home/you/.local/bin/claude")
  ```

## Usage

1. `M-x sprig-status` opens the navigator, listing every stored session on the host, newest first; `/` narrows it to a project or title.
2. `RET` (or `o`) on a row opens that session's review buffer, replaying its full history. `s` starts a fresh session, prompting for its working directory. `M-x sprig-review-session` does the same directly.
3. In the review buffer, review the agent's work: prose reads as prose, and every tool call folds to a one-line heading naming what it touched. Move with `n` / `p`, and `TAB` on an edit to unfold its diff.
4. Steer it: mark sections with `SPC`, then use a verb (below). `c c` composes a message and sends it; the session starts or resumes automatically on the first send.
5. `c i` (or `k` in the navigator) interrupts a streaming turn; the session resumes on the next send.

The session lives on past the buffer: reopen it any time from the navigator, or resume it with `c` there. Nothing is saved by you, because the CLI's log already is the record.

### Commands

| Command | Binding | Does |
|---|---|---|
| `sprig-status` | `M-x` | Open the navigator listing stored sessions and their status |
| `sprig-review-session` | `M-x` | Open a review buffer for a session (start fresh, or resume an id) |
| `sprig-review-connect` | `M-x` | Start or resume the session owned by the current review buffer |
| `sprig-review-open-file` | `M-x` | Review a session-log `.jsonl` file directly (offline, read-only) |

### Navigator

`M-x sprig-status` opens a `*sprig-status*` buffer listing every stored `claude` session on the host, newest first and capped to `sprig-status-max-sessions`, plus any open review buffer that owns a live session. Each row shows a status glyph (`▶` streaming, `●` idle, `○` disconnected), the session's title (from the CLI's own `ai-title`), its project (from the session's own `cwd`), and a short session id. It refreshes itself as sessions start, stream, and finish. Press `TAB` on a row to expand an inline preview of the tail of that session's last reply. `/` narrows the list to sessions whose project or title match a substring, and `L` lifts the cap to show every session.

| Key | Does |
|---|---|
| `n` / `p` | Move to the next / previous session, skipping preview lines |
| `RET` / `o` | Open the session's review buffer (replaying its log) |
| `s` | Start a fresh session, prompting for its working directory |
| `TAB` | Toggle an inline preview of the session's last reply |
| `c` | Open the session and start or resume it |
| `k` | Interrupt the streaming session |
| `d` | Disconnect the session (its log is kept) |
| `/` | Filter the list by project or title (empty clears) |
| `L` | Toggle the `sprig-status-max-sessions` cap (show all / newest) |
| `g` | Refresh the list |
| `q` | Bury the navigator |

### Review buffer

The review buffer is a read-only, Magit-like view of one session. It replays the whole transcript from the CLI's session log (`~/.claude/projects/<cwd>/<id>.jsonl` on the session host, fetched over SSH for a remote session) and, once connected, streams the in-flight turn in live. The agent's file edits render inline as a foldable diff, reconstructed from the `Edit` / `MultiEdit` / `Write` tool calls. Move with `n` / `p`, fold with `TAB`.

Every tool call folds to its one-line heading, so a long turn reads as a list of what the agent did rather than as pages of diff; `TAB` opens the change you want to review. Set `sprig-review-expand-diffs` to `t` to have diff-bearing tools render open instead.

Turns carry no role labels. Your own turns are tinted (`sprig-review-user`) and the agent's are not, which is the whole of the distinction, and only prose is padded with a blank line, so a turn's tool calls stay packed into one list.

Every block is dated in the left margin, the way `magit-log` dates a commit, so the stamp costs the prose no width and can never be mistaken for something the agent said. Replayed history is dated from the session log's own record timestamps, and a live turn is dated when it reaches the buffer; both show in local time. `sprig-review-timestamp-format` sets the format (`nil` drops the margin, a wider format like `"%m-%d %H:%M"` dates a conversation spanning days, and the margin sizes itself to fit).

It is also the steering surface. Marking is the one selection primitive; a verb acts on the marked sections, or the section at point when nothing is marked. Every change-touching verb is an instruction sent to the agent (Sprig itself never runs git):

| Key | Does |
|---|---|
| `RET` | Visit the file the section points to (over SSH/TRAMP if remote) |
| `g` | Re-read the session log into the buffer (its history is seeded once at open, never re-read after) |
| `t` | Retitle the buffer's header (display only; the CLI owns the stored title) |
| `SPC` / `m` | Toggle the mark on the section at point |
| `U` | Clear all marks |
| `k` | Reject: ask the agent to undo the marked (or point) diff hunks |
| `x` | Run: ask the agent to run the marked tool call's command |
| `C` | Commit: ask the agent to commit the current changes |
| `a` | Accept: clear the marks (sends nothing, commits nothing) |
| `c` | Transient, listing every verb: `c c` compose & send, `c p` compose in plan mode, `c s` steer the running turn, `c r` resend last turn, `c i` interrupt, and `c k` / `c a` / `c C` / `c x` for the four above |

`c c` opens a compose buffer (`C-c C-c` sends, `C-c C-k` cancels); any marked sections are attached to the message as context, and the first send starts or resumes the session. `c p` sends the turn in plan mode (the agent plans rather than acts), switched over the session's control channel; a plain `c c` afterwards returns to normal execution. The header shows the permission mode while it is not the normal one, and the mode line carries it too (`[plan]`, `[acceptEdits]`, ...).

`c s` **steers the turn already in flight**, rather than waiting it out or killing it. The CLI's stdin stays open for the length of a turn, so the message is queued and handed to the agent at its next tool-call boundary: it reads it and changes course *within the same turn*, no interrupt and no restart. Watching a turn head the wrong way, `c s` is the cheap correction and `c i` the expensive one. A `c c` mid-turn still refuses, since that would be a second turn. If the turn happens to finish while you are still composing, the message is sent as an ordinary turn rather than lost.

When the agent calls `AskUserQuestion` mid-turn, Sprig renders the question and its options and reads your pick in the minibuffer (multiple questions are asked in turn; blank skips one); the choice rides back to the agent and the exchange shows inline as tool activity. A tool that needs approval prompts the same way. When it presents a plan (`ExitPlanMode`), the plan renders in the buffer and Sprig asks you to approve it or reject it with feedback; approval exits plan mode and the agent starts work, a rejection sends your feedback back for a revised plan.

## Options

| Variable | Default | Meaning |
|---|---|---|
| `sprig-remote` | `nil` | SSH destination, or nil for local |
| `sprig-program` | `"claude"` | Path to the CLI on the session host |
| `sprig-directory` | `nil` | Fallback working directory for a new session |
| `sprig-model` | `"claude-opus-4-8"` | Model id, or nil for CLI default |
| `sprig-system-prompt` | short hint | Appended system prompt, or nil |
| `sprig-ssh-program` | `"ssh"` | SSH client program |
| `sprig-ssh-args` | `("-T" "-A")` | Extra SSH args (`-A` forwards your agent to the host) |
| `sprig-extra-args` | `nil` | Extra `claude` args |
| `sprig-supported-dialog-kinds` | `("ask_user_question" "exit_plan_mode")` | Dialog kinds Sprig tells the CLI it can answer; declaring a kind is what enables the tool behind it (nil disables both) |
| `sprig-permission-function` | `sprig-permission-prompt` | Called with a tool name and input when the CLI asks to run a tool; non-nil allows, nil denies. Set to `always` to auto-approve |
| `sprig-error-buffer` | `"*sprig-errors*"` | Buffer where a failed session's command and stderr are logged |
| `sprig-status-max-sessions` | `30` | Newest stored sessions the navigator lists at once (nil = no cap; `L` lifts it live) |
| `sprig-status-directories` | `nil` | Deprecated: when set, seeds the navigator's initial `/` filter with the first entry's project name |
| `sprig-status-ignore-directories` | `nil` | Regexps matched against a session's encoded project directory; matches are hidden from the navigator (e.g. throwaway `/tmp` / SDK-probe runs) |
| `sprig-status-preview-max-lines` | `3` | Lines shown in a navigator `TAB` inline reply preview |
| `sprig-review-refresh-delay` | `0.1` | Seconds to coalesce structural events before re-rendering a review buffer |
| `sprig-review-expand-diffs` | `nil` | Render a diff-bearing tool call open instead of folded to its heading |
| `sprig-review-timestamp-format` | `"%H:%M"` | `format-time-string` format for the left-margin timestamp on each block, in local time (nil = no timestamps, no margin) |
| `sprig-review-fontify-markdown` | `t` | Fontify review prose with `markdown-mode` faces when it is installed |

The navigator scans every session log under `~/.claude/projects/` on the session host, newest first, and reads each session's own `cwd` and `ai-title` records for its project and title. For a remote session those logs live on the SSH host and are scanned over the same SSH the transport uses, in two round trips (a mtime-sorted listing, then one batched slurp of the capped set's tails), so a host with hundreds of sessions still lists quickly.

## Status / caveats

- v0.7.1, written against `claude` 2.1.x. The protocol round-trip (streaming, multi-turn memory, session resume, plan-mode switch) is verified against the real CLI; the Elisp itself has had light exercise, so expect a rough edge or two.
- One turn at a time per session (several sessions can stream at once).
- Session ids are per-host: a session started on one machine (or the SSH host) cannot resume on another. When the CLI reports the stored id is unknown, Sprig drops it and starts a fresh session automatically; the review buffer keeps showing the replayed history, but the new session does not carry the earlier turns' server-side memory.
- Interrupt currently kills the turn's process; the session resumes on the next send. Graceful interrupt (the CLI advertises `interrupt_receipt_v1`) is future work.
- Diffs are reconstructed from tool-call payloads (`Edit` / `MultiEdit` / `Write`), so a `Bash`-driven edit is not yet attributed; git ground truth is a later slice.
- The `sprig-status` navigator ships as a flat session list; the fork forest it will grow into is not built yet.

## Development

After editing any of the three source files, `M-x sprig-reload` re-loads all of them from disk in dependency order, so a change takes effect without restarting Emacs. Open buffers keep their state and pick up the new definitions. Edited faces take effect too: `defface` is a no-op on an already-defined face, so the reload undefines sprig's own faces first, and a face you have customized or themed keeps that.

`sprig-tests.el` is an ERT suite covering the process-free layers (the stream-json transport and its event vocabulary, command construction, the review model and tool-payload diff engine, the stored-session log parser, and the navigator's session enumeration). It needs no extra dependencies and runs offline, starting no session:

```
emacs -Q --batch -L . -l sprig.el -l sprig-tests.el -f ert-run-tests-batch-and-exit
```

The review buffer (`sprig-review-mode.el`) has its own suite in `sprig-review-mode-tests.el`, which loads `magit-section`. Point the load path at wherever it is installed (locally, the vendored `.deps/` used for development):

```
emacs -Q --batch -L . -L .deps/compat -L .deps/cond-let -L .deps/llama \
      -L .deps/magit-section \
      -l sprig.el -l sprig-review.el -l sprig-review-mode.el \
      -l sprig-review-mode-tests.el -f ert-run-tests-batch-and-exit
```

## Direction

The review-and-steer model is the point of the project. See [DESIGN.md](DESIGN.md) for the full write-up. In short:

- A conversation is a read-only review buffer; the crux is reviewing the agent's actual file changes inline and steering them.
- Sprig never touches git: accept, reject, and commit are instructions sent to the agent, which keeps the remote path working from day one.
- The store is the CLI's own session log, so Sprig persists nothing and replays history from it.
- A `sprig-status` buffer navigates the sessions, one process per session, many able to stream at once.
