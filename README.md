# claude-org.el

A small Org-native chat client for a persistent **Claude Code session**, local or over **SSH**. It talks to the `claude` CLI's stream-json protocol, so it uses whatever the CLI is logged in as (a Claude **Pro/Max subscription** works, no API key needed).

This is a *chat* client: tools are disabled, so Claude answers in text and never edits your files. If you want agentic edits from Emacs, use `claude-code-ide.el` instead.

## How it works

Emacs runs one long-lived process per conversation buffer:

```
claude -p --input-format stream-json --output-format stream-json \
       --include-partial-messages --verbose --allowedTools ""
```

You write a user-message JSON line to its stdin; it streams assistant token deltas back on stdout, which get inserted into the buffer live. The session id is captured from the CLI and stored as a `#+CLAUDE_SESSION:` keyword, so the conversation survives an Emacs restart and reconnects with `--resume`.

Because the whole protocol is plain stdio, running the session on a remote host is just a matter of prefixing the command with `ssh HOST`. Set `claude-org-remote` and the session runs there instead of locally. The remote box is where `claude` must be installed and logged in.

## Requirements

- Emacs 27.1+ (uses the built-in `json-parse-string` / `json-serialize`).
- `claude` CLI v2.1+ on the machine that runs the session (local or the SSH host), logged in (`claude` then `/login`).

## Install

Put `claude-org.el` on your `load-path`, then:

```elisp
(require 'claude-org)

;; Run the session on a remote server over SSH (recommended for your setup):
(setq claude-org-remote "you@your-server")   ;; nil = run locally
(setq claude-org-model  "claude-opus-4-8")     ;; or nil for the CLI default

;; Turn on the keymap in Org buffers you use for chatting:
(add-hook 'org-mode-hook #'claude-org-mode)
```

With `use-package` and a local checkout:

```elisp
(use-package claude-org
  :load-path "~/src/claude-org"
  :hook (org-mode . claude-org-mode)
  :custom
  (claude-org-remote "you@your-server")
  (claude-org-model "claude-opus-4-8"))
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
  (setq claude-org-program "/home/you/.local/bin/claude")
  ```

## Usage

1. Open an `.org` file. It becomes your conversation transcript.
2. `M-x claude-org-connect` (`C-c C-a C-o`) to start/resume the session.
3. Type a message, then send it:
   - select it and `C-c C-a C-c` (region), or
   - put point in a subtree and `C-c C-a C-c` (sends the subtree body).
4. The reply streams in under a `** Claude` heading, followed by a fresh `** You` heading for your next message.
5. `C-c C-a C-k` (`claude-org-disconnect`) stops the process; the transcript and `#+CLAUDE_SESSION:` id are kept, so reconnecting resumes the conversation.

### Commands

| Command | Binding | Does |
|---|---|---|
| `claude-org-connect` | `C-c C-a C-o` | Start or resume the session for this buffer |
| `claude-org-send-dwim` | `C-c C-a C-c` | Send the region, else the current subtree |
| `claude-org-send-region` | | Send the active region |
| `claude-org-send-subtree` | | Send the current subtree body |
| `claude-org-disconnect` | `C-c C-a C-k` | Stop the session (conversation kept) |

## Options

| Variable | Default | Meaning |
|---|---|---|
| `claude-org-remote` | `nil` | SSH destination, or nil for local |
| `claude-org-program` | `"claude"` | Path to the CLI on the session host |
| `claude-org-model` | `"claude-opus-4-8"` | Model id, or nil for CLI default |
| `claude-org-system-prompt` | short Org hint | Appended system prompt, or nil |
| `claude-org-ssh-args` | `("-T")` | Extra SSH args |
| `claude-org-extra-args` | `nil` | Extra `claude` args |

## Status / caveats

- v0.1, written against `claude` 2.1.205. The protocol round-trip (streaming, multi-turn memory, session resume) is verified against the real CLI; the Elisp itself has not yet been exercised in a running Emacs, so expect a rough edge or two on first run.
- One turn at a time per buffer (no interrupt yet).
- Loading the full CLAUDE.md/skills context on the session host adds cost per turn; a `--bare`-style lean mode is a possible future option, but `--bare` currently forces API-key auth, so it is off by the subscription path.

## Ideas / next steps

- Interrupt support (the CLI advertises `interrupt_receipt_v1`).
- Render assistant text into a dedicated read-only region or `#+begin_quote`.
- A `send-buffer` command and a proper `M-x claude-org` scratch conversation.
- Show live usage/cost in the mode line.
