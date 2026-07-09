# sprig

Sprig is an Emacs interface for conversing with an LLM agent, aimed at breaking out of linear chat.

**Where it is today:** a small chat client for a persistent **Claude Code session**, local or over **SSH**. It talks to the `claude` CLI's stream-json protocol, so it uses whatever the CLI is logged in as (a Claude **Pro/Max subscription** works, no API key needed). One Org buffer is one conversation.

**Where it is going:** a non-linear, forkable model where conversations are plain Markdown files you edit directly and explore in parallel, driven from a Magit-like control buffer. That design is written up in [DESIGN.org](DESIGN.org) and is **not yet implemented**. The current code still reflects the earlier single-buffer Org design.

This is a *chat* client: tools are disabled, so the agent answers in text and never edits your files. If you want agentic edits from Emacs, use `claude-code-ide.el` instead.

## How it works

Emacs runs one long-lived process per conversation buffer:

```
claude -p --input-format stream-json --output-format stream-json \
       --include-partial-messages --verbose --allowedTools ""
```

You write a user-message JSON line to its stdin; it streams assistant token deltas back on stdout, which get inserted into the buffer live. The session id is captured from the CLI and stored as a `#+CLAUDE_SESSION:` keyword, so the conversation survives an Emacs restart and reconnects with `--resume`.

Because the whole protocol is plain stdio, running the session on a remote host is just a matter of prefixing the command with `ssh HOST`. Set `sprig-remote` and the session runs there instead of locally. The remote box is where `claude` must be installed and logged in.

## Requirements

- Emacs 27.1+ (uses the built-in `json-parse-string` / `json-serialize`).
- `claude` CLI v2.1+ on the machine that runs the session (local or the SSH host), logged in (`claude` then `/login`).

## Install

Put `sprig.el` on your `load-path`, then:

```elisp
(require 'sprig)

;; Run the session on a remote server over SSH:
(setq sprig-remote "you@your-server")   ;; nil = run locally
(setq sprig-model  "claude-opus-4-8")     ;; or nil for the CLI default

;; Turn on the keymap in Org buffers you use for chatting:
(add-hook 'org-mode-hook #'sprig-mode)
```

With `use-package` and a local checkout:

```elisp
(use-package sprig
  :load-path "~/Projects/sprig"
  :hook (org-mode . sprig-mode)
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

1. Open an `.org` file. It becomes your conversation transcript.
2. `M-x sprig-connect` (`C-c C-a C-o`) to start/resume the session.
3. Type a message, then send it:
   - select it and `C-c C-a C-c` (region), or
   - put point in a subtree and `C-c C-a C-c` (sends the subtree body).
4. The reply streams in under a `** Claude` heading, followed by a fresh `** You` heading for your next message.
5. `C-c C-a C-k` (`sprig-disconnect`) stops the process; the transcript and `#+CLAUDE_SESSION:` id are kept, so reconnecting resumes the conversation.

### Commands

| Command | Binding | Does |
|---|---|---|
| `sprig-connect` | `C-c C-a C-o` | Start or resume the session for this buffer |
| `sprig-send-dwim` | `C-c C-a C-c` | Send the region, else the current subtree |
| `sprig-send-region` | | Send the active region |
| `sprig-send-subtree` | | Send the current subtree body |
| `sprig-disconnect` | `C-c C-a C-k` | Stop the session (conversation kept) |

## Options

| Variable | Default | Meaning |
|---|---|---|
| `sprig-remote` | `nil` | SSH destination, or nil for local |
| `sprig-program` | `"claude"` | Path to the CLI on the session host |
| `sprig-model` | `"claude-opus-4-8"` | Model id, or nil for CLI default |
| `sprig-system-prompt` | short Org hint | Appended system prompt, or nil |
| `sprig-ssh-args` | `("-T")` | Extra SSH args |
| `sprig-extra-args` | `nil` | Extra `claude` args |

## Status / caveats

- v0.1, written against `claude` 2.1.205. The protocol round-trip (streaming, multi-turn memory, session resume) is verified against the real CLI; the Elisp itself has not yet been exercised in a running Emacs, so expect a rough edge or two on first run.
- One turn at a time per buffer (no interrupt yet).
- The current implementation is the older single-buffer Org client. The Markdown, fork-by-copy, and navigator model in [DESIGN.org](DESIGN.org) is the planned direction, not built yet.
- Loading the full CLAUDE.md/skills context on the session host adds cost per turn; a `--bare`-style lean mode is a possible future option, but `--bare` currently forces API-key auth, so it is off by the subscription path.

## Direction

The fork-and-explore model is the point of the project. See [DESIGN.org](DESIGN.org) for the full write-up. In short:

- One conversation branch is one plain Markdown file you edit directly; the agent's Markdown output lands with no conversion.
- Forking copies a file up to the fork point, so each file is a complete, standalone transcript and context assembly is just "send the file".
- A Magit-like `sprig-status` buffer navigates the forest of branches, with single-key verbs to open, fork, interrupt, and prune.
- Many branches can stream at once, one process per file.
