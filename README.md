# sprig

Sprig is an Emacs interface for conversing with an LLM agent, aimed at breaking out of linear chat.

**Where it is today:** one conversation branch is a plain **Markdown file** you edit directly. You type your turns as prose; the agent's replies stream in as Markdown, delimited by invisible `sprig:` HTML-comment sentinels that `sprig-mode` hides behind chat-like chrome (the raw sentinels stay in the file, so a reopened buffer still parses and folds correctly). The transport is a persistent **Claude Code session**, local or over **SSH**, via the `claude` CLI's stream-json protocol, so it uses whatever the CLI is logged in as (a Claude **Pro/Max subscription** works, no API key needed).

**Where it is going:** a non-linear, forkable model where you hold many conversations at once, fork any of them to explore several directions in parallel, and drive the whole forest from a Magit-like `sprig-status` navigator. That design is written up in [DESIGN.md](DESIGN.md). Forking (the fork forest) is **not yet implemented**, but the `sprig-status` navigator now ships in a first, flat-list form, and concurrent streams already work since each conversation is an independent buffer. Each buffer still runs one turn at a time.

Tools are not force-disabled. The agent's tool use follows the `claude` CLI's own permission configuration, and any tool calls and their results render inline in the transcript (see `sprig-render-tools`), so the agent can read, run, and edit as far as your CLI setup allows, not only answer in prose.

## How it works

Emacs runs one long-lived process per conversation buffer:

```
claude -p --input-format stream-json --output-format stream-json \
       --include-partial-messages --verbose
```

Per buffer, Sprig appends `--model`, `--append-system-prompt`, and `--resume` to that command as configured; tools are governed by the CLI's own permission config rather than disabled. You write a user-message JSON line to its stdin; it streams assistant token deltas back on stdout, which get inserted into the buffer live inside a new reply span delimited by `<!-- sprig:reply -->` / `<!-- sprig:end -->` sentinels that `sprig-mode` renders as chat. The session id is captured from the CLI and stored in the file's YAML frontmatter as `claude_session:`, so the conversation survives an Emacs restart and reconnects with `--resume`.

Because the whole protocol is plain stdio, running the session on a remote host is just a matter of prefixing the command with `ssh HOST`. Set `sprig-remote` and the session runs there instead of locally. The remote box is where `claude` must be installed and logged in.

Note: the CLI keeps conversation memory server-side and resumes by session id, so a send transmits only your new turn. The "context is the whole file" replay the fork model wants (see [DESIGN.md](DESIGN.md)) suits a stateless messages backend and is future work; the turn parser that assembles that message list is already in place.

## Requirements

- Emacs 28.1+ (uses the built-in `json-parse-string` / `json-serialize`).
- `magit-section` 4.0+, for the read-only review buffer. It is declared in the package headers, so `package.el` / straight install it (and its own deps) automatically.
- `claude` CLI v2.1+ on the machine that runs the session (local or the SSH host), logged in (`claude` then `/login`).
- `markdown-mode` is recommended for the editing buffer, but not required.

## Install

Put `sprig.el` on your `load-path`, then:

```elisp
(require 'sprig)

;; Run the session on a remote server over SSH:
(setq sprig-remote "you@your-server")   ;; nil = run locally
(setq sprig-model  "claude-opus-4-8")     ;; or nil for the CLI default

;; Turn on the keymap in the Markdown buffers you use for chatting:
(add-hook 'markdown-mode-hook #'sprig-mode)
```

With `use-package` and a local checkout:

```elisp
(use-package sprig
  :load-path "~/Projects/sprig"
  :hook (markdown-mode . sprig-mode)
  :custom
  (sprig-remote "you@your-server")
  (sprig-model "claude-opus-4-8"))
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

1. Open a `.md` file, or `M-x sprig-new` (`s` in the navigator) to start an in-memory branch you can save later with `sprig-save` (`w`). It becomes your conversation branch. Killing an unsaved in-memory branch that holds a transcript or a live session asks first, so you do not lose it by accident.
2. `M-x sprig-connect` (`C-c C-a C-o`) to start/resume the session. Starting a new session prompts for the working directory (seeded with the current default) and records it in the file's frontmatter.
3. Type a message as plain prose at the end of the buffer.
4. `sprig-send` (`C-c C-c`) sends the prose typed since the last reply. The reply streams into a new reply span (hidden `sprig:reply` sentinels, shown as chat).
5. Type your next message below that block and send again.
6. `sprig-interrupt` (`C-c C-k`) aborts a streaming reply, keeps the partial (marked `interrupted`), and leaves point ready for a redirect.
7. `sprig-disconnect` (`C-c C-a C-k`) stops the process; the transcript and `claude_session:` id are kept, so reconnecting resumes the conversation.

### Commands

| Command | Binding | Does |
|---|---|---|
| `sprig-new` | `M-x` | Start a fresh in-memory conversation (no file yet) |
| `sprig-save` | `M-x` | Save an in-memory conversation to a file |
| `sprig-connect` | `C-c C-a C-o` | Start or resume the session for this buffer |
| `sprig-send` | `C-c C-c` | Send the prose typed since the last reply |
| `sprig-interrupt` | `C-c C-k` | Abort a streaming reply, keep and mark the partial |
| `sprig-disconnect` | `C-c C-a C-k` | Stop the session (conversation kept) |
| `sprig-review` | `C-c C-a C-r` | Open a read-only review buffer for this conversation |
| `sprig-set-tool-display` | `M-x` | Set how much tool activity this file renders (`none`/`calls`/`full`) |
| `sprig-status` | `M-x` | Open the navigator listing all sessions and their status |

### Navigator

`M-x sprig-status` opens a `*sprig-status*` buffer that lists every open conversation with its live status (`▶` streaming, `●` idle, `◼` interrupted, `○` disconnected), plus unopened branch files found under `sprig-status-directories`. It refreshes itself as sessions start, stream, and finish, so a reply landing in a buffer you are not viewing shows up here. Press `TAB` on a row to expand an inline preview of the tail of that session's last reply, without leaving the navigator. In-buffer keys:

| Key | Does |
|---|---|
| `n` / `p` | Move to the next / previous session, skipping preview lines |
| `s` | Start a fresh in-memory conversation (save to a file later, or not) |
| `RET` / `o` | Open the conversation on this line |
| `TAB` | Toggle an inline preview of the session's last reply |
| `c` | Connect the session (opening its file if needed) |
| `w` | Save an in-memory conversation to a file (default name from its title) |
| `k` | Interrupt the streaming session |
| `d` | Disconnect the session |
| `g` | Refresh the list |
| `q` | Bury the navigator |
| `f` / `r` / `x` | Fork / rename / prune (planned; not yet implemented) |

## Options

| Variable | Default | Meaning |
|---|---|---|
| `sprig-remote` | `nil` | SSH destination, or nil for local |
| `sprig-program` | `"claude"` | Path to the CLI on the session host |
| `sprig-directory` | `nil` | Working directory for the session, or nil for the file's directory |
| `sprig-model` | `"claude-opus-4-8"` | Model id, or nil for CLI default |
| `sprig-system-prompt` | short Markdown hint | Appended system prompt, or nil |
| `sprig-render-tools` | `none` | How much tool activity to write to the transcript: `none`, `calls`, or `full` |
| `sprig-fold-tool-calls` | `t` | Fold tool-call and result blocks to their header on open |
| `sprig-hide-sentinels` | `t` | Hide the `sprig:` sentinel lines behind chat chrome |
| `sprig-reply-divider` | `t` | Draw a faint rule at each reply-span boundary |
| `sprig-highlight-user-input` | `t` | Give the user's own turns a distinguishing face |
| `sprig-ssh-program` | `"ssh"` | SSH client program |
| `sprig-ssh-args` | `("-T" "-A")` | Extra SSH args (`-A` forwards your agent to the host) |
| `sprig-extra-args` | `nil` | Extra `claude` args |
| `sprig-auto-title` | `t` | After the first reply, name a titleless branch from the opening exchange |
| `sprig-error-buffer` | `"*sprig-errors*"` | Buffer where a failed session's command and stderr are logged |
| `sprig-show-cost` | `nil` | Append the turn's notional cost to the done message (off, since it is not real spend on a subscription) |
| `sprig-status-directories` | `nil` | Directories the navigator scans for branch files (nil = open buffers' dirs plus `sprig-directory`) |
| `sprig-status-preview-max-lines` | `3` | Lines shown in a navigator `TAB` inline reply preview |

A single file can override the working directory with a `working_dir:` line in its YAML frontmatter, so one branch can run against a different project than the `sprig-directory` default. The value may use `~` and, for a remote session, is resolved on the SSH host.

The navigator's Title column comes from a `title:` frontmatter line, falling back to the file name (or the buffer name for an unsaved scratch branch). With `sprig-auto-title` on, a branch that has no `title:` yet gets one after its first reply: a short throwaway `claude` run (using `sprig-model`) turns the opening user turn and reply into a label, the same recipe the CLI uses to name its own sessions. A `title:` you write by hand is always left alone.

Tool calls and their results are transcript-only: they render inline for you to read but are stripped from the message list sent back to the model (the CLI keeps its own tool memory). `sprig-render-tools` sets how much is written (`none`, `calls`, `full`), and a single file overrides that default with a `sprig_tools:` frontmatter line, set by `M-x sprig-set-tool-display`.

## Status / caveats

- v0.4.1, written against `claude` 2.1.205. The protocol round-trip (streaming, multi-turn memory, session resume) is verified against the real CLI; the Elisp itself has had light exercise, so expect a rough edge or two.
- Single file, one turn at a time per buffer (several buffers can stream at once).
- Session ids are per-host: a file created against one machine (or the SSH host) cannot resume on another. When the CLI reports the stored id is unknown, Sprig drops it and starts a fresh session automatically; the transcript in the file is kept, but the new session does not carry the earlier turns' server-side memory (transcript replay is future work, see [DESIGN.md](DESIGN.md)).
- `sprig-interrupt` currently kills the turn's process; the session resumes on the next send. Graceful interrupt (the CLI advertises `interrupt_receipt_v1`) is future work.
- The `sprig-status` navigator ships as a flat session list; the fork forest it will grow into (and forking itself) is not built yet.
- Loading the full CLAUDE.md/skills context on the session host adds cost per turn; a `--bare`-style lean mode is a possible future option, but `--bare` currently forces API-key auth, so it is off by the subscription path.

## Development

`sprig-tests.el` is an ERT suite covering the process-free layers (frontmatter, turn parsing, the stream-json transport and its event vocabulary, the sink, decoration parity, the review model and tool-payload diff engine, and the string and command-construction helpers). It needs no extra dependencies and runs offline, starting no session:

```
emacs -Q --batch -L . -l sprig.el -l sprig-tests.el -f ert-run-tests-batch-and-exit
```

The read-only review buffer (`sprig-review-mode.el`) has its own suite in `sprig-review-mode-tests.el`, which loads `magit-section`. Point the load path at wherever it is installed (locally, the vendored `.deps/` used for development):

```
emacs -Q --batch -L . -L .deps/compat -L .deps/cond-let -L .deps/llama \
      -L .deps/magit-section \
      -l sprig-review-mode.el -l sprig-review-mode-tests.el \
      -f ert-run-tests-batch-and-exit
```

## Direction

The fork-and-explore model is the point of the project. See [DESIGN.md](DESIGN.md) for the full write-up. In short:

- One conversation branch is one plain Markdown file you edit directly; the agent's Markdown output lands with no conversion.
- Forking copies a file up to the fork point, so each file is a complete, standalone transcript and context assembly is just "send the file".
- A Magit-like `sprig-status` buffer navigates the forest of branches, with single-key verbs to open, fork, interrupt, and prune.
- Many branches can stream at once, one process per file.
