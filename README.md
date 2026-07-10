# sprig

Sprig is an Emacs interface for conversing with an LLM agent, aimed at breaking out of linear chat.

**Where it is today:** a chat client where one conversation branch is a plain **Markdown file** you edit directly. You type your turns as prose; the agent's replies stream in wrapped in `<details>` blocks that fold in the editor and collapse on GitHub. The transport is a persistent **Claude Code session**, local or over **SSH**, via the `claude` CLI's stream-json protocol, so it uses whatever the CLI is logged in as (a Claude **Pro/Max subscription** works, no API key needed).

**Where it is going:** a non-linear, forkable model where you hold many conversations at once, fork any of them to explore several directions in parallel, and drive the whole forest from a Magit-like `sprig-status` navigator. That design is written up in [DESIGN.md](DESIGN.md). Forking (the fork forest) is **not yet implemented**, but the `sprig-status` navigator now ships in a first, flat-list form, and concurrent streams already work since each conversation is an independent buffer. Each buffer still runs one turn at a time.

This is a *chat* client: tools are disabled, so the agent answers in text and never edits your files. If you want agentic edits from Emacs, use `claude-code-ide.el` instead.

## How it works

Emacs runs one long-lived process per conversation buffer:

```
claude -p --input-format stream-json --output-format stream-json \
       --include-partial-messages --verbose --allowedTools ""
```

You write a user-message JSON line to its stdin; it streams assistant token deltas back on stdout, which get inserted into the buffer live under a new `<details>` block. The session id is captured from the CLI and stored in the file's YAML frontmatter as `claude_session:`, so the conversation survives an Emacs restart and reconnects with `--resume`.

Because the whole protocol is plain stdio, running the session on a remote host is just a matter of prefixing the command with `ssh HOST`. Set `sprig-remote` and the session runs there instead of locally. The remote box is where `claude` must be installed and logged in.

Note: the CLI keeps conversation memory server-side and resumes by session id, so a send transmits only your new turn. The "context is the whole file" replay the fork model wants (see [DESIGN.md](DESIGN.md)) suits a stateless messages backend and is future work; the turn parser that assembles that message list is already in place.

## Requirements

- Emacs 27.1+ (uses the built-in `json-parse-string` / `json-serialize`).
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

1. Open a `.md` file. It becomes your conversation branch.
2. `M-x sprig-connect` (`C-c C-a C-o`) to start/resume the session.
3. Type a message as plain prose at the end of the buffer.
4. `sprig-send` (`C-c C-c`) sends the prose typed since the last reply. The reply streams into a new `<details>` block.
5. Type your next message below that block and send again.
6. `sprig-interrupt` (`C-c C-k`) aborts a streaming reply, keeps the partial (marked `interrupted`), and leaves point ready for a redirect.
7. `sprig-disconnect` (`C-c C-a C-k`) stops the process; the transcript and `claude_session:` id are kept, so reconnecting resumes the conversation.

### Commands

| Command | Binding | Does |
|---|---|---|
| `sprig-connect` | `C-c C-a C-o` | Start or resume the session for this buffer |
| `sprig-send` | `C-c C-c` | Send the prose typed since the last reply |
| `sprig-interrupt` | `C-c C-k` | Abort a streaming reply, keep and mark the partial |
| `sprig-disconnect` | `C-c C-a C-k` | Stop the session (conversation kept) |
| `sprig-status` | `M-x` | Open the navigator listing all sessions and their status |

### Navigator

`M-x sprig-status` opens a `*sprig-status*` buffer that lists every open conversation with its live status (`▶` streaming, `●` idle, `◼` interrupted, `○` disconnected), plus unopened branch files found under `sprig-status-directories`. It refreshes itself as sessions start, stream, and finish, so a reply landing in a buffer you are not viewing shows up here. In-buffer keys:

| Key | Does |
|---|---|
| `RET` / `o` | Open the conversation on this line |
| `c` | Connect the session (opening its file if needed) |
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
| `sprig-assistant-summary` | `"assistant"` | Label in the reply `<details>` summary |
| `sprig-ssh-args` | `("-T" "-A")` | Extra SSH args (`-A` forwards your agent to the host) |
| `sprig-extra-args` | `nil` | Extra `claude` args |
| `sprig-error-buffer` | `"*sprig-errors*"` | Buffer where a failed session's command and stderr are logged |
| `sprig-show-cost` | `nil` | Append the turn's notional cost to the done message (off, since it is not real spend on a subscription) |
| `sprig-status-directories` | `nil` | Directories the navigator scans for branch files (nil = open buffers' dirs plus `sprig-directory`) |

A single file can override the working directory with a `working_dir:` line in its YAML frontmatter, so one branch can run against a different project than the `sprig-directory` default. The value may use `~` and, for a remote session, is resolved on the SSH host.

## Status / caveats

- v0.2, written against `claude` 2.1.205. The protocol round-trip (streaming, multi-turn memory, session resume) is verified against the real CLI; the Elisp itself has had light exercise, so expect a rough edge or two.
- Single file, one turn at a time per buffer (several buffers can stream at once).
- Session ids are per-host: a file created against one machine (or the SSH host) cannot resume on another. When the CLI reports the stored id is unknown, Sprig drops it and starts a fresh session automatically; the transcript in the file is kept, but the new session does not carry the earlier turns' server-side memory (transcript replay is future work, see [DESIGN.md](DESIGN.md)).
- `sprig-interrupt` currently kills the turn's process; the session resumes on the next send. Graceful interrupt (the CLI advertises `interrupt_receipt_v1`) is future work.
- The `sprig-status` navigator ships as a flat session list; the fork forest it will grow into (and forking itself) is not built yet.
- Loading the full CLAUDE.md/skills context on the session host adds cost per turn; a `--bare`-style lean mode is a possible future option, but `--bare` currently forces API-key auth, so it is off by the subscription path.

## Direction

The fork-and-explore model is the point of the project. See [DESIGN.md](DESIGN.md) for the full write-up. In short:

- One conversation branch is one plain Markdown file you edit directly; the agent's Markdown output lands with no conversion.
- Forking copies a file up to the fork point, so each file is a complete, standalone transcript and context assembly is just "send the file".
- A Magit-like `sprig-status` buffer navigates the forest of branches, with single-key verbs to open, fork, interrupt, and prune.
- Many branches can stream at once, one process per file.
