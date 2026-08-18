;;; sprig.el --- Transport and navigator for reviewing agent sessions -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.50.0
;; Package-Requires: ((emacs "28.1") (magit-section "4.0.0"))
;; Keywords: tools, convenience, ai

;;; Commentary:

;; Sprig is an Emacs interface for reviewing and steering an LLM agent's
;; work.  You never edit a transcript: a conversation is a read-only,
;; Magit-like review buffer (see sprig-review-mode.el and DESIGN.md), and
;; the whole forest of them is driven from the `sprig-status' navigator.
;;
;; This file is the transport and the navigator; it owns no rendering.
;;
;; Transport: the `claude' CLI's stream-json protocol over stdio, local or
;; via `ssh HOST claude ...' (set `sprig-remotes').  `sprig--claude-parse-line'
;; turns raw wire lines into a small backend-neutral event vocabulary
;; (see "Transport and sink"), and each session-owning buffer folds those
;; events with its `sprig--sink'.  The CLI uses whatever it is logged in as
;; (e.g. a Pro/Max subscription), so no API key is required, and the agent
;; runs with its normal tools, so a reply may run commands and edit files.
;;
;; A branch is a `claude' session.  The CLI already persists each session
;; as a JSONL log under ~/.claude/projects/<cwd>/<id>.jsonl on the host
;; where it runs, so sprig keeps no store of its own: history is replayed
;; from that log, and it survives an Emacs restart because the id names the
;; file.  A review buffer owns its session outright (`sprig-review-session',
;; `sprig-review-connect'); the transport routes its events to the review
;; model and its verbs steer the session directly.
;;
;; Navigator: `sprig-status' lists every stored session on the host,
;; newest first and capped, plus any open review buffer that owns a live
;; session, with per-session status and an inline preview of the last
;; reply.  `/' narrows to a project or title, `L' lifts the cap.  Open /
;; connect / interrupt / disconnect act on a session-owning review buffer;
;; `s' starts a fresh session.

;;; Code:

(require 'json)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'transient)                     ; the navigator's c / a dispatch menus
(require 'iso8601)                       ; parse the log's own timestamps
(require 'sprig-review)                  ; pure data layer; no magit-section
(eval-when-compile (require 'let-alist))

(defgroup sprig nil
  "Non-linear agent conversations in Markdown."
  :group 'tools
  :prefix "sprig-")

(defcustom sprig-program "claude"
  "Path to the `claude' CLI (on the machine where the session runs)."
  :type 'string)

(defcustom sprig-remotes nil
  "SSH destinations (e.g. \"user@host\") the navigator lists, or nil.
Each entry becomes a `remote' group of its own in the navigator, scanned
and capped independently, alongside the always-present `local' group, so
several hosts show at once.  The first entry is the primary remote: a
session started outside the navigator, and any review buffer not pinned
to a host of its own, runs there rather than locally.  Nil lists only the
local machine."
  :type '(repeat (string :tag "SSH destination")))

(defcustom sprig-ssh-program "ssh"
  "SSH client used when a remote is set."
  :type 'string)

(defcustom sprig-ssh-args '("-T" "-A")
  "Extra arguments passed to SSH (before the destination).
`-T' disables pseudo-tty allocation, which is what we want for a pipe.
`-A' forwards your SSH agent so the remote session can use your keys
\(e.g. for git); drop it if the host should not have that access."
  :type '(repeat string))

(defcustom sprig-directory nil
  "Working directory for the agent session, or nil.
When nil, a local session runs in the conversation file's directory and
a remote session in the SSH login directory.  A file overrides this with
a `working_dir:' line in its YAML frontmatter.  The value may use `~' and,
for a remote session, is interpreted on the SSH host."
  :type '(choice (const :tag "Default" nil) (directory :tag "Directory")))

(defcustom sprig-config-directory nil
  "Directory for the CLI's config, credentials, and session logs, or nil.
When non-nil, sprig runs the `claude' CLI with the CLAUDE_CONFIG_DIR
environment variable set to this path, so its sessions, their logs, and
its login are kept separate from the default ~/.claude.  The navigator
then lists only the sessions started under it.  nil uses the CLI's own
default (~/.claude), sharing everything with the plain CLI.

The value is interpreted on the session host (the SSH host for a remote
session) and may use `~'.  An XDG-friendly choice, needing `(require
\\='xdg)':

  (setq sprig-config-directory
        (expand-file-name \"sprig/claude\" (xdg-config-home)))

A fresh config dir starts logged out; set it up once per host with
\\[sprig-login]."
  :type '(choice (const :tag "CLI default (~/.claude)" nil)
                 (directory :tag "Config directory")))

(defcustom sprig-use-broker nil
  "Whether to run sessions through the sprig-broker, and which ones.
The broker is a small per-host daemon that owns the `claude' child, so a
session survives its client going away: reconnecting reattaches to the same
live process rather than resuming a killed one, and an in-flight turn is not
lost.  See the \"Detach and reattach\" section of DESIGN.md.

  nil      off; every session is a direct `claude' child of Emacs.
  remote   broker remote (SSH) sessions only; a local session stays a direct
           child of Emacs (`t' means this too, for backward compatibility).
  all      broker local sessions as well, so a local session outlives Emacs:
           close or restart Emacs and reattach to the same process later.

A brokered session needs `python3' on the host running it (the SSH host, or
this machine for `all').  For a remote host sprig ships the broker on first
use (see `sprig-broker-remote-path'); locally it writes the same script under
`sprig-broker-remote-path' expanded here.  Off by default; this is new."
  :type '(choice (const :tag "Off" nil)
                 (const :tag "Remote sessions only" remote)
                 (const :tag "Remote and local sessions" all)))

(defcustom sprig-broker-remote-path "~/.local/share/sprig/sprig-broker"
  "Path the broker is installed to on each SSH host.
Interpreted on the host and may use `~'.  sprig compares the installed
copy's version against `sprig-broker-version' and reinstalls when they
differ, so a path on a per-user, writable filesystem is what you want."
  :type 'string)

(defcustom sprig-broker-program nil
  "Local file to ship to hosts instead of the embedded broker, or nil.
When nil, sprig ships the broker source embedded in the package
\(`sprig--broker-source-text'), so nothing need be laid out beside the
loaded library: package managers such as straight ship only .el files, and
the broker script would otherwise be missing.  Set this to a path to ship a
different script, for instance your working copy while iterating on it."
  :type '(choice (const :tag "Embedded copy" nil) (file :tag "Broker script")))

(defconst sprig-broker-version "7"
  "Broker wire-protocol version sprig expects.
Mirrors the `VERSION' constant in the broker script; a host whose installed
broker reports a different value is reinstalled before use.")

(defcustom sprig-status-auto-reattach t
  "When non-nil, `sprig-status' reattaches to broker-held sessions it lists.
A session the broker still holds carries a `<id>.sprig-live' marker beside
its log (see `sprig--live-file'), which the scan reports for free.  When the
navigator sees such a session it connects to it in the background, attach-
only, so its live turn streams and it is ready to steer without your opening
it and sending a throwaway message.  A stale marker (from a crashed daemon)
just fails to attach, harmlessly, and is tried only once.  Needs
`sprig-use-broker'; off it, this does nothing."
  :type 'boolean)

(defcustom sprig-model "claude-opus-4-8"
  "Model id, or nil to let the CLI choose its default."
  :type '(choice (const :tag "CLI default" nil) (string :tag "Model id")))

(defcustom sprig-interrupt-timeout 5
  "Seconds to wait for a graceful interrupt before killing the turn.
`c i' interrupts by sending an `interrupt' control request, which lets the
CLI end the turn cleanly and keep the session live (no resume on the next
send).  Should the CLI not honour it within this many seconds, sprig falls
back to killing the process, the old hard interrupt.  A number, or nil to
wait indefinitely and never fall back."
  :type '(choice (const :tag "Never fall back" nil) (number :tag "Seconds")))

(defcustom sprig-system-prompt
  "You are chatting inside a Markdown buffer. Answer concisely in Markdown."
  "Text appended to the system prompt, or nil to skip."
  :type '(choice (const :tag "None" nil) string))

(defcustom sprig-extra-args nil
  "Extra arguments appended to the `claude' command line."
  :type '(repeat string))

(defcustom sprig-supported-dialog-kinds '("ask_user_question" "exit_plan_mode")
  "Dialog kinds sprig tells the CLI it can answer, via the `initialize'
handshake.  Declaring a kind is what makes the CLI enable the tool behind
it in headless stream-json mode: `ask_user_question' turns on the
AskUserQuestion tool, `exit_plan_mode' the ExitPlanMode tool (in plan
mode).  A kind sprig cannot actually render should not be listed; the CLI
falls back to the tool's no-dialog behaviour for any kind it is not told
about.  nil disables the handshake, matching the classic behaviour where
neither tool is offered."
  :type '(repeat string))

(defcustom sprig-permission-function nil
  "Function consulted when the CLI asks to run a tool (`can_use_tool'), or nil.
nil, the default, asks in the review buffer: the call renders as a dialog
you answer with `a a', and nothing is held up meanwhile.

Non-nil is called with the tool name (a string) and its input (an alist),
and returns non-nil to allow the call, nil to deny it.  Set it to `always'
to auto-approve everything the CLI would otherwise gate.  Such a function
runs inside the process filter, so it must not prompt: a prompt there
holds the filter, and Emacs with it, until it is answered.
`sprig-permission-prompt' is exactly that prompt, kept for anyone who
wants it deliberately.

This is consulted only for tools the CLI's own permission configuration
does not already allow; adding `--permission-prompt-tool stdio' routes
those escalations to sprig instead of the headless auto-deny."
  :type '(choice (const :tag "Ask in the review buffer" nil) function))

(defcustom sprig-error-buffer "*sprig-errors*"
  "Name of the buffer where session failures are logged.
When a session exits abnormally, its command, exit status, and captured
stderr are appended here and the buffer is displayed."
  :type 'string)

(defcustom sprig-debug nil
  "When non-nil, trace courier and permission activity to `*sprig-debug*'.
Every control response sprig sends is logged with its raw bytes, each
courier decision (fired, or reached the gate with nothing staged) is
noted, and the session's stderr is mirrored live, so a staged edit that
fails to land can be traced end to end.  Off by default: the log is
verbose and only useful when diagnosing the courier."
  :type 'boolean)

(defcustom sprig-status-max-sessions 30
  "How many of the newest stored sessions the navigator lists at once.
The `sprig-status' navigator scans every session on the host, newest
first, and shows this many so a host with hundreds of sessions still
paints fast.  `L' in the navigator lifts the cap for that buffer; `/'
narrows the list to a project or title.  nil means no cap."
  :type '(choice (const :tag "No cap" nil) integer))

(defcustom sprig-status-directories nil
  "Deprecated: an initial project filter for the `sprig-status' navigator.
The navigator now lists every session on the host regardless of folder;
narrow it live with `/'.  When this is set, the navigator opens filtered
to the first entry's project name, preserving the old scoped-to-a-project
feel.  Prefer leaving it nil and using `/'."
  :type '(choice (const :tag "No initial filter" nil)
                 (repeat directory)))

(defcustom sprig-status-live-refresh-interval 1.0
  "Seconds to coalesce live navigator refreshes over, or nil to disable them.
While a turn is in flight its context readout and status change with every
event, but a full navigator render re-scans the session logs (over SSH for
a remote host), so it cannot run per event.  A number keeps the open
navigator current by rendering at most once per that many seconds during a
turn; nil leaves it refreshing only at turn boundaries, as it did before."
  :type '(choice (const :tag "Only at turn boundaries" nil) number))

(defcustom sprig-status-ignore-directories nil
  "Regexps for stored sessions the navigator should hide.
Each is matched against a session's project directory name: the CLI's
encoded working directory, which is the `cwd' with every `/' and `.'
flattened to `-' (e.g. `/tmp/sdk-probe' is `-tmp-sdk-probe').  A session
whose directory matches any regexp is dropped before the newest-N cap, so
throwaway sessions (SDK probes, scratch runs under /tmp) neither clutter
the list nor use up a slot.  An explicitly opened session still shows.
Example, hiding /tmp and everything under it:

  (setq sprig-status-ignore-directories \\='(\"\\\\`-tmp\\\\(-\\\\|\\\\'\\\\)\"))"
  :type '(repeat regexp))

(defface sprig-status-star '((t :inherit warning))
  "Face for the star marking a pinned navigator session.")

(defface sprig-status-preview '((t :inherit shadow))
  "Face for the inline reply preview shown under an active navigator row.")

(defface sprig-status-preview-prompt '((t :inherit shadow :weight bold))
  "Face for the last user prompt shown as the lead of an inline preview.
Muted like the reply below it, but weighted so the prompt reads as the
question the reply is answering rather than more of the reply.")

(defface sprig-status-group '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a navigator group heading naming the host its rows run on.")

(defface sprig-mode-tag '((t :inherit font-lock-keyword-face))
  "Face for the permission mode tag on a state line.
Shared by the navigator preview and the review buffer, so `plan' reads the
same in both.  Coloured on its own terms, apart from the turn's state and
the context, so it reads as the mode it is and not as a warning about the
turn.")

;;;; Buffer-local state

(defvar-local sprig--process nil
  "The stream-json `claude' process bound to this conversation buffer.")
(defvar-local sprig--session-id nil
  "Session id captured from the CLI, used for --resume.")
(defvar-local sprig--fork-session nil
  "Non-nil while this buffer's session is still to be forked off its parent.
Set by `sprig-review-session' for a fork, where `sprig--session-id' starts
out as the *parent's* id so the spawn resumes it; the added
`--fork-session' then makes the CLI continue that history under an id of
its own rather than writing to the parent's log.  Cleared as soon as the
CLI hands that id back, since the fork has happened by then and a later
send must resume the fork rather than fork the parent afresh.")
(defvar-local sprig--busy nil
  "Non-nil while a turn is in flight.")
(defvar-local sprig--compacting nil
  "Non-nil while the session is compacting its context.
Live transport state, like `sprig--busy', rather than part of the review
model: a compaction is something happening now, so replaying the log must
not bring it back.  A compaction can run a minute or more, and an
automatic one interrupts a turn mid-flight, so the state line says so
instead of leaving the turn looking stalled.")
(defvar-local sprig--queued nil
  "Messages waiting for the in-flight turn to end, oldest first.
Live transport state, like `sprig--busy': a queued message is something
about to happen, not something the log records, so replaying cannot bring
it back.  Flushed one per `done' (see `sprig--flush-queue'), so a queue of
several plays out as one turn each rather than a single run-on message.
Dropped on an interrupt or a process death: both mean the work the message
was queued behind is not going to land, so the message's premise is gone.")
(defvar-local sprig--interrupt-timer nil
  "Fallback timer armed while a graceful interrupt is outstanding, or nil.
Set by `sprig--interrupt-turn' after it sends the `interrupt' control
request; cancelled when the turn's `done' lands (the interrupt worked) or
when the process is torn down.  If it fires first, the CLI never ended the
turn, so it falls back to killing the process (`sprig--interrupt-timeout').")
(defvar-local sprig--interrupt-request-id nil
  "Request id of the outstanding `interrupt' control request, or nil.
Lets the sink match the CLI's `control_response' receipt to our own
interrupt: an error receipt means the CLI refused it, so we fall back to
the hard kill at once rather than waiting out `sprig-interrupt-timeout'.")
(defvar-local sprig--blocks nil
  "Alist of in-flight streaming tool-use blocks, keyed by block index.
Each entry is (INDEX :id ID :name NAME :json ACC), where ACC accumulates
the streamed `input_json_delta' fragments until the block closes.")
(defvar-local sprig--permission-mode nil
  "The session's current permission mode, tracked from `status' events.
nil until the CLI reports one; \"plan\" while a plan turn is in effect.")
(defvar-local sprig--courier nil
  "Human-authored edits waiting for the agent to courier to disk, newest first.
Each entry is a plist (:file PATH :old STRING :new STRING) staged from a
staging buffer (see `sprig-review-stage-dispatch').  When the agent then
issues an edit on a matching file, `sprig--maybe-courier' allows it but
replaces the tool input's strings with the staged pair via `updatedInput',
so the human's bytes land whatever the agent proposed: a courier that
cannot tamper.  Live state, not persisted, and consumed on use.")
(defvar-local sprig--control-counter 0
  "Monotonic counter for control-request ids on this buffer's session.")
(defvar-local sprig--sink #'ignore
  "Function applied to each transport event in this session-owning buffer.
A review buffer that owns its session sets this to `sprig--review-sink' to
fold the events into its model.  The default is a no-op, and its identity
also marks a buffer as a session owner (see `sprig--owning-review-buffers'),
so it must stay non-`sprig--review-sink' for a buffer that owns nothing.")
(defvar-local sprig--connect-fn #'sprig-review-connect
  "Command that (re)starts this buffer's session, called with a NO-PROMPT arg.
Lets the transport reconnect a stale session without knowing the owner.")
(defvar-local sprig--working-dir nil
  "Working directory for a session not backed by a Markdown file.
A review buffer owns its session directly and has no frontmatter, so it
records the session's directory here for `sprig--directory'.")
(defvar-local sprig--remote-override 'inherit
  "Per-session SSH-destination override for this buffer's session.
The symbol `inherit' (the default) follows the primary remote (the first
of `sprig-remotes'); any other value overrides it for this buffer alone,
including nil for a session forced to run locally while a remote is
configured.  The transport reads it through `sprig--remote'.  The
navigator scans every host it lists (see `sprig--status-hosts') and pins
each row's buffer to the host its log came from.")

(defun sprig--primary-remote ()
  "The primary remote, or nil for local.
The first of `sprig-remotes', which is the host a session inherits when
it is not pinned to one of its own."
  (car sprig-remotes))

(defun sprig--remote ()
  "Effective SSH destination for this buffer's session, or nil for local.
Returns the buffer-local `sprig--remote-override' unless it is `inherit',
in which case it falls back to the primary remote (see
`sprig--primary-remote').  Transport paths that run in a session-owning
buffer call this instead of reading the global directly, so a session can
run local or remote independent of the configured default."
  (if (eq sprig--remote-override 'inherit)
      (sprig--primary-remote)
    sprig--remote-override))

(defun sprig--buffer-remote (buffer)
  "Effective SSH destination for BUFFER's session, or nil for local.
`sprig--remote' read from outside the buffer, for the navigator, which
groups rows by the host their session runs on."
  (let ((override (buffer-local-value 'sprig--remote-override buffer)))
    (if (eq override 'inherit) (sprig--primary-remote) override)))

(defun sprig--remote-override-value (host)
  "Return the `sprig--remote-override' HOST asks a new session to take.
A string is an SSH destination to pin the session to; any other non-nil
value pins it to the local machine; nil follows the primary remote as it
stands."
  (cond ((stringp host) host)
        (host nil)
        (t 'inherit)))

;;;; Command construction

(defun sprig--base-args ()
  "The `claude' argument list (without program / ssh wrapping)."
  (append
   (list "-p"
         "--input-format" "stream-json"
         "--output-format" "stream-json"
         "--include-partial-messages"
         "--verbose"
         ;; Route the CLI's interactive control requests (permission
         ;; prompts, tool-driven dialogs) to us over stdio, rather than
         ;; letting them auto-deny in headless mode.  This is also what
         ;; makes the CLI enable AskUserQuestion, alongside the
         ;; `initialize' handshake's `supportedDialogKinds' (see
         ;; `sprig--send-initialize').
         "--permission-prompt-tool" "stdio")
   (when sprig-model (list "--model" sprig-model))
   (when sprig-system-prompt
     (list "--append-system-prompt" sprig-system-prompt))
   (when sprig--session-id
     (append (list "--resume" sprig--session-id)
             ;; Fork the resumed session rather than write on into it, so
             ;; the parent conversation is left exactly as it was.
             (when sprig--fork-session (list "--fork-session"))))
   sprig-extra-args))

(defun sprig--remote-dir-arg (dir)
  "Return DIR shell-quoted for a remote `cd', keeping a leading `~' live.
`shell-quote-argument' would escape a leading tilde and defeat the remote
shell's home expansion, so quote only the part after any `~' prefix."
  (if (string-match "\\`\\(~[^/]*\\)\\(.*\\)\\'" dir)
      (let ((rest (match-string 2 dir)))
        (concat (match-string 1 dir)
                (if (string-empty-p rest) "" (shell-quote-argument rest))))
    (shell-quote-argument dir)))

(defun sprig--wrap-command (args dir remote-host)
  "Wrap ARGS (a `claude' argv, program first) for a local or REMOTE-HOST run.
Locally ARGS is returned as is; the working directory is set by the caller
binding `default-directory'.  For a remote host the argv is shell-quoted and
prefixed with an optional `env CLAUDE_CONFIG_DIR=' and a `cd DIR && exec',
then handed to SSH.  Shared by the session command and the side-question
one-shot, so both reach a remote box the same way."
  (if remote-host
      (let ((remote (mapconcat #'shell-quote-argument args " ")))
        (when sprig-config-directory
          (setq remote (concat "env CLAUDE_CONFIG_DIR="
                               (sprig--remote-dir-arg sprig-config-directory)
                               " " remote)))
        (when dir
          (setq remote (concat "cd " (sprig--remote-dir-arg dir)
                               " && exec " remote)))
        (append (list sprig-ssh-program)
                sprig-ssh-args
                (list remote-host remote)))
    args))

(defun sprig--broker-remote-p ()
  "Non-nil when `sprig-use-broker' brokers remote sessions (any non-nil value)."
  (and sprig-use-broker t))

(defun sprig--broker-local-p ()
  "Non-nil when `sprig-use-broker' brokers local sessions too (the `all' value)."
  (eq sprig-use-broker 'all))

(defun sprig--command ()
  "Full command vector for `make-process', local or via SSH.
A local session's working directory is set by `sprig--spawn' binding
`default-directory'; a remote session's is set here by prefixing a `cd'.
With `sprig-use-broker' a remote session instead runs through the broker
\(`sprig--broker-command'), so it survives a dropped link; with the `all'
value a local session runs through a local broker too (`sprig--broker-command-
local'), so it survives Emacs itself exiting."
  (let ((remote (sprig--remote)))
    (cond
     ((and remote (sprig--broker-remote-p))
      (sprig--broker-command remote))
     ((and (not remote) (sprig--broker-local-p))
      (sprig--broker-command-local))
     (t
      (sprig--wrap-command (cons sprig-program (sprig--base-args))
                           (sprig--directory)
                           remote)))))

(defvar sprig--broker-attach-only nil
  "When non-nil, a brokered `open' is attach-only: no spawn, no daemon start.
Dynamically bound around the navigator's auto-reattach (`sprig--reattach-
session'), so a stale `<id>.sprig-live' marker left by a crashed daemon
fails to attach rather than resurrecting a dead session.  It also tells
`sprig--spawn' to flag the process `:reattach-probe', so the sentinel keeps
that fast-failing exit quiet.")

(defun sprig--broker-command (host)
  "Command vector running a brokered remote session on HOST.
In place of `exec claude', the session is `python3 BROKER open ...'.  The
broker attaches to the live session named by `sprig--session-id' when it
still holds it, and otherwise spawns a fresh `claude' (resuming from the
JSONL when an id is set).  A fork names no session, so it spawns rather
than attaching to its still-live parent, keeping the parent untouched.
With `sprig--broker-attach-only' the `open' is attach-only, for reattach.
Config dir rides `--env' (the broker sets it on the child), the working
dir rides `--cwd', and the `claude' argv follows a `--'."
  (let* ((dir (sprig--directory))
         (session (and sprig--session-id (not sprig--fork-session)
                       sprig--session-id))
         (tokens
          (append
           (list "python3" (sprig--remote-dir-arg sprig-broker-remote-path)
                 "open" "--program" (shell-quote-argument sprig-program))
           (when sprig--broker-attach-only (list "--attach-only" "--no-start"))
           (when dir (list "--cwd" (sprig--remote-dir-arg dir)))
           (when session (list "--session" (shell-quote-argument session)))
           (when sprig-config-directory
             (list "--env"
                   (concat "CLAUDE_CONFIG_DIR="
                           (sprig--remote-dir-arg sprig-config-directory))))
           (list "--")
           (mapcar #'shell-quote-argument (sprig--base-args)))))
    (append (list sprig-ssh-program) sprig-ssh-args
            (list host (mapconcat #'identity tokens " ")))))

(defun sprig--broker-local-path ()
  "Local filesystem path the broker script is installed at.
`sprig-broker-remote-path' names the install path on any host; run here it
is a local path, so its leading `~' is expanded."
  (expand-file-name sprig-broker-remote-path))

(defun sprig--broker-local-runtime-dir ()
  "Runtime dir the local broker's control socket lives under.
The broker keys its socket path off `XDG_RUNTIME_DIR' (see the broker's
`runtime_dir'), but that variable is not always in Emacs's environment: a
GUI or systemd-launched Emacs can lack it, and then a daemon started once
with it set is unreachable from a later reattach without it, which reads as
`no broker running'.  Compute it here the same way every launch, so the two
always agree: the variable when set, else the standard per-user runtime dir
`/run/user/UID' when it exists, else a private `/tmp' dir."
  (or (getenv "XDG_RUNTIME_DIR")
      (let ((std (format "/run/user/%d" (user-uid))))
        (and (file-directory-p std) std))
      (format "/tmp/sprig-broker-%d" (user-uid))))

(defun sprig--broker-command-local ()
  "Command vector running a brokered LOCAL session, no SSH.
Like `sprig--broker-command' but `python3 BROKER open ...' runs as a direct
child of Emacs and its argv is passed to `make-process' unquoted (no shell).
The broker daemon it reaches is detached (`start_new_session'), so the
session outlives this Emacs: a later `sprig-status' reattaches to it.  The
working dir rides `--cwd', the config dir `--env' (the broker sets it on the
child), and the `claude' argv follows a `--'."
  (let* ((dir (sprig--directory))
         (session (and sprig--session-id (not sprig--fork-session)
                       sprig--session-id)))
    (append
     (list "python3" (sprig--broker-local-path)
           "open" "--program" sprig-program)
     (when sprig--broker-attach-only (list "--attach-only" "--no-start"))
     (when dir (list "--cwd" (expand-file-name dir)))
     (when session (list "--session" session))
     (when sprig-config-directory
       (list "--env" (concat "CLAUDE_CONFIG_DIR="
                             (expand-file-name sprig-config-directory))))
     (list "--")
     (sprig--base-args))))

(defconst sprig--broker-not-held-re
  "no broker running (session not held)\\|session not held by broker"
  "Broker stderr that proves it does not hold the probed session.
The first is the client failing fast with no daemon listening (a reboot
took the daemon and its sessions); the second is a live daemon answering
that the session is gone.  Either way the session's `.sprig-live' marker
is stale.  A transport failure (ssh dying) prints neither and proves
nothing, so it must not match.")

(defun sprig--remove-live-marker (id host)
  "Delete session ID's stale `.sprig-live' marker on HOST, best-effort.
nil HOST is the local machine.  The broker removes the marker when a
session ends, but a daemon that dies without cleanup (the machine
restarted) leaves it behind, and nothing else ever removes it: the
navigator would keep showing the session as held, a ghost row.  Called
when a reattach probe has proven the marker stale (see
`sprig--broker-not-held-re').  A remote marker is removed with one
fire-and-forget ssh, so the caller (a process sentinel) never blocks."
  (let ((name (concat id ".sprig-live")))
    (if host
        (ignore-errors
          (apply #'start-process "sprig-marker-rm" nil sprig-ssh-program
                 (append sprig-ssh-args
                         (list host
                               (concat "sh -c "
                                       (shell-quote-argument
                                        (format "find %s -name %s -delete 2>/dev/null; :"
                                                (sprig--remote-dir-arg
                                                 (directory-file-name
                                                  (sprig--projects-directory)))
                                                (shell-quote-argument name))))))))
      (let ((root (expand-file-name (sprig--projects-directory))))
        (when (file-directory-p root)
          (dolist (f (directory-files-recursively
                      root (concat "\\`" (regexp-quote id)
                                   "\\.sprig-live\\'")))
            (ignore-errors (delete-file f))))))))

(defun sprig--broker-stop-session (id host)
  "Ask HOST's broker to stop held session ID; return non-nil when it did.
nil HOST stops on the local machine.  The broker closes the child's stdin,
so `claude' exits cleanly and the session is dropped (and its live marker
removed); the JSONL survives, so the session resumes fresh on the next
open.  Best-effort and fail-fast: the broker's `stop' connects without
autostart, so a broker that is not running is never started just to be
told there is nothing to stop."
  (ignore-errors
    (if host
        (progn
          (sprig--remote-sh
           (format "python3 %s stop %s"
                   (sprig--remote-dir-arg sprig-broker-remote-path)
                   (shell-quote-argument id))
           host)
          t)
      ;; Pin XDG_RUNTIME_DIR the same way the local spawn does, so the stop
      ;; reaches the same socket the daemon was started with.
      (let ((process-environment
             (cons (concat "XDG_RUNTIME_DIR=" (sprig--broker-local-runtime-dir))
                   process-environment)))
        (eq 0 (call-process "python3" nil nil nil
                            (sprig--broker-local-path) "stop" id))))))

(defun sprig--broker-local-version ()
  "Version the installed local broker reports, or nil if absent or unrunnable."
  (with-temp-buffer
    (when (ignore-errors
            (eq 0 (call-process "python3" nil '(t nil) nil
                                (sprig--broker-local-path) "version")))
      (let ((v (string-trim (buffer-string))))
        (unless (string-empty-p v) v)))))

(defun sprig--ensure-broker-local ()
  "Make sure the local broker script is installed and current, shipping it if not.
The local counterpart of `sprig--ensure-broker': it compares the installed
copy's reported version against `sprig-broker-version' and (re)writes the
embedded source when they differ or it is missing."
  (unless (equal (sprig--broker-local-version) sprig-broker-version)
    (sprig--install-broker-local)))

(defun sprig--install-broker-local ()
  "Write the broker source (`sprig--broker-source') to `sprig--broker-local-path'.
Creates the parent directory and marks the script executable, so the local
`open' command can run it under `python3'."
  (let* ((path (sprig--broker-local-path))
         (dir (file-name-directory path)))
    (make-directory dir t)
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file path
        (insert (sprig--broker-source))))
    (set-file-modes path #o755)))

;; Defined by the generated block below (broker-source-begin); declared here so
;; the compiler sees it as special when this function is compiled first.
(defvar sprig--broker-source-text)

(defun sprig--broker-source ()
  "Broker script bytes to ship to a host.
`sprig-broker-program' names a file to read when set; otherwise the copy
embedded in `sprig--broker-source-text', so install needs no file laid out
beside the loaded library."
  (if sprig-broker-program
      (with-temp-buffer
        (insert-file-contents-literally sprig-broker-program)
        (buffer-string))
    sprig--broker-source-text))

(defun sprig--broker-install-command ()
  "Shell command installing the broker at `sprig-broker-remote-path'.
Reads the script from stdin (the SSH channel), writes it atomically, and
marks it executable.  Paths keep a leading `~' live for the remote shell."
  (let ((path (sprig--remote-dir-arg sprig-broker-remote-path))
        (dir (sprig--remote-dir-arg
              (directory-file-name
               (file-name-directory sprig-broker-remote-path)))))
    (format "mkdir -p %s && cat > %s.tmp && chmod +x %s.tmp && mv %s.tmp %s"
            dir path path path path)))

(defun sprig--ensure-broker (host)
  "Make sure HOST has the current broker installed, shipping it if not.
Compares the installed broker's reported version against
`sprig-broker-version' and reships when they differ or it is missing.  A
no-op once a host is current."
  (let* ((sprig-remotes (list host))
         (have (ignore-errors
                 (string-trim
                  (sprig--remote-sh
                   (format "python3 %s version 2>/dev/null"
                           (sprig--remote-dir-arg sprig-broker-remote-path)))))))
    (unless (equal have sprig-broker-version)
      (sprig--install-broker host))))

(defun sprig--install-broker (host)
  "Ship the broker script to HOST at `sprig-broker-remote-path'.
The source rides SSH's stdin (`sprig--broker-source'), so no file need sit
beside the loaded library for the install to find."
  (let ((status (apply #'call-process-region
                       (sprig--broker-source) nil
                       sprig-ssh-program nil nil nil
                       (append sprig-ssh-args
                               (list host (sprig--broker-install-command))))))
    (unless (eq status 0)
      (error "sprig: broker install on %s failed (status %s)" host status))))

;;;; broker-source-begin (generated by broker/embed.py; do not edit by hand)
(defconst sprig--broker-source-text
"#!/usr/bin/env python3
\"\"\"sprig-broker: keep `claude` sessions alive across client disconnects.

Stage 1 of the session broker (see DESIGN.md, \"Detach and reattach\").  One
daemon per user holds each session's stdin open (the holder, so a client
coming and going never EOFs claude), spools its stdout to a file, and fans
that stream out to attached clients.  A client attaches over a Unix socket
and gets a replay of the spool from a byte offset, then the live tail, plus a
path back to the child's stdin.  Detaching a client leaves the session
running; a fresh client reattaches and drives the next turn on the same
process.

Subcommands:
  daemon                 run the broker (usually auto-started on first use)
  spawn [--cwd D] [-- ARG...]   start a session, print its key
  attach KEY [--offset N]       bridge this process's stdio to the session
  list                   print sessions as JSON
  stop KEY               close the session's stdin (claude exits) and drop it

`attach` is the load-bearing verb: its stdout is the raw claude stream-json
and its stdin is the turn input, so a caller (a shell, or Emacs over ssh)
drives it exactly as it would a direct `claude` process.
\"\"\"

import argparse
import glob
import json
import os
import re
import selectors
import shutil
import socket
import subprocess
import sys
import threading
import time

# Bumped when the wire protocol or install path changes, so Sprig can tell a
# stale remote copy from a current one and reinstall.  Mirrored in sprig.el as
# `sprig-broker-version'.
VERSION = \"7\"


# --- paths -----------------------------------------------------------------

def runtime_dir():
    base = os.environ.get(\"XDG_RUNTIME_DIR\") or f\"/tmp/sprig-broker-{os.getuid()}\"
    d = os.path.join(base, \"sprig-broker\")
    os.makedirs(os.path.join(d, \"spool\"), exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    return d


def sock_path():
    return os.path.join(runtime_dir(), \"control.sock\")


def spool_path(key):
    return os.path.join(runtime_dir(), \"spool\", key + \".spool\")


def err_path(key):
    return os.path.join(runtime_dir(), \"spool\", key + \".err\")


# --- small wire helpers ----------------------------------------------------

def send_json(conn, obj):
    conn.sendall((json.dumps(obj) + \"\\n\").encode())


def recv_line(conn):
    \"\"\"Read one newline-terminated request; return (line_bytes, rest_bytes).

    Any bytes past the newline belong to whatever follows the request (an
    attach's stdin stream), so they are handed back rather than dropped.\"\"\"
    buf = b\"\"
    while b\"\\n\" not in buf:
        chunk = conn.recv(4096)
        if not chunk:
            return buf, b\"\"
        buf += chunk
    line, _, rest = buf.partition(b\"\\n\")
    return line, rest


def write_all(fd, data):
    while data:
        n = os.write(fd, data)
        data = data[n:]


def extract_session_id(buf):
    for line in buf.split(b\"\\n\"):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        sid = obj.get(\"session_id\")
        if sid:
            return sid
    return None


def resume_id_from_args(args):
    \"\"\"The id a `--resume ID' argv resumes, or None.  A `--fork-session' run
    resumes a parent only to branch off a fresh id, so it is not a resume for
    marker purposes and returns None.\"\"\"
    if \"--fork-session\" in args:
        return None
    for i, a in enumerate(args):
        if a == \"--resume\" and i + 1 < len(args):
            return args[i + 1]
    return None


_REQUEST_ID_RE = re.compile(rb'\"request_id\"\\s*:\\s*\"([^\"]+)\"')


def request_id_of(line):
    \"\"\"The `request_id' a stream-json control line names, or None.  A request
    carries it at top level; a response nests it inside `response', but the
    same field name serves both, so one search finds either.\"\"\"
    m = _REQUEST_ID_RE.search(line)
    return m.group(1) if m else None


# --- session ---------------------------------------------------------------

class Session:
    def __init__(self, key, proc, cwd, args, config_dir):
        self.key = key
        self.proc = proc
        self.cwd = cwd
        self.args = args
        self.config_dir = config_dir
        self.spool = spool_path(key)
        self.spool_fd = open(self.spool, \"ab\", buffering=0)
        self.lock = threading.Lock()        # guards spool append + subscribers
        self.stdin_lock = threading.Lock()
        self.subscribers = set()            # attached client sockets
        self.cli_session_id = None
        self.marker = None                  # <id>.sprig-live path once written
        self.ended = False
        self.created = time.time()
        # A control_request the child emits (a permission prompt, an
        # AskUserQuestion) blocks the child until a client answers it.  If the
        # client detaches first, the request sits in the spool unanswered; a
        # plain live-tail reattach would skip past it and the session would
        # hang.  Track each still-pending request's spool offset (keyed by id,
        # cleared when a client's control_response answers it) so a reattach
        # can rewind to it.  Requests cluster at the tail, since a blocked
        # child emits nothing after, so rewinding replays only the prompts.
        self.pending = {}                   # request_id -> spool byte offset
        self._out_buf = b\"\"                 # partial stdout line, for scanning
        self._out_pos = 0                   # spool offset of `_out_buf' start
        self._in_buf = b\"\"                  # partial stdin line, for scanning

    def find_log(self):
        \"\"\"The CLI's JSONL log for this session, found by id, or None.
        Searching by id sidesteps reproducing the CLI's cwd-mangling rule.\"\"\"
        if not self.cli_session_id:
            return None
        hits = glob.glob(os.path.join(
            self.config_dir, \"projects\", \"*\", self.cli_session_id + \".jsonl\"))
        return hits[0] if hits else None

    def write_marker(self):
        \"\"\"Touch <id>.sprig-live beside the log, so the navigator's own scan
        sees the session is broker-held without a separate query.  Content is
        the broker socket path.  Retries briefly: the log may not exist the
        instant the session id first appears in the stream.\"\"\"
        for _ in range(20):
            if self.ended:
                return
            log = self.find_log()
            if log:
                marker = os.path.splitext(log)[0] + \".sprig-live\"
                try:
                    with open(marker, \"w\") as f:
                        f.write(sock_path() + \"\\n\")
                    self.marker = marker
                except OSError:
                    pass
                return
            time.sleep(0.1)

    def remove_marker(self):
        if self.marker:
            try:
                os.remove(self.marker)
            except OSError:
                pass
            self.marker = None

    def read_loop(self):
        \"\"\"Pump child stdout to the spool and every attached client.\"\"\"
        fd = self.proc.stdout.fileno()
        sniff = b\"\"
        while True:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            with self.lock:
                self.spool_fd.write(chunk)
                for s in list(self.subscribers):
                    try:
                        s.sendall(chunk)
                    except OSError:
                        self.subscribers.discard(s)
            self._track_out(chunk)
            if self.cli_session_id is None:
                sniff += chunk
                sid = extract_session_id(sniff)
                if sid:
                    self.cli_session_id = sid
                    sniff = b\"\"
                    threading.Thread(target=self.write_marker, daemon=True).start()
                elif len(sniff) > 65536:
                    sniff = sniff[-4096:]
        self.ended = True
        self.remove_marker()
        with self.lock:
            for s in list(self.subscribers):
                try:
                    s.shutdown(socket.SHUT_WR)
                except OSError:
                    pass

    def feed(self, data):
        \"\"\"Write DATA to the child's stdin; return False if the pipe is gone.\"\"\"
        with self.stdin_lock:
            try:
                write_all(self.proc.stdin.fileno(), data)
            except (OSError, ValueError):
                return False
        self._track_in(data)
        return True

    def _track_out(self, chunk):
        \"\"\"Note any control_request the child emits, by spool offset, so a
        reattach can find prompts left unanswered.  Scans whole lines only;
        `_out_pos' stays at the start of the partial line still buffered.\"\"\"
        self._out_buf += chunk
        while True:
            nl = self._out_buf.find(b\"\\n\")
            if nl < 0:
                break
            line = self._out_buf[:nl]
            start = self._out_pos
            self._out_pos += nl + 1
            self._out_buf = self._out_buf[nl + 1:]
            if b'\"type\":\"control_request\"' in line:
                rid = request_id_of(line)
                if rid:
                    with self.lock:
                        self.pending[rid] = start

    def _track_in(self, data):
        \"\"\"Clear a pending request once a client's control_response answers it.
        A client's own control_request (an interrupt) is not a response, so it
        leaves `pending' alone.\"\"\"
        self._in_buf += data
        while True:
            nl = self._in_buf.find(b\"\\n\")
            if nl < 0:
                break
            line = self._in_buf[:nl]
            self._in_buf = self._in_buf[nl + 1:]
            if b'\"type\":\"control_response\"' in line:
                rid = request_id_of(line)
                if rid:
                    with self.lock:
                        self.pending.pop(rid, None)

    def reattach_offset(self):
        \"\"\"Where a reattaching client should resume: the oldest unanswered
        control_request, so its prompt is re-delivered, else the spool end.\"\"\"
        with self.lock:
            pend = min(self.pending.values()) if self.pending else None
        if pend is not None:
            return pend
        try:
            return os.path.getsize(self.spool)
        except OSError:
            return 0

    def close_stdin(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass


# --- broker ----------------------------------------------------------------

class Broker:
    def __init__(self):
        self.sessions = {}
        self.aliases = {}          # cli_session_id -> key
        self.lock = threading.Lock()
        self._counter = 0

    def new_key(self):
        with self.lock:
            self._counter += 1
            return f\"s{os.getpid()}-{self._counter}\"

    def add(self, sess):
        with self.lock:
            self.sessions[sess.key] = sess

    def drop(self, key):
        with self.lock:
            self.sessions.pop(key, None)

    def resolve(self, ident):
        \"\"\"Map a broker key or a captured CLI session id to a live key.\"\"\"
        if ident is None:
            return None
        with self.lock:
            if ident in self.sessions:
                return ident
            for k, s in self.sessions.items():
                if s.cli_session_id:
                    self.aliases[s.cli_session_id] = k
            key = self.aliases.get(ident)
            return key if key in self.sessions else None


def do_spawn(broker, req):
    cwd = req.get(\"cwd\") or None
    args = req.get(\"args\") or []
    program = req.get(\"program\", \"claude\")
    env = os.environ.copy()
    for kv in req.get(\"env\") or []:
        if \"=\" in kv:
            k, v = kv.split(\"=\", 1)
            # expanduser only touches a leading `~', so non-path values pass
            # through untouched; the config dir needs it to locate the log.
            env[k] = os.path.expanduser(v)
    config_dir = os.path.expanduser(env.get(\"CLAUDE_CONFIG_DIR\") or \"~/.claude\")
    # A missing working directory is the most likely spawn failure (a session
    # resumed against a host that lacks its recorded cwd); name it plainly
    # rather than leaking a raw errno to the review buffer.
    if cwd and not os.path.isdir(cwd):
        raise RuntimeError(f\"working directory not found on host: {cwd}\")
    key = broker.new_key()
    err = open(err_path(key), \"ab\", buffering=0)
    try:
        proc = subprocess.Popen(
            [program] + args,
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=err,
            bufsize=0,
            start_new_session=True,
            env=env,
        )
    except FileNotFoundError:
        raise RuntimeError(f\"cannot run {program!r}: not found on host PATH\")
    sess = Session(key, proc, cwd, args, config_dir)
    # A resume names its session id up front (`--resume ID' in the argv), so
    # seed it and mark the session held at once rather than waiting to scrape
    # the id back out of the stream: a resumed-but-idle session emits nothing
    # until its first turn, so the marker would otherwise not appear until then
    # and the navigator could not see the session was held.  A fork (`--fork-
    # session') gets a fresh id we do not know yet, so it is left to the stream.
    resume_id = resume_id_from_args(args)
    if resume_id:
        sess.cli_session_id = resume_id
        threading.Thread(target=sess.write_marker, daemon=True).start()
    broker.add(sess)
    threading.Thread(target=sess.read_loop, daemon=True).start()
    return {\"ok\": True, \"session\": key, \"spool\": sess.spool}


def do_list(broker):
    out = []
    with broker.lock:
        items = list(broker.sessions.items())
    for k, s in items:
        try:
            size = os.path.getsize(s.spool)
        except OSError:
            size = 0
        out.append({
            \"session\": k,
            \"cli_session_id\": s.cli_session_id,
            \"ended\": s.ended,
            \"spool_size\": size,
            \"cwd\": s.cwd,
            \"pid\": s.proc.pid,
        })
    return {\"ok\": True, \"sessions\": out}


def do_stop(broker, req):
    key = broker.resolve(req.get(\"session\"))
    if key is None:
        return {\"ok\": False, \"error\": \"no such session\"}
    sess = broker.sessions[key]
    sess.close_stdin()

    def reap():
        try:
            sess.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            sess.proc.terminate()
        broker.drop(key)

    threading.Thread(target=reap, daemon=True).start()
    return {\"ok\": True, \"session\": key}


def serve_attach(sess, conn, rest, offset):
    \"\"\"Replay SESS's spool from OFFSET, then bridge the live stream both ways.\"\"\"
    # Replay and subscribe to the live tail atomically against the reader, so
    # no byte is missed or doubled at the seam.
    with sess.lock:
        try:
            with open(sess.spool, \"rb\") as f:
                f.seek(offset)
                data = f.read()
            if data:
                conn.sendall(data)
        except OSError:
            pass
        if not sess.ended:
            sess.subscribers.add(conn)
    if sess.ended:
        try:
            conn.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        return
    # Anything the client sent past its request line is already stdin.
    if rest:
        sess.feed(rest)
    # Pump this client's stdin into the child until the client goes away.
    # Dropping the client never closes the child's stdin: the daemon holds it.
    try:
        while True:
            data = conn.recv(65536)
            if not data:
                break
            if not sess.feed(data):
                break
    except OSError:
        pass
    finally:
        with sess.lock:
            sess.subscribers.discard(conn)


def do_attach(broker, conn, rest, req):
    key = broker.resolve(req.get(\"session\"))
    if key is None:
        send_json(conn, {\"ok\": False, \"error\": \"no such session\"})
        return
    sess = broker.sessions[key]
    offset = int(req.get(\"offset\") or 0)
    send_json(conn, {
        \"ok\": True,
        \"session\": sess.key,
        \"cli_session_id\": sess.cli_session_id,
        \"ended\": sess.ended,
    })
    serve_attach(sess, conn, rest, offset)


def do_open(broker, conn, rest, req):
    \"\"\"Attach to a live session by id, or spawn a fresh one, then bridge.

    A caller that does not yet know a session (or whose session is gone) gets
    a spawn and a full replay from offset 0, so it sees the init line and the
    CLI session id.  A caller reattaching to a live session gets the live tail
    only (from the current spool end), since settled history is in the JSONL,
    except that an unanswered control_request rewinds the tail to itself so the
    prompt is re-delivered and the session does not hang (see reattach_offset).\"\"\"
    sid = req.get(\"session\")
    key = broker.resolve(sid) if sid else None
    if key is None:
        if req.get(\"attach_only\"):
            # Reattach path: never resurrect a session the broker no longer
            # holds (a stale marker), so opening the navigator cannot spawn.
            send_json(conn, {\"ok\": False, \"error\": \"session not held by broker\"})
            return
        resp = do_spawn(broker, req)
        sess = broker.sessions[resp[\"session\"]]
        offset = 0
        spawned = True
    else:
        sess = broker.sessions[key]
        offset = sess.reattach_offset()
        spawned = False
    send_json(conn, {
        \"ok\": True,
        \"session\": sess.key,
        \"cli_session_id\": sess.cli_session_id,
        \"ended\": sess.ended,
        \"spawned\": spawned,
    })
    serve_attach(sess, conn, rest, offset)


def handle(broker, conn):
    cmd = None
    try:
        line, rest = recv_line(conn)
        if not line:
            return
        req = json.loads(line)
        cmd = req.get(\"cmd\")
        if cmd == \"spawn\":
            send_json(conn, do_spawn(broker, req))
        elif cmd == \"list\":
            send_json(conn, do_list(broker))
        elif cmd == \"stop\":
            send_json(conn, do_stop(broker, req))
        elif cmd == \"ping\":
            send_json(conn, {\"ok\": True})
        elif cmd == \"attach\":
            do_attach(broker, conn, rest, req)
        elif cmd == \"open\":
            do_open(broker, conn, rest, req)
        else:
            send_json(conn, {\"ok\": False, \"error\": f\"unknown cmd {cmd!r}\"})
    except Exception as e:  # noqa: BLE001 - report, never crash the accept loop
        try:
            send_json(conn, {\"ok\": False, \"error\": str(e)})
        except OSError:
            pass
    finally:
        if cmd != \"attach\":
            conn.close()


# --- daemon lifecycle ------------------------------------------------------

def socket_is_live(path):
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.settimeout(1.0)
        c.connect(path)
        send_json(c, {\"cmd\": \"ping\"})
        line, _ = recv_line(c)
        c.close()
        return bool(line)
    except OSError:
        return False


def run_daemon():
    path = sock_path()
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        srv.bind(path)
    except OSError:
        if socket_is_live(path):
            return  # another daemon owns the socket
        try:
            os.unlink(path)
        except OSError:
            pass
        srv.bind(path)
    os.chmod(path, 0o600)
    srv.listen(64)
    broker = Broker()
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(broker, conn), daemon=True).start()


def _systemd_run_daemon(argv):
    \"\"\"Try to start the daemon as a transient `--user' unit; True if launched.

    A plain `setsid' fork (below) still lives in the SSH login's
    `session-N.scope' cgroup, which `systemd-logind' tears down on logout,
    killing the daemon with it wherever `KillUserProcesses=yes' (the systemd
    default).  A `systemd-run --user' unit runs under `user@UID.service'
    instead, which logout leaves alone as long as lingering is on
    (`loginctl enable-linger'); the socket then outlives the client that
    started it.  Best-effort: any failure falls through to the `setsid' path,
    so a host without systemd, without a user manager, or without linger is no
    worse off than before.\"\"\"
    # An escape hatch: the test suite (and anyone who wants the bare setsid
    # daemon) sets this so a run never touches the real user manager, e.g.
    # registering the fixed unit name outside the test's throwaway sandbox.
    if os.environ.get(\"SPRIG_BROKER_NO_SYSTEMD\"):
        return False
    run = shutil.which(\"systemd-run\")
    if not run or not os.environ.get(\"XDG_RUNTIME_DIR\"):
        return False
    # A fixed unit name makes a second start a harmless no-op (the unit is
    # already active) rather than a duplicate daemon racing for the socket.
    unit = f\"sprig-broker-{os.getuid()}\"
    # A `--user' unit inherits the user manager's environment, not the caller's,
    # so carry across the two that the daemon and its `claude' children need:
    # PATH (the manager's is minimal, and claude is often on a login-only path
    # such as ~/.local/bin, so without this the spawn fails \"not found on host
    # PATH\"), and XDG_RUNTIME_DIR (so the daemon's socket lands where the client
    # that started it looks for it).
    setenv = [f\"--setenv={var}={os.environ[var]}\"
              for var in (\"PATH\", \"XDG_RUNTIME_DIR\") if os.environ.get(var)]
    try:
        rc = subprocess.call(
            [run, \"--user\", \"--quiet\", \"--collect\",
             f\"--unit={unit}\", \"--property=Type=simple\"] + setenv + [\"--\"] + argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return False
    # rc 0 means the unit started; a nonzero rc when the unit is already
    # running (a benign \"unit already exists\") still leaves a daemon up, so
    # treat a live socket as success regardless.
    return rc == 0 or socket_is_live(sock_path())


def start_daemon():
    argv = [sys.executable, os.path.abspath(__file__), \"daemon\"]
    if _systemd_run_daemon(argv):
        return
    subprocess.Popen(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def connect(autostart=True):
    \"\"\"Connect to the daemon's socket.  With AUTOSTART, launch a daemon and
    wait for it; without, return None at once if none is listening (the
    reattach path wants to fail fast rather than start an empty daemon).\"\"\"
    path = sock_path()
    for attempt in range(60):
        try:
            c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            c.connect(path)
            return c
        except OSError:
            if not autostart:
                return None
            if attempt == 0:
                start_daemon()
            time.sleep(0.1)
    raise SystemExit(\"sprig-broker: could not reach or start the daemon\")


# --- client subcommands ----------------------------------------------------

def request(obj):
    c = connect()
    send_json(c, obj)
    line, _ = recv_line(c)
    c.close()
    return json.loads(line) if line else {}


def cmd_spawn(a):
    resp = request({\"cmd\": \"spawn\", \"cwd\": a.cwd, \"args\": a.args, \"program\": a.program})
    if not resp.get(\"ok\"):
        sys.stderr.write(f\"sprig-broker: {resp.get('error')}\\n\")
        return 1
    print(resp[\"session\"])
    return 0


def cmd_list(a):
    \"\"\"List held sessions.  With no daemon running nothing is held, so print
    an empty listing rather than starting a daemon just to ask it: a caller
    verifying live markers reads that as `none held', exactly right.\"\"\"
    c = connect(autostart=False)
    if c is None:
        print(json.dumps({\"ok\": True, \"sessions\": []}))
        return 0
    send_json(c, {\"cmd\": \"list\"})
    line, _ = recv_line(c)
    c.close()
    print(json.dumps(json.loads(line) if line else {}, indent=2))
    return 0


def cmd_stop(a):
    \"\"\"Stop a held session.  Connects without autostart: with no daemon there
    is nothing to stop, and starting an empty one just to learn that would
    leave it running.\"\"\"
    c = connect(autostart=False)
    if c is None:
        sys.stderr.write(\"sprig-broker: no broker running (nothing to stop)\\n\")
        return 1
    send_json(c, {\"cmd\": \"stop\", \"session\": a.session})
    line, _ = recv_line(c)
    c.close()
    resp = json.loads(line) if line else {}
    if not resp.get(\"ok\"):
        sys.stderr.write(f\"sprig-broker: {resp.get('error')}\\n\")
        return 1
    return 0


def bridge(conn, rest):
    \"\"\"Copy this process's stdin into CONN and CONN's stream to stdout.

    From the caller's side CONN behaves like a plain claude process: stdout is
    the raw stream-json, stdin is the turn input.  Closing our stdin (or being
    killed) detaches without touching the session.\"\"\"
    out = sys.stdout.buffer
    if rest:
        out.write(rest)
        out.flush()
    sel = selectors.DefaultSelector()
    sel.register(conn, selectors.EVENT_READ, \"sock\")
    sel.register(sys.stdin.buffer, selectors.EVENT_READ, \"stdin\")
    while True:
        for key, _ in sel.select():
            if key.data == \"sock\":
                data = conn.recv(65536)
                if not data:
                    return 0  # session ended or daemon closed
                out.write(data)
                out.flush()
            else:
                data = os.read(sys.stdin.fileno(), 65536)
                if not data:
                    try:
                        conn.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    return 0
                conn.sendall(data)


def cmd_attach(a):
    conn = connect()
    send_json(conn, {\"cmd\": \"attach\", \"session\": a.session, \"offset\": a.offset})
    line, rest = recv_line(conn)
    status = json.loads(line) if line else {}
    if not status.get(\"ok\"):
        sys.stderr.write(f\"sprig-broker: {status.get('error', 'attach failed')}\\n\")
        return 1
    return bridge(conn, rest)


def cmd_open(a):
    conn = connect(autostart=not a.no_start)
    if conn is None:
        sys.stderr.write(\"sprig-broker: no broker running (session not held)\\n\")
        return 1
    send_json(conn, {
        \"cmd\": \"open\",
        \"session\": a.session,
        \"cwd\": a.cwd,
        \"program\": a.program,
        \"env\": a.env,
        \"attach_only\": a.attach_only,
        \"args\": a.args[1:] if a.args and a.args[0] == \"--\" else a.args,
    })
    line, rest = recv_line(conn)
    status = json.loads(line) if line else {}
    if not status.get(\"ok\"):
        sys.stderr.write(f\"sprig-broker: {status.get('error', 'open failed')}\\n\")
        return 1
    return bridge(conn, rest)


def cmd_version(a):
    print(VERSION)
    return 0


def main():
    p = argparse.ArgumentParser(prog=\"sprig-broker\")
    sub = p.add_subparsers(dest=\"cmd\", required=True)

    sub.add_parser(\"daemon\")

    sp = sub.add_parser(\"spawn\")
    sp.add_argument(\"--cwd\", default=None)
    sp.add_argument(\"--program\", default=\"claude\")
    sp.add_argument(\"args\", nargs=argparse.REMAINDER)

    at = sub.add_parser(\"attach\")
    at.add_argument(\"session\")
    at.add_argument(\"--offset\", type=int, default=0)

    op = sub.add_parser(\"open\")
    op.add_argument(\"--session\", default=None)
    op.add_argument(\"--cwd\", default=None)
    op.add_argument(\"--program\", default=\"claude\")
    op.add_argument(\"--env\", action=\"append\", default=[])
    op.add_argument(\"--attach-only\", action=\"store_true\")
    op.add_argument(\"--no-start\", action=\"store_true\")
    op.add_argument(\"args\", nargs=argparse.REMAINDER)

    sub.add_parser(\"list\")
    sub.add_parser(\"version\")

    st = sub.add_parser(\"stop\")
    st.add_argument(\"session\")

    a = p.parse_args()
    if a.cmd == \"daemon\":
        run_daemon()
        return 0
    if a.cmd == \"spawn\":
        # Drop a leading \"--\" left by REMAINDER.
        if a.args and a.args[0] == \"--\":
            a.args = a.args[1:]
        return cmd_spawn(a)
    if a.cmd == \"attach\":
        return cmd_attach(a)
    if a.cmd == \"open\":
        return cmd_open(a)
    if a.cmd == \"list\":
        return cmd_list(a)
    if a.cmd == \"version\":
        return cmd_version(a)
    if a.cmd == \"stop\":
        return cmd_stop(a)
    return 2


if __name__ == \"__main__\":
    sys.exit(main())
"
  "Embedded copy of broker/sprig-broker, shipped to a host on first use.
Generated by broker/embed.py; the test
`sprig-test-broker-source-matches-file' guards that it matches the
script.  Regenerate with broker/embed.py after editing the broker.")
;;;; broker-source-end

;;;; Transport and sink
;;
;; The transport turns the backend's raw output lines into a small,
;; backend-neutral event vocabulary; a per-buffer `sprig--sink' applies
;; those events (a review buffer folds them into its model).  `sprig--handle'
;; is the seam.  Only the `sprig--claude-*' functions know the `claude' CLI's
;; stream-json wire format, so another backend means another parser emitting
;; the same events, with the sink untouched.
;;
;; An event is a list whose car is the tag:
;;   (session ID)              session id captured from the backend
;;   (text-block)              a new text block began; separate it
;;   (text STR)                assistant text to insert
;;   (tool-call ID NAME INPUT) a completed tool-use call (INPUT is JSON)
;;   (tool-result ID ERR TEXT) a tool result (ERR non-nil means error)
;;   (done COST ERR)           the turn finished
;;   (context TOKENS)          the turn's prompt size, i.e. context in use
;;   (compacting FLAG)         a compaction started (t) or ended (nil)
;;   (subagent ID PLIST)       a subagent's progress, ID being the `Agent'
;;                             tool call it runs under (see `sprig--claude-task')
;;   (subagent-call ID TID NAME INPUT)  a step the subagent under ID took
;;   (subagent-result ID TID ERR TEXT)  that step's result
;;   (mode MODE)               the session's permission mode (e.g. "plan")
;;   (control-request ID REQ)  the CLI asks us to answer a control request
;;   (control-response ID SUB) the CLI's receipt for a request we sent
;;   (error MESSAGE)           a backend error to surface inline

(defun sprig--filter (proc chunk)
  "Accumulate CHUNK from PROC and dispatch complete JSON lines."
  (let* ((acc (concat (or (process-get proc :acc) "") chunk))
         (lines (split-string acc "\n")))
    ;; Last element is the (possibly empty) incomplete tail.
    (process-put proc :acc (car (last lines)))
    (dolist (line (butlast lines))
      (setq line (string-trim line))
      (unless (string-empty-p line)
        ;; The first line a reattach emits means the attach landed (the broker
        ;; replied), so it is a live session now, not a probe: drop the quiet-
        ;; failure flags so a later genuine exit reports normally.
        (when (process-get proc :reattach-probe)
          (process-put proc :reattach-probe nil)
          (process-put proc :deliberate nil))
        (sprig--handle proc line)))))

(defun sprig--handle (proc line)
  "Parse one raw LINE from PROC and apply its events to the conversation.
The seam: the CLI parser produces backend-neutral events and the sink
dispatches each, both in the conversation buffer so per-stream transport
state (`sprig--blocks') stays local to it."
  (let ((buf (process-get proc :conv-buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (dolist (event (sprig--claude-parse-line line))
          (funcall sprig--sink event))))))

;;; claude CLI transport: raw stream-json lines -> events

(defun sprig--claude-tool-results (content)
  "Turn a CLI `user' message CONTENT list into `tool-result' events."
  (when (listp content)
    (delq nil
          (mapcar (lambda (block)
                    (when (consp block)
                      (let-alist block
                        (when (equal .type "tool_result")
                          (list 'tool-result
                                (or .tool_use_id "t")
                                .is_error
                                (string-trim
                                 (sprig--tool-result-text .content)))))))
                  content))))

(defun sprig--claude-subagent-steps (parent content)
  "Turn a subagent message CONTENT under PARENT into its step events.
PARENT is the `Agent' call the subagent runs under, so its steps hang off
the row already on screen rather than loose in the main agent's work.

A subagent's messages arrive whole, not as deltas, so unlike the main
agent's there is nothing to reassemble: one record, one step.  Its own
prose is dropped and only its tool calls kept; the reader wants to know
what it *did*, and what it concluded arrives as the `Agent' call's result."
  (when (listp content)
    (delq nil
          (mapcar (lambda (block)
                    (when (consp block)
                      (let-alist block
                        (cond
                         ((equal .type "tool_use")
                          (list 'subagent-call parent (or .id "t") .name
                                ;; Serialised to match the main agent's calls,
                                ;; whose input reaches the model as JSON text.
                                (if .input (json-serialize .input) "{}")))
                         ((equal .type "tool_result")
                          (list 'subagent-result parent (or .tool_use_id "t")
                                .is_error
                                (string-trim (sprig--tool-result-text .content))))))))
                  content))))

(defun sprig--claude-task (subtype ev)
  "Turn a `task_*' system record EV of SUBTYPE into a `subagent' event, or nil.
The CLI narrates a subagent over its own small protocol, keyed throughout by
`tool_use_id', which is the `Agent' call in the transcript, so the progress
lands on the row the reader is already looking at.

The three carry different things and all of them are wanted: `task_started'
names the agent and the job, `task_progress' says what it is doing right now
\(and is the only event that repeats, so it is what makes the row move), and
`task_notification' ends it with a status.  `task_updated' is skipped: it
patches status by `task_id' alone, carrying no `tool_use_id' to route by, and
says nothing `task_notification' has not already said.

Returns nil for a record with no `tool_use_id' rather than inventing a row
to hang it on."
  (let-alist ev
    (when .tool_use_id
      (list
       (list 'subagent .tool_use_id
             (pcase subtype
               ("task_started"
                (list :status "running" :agent-type .subagent_type
                      :description .description))
               ("task_progress"
                (list :status "running" :agent-type .subagent_type
                      :description .description
                      :last-tool .last_tool_name
                      :tokens .usage.total_tokens
                      :tool-uses .usage.tool_uses))
               ("task_notification"
                ;; The summary is deliberately dropped: the subagent's report
                ;; arrives again as this `Agent' call's tool result, which the
                ;; buffer already renders, so keeping it here would print the
                ;; same prose twice under one row.
                (list :status (or .status "completed")))))))))

(defun sprig--claude-parse-line (line)
  "Parse one stream-json LINE from the `claude' CLI into a list of events.
Returns the events in order (see the event vocabulary above), or nil.
Reassembling the CLI's fragmented tool-use input is transport state kept
in the buffer-local `sprig--blocks'; run this in the conversation buffer."
  (let ((ev (condition-case nil
                (json-parse-string line :object-type 'alist :array-type 'list
                                   :null-object nil :false-object nil)
              (error nil))))
    (when ev
      (let-alist ev
        (cond
         ;; Session init: report the id; the sink decides whether to keep it.
         ((and (equal .type "system") (equal .subtype "init"))
          (when .session_id (list (list 'session .session_id))))
         ;; A status message reports the current permission mode, e.g. after
         ;; a `set_permission_mode' control request switches to plan, and it
         ;; brackets a compaction: `compacting' when it starts, then a
         ;; `compact_result' when it lands.  A compaction takes a minute or
         ;; more, so say it is running rather than let the line read as an
         ;; ordinary wait.  A failed one is reported here and nowhere the
         ;; reader would see it: the CLI's own `result' still says success,
         ;; so without this the verb fails silently.
         ((and (equal .type "system") (equal .subtype "status"))
          (append
           (when .permissionMode (list (list 'mode .permissionMode)))
           (cond
            ((equal .status "compacting") (list (list 'compacting t)))
            (.compact_result
             (cons (list 'compacting nil)
                   (unless (equal .compact_result "success")
                     (list (list 'error
                                 (format "Compaction failed: %s"
                                         (or .compact_error .compact_result))))))))))
         ;; A subagent's progress, keyed by the `Agent' call it runs under.
         ;; This is the only word we get while one runs: its own messages
         ;; arrive as top-level `assistant' records (which carry no deltas,
         ;; so nothing streams), and its transcript is written to a file of
         ;; its own that the session log never mentions.  Without these the
         ;; `Agent' row would simply sit there for the minutes it takes.
         ((and (equal .type "system")
               (member .subtype '("task_started" "task_progress"
                                  "task_notification")))
          (sprig--claude-task .subtype ev))
         ;; A compaction landed: the boundary carries the post-compact token
         ;; count, the context now in use.  Report it so the readout drops
         ;; from the pre-compact size at once, not on the next turn.
         ;; The stream names these in snake_case; the session log spells the
         ;; same boundary in camelCase, which `sprig-review-session-record-events'
         ;; reads on replay.  Keep the two spellings with their own reader.
         ((and (equal .type "system") (equal .subtype "compact_boundary")
               .compact_metadata.post_tokens)
          (list (list 'context .compact_metadata.post_tokens)))
         ;; Streaming assistant content (text and tool-use blocks).
         ((equal .type "stream_event")
          (cond
           ;; The turn opens: its message carries the prompt's token usage,
           ;; which is the context-window size in use for this turn.
           ((equal .event.type "message_start")
            (when .event.message.usage
              (list (list 'context
                          (+ (or .event.message.usage.input_tokens 0)
                             (or .event.message.usage.cache_read_input_tokens 0)
                             (or .event.message.usage.cache_creation_input_tokens 0))))))
           ;; A new text block after earlier text (e.g. prose resuming after
           ;; a tool use): the sink separates them with a paragraph break.
           ((and (equal .event.type "content_block_start")
                 (equal .event.content_block.type "text"))
            (list (list 'text-block)))
           ;; A tool-use block opens: start accumulating its input JSON.
           ((and (equal .event.type "content_block_start")
                 (equal .event.content_block.type "tool_use"))
            (push (list .event.index
                        :id (or .event.content_block.id
                                (format "t%d" .event.index))
                        :name .event.content_block.name
                        :json "")
                  sprig--blocks)
            nil)
           ;; Text delta.
           ((and (equal .event.type "content_block_delta")
                 (equal .event.delta.type "text_delta")
                 .event.delta.text)
            (list (list 'text .event.delta.text)))
           ;; Tool-input delta: append to the block's accumulator.
           ((and (equal .event.type "content_block_delta")
                 (equal .event.delta.type "input_json_delta")
                 .event.delta.partial_json)
            (let ((blk (assq .event.index sprig--blocks)))
              (when blk
                (plist-put (cdr blk) :json
                           (concat (plist-get (cdr blk) :json)
                                   .event.delta.partial_json))))
            nil)
           ;; Block closes: emit the reassembled tool-use call.
           ((equal .event.type "content_block_stop")
            (let ((blk (assq .event.index sprig--blocks)))
              (when blk
                (setq sprig--blocks
                      (assq-delete-all .event.index sprig--blocks))
                (list (list 'tool-call
                            (plist-get (cdr blk) :id)
                            (plist-get (cdr blk) :name)
                            (plist-get (cdr blk) :json))))))))
         ;; Tool results come back as a `user' message.  Read `content' by
         ;; hand rather than via `.message.content': `let-alist' would bind
         ;; that eagerly for every line, and a `system'/`error' line whose
         ;; `message' is a plain string would crash the nested lookup.
         ;; A subagent's own work, tagged with the `Agent' call it runs under.
         ;; It must not fold into the main thread: its results would strand as
         ;; loose rows with no name (their calls arrive as top-level
         ;; `assistant' records, which carry no deltas and so were never read),
         ;; putting the subagent's `ls' output in the transcript as though the
         ;; main agent had run it.  Routed under its `Agent' row instead.
         ((and (member .type '("assistant" "user")) .parent_tool_use_id)
          (sprig--claude-subagent-steps
           .parent_tool_use_id (and (listp .message) (alist-get 'content .message))))
         ((equal .type "user")
          (sprig--claude-tool-results
           (and (listp .message) (alist-get 'content .message))))
         ;; The CLI asks us to answer an interactive control request: a
         ;; tool wants permission (`can_use_tool'), or a tool-driven
         ;; dialog needs rendering (`request_user_dialog').  Surface it
         ;; for the sink to answer via `sprig--answer-control-request'.
         ;; Re-read the request with JSON-faithful array/false/null objects,
         ;; so a value we echo back (AskUserQuestion's `questions') survives
         ;; the round trip: arrays as JSON arrays (the codebase-wide list
         ;; arrays would serialise as objects) and `false' as `false' (the
         ;; codebase-wide nil would serialise as `null' and fail the tool's
         ;; boolean schema).
         ((and (equal .type "control_request") .request_id (listp .request))
          (list (list 'control-request .request_id
                      (alist-get 'request
                                 (json-parse-string
                                  line :object-type 'alist :array-type 'array
                                  :null-object :null :false-object :false)))))
         ;; The CLI's receipt for a control request we sent (e.g. our
         ;; interrupt).  A `success' subtype confirms it landed; an `error'
         ;; means it was refused.  `request_id' rides inside `response', so
         ;; the sink can match it to the request it acks.
         ((equal .type "control_response")
          (list (list 'control-response
                      .response.request_id .response.subtype)))
         ;; Turn complete.
         ((equal .type "result")
          (list (list 'done .total_cost_usd .is_error)))
         ;; A non-streamed error surfaced as a result-less error.
         ((and (equal .type "system") (equal .subtype "error"))
          (list (list 'error (or .message line)))))))))

(defun sprig--tool-result-text (content)
  "Flatten a tool_result CONTENT field (string or block list) to text."
  (cond
   ((stringp content) content)
   ((listp content)
    (mapconcat (lambda (b)
                 (if (stringp b) b (let-alist b (or .text ""))))
               content ""))
   (t (format "%S" content))))

;;;; Process lifecycle: stderr, errors, sentinel

(defun sprig--debug (fmt &rest args)
  "Append a timestamped FMT/ARGS line to `*sprig-debug*' when `sprig-debug'.
A no-op when debugging is off, so callers can trace freely without cost."
  (when sprig-debug
    (with-current-buffer (get-buffer-create "*sprig-debug*")
      (goto-char (point-max))
      (insert (format-time-string "[%H:%M:%S] ")
              (apply #'format fmt args)
              "\n"))))

(defun sprig--make-stderr ()
  "Return a pipe process that accumulates the session's stderr.
Routing stderr here keeps its non-JSON diagnostics out of `sprig--filter',
which would otherwise silently drop them.  The text is read back from the
process property `:acc' when the main process exits (or `sprig-show-stderr'
mid-session), and mirrored live to `*sprig-debug*' when `sprig-debug'."
  (make-pipe-process
   :name "sprig-stderr"
   :buffer nil
   :noquery t
   :coding 'utf-8-unix
   :filter (lambda (proc chunk)
             (process-put proc :acc (concat (or (process-get proc :acc) "") chunk))
             (sprig--debug "stderr: %s" (string-trim-right chunk)))
   :sentinel #'ignore))

(defun sprig--log-error (conv-buffer header body)
  "Append a failure entry to `sprig-error-buffer' and display it.
HEADER names what failed; BODY is the captured stderr or detail text."
  (let ((buf (get-buffer-create sprig-error-buffer)))
    (with-current-buffer buf
      (unless (derived-mode-p 'special-mode) (special-mode))
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "=== %s: %s ===\n%s\n\n"
                        (buffer-name conv-buffer)
                        header
                        (if (and body (not (string-empty-p (string-trim body))))
                            (string-trim body)
                          "(no stderr output)")))))
    (display-buffer buf)))

(defun sprig-show-stderr ()
  "Show the live session's captured stderr in `sprig-error-buffer'.
The CLI's non-JSON diagnostics accumulate quietly until an abnormal exit;
among them are permission-handler complaints (a rejected or empty
`updatedInput' the courier sent, say), so surfacing them mid-session lets
a staged edit that failed to land be diagnosed without waiting for a
crash.  Call it from the review buffer whose session you are debugging."
  (interactive)
  (let ((stderr (and (process-live-p sprig--process)
                     (process-get sprig--process :stderr-proc))))
    (unless stderr (user-error "No live session in this buffer"))
    (sprig--log-error (current-buffer) "stderr so far"
                      (or (process-get stderr :acc) ""))))

(defconst sprig--session-not-found-re
  "No conversation found with session ID"
  "Substring the CLI prints when a `--resume' id does not exist on the host.
Session ids are per-host, so a file created on one machine (or the SSH
host) cannot resume locally.  Sprig treats this as a signal to start a
fresh session rather than fail.")

(defun sprig--sentinel (proc event)
  "Report PROC lifecycle EVENT, logging stderr on an abnormal exit."
  (let ((buf (process-get proc :conv-buffer))
        (stderr-proc (process-get proc :stderr-proc)))
    (when (memq (process-status proc) '(exit signal))
      ;; The stderr rides a separate pipe process, and this sentinel can run
      ;; before that pipe's final chunk reaches its filter: a decision read
      ;; off `:acc' now (the stale-resume detection, the stale live-marker
      ;; cleanup) would then see nothing and silently skip.  Drain any
      ;; pending output first, bounded, so `err' holds what was written.
      (when (process-live-p stderr-proc)
        (while (accept-process-output stderr-proc 0.05)))
      (let ((err (and stderr-proc (process-get stderr-proc :acc)))
            (status (process-exit-status proc))
            (deliberate (process-get proc :deliberate)))
        (when (process-live-p stderr-proc)
          (delete-process stderr-proc))
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (setq sprig--process nil
                  sprig--busy nil)
            ;; A floated steer was written to stdin; a hard exit emits no
            ;; `done' through the sink to land it, so commit it here rather
            ;; than leave it pinned forever.  A clean turn end already
            ;; committed it on its `done'.
            (sprig-review--commit-pending-steer)
            (sprig--drop-queue "the session ended")
            (sprig--clear-interrupt)
            (sprig--status-refresh)
            (cond
             ;; A clean, expected teardown: interrupt, disconnect, or exit 0.
             ;; A background reattach that never landed (an unreachable or
             ;; stale marker) is silent: it was best-effort and the user never
             ;; asked for it, so a message would only be noise.
             ((or deliberate (and (eq (process-status proc) 'exit)
                                  (zerop status)))
              (if (not (process-get proc :reattach-probe))
                  (message "sprig: session ended (%s)" (string-trim event))
                ;; The probe never streamed, so the reattach did not land.
                ;; When the broker itself answered that it does not hold the
                ;; session, the live marker is proven stale (a reboot took
                ;; the daemon, or it dropped the session) and nothing else
                ;; ever removes it, so the navigator would show the session
                ;; as held for good, a ghost.  Clean it up and re-render.  A
                ;; transport failure proves nothing and leaves it alone.
                (when (and err sprig--session-id
                           (string-match-p sprig--broker-not-held-re err))
                  (sprig--remove-live-marker sprig--session-id (sprig--remote))
                  (sprig--status-refresh))))
             ;; Stale/foreign resume id: the session does not exist on this
             ;; host.  Drop it and reconnect fresh so the user is not stuck;
             ;; the new session's id replaces the stale one on init.  Only
             ;; server-side memory of the prior turns is lost, and the review
             ;; buffer already shows the replayed history regardless.
             ((and err sprig--session-id
                   (string-match-p sprig--session-not-found-re err))
              (let ((stale sprig--session-id))
                (setq sprig--session-id nil)
                (message "sprig: session %s not found here; starting fresh (prior turns are not replayed)"
                         stale)
                (funcall sprig--connect-fn t)))
             ;; An unexpected exit: surface why in the error buffer.
             (t
              (sprig--log-error
               buf (format "session %s" (string-trim event)) err)
              (message "sprig: session failed (%s); see %s"
                       (string-trim event) sprig-error-buffer)))))))))

;;;; Session configuration

(defun sprig--directory ()
  "Return the working directory for this buffer's session, or nil.
The buffer-local `sprig--working-dir' overrides the `sprig-directory'
default.  The raw string is returned unexpanded, so a leading `~' or an
environment variable is resolved wherever the session runs."
  (let ((v (or sprig--working-dir sprig-directory)))
    (unless (or (null v) (string-empty-p (string-trim v)))
      (string-trim v))))

(defun sprig--sync-default-directory ()
  "Point this buffer's `default-directory' at its session's working dir.
So `C-x C-f' and friends from the buffer default to the session's own
directory rather than to wherever the buffer happened to be created.  A
remote session's dir lives on the SSH host, so it is named over TRAMP the
way visiting a changed file is; a dir-less session (the login dir) keeps
the inherited default."
  (when-let* ((dir (sprig--directory)))
    (let ((remote (sprig--remote)))
      (setq default-directory
            (file-name-as-directory
             (if remote
                 (format "/ssh:%s:%s" remote dir)
               (expand-file-name dir)))))))

;;;; Session lifecycle

(defun sprig--spawn ()
  "Start the CLI session process for the current buffer and bind it.
Reads the resume id from `sprig--session-id' (nil for a fresh session)
and the working directory from `sprig--directory', both already resolved
by the caller.  Sets and returns `sprig--process'.  Buffer-agnostic: the
Markdown transcript and a session-owning review buffer share it."
  ;; A brokered session needs the broker present first; ship it on first use,
  ;; then the command below attaches through it.  Remote sessions install over
  ;; SSH; a local brokered session (`all') installs here.
  (cond ((and (sprig--broker-remote-p) (sprig--remote))
         (sprig--ensure-broker (sprig--remote)))
        ((and (sprig--broker-local-p) (not (sprig--remote)))
         (sprig--ensure-broker-local)))
  (let* ((dir (sprig--directory))
         ;; Local sessions inherit `default-directory'; a configured dir
         ;; overrides it.  Remote sessions get their `cd' in `sprig--command'.
         (default-directory
          (if (and dir (not (sprig--remote)))
              (let ((expanded (file-name-as-directory (expand-file-name dir))))
                (unless (file-directory-p expanded)
                  (user-error "sprig: no such directory: %s" expanded))
                expanded)
            default-directory))
         ;; A local session's CLAUDE_CONFIG_DIR rides the process env (no
         ;; shell to expand `~', so expand it here); a remote one is set in
         ;; the `env' prefix of `sprig--command'.  A local brokered session
         ;; also pins XDG_RUNTIME_DIR, so the broker's socket lands in the same
         ;; place whether or not this Emacs happens to have the variable set;
         ;; otherwise a daemon started with it set is unreachable from a later
         ;; reattach without it (see `sprig--broker-local-runtime-dir').
         (process-environment
          (let ((env process-environment))
            (when (and sprig-config-directory (not (sprig--remote)))
              (setq env (cons (concat "CLAUDE_CONFIG_DIR="
                                      (expand-file-name sprig-config-directory))
                              env)))
            (when (and (sprig--broker-local-p) (not (sprig--remote)))
              (setq env (cons (concat "XDG_RUNTIME_DIR="
                                      (sprig--broker-local-runtime-dir))
                              env)))
            env))
         (stderr (sprig--make-stderr))
         (proc (make-process
                :name "sprig"
                :buffer nil
                :command (sprig--command)
                :connection-type 'pipe
                :coding 'utf-8-unix
                :noquery t
                :stderr stderr
                :filter #'sprig--filter
                :sentinel #'sprig--sentinel)))
    (process-put proc :conv-buffer (current-buffer))
    (process-put proc :stderr-proc stderr)
    (setq sprig--process proc)
    ;; An attach-only spawn is the navigator's best-effort reattach probe.  Flag
    ;; it here, at creation, not at the call site: a `--no-start' probe whose
    ;; daemon is gone exits nonzero almost at once, so a caller that flags the
    ;; process only after `sprig--ensure' returns can find it already dead and
    ;; miss the window, leaving the sentinel to log a spurious failure.  The
    ;; flag clears the instant the attach streams (`sprig--filter'), so a real
    ;; failure after a landed reattach still reports.
    (when sprig--broker-attach-only
      (process-put proc :deliberate t)
      (process-put proc :reattach-probe t))
    ;; Announce our capabilities before any user turn, so the CLI enables
    ;; the interactive tools it would otherwise withhold in headless mode.
    (sprig--send-initialize)
    proc))

(defun sprig--ensure ()
  "Ensure a live session, connecting if needed."
  (unless (process-live-p sprig--process)
    (funcall sprig--connect-fn)))

(defun sprig--teardown-process ()
  "Stop this buffer's session process deliberately and clear its state.
The `:deliberate' flag tells `sprig--sentinel' the exit was expected, so
it reports a clean teardown rather than logging a failure."
  (when (process-live-p sprig--process)
    (process-put sprig--process :deliberate t)
    (delete-process sprig--process))
  (sprig--drop-queue "the session was stopped")
  (sprig--clear-interrupt)
  (setq sprig--process nil sprig--busy nil))

(defun sprig--send-user (text)
  "Send TEXT to the session as a user message."
  (let ((json (json-serialize
               `(:type "user"
                 :message (:role "user"
                           :content [(:type "text" :text ,text)])))))
    (process-send-string sprig--process (concat json "\n"))))

(defun sprig--send-control (request)
  "Send a control_request carrying REQUEST (a plist) to the session.
The stream-json input channel accepts these beside user messages; a
`set_permission_mode' request is how a turn is put into plan mode.
Returns the request id, so a caller that cares about the CLI's ack (the
matching `control_response') can correlate it, as `sprig--interrupt-turn'
does with the interrupt receipt."
  (let* ((id (format "sprig-%d"
                     (setq sprig--control-counter (1+ sprig--control-counter))))
         (json (json-serialize
                (list :type "control_request"
                      :request_id id
                      :request request))))
    (process-send-string sprig--process (concat json "\n"))
    id))

(defun sprig--set-permission-mode (mode)
  "Ask the session to switch to permission MODE (e.g. \"plan\", \"auto\")."
  (sprig--send-control (list :subtype "set_permission_mode" :mode mode))
  (setq sprig--permission-mode mode))

(defun sprig--courier-take (file-path)
  "Pop the staged courier edit for FILE-PATH off `sprig--courier', or nil.
Matches on the basename, so the agent's absolute path lines up with a
repo-relative staged path; with a single edit pending it takes that one.
Consumes the entry, so each staged edit is couriered at most once."
  (when sprig--courier
    (let* ((base (and file-path (file-name-nondirectory file-path)))
           (hit (or (seq-find (lambda (e)
                                (equal base (file-name-nondirectory
                                             (plist-get e :file))))
                              sprig--courier)
                    (and (null (cdr sprig--courier)) (car sprig--courier)))))
      (when hit
        (setq sprig--courier (delq hit sprig--courier))
        hit))))

(defun sprig--courier-updated-input (input edit)
  "Return INPUT (a tool-input alist) with EDIT's staged strings substituted.
Keeps the agent's own `file_path' (already resolved to an absolute path)
and overrides only `old_string'/`new_string' with the human-authored pair,
so the couriered write carries exactly the staged bytes."
  (let ((out (copy-alist input)))
    (setf (alist-get 'old_string out) (plist-get edit :old))
    (setf (alist-get 'new_string out) (plist-get edit :new))
    out))

(defvar sprig--edit-tools '("Edit" "Write" "MultiEdit" "NotebookEdit")
  "Tool names that write a file, and so can carry a staged courier edit.
A `can_use_tool' for one of these is where `sprig--maybe-courier' steps in
to substitute the human's staged bytes.")

(defun sprig--maybe-courier (request-id tool-name input)
  "Courier a staged edit if TOOL-NAME/INPUT matches one, answering REQUEST-ID.
When a human staged an edit for this file (see `sprig--courier') and the
agent reaches for an edit tool, allow the call but replace the tool input's
strings with the staged pair via `updatedInput', so the human's bytes land
whatever the agent proposed: the courier that cannot tamper.  Returns
non-nil when it answered, nil to let normal permission handling take the
call.  Works in any permission mode, since an edit reaching `can_use_tool'
is all it needs; it rides the same channel Sprig already answers on."
  (if-let ((_ (member tool-name sprig--edit-tools))
           (edit (sprig--courier-take (alist-get 'file_path input))))
      (progn
        (sprig--debug
         "courier: firing %s for %s (old=%d new=%d bytes, req=%s)"
         tool-name (alist-get 'file_path input)
         (length (or (plist-get edit :old) ""))
         (length (or (plist-get edit :new) "")) request-id)
        (message "sprig: couriered your staged edit to %s"
                 (file-name-nondirectory (or (alist-get 'file_path input) "")))
        (sprig--send-control-response
         request-id
         (list :behavior "allow"
               :updatedInput (sprig--courier-updated-input input edit)))
        t)
    ;; A staged edit is pending but this edit did not match it: the human's
    ;; bytes are about to be lost to the agent's placeholder.  Warn always,
    ;; not just under `sprig-debug', since it is silent data loss otherwise.
    (when (and (member tool-name sprig--edit-tools) sprig--courier)
      (sprig--debug
       "courier: %s for %s reached the gate, nothing staged matched (%d pending)"
       tool-name (alist-get 'file_path input) (length sprig--courier))
      (message
       "sprig: staged edit NOT couriered: %s did not match the %d staged; \
check the path or re-stage"
       (file-name-nondirectory (or (alist-get 'file_path input) "?"))
       (length sprig--courier)))
    nil))

(defun sprig--send-interrupt ()
  "Ask the session to interrupt the turn in flight, returning the request id.
The CLI aborts the current turn and ends it with a `result', so the turn
closes through the normal `done' path and the process stays live: unlike
killing it, the next send needs no `--resume'.  The returned id matches
the CLI's `control_response' receipt (see `sprig--interrupt-turn')."
  (sprig--send-control (list :subtype "interrupt")))

(defun sprig--send-initialize ()
  "Announce sprig's client capabilities to the freshly spawned session.
Declaring `sprig-supported-dialog-kinds' is what makes the CLI enable the
interactive tools (AskUserQuestion, ExitPlanMode); without it they are
withheld in headless stream-json mode.  Sent once, before the first user
message, and harmless on a resumed session (the CLI just re-acks it)."
  (when sprig-supported-dialog-kinds
    (sprig--send-control
     (list :subtype "initialize"
           :supportedDialogKinds (vconcat sprig-supported-dialog-kinds)))))

(defun sprig--send-control-response (request-id response)
  "Answer the CLI's control_request REQUEST-ID with RESPONSE (a plist).
RESPONSE is the decision payload (e.g. (:behavior \"allow\")); it is
wrapped in the success envelope the CLI expects."
  (let ((json (json-serialize
               (list :type "control_response"
                     :response (list :subtype "success"
                                     :request_id request-id
                                     :response response)))))
    (sprig--debug "-> control_response %s: %s" request-id json)
    (process-send-string sprig--process (concat json "\n"))))

(defun sprig-permission-prompt (tool-name input)
  "Default `sprig-permission-function': ask in the minibuffer.
TOOL-NAME is the tool the CLI wants to run and INPUT its arguments alist."
  (let ((cmd (or (alist-get 'command input)
                 (alist-get 'file_path input)
                 (alist-get 'path input))))
    (y-or-n-p (format "sprig: allow %s%s? "
                      tool-name
                      (if cmd (format " (%s)"
                                      (truncate-string-to-width cmd 60 nil nil "…"))
                        "")))))

(defun sprig--answer-control-request (request-id req)
  "Answer the CLI control_request REQUEST-ID described by REQ (an alist).
AskUserQuestion is rendered for a choice and ExitPlanMode for plan
approval; other permission requests consult `sprig-permission-function';
anything unrecognised is cancelled so the turn keeps moving rather than
parking on a prompt sprig cannot render.  A quit (\\`C-g') at any prompt is
caught and answered safely (see `sprig--safe-quit-response'), so the
session never hangs on an unanswered request."
  (let-alist req
    (condition-case nil
        (cond
         ((and (equal .subtype "can_use_tool")
               (equal .tool_name "AskUserQuestion"))
          (sprig--offer-user-question request-id .input))
         ((and (equal .subtype "can_use_tool")
               (equal .tool_name "ExitPlanMode"))
          (sprig--offer-plan request-id .input))
         ;; A staged courier edit (see `sprig--courier') is applied here,
         ;; overriding the agent's bytes with the human's.  Before the generic
         ;; gate so the couriered write is not prompted; after the interactive
         ;; cases so a question or plan still renders.  A no-op otherwise.
         ((and (equal .subtype "can_use_tool")
               (sprig--maybe-courier request-id .tool_name .input)))
         ((equal .subtype "can_use_tool")
          (if sprig-permission-function
              (sprig--send-control-response
               request-id
               (if (funcall sprig-permission-function .tool_name .input)
                   ;; Omit `updatedInput': absent means "run the call
                   ;; unchanged", avoiding a lossy JSON round-trip of the input.
                   (list :behavior "allow")
                 (list :behavior "deny" :message "Denied in sprig")))
            (sprig--offer-permission request-id req)))
         (t (sprig--send-control-response request-id (list :behavior "cancelled"))))
      (quit (sprig--send-control-response
             request-id (sprig--safe-quit-response req))))))

(defun sprig--safe-quit-response (req)
  "The conservative control response when the user quits a prompt for REQ.
Never approves on a quit: a permission or plan approval denies, a question
allows with no answer (the tool's own skip), a dialog cancels."
  (let-alist req
    (cond
     ((equal .tool_name "AskUserQuestion") (list :behavior "allow"))
     ((equal .subtype "can_use_tool")
      (list :behavior "deny" :message "Cancelled in sprig"))
     (t (list :behavior "cancelled")))))

(defun sprig--offer-permission (request-id req)
  "Put the tool call REQ wants to make into the buffer, to be allowed there.
Nothing is sent back yet, for the reason in `sprig--offer-user-question':
a prompt from inside the process filter holds the filter, and Emacs with
it, so every other session's output would stall behind you deciding
whether one call may run.  The whole REQ rides along, not just its input,
the rendering wanting the tool's name too."
  (sprig-review-consume (list 'dialog request-id "can_use_tool" req)))

(defun sprig--review-allow-tool (id)
  "Allow the tool call of dialog ID, this once."
  ;; Omit `updatedInput': absent means "run the call unchanged".
  (sprig--send-control-response id (list :behavior "allow"))
  (sprig-review-consume (list 'dialog-answer id "allowed")))

(defun sprig--review-deny-tool (id)
  "Deny the tool call of dialog ID; the agent is told no and goes on."
  (sprig--send-control-response id (list :behavior "deny"
                                         :message "Denied in sprig"))
  (sprig-review-consume (list 'dialog-answer id "denied")))

(defun sprig--offer-plan (request-id input)
  "Put the ExitPlanMode plan in INPUT into the buffer, to be approved there.
Nothing is sent back yet, for the reasons in `sprig--offer-user-question',
and for one more: the plan was never on screen.  The prompt named its
first line and the buffer showed a bare `ExitPlanMode' row, the plan text
rendering nowhere, so approval was a yes to something unread.  As a dialog
it renders in full, and is approved once it has been."
  (sprig-review-consume (list 'dialog request-id "exit_plan_mode" input)))

(defun sprig--review-approve-plan (id)
  "Approve the plan of dialog ID: the agent leaves plan mode and starts work."
  (sprig--send-control-response id (list :behavior "allow"))
  (sprig-review-consume (list 'dialog-answer id "approved")))

(defun sprig--review-reject-plan (id feedback)
  "Reject the plan of dialog ID with FEEDBACK, which the agent re-plans against."
  (let ((message (if (string-empty-p feedback) "Plan rejected." feedback)))
    (sprig--send-control-response id (list :behavior "deny" :message message))
    (sprig-review-consume (list 'dialog-answer id (concat "rejected: " message)))))

(defun sprig--offer-user-question (request-id input)
  "Put the AskUserQuestion INPUT into the buffer, to be answered there.
Nothing is sent back yet.  This runs inside the process filter, so a
prompt here would block the filter, and with it every other session's
output and Emacs itself, for as long as the question went unanswered; and
the question deserves the buffer anyway, where the conversation it is
about already is.  So it is handed over as a `dialog' event and stands
pending until `sprig--review-answer-dialog' hears back (see
`sprig-review-dialog-send')."
  (sprig-review-consume (list 'dialog request-id "ask_user_question" input)))

(defun sprig--review-answer-dialog (id input answers)
  "Answer the pending dialog ID, whose tool INPUT gets ANSWERS.
ANSWERS is an alist of question text to the chosen label (multi-select
labels joined with commas, matching the CLI); nil waves the question
through, which the tool replays as its own \"skipped\" outcome.  The
answers ride back as `updatedInput', the input plus an `answers' map,
which is how the CLI feeds them to the tool."
  (sprig--send-control-response
   id
   (if answers
       (list :behavior "allow"
             :updatedInput (append input (list (cons 'answers answers))))
     (list :behavior "allow")))
  (sprig-review-consume (list 'dialog-answer id answers)))

(defun sprig--mode-line-permission ()
  "Mode-line tag for this session's permission mode, or nil when unknown.
Surfaces plan / acceptEdits / auto and friends so the active Claude mode
is visible without opening the header."
  (when sprig--permission-mode
    (propertize (format " [%s]" sprig--permission-mode)
                'help-echo "Claude permission mode")))

;;;; Review buffer
;;
;; A read-only, Magit-like view of the conversation (see DESIGN.md).  The
;; store is the CLI's own session log, so history is replayed from that
;; file, no sprig store.  It lives on the session host, so a remote
;; session's log is fetched over the same SSH the transport uses.  The
;; buffer is then attached (`sprig--review-buffer') so the in-flight turn
;; tees in live.

(declare-function sprig-review-buffer "sprig-review-mode" (name))
(declare-function sprig-review-seed "sprig-review-mode" (events &optional meta))
(declare-function sprig-review-consume "sprig-review-mode" (event))
(declare-function sprig-review-stage-steer "sprig-review-mode" (text))
(declare-function sprig-review--commit-pending-steer "sprig-review-mode" ())
(declare-function sprig-review-flush "sprig-review-mode" (&optional buffer))
(declare-function sprig-review--schedule "sprig-review-mode" ())
(declare-function sprig-review-set-remote "sprig-review-mode" (remote))
(declare-function sprig-review-session-events "sprig-review" (lines))
(declare-function sprig-review-interrupt "sprig-review-mode" ())
;; The review verbs the navigator's c / a dispatch runs on the row's session.
(declare-function sprig-review-message "sprig-review-mode" (&optional plan queue))
(declare-function sprig-review-queue "sprig-review-mode" ())
(declare-function sprig-review-drop-queue "sprig-review-mode" ())
(declare-function sprig-review-accept "sprig-review-mode" ())
(declare-function sprig-review-decline "sprig-review-mode" ())
(declare-function sprig-review-message-plan "sprig-review-mode" ())
(declare-function sprig-review-retry "sprig-review-mode" ())
(declare-function sprig-review-compact "sprig-review-mode" ())
(declare-function sprig-review-btw "sprig-review-mode" (question))
(declare-function sprig-review--fontify-markdown "sprig-review-mode" (text))
(declare-function sprig-review--completed-prose "sprig-review-mode" (text))
(declare-function sprig-review--paragraph-landed-p "sprig-review-mode" (delta))
(defvar sprig-review-defer-live-prose)
(defvar sprig-review--stream-nl)
(declare-function sprig-review-answer "sprig-review-mode" ())
(declare-function sprig-review-answer-recommended "sprig-review-mode" ())
(declare-function sprig-review-answer-skip "sprig-review-mode" ())
(declare-function sprig-review-plan-mode "sprig-review-mode" ())
(declare-function sprig-review-auto-mode "sprig-review-mode" ())
(declare-function sprig-review-accept-edits-mode "sprig-review-mode" ())
(declare-function sprig-review-manual-mode "sprig-review-mode" ())
(declare-function sprig-review-bypass-mode "sprig-review-mode" ())

(defun sprig--remote-sh (command &optional host)
  "Run shell COMMAND on HOST via SSH; return stdout.
HOST defaults to this buffer's session host (`sprig--remote'); pass it
explicitly from a buffer that does not own the session, such as the diff
buffer.  COMMAND is POSIX-sh syntax, so it is wrapped in `sh -c' rather
than left to the host's login shell: a non-POSIX login shell such as fish
rejects the scan's `for'-loop outright, which would silently strip every
session of its recorded cwd.  Signals if SSH exits non-zero."
  (with-temp-buffer
    (let ((status (apply #'call-process sprig-ssh-program nil t nil
                         (append sprig-ssh-args
                                 (list (or host (sprig--remote))
                                       (concat "sh -c "
                                               (shell-quote-argument command)))))))
      (unless (eq status 0)
        (error "sprig: remote command failed (%s): %s"
               status (string-trim (buffer-string))))
      (buffer-string))))

(defun sprig--session-log-file ()
  "Return the path of this buffer's session log, or nil when there is none.
Nil for a remote session as well: that log is read by shell over SSH (see
`sprig--session-log-lines') rather than opened by path, so there is no name
here for a caller to hang anything else off.  A caller that wants the files
*beside* the log, the subagent transcripts, needs this rather than the
lines, and gets nothing for a remote session, which is why a remote
`Agent' replays without its steps."
  (when (and sprig--session-id (not (sprig--remote)))
    (car (directory-files-recursively
          (expand-file-name (sprig--projects-directory))
          (concat "\\`" (regexp-quote sprig--session-id) "\\.jsonl\\'")))))

(defun sprig--session-log-lines ()
  "Return the stored session-log lines for this buffer's session.
Locates the log by session id under the session host's projects directory
\(local or over SSH), so the working-directory encoding never has to be
reproduced.  Signals a `user-error' when there is no id or no log."
  (let ((id (or sprig--session-id
                (user-error "sprig: no session id yet; connect first"))))
    (if (sprig--remote)
        (let* ((name (shell-quote-argument (concat id ".jsonl")))
               (path (string-trim
                      (sprig--remote-sh
                       (format "find %s -name %s -print -quit"
                               (sprig--remote-dir-arg (sprig--projects-directory))
                               name)))))
          (when (string-empty-p path)
            (user-error "sprig: no session log for %s on %s" id (sprig--remote)))
          (split-string (sprig--remote-sh
                         (format "cat %s" (shell-quote-argument path)))
                        "\n" t))
      (let ((file (car (directory-files-recursively
                        (expand-file-name (sprig--projects-directory))
                        (concat "\\`" (regexp-quote id) "\\.jsonl\\'")))))
        (unless file
          (user-error "sprig: no session log for %s" id))
        (with-temp-buffer
          (insert-file-contents file)
          (split-string (buffer-string) "\n" t))))))

(defun sprig--remote-log-command (id)
  "Shell command that prints the stored log for session ID, or nothing.
One SSH round trip does the whole fetch: `find' locates the log by id under
the projects dir, then `cat' streams it.  Nothing is printed when there is no
such log, so an empty result is `no log', not an error."
  (let ((root (sprig--remote-dir-arg (sprig--projects-directory)))
        (name (shell-quote-argument (concat id ".jsonl"))))
    (format "p=$(find %s -name %s -print -quit 2>/dev/null); \
[ -n \"$p\" ] && cat \"$p\"" root name)))

(defun sprig--session-log-lines-async (callback)
  "Fetch the current buffer's remote session-log lines in the background.
CALLBACK is called with the lines (a list, or nil for no log or a failed
fetch) back in the originating buffer once the SSH fetch lands, so opening or
re-reading a remote session never blocks Emacs on the round trip.  The buffer,
its session id, and its remote are captured now; CALLBACK is skipped if the
buffer has since died.  Remote only: a local caller reads the file directly."
  (let* ((buffer (current-buffer))
         (id sprig--session-id)
         (host (sprig--remote))
         (command (sprig--remote-log-command id))
         ;; Launch from a local directory so a remote `default-directory'
         ;; cannot send the `ssh' itself through TRAMP.
         (default-directory temporary-file-directory)
         (out (generate-new-buffer " *sprig-log-fetch*"))
         (proc (make-process
                :name "sprig-log-fetch" :buffer out :noquery t
                :connection-type 'pipe
                :command (append (list sprig-ssh-program) sprig-ssh-args
                                 (list host (concat "sh -c "
                                                    (shell-quote-argument
                                                     command)))))))
    (set-process-sentinel
     proc
     (lambda (p _event)
       (when (memq (process-status p) '(exit signal))
         (let ((lines (and (eq (process-exit-status p) 0)
                           (buffer-live-p (process-buffer p))
                           (split-string
                            (with-current-buffer (process-buffer p)
                              (buffer-string))
                            "\n" t))))
           (when (buffer-live-p (process-buffer p))
             (kill-buffer (process-buffer p)))
           (when (buffer-live-p buffer)
             (with-current-buffer buffer (funcall callback lines)))))))))

;; A review buffer owns its session outright: the transport routes events
;; to `sprig--review-sink' and its verbs steer the session directly (see
;; DESIGN.md, option A: CLI sessions are the branches).

(defun sprig--review-sink (event)
  "Sink for a review buffer that owns its session: track state, then consume.
Keeps the transport bookkeeping (session id, permission mode, busy flag)
in step without a Markdown transcript, then folds EVENT into the review
model via `sprig-review-consume'."
  (pcase event
    (`(session ,id)
     (when id
       (cond
        ;; A fork answers with the new session's own id, and it has to be
        ;; taken over the parent's: the parent id was only ever here to
        ;; resume from, and leaving it would make the next send fork the
        ;; parent again rather than carry the fork on.
        (sprig--fork-session
         (setq sprig--session-id id
               sprig--fork-session nil))
        ((not sprig--session-id)
         (setq sprig--session-id id)))))
    (`(mode ,m) (setq sprig--permission-mode m) (force-mode-line-update))
    (`(compacting ,flag) (setq sprig--compacting flag))
    (`(control-request ,id ,req) (sprig--answer-control-request id req))
    (`(control-response ,id ,subtype) (sprig--interrupt-receipt id subtype))
    ;; The turn ending clears the compaction too: an interrupted or failed
    ;; one need not report a result, and a flag left set would leave the
    ;; line claiming a compaction that stopped with the turn.
    (`(done ,_ ,_) (setq sprig--busy nil
                         sprig--compacting nil)
     (sprig--clear-interrupt)
     ;; The turn is over: render the final state at once, dropping any
     ;; coalesced mid-turn refresh still pending so it cannot fire a stale
     ;; render a beat later.
     (sprig--status-refresh-cancel)
     (sprig--status-refresh)))
  ;; A control-request/response is transport, not conversation: it carries no
  ;; renderable content (the model never reads either), so it is handled above
  ;; and not consumed.  Consuming it would matter beyond the wasted event: it
  ;; would push onto `sprig-review--events', so an attach's `initialize' ack
  ;; alone makes the buffer non-pristine and the background history fetch
  ;; (`sprig--review-session-buffer', which seeds settled history only while the
  ;; buffer is pristine) then skips, leaving a reattached session with no history.
  (unless (memq (car-safe event) '(control-request control-response))
    (sprig-review-consume event))
  ;; Keep the open navigator's live row current through the turn: its context
  ;; readout and status move with the events, not only at `done'.  Coalesced,
  ;; so a stream's burst of events makes one render, not one per event.
  (unless (eq (car-safe event) 'done)
    (sprig--status-refresh-soon))
  ;; The queue flushes after the `done' is consumed, never inside the pcase
  ;; above: the flush sends, and a send consumes a `user' event of its own,
  ;; which would then be folded in ahead of the `done' it was waiting for and
  ;; read as though it had been sent into the turn it queued behind.
  (when (eq (car-safe event) 'done)
    (sprig--flush-queue)))

;;;; Side questions ("by the way")
;;
;; A side question is a throwaway one-shot: `claude -p ... --resume ID
;; --fork-session --no-session-persistence'.  It forks the session so it sees
;; the whole conversation, but persistence is off, so it writes no log and
;; never touches the parent (the CLI's own `/btw', reproduced from outside the
;; interactive app).  It runs in its own process, so it neither opens a turn
;; nor waits on one: it streams its answer into `*sprig-btw*' while the real
;; session carries on untouched.  The one thing a `--resume' fork cannot see is
;; the turn still streaming (the log is not written until the turn ends), so
;; when one is in flight its live text is added to the question by the caller.

(defvar sprig--btw-process nil
  "The running side-question process, or nil.
One at a time, so a second `c b' does not interleave its answer with the
first in the shared `*sprig-btw*' buffer.")

(define-derived-mode sprig-btw-mode special-mode "sprig-btw"
  "Major mode for the `*sprig-btw*' side-question buffer."
  ;; Render the answer's markdown the way a review buffer does: its markup
  ;; carries `invisible markdown-markup' and its colours ride `font-lock-face'
  ;; (see `sprig-review--fontify-markdown').  special-mode runs no font-lock,
  ;; so hide the one here and alias the other into `face' by hand.
  (add-to-invisibility-spec 'markdown-markup)
  (setq-local char-property-alias-alist '((face font-lock-face)))
  (setq-local word-wrap t)
  (setq-local truncate-lines nil))

(defvar-local sprig--btw-answer-beg nil
  "Where the current answer's text begins in `*sprig-btw*'.
`sprig--btw-consume' fontifies the answer's markdown from here as it
streams; a fresh question resets it (`sprig--btw-display').")

(defvar-local sprig--btw-answer-raw ""
  "Raw text of the answer streaming into `*sprig-btw*' so far.
Its completed paragraphs are shown fontified and the still-typing one is
withheld, the way `sprig-review-defer-live-prose' reveals a review reply; a
fresh question resets it (`sprig--btw-display').")

(defun sprig--btw-args (id)
  "The `claude' argument list for a side question against session ID.
Resumes ID and forks with persistence off: the side turn sees the
conversation but writes no log and leaves the parent untouched.  Unlike a
real session it routes no permission prompts to us (there is no review
buffer to answer them in), so a tool needing approval simply auto-denies
and the turn answers from what it has."
  (append
   (list "-p"
         "--input-format" "stream-json"
         "--output-format" "stream-json"
         "--include-partial-messages"
         "--verbose"
         "--resume" id
         "--fork-session"
         "--no-session-persistence")
   (when sprig-model (list "--model" sprig-model))
   (when sprig-system-prompt
     (list "--append-system-prompt" sprig-system-prompt))
   sprig-extra-args))

(defun sprig--btw-command (id dir remote-host)
  "Full command for a side question against session ID, in DIR on REMOTE-HOST.
A `--resume' is scoped to the cwd's project, so the one-shot must run in the
session's own DIR, exactly as its session process does."
  (sprig--wrap-command (cons sprig-program (sprig--btw-args id))
                       dir remote-host))

(defun sprig--btw-compose (question context tail)
  "Assemble the side-question message from QUESTION, marked CONTEXT and TAIL.
TAIL is the in-flight turn's note (or nil), CONTEXT the marked sections (or
nil).  The instruction keeps it a question: a side turn should answer, not
edit."
  (string-join
   (delq nil
         (list tail
               (when context
                 (format "Regarding these marked sections:\n\n%s" context))
               (format "Side question (just answer briefly; do not edit any \
files): %s" question)))
   "\n\n"))

(defun sprig--btw-consume (event)
  "Sink for the `*sprig-btw*' buffer: stream a side question's answer in.
Runs in that buffer (see `sprig--handle'), appending assistant text as it
arrives and closing the entry when the turn ends."
  (let ((inhibit-read-only t)
        (defer (and (bound-and-true-p sprig-review-defer-live-prose)
                    (fboundp 'sprig-review--completed-prose))))
    (pcase event
      (`(text ,s)
       (setq sprig--btw-answer-raw (concat sprig--btw-answer-raw s))
       (if defer
           ;; Reveal only whole paragraphs, fontified, the way a review reply
           ;; is deferred; withhold the one still being typed until it lands.
           (when (sprig-review--paragraph-landed-p s)
             (sprig--btw-repaint (sprig-review--completed-prose
                                  sprig--btw-answer-raw)))
         (goto-char (point-max))
         (insert s)
         (dolist (win (get-buffer-window-list (current-buffer) nil t))
           (set-window-point win (point-max)))))
      (`(done ,_ ,err)
       (goto-char (point-max))
       (if err
           (insert "\n\n[the side question failed]\n")
         ;; Render the whole answer, including the final paragraph the
         ;; deferred stream was still withholding.
         (sprig--btw-repaint sprig--btw-answer-raw)
         (goto-char (point-max))
         (insert "\n")))
      (`(error ,m)
       (goto-char (point-max))
       (insert (format "\n\n[error] %s\n" m)))
      (_ nil))))

(defun sprig--btw-repaint (text)
  "Replace the current answer in `*sprig-btw*' with TEXT's fontified markdown.
The answer region runs from `sprig--btw-answer-beg' to the buffer end; TEXT
is the completed-paragraph prefix while streaming and the whole answer once
it settles.  A no-op when TEXT is nil (nothing has landed yet), the start
was not recorded, or markdown is unavailable."
  (when (and text sprig--btw-answer-beg
             (fboundp 'sprig-review--fontify-markdown))
    (let ((inhibit-read-only t))
      (delete-region sprig--btw-answer-beg (point-max))
      (goto-char sprig--btw-answer-beg)
      (insert (sprig-review--fontify-markdown text))
      (dolist (win (get-buffer-window-list (current-buffer) nil t))
        (set-window-point win (point-max))))))

(defun sprig--btw-display (question)
  "Show `*sprig-btw*' with a fresh QUESTION heading, returning the buffer.
Repeat questions append under their own heading, echoing the CLI's own
running `/btw' side panel."
  (let ((buf (get-buffer-create "*sprig-btw*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'sprig-btw-mode) (sprig-btw-mode))
      (setq-local sprig--sink #'sprig--btw-consume)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (unless (bobp) (insert "\n\n"))
        (insert (propertize (format "btw: %s" question) 'face '(:inherit bold))
                "\n\n")
        ;; Where this answer's text starts, so `sprig--btw-repaint' can find
        ;; it, and a clean slate for the deferred-paragraph accumulator.
        (setq sprig--btw-answer-beg (point)
              sprig--btw-answer-raw "")
        (when (boundp 'sprig-review--stream-nl)
          (setq sprig-review--stream-nl nil))))
    ;; Reuse an existing window the way `sprig-status' does, rather than
    ;; carving out a dedicated side window of its own.
    (pop-to-buffer buf)
    buf))

(defun sprig--btw-sentinel (proc _event)
  "Clear the side-question process and its stderr when PROC ends."
  (when (memq (process-status proc) '(exit signal))
    (when (eq proc sprig--btw-process) (setq sprig--btw-process nil))
    (let ((stderr (process-get proc :stderr-proc)))
      (when (process-live-p stderr) (delete-process stderr)))))

(defun sprig--fork-spawn (command dir remote-host buffer name sentinel)
  "Start a forked one-shot NAME running COMMAND, streaming events into BUFFER.
DIR/REMOTE-HOST mirror the session; a local cwd and CLAUDE_CONFIG_DIR are
bound here the way `sprig--spawn' does.  The reused transport filter
dispatches to BUFFER's buffer-local `sprig--sink'; SENTINEL cleans up when
the one-shot exits.  Shared by the side question and the retitle fork."
  (let* ((default-directory
          (if (and dir (not remote-host))
              (file-name-as-directory (expand-file-name dir))
            default-directory))
         (process-environment
          (if (and sprig-config-directory (not remote-host))
              (cons (concat "CLAUDE_CONFIG_DIR="
                            (expand-file-name sprig-config-directory))
                    process-environment)
            process-environment))
         (stderr (sprig--make-stderr))
         (proc (make-process
                :name name
                :buffer nil
                :command command
                :connection-type 'pipe
                :coding 'utf-8-unix
                :noquery t
                :stderr stderr
                :filter #'sprig--filter
                :sentinel sentinel)))
    (process-put proc :conv-buffer buffer)
    (process-put proc :stderr-proc stderr)
    proc))

(defun sprig--btw-spawn (command dir remote-host buffer)
  "Start a side-question one-shot running COMMAND, streaming into BUFFER.
A thin wrapper over `sprig--fork-spawn' with the side question's process
name and sentinel; the answer lands in the `*sprig-btw*' sink."
  (sprig--fork-spawn command dir remote-host buffer
                     "sprig-btw" #'sprig--btw-sentinel))

(defun sprig--btw-send (proc text)
  "Write TEXT to PROC as the one user message, then close its stdin.
The one-shot processes the message and exits on EOF, which is what makes it
a single side turn rather than a live session."
  (process-send-string
   proc
   (concat (json-serialize
            `(:type "user"
              :message (:role "user"
                        :content [(:type "text" :text ,text)])))
           "\n"))
  (process-send-eof proc))

(defun sprig--btw-ask (id dir remote-host question context tail)
  "Fire a side QUESTION against session ID in DIR on REMOTE-HOST.
CONTEXT is any marked-section text, TAIL the in-flight turn note; both may
be nil.  Streams the answer into `*sprig-btw*'.  The one-at-a-time guard is
`sprig--btw-process'."
  (when (process-live-p sprig--btw-process)
    (user-error "A side question is already running; wait for it to finish"))
  (let* ((text (sprig--btw-compose question context tail))
         (command (sprig--btw-command id dir remote-host))
         (buffer (sprig--btw-display question)))
    (setq sprig--btw-process (sprig--btw-spawn command dir remote-host buffer))
    (sprig--btw-send sprig--btw-process text)
    (message "sprig: side question sent (%s)"
             (if remote-host "remote" "local"))))

;;; Retitle a session
;;
;; A retitle writes the session a user title.  On disk that title is the
;; `custom-title'/`agent-name' pair the CLI's own `/rename' appends, so
;; Sprig writes the same records directly (`sprig--title-persist') rather
;; than driving `claude': the effect is identical and it costs no process,
;; no turn, and works on a closed session.  A user title is never
;; regenerated, so it always beats the CLI's `aiTitle' (see
;; `sprig--log-title'), and unlike an appended `aiTitle' it is not buried
;; when work continues.  The agent variant additionally forks the session
;; the way `c b' does (`--fork-session --no-session-persistence') only to
;; *propose* a title, which you then confirm or edit before it is written.

(defvar sprig--title-process nil
  "The live retitle one-shot, or nil.  Guards one retitle at a time.")

(defvar-local sprig--title-raw ""
  "Assistant text collected from the retitle fork, assembled on `done'.")

(defvar-local sprig--title-callback nil
  "One-argument function run with the proposed title once the fork settles.")

(defun sprig--title-prompt ()
  "The message asking a forked one-shot for a short session title."
  "Give this session a short title: at most about six words, no quotes, no \
trailing punctuation, plain text on a single line. Reply with the title \
alone and nothing else.")

(defun sprig--title-clean (text)
  "Reduce the fork's answer TEXT to a single tidy title line, or nil.
Takes the first non-blank line, strips surrounding quotes, any leading
list/heading markup, and trailing punctuation, and caps the length so a
chatty answer still yields a usable title."
  (let* ((line (seq-find (lambda (l) (not (string-blank-p l)))
                         (split-string (or text "") "\n")))
         (s (and line (string-trim line))))
    (when (and s (not (string-empty-p s)))
      (setq s (replace-regexp-in-string "\\`[-*#>[:space:]]+" "" s))
      (setq s (replace-regexp-in-string "\\`[\"'“”‘’`]+\\|[\"'“”‘’`]+\\'" "" s))
      (setq s (string-trim s))
      (setq s (replace-regexp-in-string "[.,;:!?[:space:]]+\\'" "" s))
      (when (> (length s) 80) (setq s (substring s 0 80)))
      (setq s (string-trim s))
      (and (not (string-empty-p s)) s))))

(defun sprig--title-sentinel (proc _event)
  "Clear the retitle process and its stderr when PROC ends, killing its buffer."
  (when (memq (process-status proc) '(exit signal))
    (when (eq proc sprig--title-process) (setq sprig--title-process nil))
    (let ((stderr (process-get proc :stderr-proc)))
      (when (process-live-p stderr) (delete-process stderr)))
    (let ((buf (process-get proc :conv-buffer)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(defun sprig--title-consume (event)
  "Sink for a retitle fork: collect its answer, then hand it to the callback.
Runs in the fork's hidden buffer; assembles assistant text and, on `done',
calls the stored `sprig--title-callback' with the cleaned title (nil on
failure).  The call is deferred with a zero timer so the confirm prompt runs
at top level rather than inside the process filter."
  (pcase event
    (`(text ,s) (setq sprig--title-raw (concat sprig--title-raw s)))
    (`(done ,_ ,err)
     (let ((cb sprig--title-callback)
           (proposed (and (not err) (sprig--title-clean sprig--title-raw))))
       (setq sprig--title-callback nil)
       (when cb (run-at-time 0 nil cb proposed))))
    (`(error ,_)
     (let ((cb sprig--title-callback))
       (setq sprig--title-callback nil)
       (when cb (run-at-time 0 nil cb nil))))
    (_ nil)))

(defun sprig--title-ask (id dir remote-host callback)
  "Fork session ID in DIR on REMOTE-HOST to propose a title; run CALLBACK on it.
CALLBACK gets the cleaned title string, or nil when the fork failed or gave
nothing usable.  Reuses the side-question fork transport; one retitle runs
at a time (`sprig--title-process')."
  (when (process-live-p sprig--title-process)
    (user-error "A retitle is already running; wait for it to finish"))
  (let ((command (sprig--btw-command id dir remote-host))
        (buffer (generate-new-buffer " *sprig-title*")))
    (with-current-buffer buffer
      (setq-local sprig--sink #'sprig--title-consume)
      (setq-local sprig--title-raw "")
      (setq-local sprig--title-callback callback))
    (setq sprig--title-process
          (sprig--fork-spawn command dir remote-host buffer
                             "sprig-title" #'sprig--title-sentinel))
    (sprig--btw-send sprig--title-process (sprig--title-prompt))
    (message "sprig: asking the agent for a title (%s)..."
             (if remote-host "remote" "local"))))

(defun sprig--title-persist (id remote-host title)
  "Write TITLE as session ID's user title, into its log.
Appends the `custom-title' and `agent-name' records the CLI's own `/rename'
writes, rather than driving `claude' to run it: on disk `/rename' does no
more than append this pair, and there is no separate name index.  Unlike
`ai-title' (the CLI's generated title, re-emitted every turn), a user title
is never regenerated, so it always wins (see `sprig--log-title').  The log
is found by id under the projects directory on REMOTE-HOST (nil for local);
returns non-nil on a successful write."
  (let ((lines (concat
                (json-serialize `(:type "custom-title" :customTitle ,title
                                  :sessionId ,id))
                "\n"
                (json-serialize `(:type "agent-name" :agentName ,title
                                  :sessionId ,id))
                "\n")))
    (if remote-host
        (sprig--title-persist-remote id lines remote-host)
      (sprig--title-persist-local id lines))))

(defun sprig--title-persist-local (id text)
  "Append TEXT to local session ID's log, returning non-nil when it lands."
  (let ((file (car (directory-files-recursively
                    (expand-file-name (sprig--projects-directory))
                    (concat "\\`" (regexp-quote id) "\\.jsonl\\'")))))
    (when file
      (write-region text nil file 'append 'silent)
      t)))

(defun sprig--title-persist-remote (id text host)
  "Append TEXT to remote session ID's log on HOST, returning non-nil on success.
One SSH round trip finds the log by id and appends the records with `>>'."
  (let* ((sprig-remotes (list host))
         (root (sprig--remote-dir-arg (sprig--projects-directory)))
         (name (shell-quote-argument (concat id ".jsonl")))
         (out (sprig--remote-sh
               (format "p=$(find %s -name %s -print -quit 2>/dev/null); \
[ -n \"$p\" ] && printf %s >> \"$p\" && echo ok"
                       root name (shell-quote-argument text)))))
    (and out (string-match-p "ok" out))))

(declare-function sprig-review-set-title "sprig-review-mode" (title))

(defun sprig--title-reflect (id title)
  "Show TITLE for session ID at once, ahead of the next disk scan.
Updates the header of any open review buffer that owns ID and marks the
navigator's log-scan cache stale so the row picks the new title up on its
next render."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (derived-mode-p 'sprig-review-mode)
                 (equal sprig--session-id id))
        (sprig-review-set-title title))))
  (sprig--status-scan-invalidate)
  (sprig--status-refresh))

(defun sprig--title-live-buffer (id)
  "Return a live review buffer that owns session ID with a running process, or nil."
  (seq-find (lambda (b)
              (and (equal (buffer-local-value 'sprig--session-id b) id)
                   (process-live-p (buffer-local-value 'sprig--process b))))
            (buffer-list)))

(defvar sprig--status-reattach-attempted nil
  "Session ids the navigator will not auto-reattach again.
An id lands here when a reattach is tried (so a failed one off a stale
`<id>.sprig-live' marker is not retried on every background scan) and when
you disconnect a session deliberately (a broker-held session's row stays
`:live', so without the mark the next scan would quietly reconnect it and
undo the disconnect).  Reset when `sprig-status' is opened afresh and on
`g' (`sprig--status-revert'), both of which re-express
attach-everything-held.")

(defun sprig--reattach-session (dir id host)
  "Attach in the background to broker-held session ID on HOST, rooted at DIR.
Builds the session's review buffer undisplayed and connects it attach-only,
so a stale marker cannot spawn a fresh session.  Errors are swallowed: a
reattach that cannot land must never disturb the navigator."
  (with-current-buffer (sprig--review-session-buffer dir id host nil)
    (unless (process-live-p sprig--process)
      ;; Reattach is best-effort: a marker whose daemon is gone or unreachable
      ;; fails attach-only and the process exits nonzero.  `sprig--broker-attach-
      ;; only' both routes the `open' as attach-only and, in `sprig--spawn',
      ;; flags the process so the sentinel keeps that failure quiet rather than
      ;; logging a session failure.  Flagging at spawn (not here, after) avoids a
      ;; race where a fast-failing probe is already dead before we could set it.
      (let ((sprig--broker-attach-only t))
        (ignore-errors (sprig--ensure))))))

(defun sprig--status-reattach-live (host rows)
  "Reattach every broker-held (:live) row in ROWS on HOST, once each.
No-op unless `sprig-status-auto-reattach' is on and the broker covers this
host: a remote HOST needs `sprig-use-broker' non-nil, a local one (nil HOST)
needs it set to `all' (only then is a local session brokered).  A session
already owned by a live buffer, or already attempted, is skipped, so this is
safe to call on every scan completion."
  (when (and sprig-status-auto-reattach
             (if host (sprig--broker-remote-p) (sprig--broker-local-p)))
    (dolist (row rows)
      (when (plist-get row :live)
        (let ((id (plist-get row :session))
              (dir (plist-get row :dir)))
          (when (and id (not (member id sprig--status-reattach-attempted))
                     (not (sprig--title-live-buffer id)))
            (push id sprig--status-reattach-attempted)
            (sprig--reattach-session dir id host)))))))

(defun sprig--title-commit (id remote-host title)
  "Set session ID's user TITLE and reflect it, trimming; an empty one cancels.
When the session is live, sends `/rename' down the wire already open to it,
letting the CLI write its own rename records.  Otherwise writes the same
`custom-title'/`agent-name' records to the log directly
\(`sprig--title-persist') on REMOTE-HOST (nil local).  Either way it updates
any open review buffer and the navigator and messages the outcome.  Shared
by the agent (`sprig--title-apply') and the manual retitle commands."
  (let ((title (string-trim title))
        (buf (sprig--title-live-buffer id)))
    (cond
     ((string-empty-p title) (message "sprig: retitle cancelled"))
     (buf
      (with-current-buffer buf (sprig--send-user (concat "/rename " title)))
      (sprig--title-reflect id title)
      (message "sprig: renamed to %s" title))
     ((sprig--title-persist id remote-host title)
      (sprig--title-reflect id title)
      (message "sprig: renamed to %s" title))
     (t (message "sprig: could not find session %s's log to retitle" id)))))

(defun sprig--title-apply (id remote-host proposed)
  "Confirm the PROPOSED title for session ID, then persist and reflect it.
Run from the retitle fork's callback: PROPOSED is the agent's suggestion, or
nil when the fork failed or gave nothing usable.  Prompts you to accept or
edit it, then commits it (`sprig--title-commit')."
  (if (not proposed)
      (message "sprig: the agent proposed no usable title")
    (sprig--title-commit id remote-host
                         (read-string "Session title: " proposed))))

(defun sprig-status-retitle ()
  "Ask the agent for a short title for the session at point, then set it.
Forks that session without opening it (like `c b') to propose a title, and
once you confirm or edit it writes a user title to its log and refreshes the
navigator."
  (interactive)
  (let* ((entry (sprig--status-entry-at-point))
         (id (plist-get entry :session))
         (dir (plist-get entry :dir))
         (host (plist-get entry :host)))
    (unless id (user-error "No session id on this row"))
    (sprig--title-ask id dir host
                      (lambda (proposed)
                        (sprig--title-apply id host proposed)))))

(defun sprig-status-set-title (title)
  "Set the title of the session on the row at point by hand, writing it out.
Prompts for TITLE (seeded with the current one) and writes a user title to
the session's log, the way `sprig-status-retitle' persists the agent's
suggestion but without asking the agent."
  (interactive
   (let ((cur (plist-get (sprig--status-entry-at-point) :title)))
     (list (read-string "Session title: "
                        (unless (equal cur "(untitled)") cur)))))
  (let* ((entry (sprig--status-entry-at-point))
         (id (plist-get entry :session))
         (host (plist-get entry :host)))
    (unless id (user-error "No session id on this row"))
    (sprig--title-commit id host title)))

(defun sprig--star-write (log host starred)
  "Create (STARRED non-nil) or delete session LOG's star marker on HOST.
HOST is nil for the local machine, else the SSH destination the log lives on.
Starring writes the `<id>.sprig-star' marker (`sprig--star-file') beside the
log, so it travels with the session and every navigator on that host reads it
back off the same scan.  Unstarring removes every `<id>.sprig-star' under the
projects root, not just this one: the CLI re-homes a session's log across
project directories, so an earlier star can be stranded in a directory the
log has since left (see `sprig--star-ids-local'), and a single stray copy
would keep the session starred.  So the id is cleared host-wide."
  (let* ((marker (sprig--star-file log))
         (id (file-name-base log))
         (root (sprig--projects-directory)))
    (if host
        (let ((sprig-remotes (list host)))
          (if starred
              (sprig--remote-sh (format "touch %s" (shell-quote-argument marker)))
            ;; Remove the sibling and sweep the root for any stranded copy.
            (sprig--remote-sh
             (format "rm -f %s; find %s -name %s -delete 2>/dev/null; :"
                     (shell-quote-argument marker)
                     (sprig--remote-dir-arg (directory-file-name root))
                     (shell-quote-argument (concat id ".sprig-star"))))))
      (if starred
          (write-region "" nil marker nil 'silent)
        (when (file-exists-p marker) (delete-file marker))
        (let ((dir (expand-file-name root)))
          (when (file-directory-p dir)
            (dolist (f (directory-files-recursively
                        dir (concat "\\`" (regexp-quote id) "\\.sprig-star\\'")))
              (ignore-errors (delete-file f)))))))))

(defun sprig-status-star ()
  "Star or unstar the session on the row at point, floating it up its group.
A starred session sorts above the rest of its host group whatever the
active column, and shows a `★' by its project.  The star is a
`<id>.sprig-star' marker written beside the session's own log on its host
\(`sprig--star-file'), so it lives with the session, survives restarts, and
every navigator on that host sees it.  A row with no log yet cannot be
starred: the marker has nowhere to sit."
  (interactive)
  (let* ((entry (sprig--status-entry-at-point))
         (log (plist-get entry :file))
         (host (plist-get entry :host)))
    (unless log (user-error "No session log to star on this row"))
    (let ((starred (not (sprig--status-starred-p entry))))
      (sprig--star-write log host starred)
      ;; Patch the cache too, then render now: a plain refresh would repaint
      ;; from the pre-toggle cache and only pick the disk marker up on the next
      ;; background scan, so the star would lag a click behind.
      (sprig--status-scan-cache-set-star host (plist-get entry :session) starred)
      (message "sprig: %s" (if starred "starred" "unstarred")))
    (sprig--status-render)))

(defun sprig--host-dir-candidates (host)
  "Distinct working directories of existing sessions on HOST.
Drawn from the same cached log scan the navigator uses (see
`sprig--status-scan-cached'), so it needs no configuration and no extra SSH
round trip: the directories the sessions already on HOST run in become
ready-made candidates for a new session's working directory."
  (let (dirs)
    (dolist (row (sprig--status-scan-cached host))
      (when-let* ((dir (plist-get row :dir)))
        (push dir dirs)))
    (delete-dups (nreverse dirs))))

(defun sprig--remote-subdirs (host dir)
  "Absolute subdirectories of DIR on HOST, each ending in a slash.
Reuses the session transport (`sprig--remote-sh'), so the listing rides the
same `ssh' as the session and needs no TRAMP.  DIR keeps a live leading `~'
\(see `sprig--remote-dir-arg'), so a home-relative path completes too; an
empty DIR lists the login directory, whose entries stay relative."
  (let* ((sprig-remotes (list host))
         (out (sprig--remote-sh
               (format "ls -1Ap -- %s 2>/dev/null"
                       (sprig--remote-dir-arg (if (string-empty-p dir) "." dir))))))
    (delq nil
          (mapcar (lambda (entry)
                    (when (string-suffix-p "/" entry)
                      (concat (if (string-empty-p dir)
                                  ""
                                (file-name-as-directory dir))
                              entry)))
                  (split-string out "\n" t)))))

(defun sprig--subdirs (host dir)
  "Absolute subdirectories of DIR, each ending in a slash.
A nil HOST lists the local filesystem; a non-nil HOST runs one SSH `ls'
\(see `sprig--remote-subdirs')."
  (if host
      (sprig--remote-subdirs host dir)
    (when (and (not (string-empty-p dir)) (file-directory-p dir))
      (let (out)
        (dolist (f (directory-files dir t nil t))
          (unless (member (file-name-nondirectory f) '("." ".."))
            (when (file-directory-p f)
              (push (file-name-as-directory f) out))))
        (nreverse out)))))

(defun sprig--dir-completion-table (host)
  "Completion table over directories on HOST for the working-dir prompt.
Offers the working directories of existing sessions on HOST as ready
candidates (see `sprig--host-dir-candidates'), and completes deeper paths
live by listing whatever directory the input names: on the local
filesystem, or over SSH for a remote HOST (one `ls' per completion, cached
for the length of the prompt so a re-list of the same directory is free).
The caller allows free text, so a directory that does not exist yet can
still be typed past the candidates."
  (let ((roots (sprig--host-dir-candidates host))
        (cache (make-hash-table :test 'equal)))
    (lambda (string pred action)
      ;; Metadata and boundary queries need no listing; answering them with
      ;; nil (the defaults) keeps them off the network.
      (unless (or (eq action 'metadata) (eq (car-safe action) 'boundaries))
        (let* ((dir (or (file-name-directory string) ""))
               (subs (gethash dir cache 'miss)))
          (when (eq subs 'miss)
            (setq subs (condition-case nil (sprig--subdirs host dir) (error nil)))
            (puthash dir subs cache))
          (complete-with-action action
                                (delete-dups (append subs (copy-sequence roots)))
                                string pred))))))

(defun sprig--read-review-dir (&optional host default)
  "Prompt for a session working directory on HOST, returning the string.
HOST is the resolved session host: nil for the local machine, else an SSH
destination.  Unlike `sprig--read-working-directory' this records nothing
in frontmatter; a session-owning review buffer keeps its directory in the
buffer-local `sprig--working-dir' instead.

Completion offers the working directories of existing sessions on HOST as
ready candidates, and completes deeper paths live: against the local
filesystem, or over SSH for a remote HOST (so the remote prompt no longer
falls back to a blind free string).  A directory that does not exist yet
can still be typed, since the prompt requires no match.  The prompt names
the host so a navigator with a group per host says which one you are
starting on.  DEFAULT, when non-nil, seeds the prompt so a fresh session
starts in the same directory as the one it was launched from (see
`sprig-status-new').  For a local session it returns an expanded absolute
path (a blank answer keeps `default-directory'); for a remote one it
returns the string as typed, where a blank means the login directory."
  (let* ((prompt (if host
                     (format "Working directory (%s, blank = login dir): " host)
                   "Working directory: "))
         (seed (or default (and (not host) (abbreviate-file-name default-directory))))
         (input (completing-read prompt (sprig--dir-completion-table host)
                                 nil nil seed)))
    (if host
        input
      (if (string-empty-p input) default-directory (expand-file-name input)))))

;;;###autoload
(defun sprig-review-connect (&optional no-prompt)
  "Start or resume the session owned by this review buffer.
Resumes `sprig--session-id' when set (replayed history already showing),
otherwise starts a fresh session, prompting for its working directory
unless NO-PROMPT."
  (interactive)
  (when (process-live-p sprig--process)
    (user-error "This review already has a live session"))
  (setq sprig--sink #'sprig--review-sink
        sprig--connect-fn #'sprig-review-connect)
  (unless (or no-prompt sprig--session-id sprig--working-dir)
    (setq sprig--working-dir (sprig--read-review-dir (sprig--remote)))
    (sprig--sync-default-directory))
  (sprig--spawn)
  (message "sprig: %s (%s%s)"
           (if sprig--session-id "resuming session" "new session")
           (if (sprig--remote) (concat "ssh " (sprig--remote)) "local")
           (if sprig--working-dir (concat " in " sprig--working-dir) ""))
  (sprig--status-refresh))

(defun sprig--review-steer (text)
  "Send TEXT into the turn already in flight, to steer it.
The CLI's stdin stays open for the length of a turn, and a user message
written to it mid-turn is queued and handed to the agent at its next
tool-call boundary, inside the same turn: the agent reads it and changes
course, and one `done' still ends the turn.  So this neither interrupts
nor opens a turn of its own; it only writes and echoes.

`sprig--busy' is cleared on `done', on teardown, and by the sentinel on
any process death, so it standing means the process is live to write to.
When it is not, the turn ended while the message was being composed, and
the message is delivered as a turn of its own rather than lost."
  (if (not sprig--busy)
      (sprig--review-deliver text)
    (sprig--send-user text)
    ;; Float it above the state line rather than splice it into the stream:
    ;; the agent has not taken it yet, so it waits at the bottom and lands in
    ;; the transcript once the agent reaches the boundary that takes it (see
    ;; `sprig-review-stage-steer' / `sprig-review--commit-pending-steer').
    (sprig-review-stage-steer text)
    (message "sprig: steering (the agent takes it at its next step)")))

(defun sprig--redraw-queue-floats ()
  "Redraw the review buffer so its queued-message floats track `sprig--queued'.
The floats are drawn straight from `sprig--queued' (see
`sprig-review--insert-pending-queue'), so any change to the queue has to
schedule a render for the change to show.  A no-op outside a review buffer."
  (when (derived-mode-p 'sprig-review-mode)
    (sprig-review--schedule)))

(defun sprig--review-queue (text)
  "Hold TEXT until the in-flight turn ends, then send it as a turn of its own.
The counterpart to `sprig--review-steer': steering changes the running
turn's course, queueing leaves it alone and speaks once it is done.  So
this is for the follow-up that should not derail what is running, the
thing you would otherwise sit and wait to type.

With no turn running there is nothing to wait for, so it just sends: the
turn ended while the message was being composed, and the promise `after
this turn' is already kept."
  (if (not sprig--busy)
      (sprig--review-deliver text)
    (setq sprig--queued (append sprig--queued (list text)))
    (sprig--redraw-queue-floats)
    (sprig--status-refresh)
    (message "sprig: queued (goes when the turn ends; c i drops it)")))

(defun sprig--flush-queue ()
  "Send the oldest queued message, if any, now the turn has ended.
One per turn: each queued message gets a turn of its own, and the rest
wait for that turn's own `done' to come round again."
  (when sprig--queued
    (let ((text (pop sprig--queued)))
      (sprig--review-deliver text)
      (message "sprig: sent the queued message%s"
               (if sprig--queued
                   (format " (%d still queued)" (length sprig--queued))
                 "")))))

(defun sprig--drop-queue (why)
  "Forget any queued messages, reporting WHY they will not be sent.
The text is echoed, not binned in silence: nothing else holds it, the
compose buffer that did is long gone, and a queue is dropped precisely
where the user is not expecting it to be."
  (when sprig--queued
    (message "sprig: %s, so %d queued message(s) will not be sent: %s"
             why (length sprig--queued)
             (mapconcat (lambda (m) (format "%S" (truncate-string-to-width m 40 nil nil t)))
                        sprig--queued "; "))
    (setq sprig--queued nil)
    (sprig--redraw-queue-floats)
    (sprig--status-refresh)))

(defun sprig--review-drop-queue ()
  "Forget the messages queued with `c q', without touching the turn (`c Q').
Deliberately not folded into `c i': dropping the queue and stopping the
turn are different wants, and only one of them needs the other's help.
Queue a follow-up, change your mind, and this is the way to take it back
\(there is no other: nothing has been sent, so there is nothing to steer).
Stopping the turn *and* meaning it is then this and `c i', two gestures
that each say one thing."
  (if sprig--queued
      (sprig--drop-queue "you dropped the queue")
    (message "sprig: nothing queued")))

(defun sprig--review-unqueue (text)
  "Take TEXT back out of the queue, leaving the rest and the turn alone.
The single-message counterpart to `c Q' (`sprig--review-drop-queue', which
clears the lot): point on one floated `c q' message and this drops just
that one.  Safe because a queued message is not on the wire yet; the first
matching entry goes, so re-queueing the same text twice drops one copy at a
time.  Errors when TEXT is not actually queued, since then the float the
caller read is stale."
  (unless (member text sprig--queued)
    (user-error "That message is no longer queued"))
  (let ((seen nil))
    (setq sprig--queued
          (seq-remove (lambda (m) (and (not seen) (equal m text) (setq seen t)))
                      sprig--queued)))
  (sprig--redraw-queue-floats)
  (sprig--status-refresh)
  (message "sprig: unqueued (%d still queued)" (length sprig--queued)))

(defun sprig--review-deliver (text &optional mode)
  "Send TEXT as this review buffer's own next user turn, echoing it locally.
Used when the review buffer owns the session.  MODE, when given, sets the
permission mode first (e.g. \"plan\").  With none, the mode is left as it
stands: it is sticky, the way Claude Code's own is, so a follow-up carries
on in plan mode rather than dropping out of it.  Leaving plan mode is its
own gesture: approving an ExitPlanMode plan, or `P' to set the mode by hand."
  (sprig--ensure)
  ;; Reached with a turn running only from a verb that needs a turn of its
  ;; own, `c p' being the one: a plan turn sets the permission mode first, so
  ;; it cannot fold into a turn already running under another one.  The verbs
  ;; that can fold in steer (`c c'), or wait (`c q'), and never come here busy.
  (when sprig--busy
    (user-error "A turn is already in flight (say it with `c c', or wait with `c q')"))
  (when (and mode (not (equal mode sprig--permission-mode)))
    (sprig--set-permission-mode mode))
  (setq sprig--busy t)
  (sprig--send-user text)
  (sprig-review-consume (list 'user text))
  (sprig--status-refresh))

(defun sprig--review-interrupt-owned ()
  "Interrupt the in-flight turn on a review buffer that owns its session."
  (cond
   ((not sprig--busy) (message "sprig: nothing to interrupt"))
   (sprig--interrupt-timer
    (message "sprig: already interrupting…"))
   (t (sprig--interrupt-turn))))

(defun sprig--interrupt-turn ()
  "Gracefully interrupt the in-flight turn, keeping the session live.
Sends an `interrupt' control request; the CLI aborts the turn and ends it
with a `result', so `sprig--busy' clears through the normal `done' path
\(which also clears the fallback state) and the process stays up, needing
no resume on the next send.  Should the CLI refuse the request (an error
receipt, see `sprig--interrupt-receipt') or never end the turn within
`sprig-interrupt-timeout' seconds (`sprig--interrupt-timeout'), it falls
back to killing the process, the old hard interrupt.

Leaves the queue alone, so the interrupt's own `done' flushes it like any
other: a queued message is the next thing, not the rest of this thing, so
stopping the turn does not unmake it.  Interrupting with one queued reads
as `stop, do this instead', which is the useful gesture.  To stop and mean
it, drop the queue first (`c Q')."
  (sprig--clear-interrupt)
  (setq sprig--interrupt-request-id (sprig--send-interrupt))
  (when sprig-interrupt-timeout
    (setq sprig--interrupt-timer
          (run-at-time sprig-interrupt-timeout nil
                       #'sprig--interrupt-timeout (current-buffer))))
  (sprig--status-refresh)
  (message "sprig: interrupting the turn…"))

(defun sprig--clear-interrupt ()
  "Clear this buffer's outstanding graceful-interrupt state, if any.
Cancels the fallback timer and forgets the request id, so a later receipt
or timeout for a settled interrupt is ignored."
  (when sprig--interrupt-timer
    (cancel-timer sprig--interrupt-timer)
    (setq sprig--interrupt-timer nil))
  (setq sprig--interrupt-request-id nil))

(defun sprig--interrupt-receipt (id subtype)
  "Act on the CLI's control_response ID with SUBTYPE for our interrupt.
A `success' receipt just confirms the interrupt landed; the turn still
ends through `done' (with the timer as a backstop), so nothing to do.  An
`error' receipt means the CLI refused it, so fall back to the hard kill at
once rather than waiting out `sprig-interrupt-timeout'.  Ignores receipts
for anything but the outstanding interrupt."
  (when (and sprig--interrupt-request-id
             (equal id sprig--interrupt-request-id)
             (not (equal subtype "success")))
    (sprig--clear-interrupt)
    (when sprig--busy
      (sprig--teardown-process)
      (sprig--status-refresh)
      (message "sprig: the CLI refused the interrupt; killed the turn"))))

(defun sprig--interrupt-timeout (buffer)
  "Kill BUFFER's turn after a graceful interrupt went unanswered.
The CLI never ended the turn within `sprig-interrupt-timeout', so fall
back to killing the process; the session resumes on the next send."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq sprig--interrupt-timer nil)
      (when sprig--busy
        (sprig--teardown-process)
        (sprig--status-refresh)
        (message "sprig: interrupt timed out; killed the turn (resumes on next send)")))))

(defun sprig--review-session-buffer (dir session-id host fork)
  "Build (or reuse) the review buffer owning DIR's session, and return it.
The buffer is left undisplayed; see `sprig-review-session' for the DIR,
SESSION-ID, HOST, and FORK arguments.  Splitting the build from the
display lets the navigator steer a stored session's buffer into being
without popping it up: a verb run from the list acts on the session
in the background, and only the verb's own compose or answer buffer shows."
  (require 'sprig-review-mode)
  (let* ((label (format "*sprig-review: %s%s*"
                        (or session-id
                            (and dir (file-name-nondirectory
                                      (directory-file-name dir)))
                            "new")
                        (if fork " (fork)" "")))
         ;; A resumed session is named by its id, and reusing that buffer is
         ;; right: opening one session twice should land in one buffer.  A
         ;; fresh session has no id yet, so its label is only the directory;
         ;; that must be made unique, or a second new session in the same
         ;; directory would reuse — and stomp — the first one's buffer while
         ;; its process keeps streaming into it.  A fork carries its parent's
         ;; id until the CLI answers with its own, so it must be uniquified
         ;; too, or it would reuse the very buffer it was forked from.
         (name (if (and session-id (not fork))
                   label
                 (generate-new-buffer-name label)))
         (buffer (sprig-review-buffer name)))
    (with-current-buffer buffer
      (setq sprig--session-id session-id
            sprig--fork-session (and fork session-id t)
            sprig--working-dir dir
            sprig--remote-override (sprig--remote-override-value host)
            sprig--sink #'sprig--review-sink
            sprig--connect-fn #'sprig-review-connect)
      (if (and session-id (sprig--remote))
          ;; A remote session's log is fetched over SSH: seed the buffer empty
          ;; now, so opening the row returns at once, and fill in the replayed
          ;; history when the background fetch lands.  Only if the buffer is
          ;; still pristine by then: a turn started in the meantime is the live
          ;; conversation now, and re-seeding would drop it.
          (progn
            (sprig-review-seed nil (list :project dir))
            (sprig--session-log-lines-async
             (lambda (lines)
               (when (and lines
                          (null (buffer-local-value 'sprig-review--events
                                                     (current-buffer)))
                          (not sprig--busy))
                 (sprig-review-seed (sprig-review-session-events lines)
                                    (list :project dir))))))
        (let* ((lines (and session-id (ignore-errors (sprig--session-log-lines))))
               (events (and lines (sprig-review-session-events lines))))
          (sprig-review-seed events (list :project dir))))
      (sprig-review-set-remote (sprig--remote))
      (sprig--sync-default-directory))
    buffer))

;;;###autoload
(defun sprig-review-session (dir &optional session-id host fork)
  "Open a review buffer that owns a session in working directory DIR.
DIR may be nil when it is unknown (a stored session whose log carried no
cwd), in which case the session runs in the host's login directory.  With
SESSION-ID, replay that stored session's log and resume it on the next
send; without, the buffer starts empty and a send opens a fresh session.
HOST pins where the session runs: a string is an SSH destination, any
other non-nil value (interactively, a prefix argument) is the local
machine even when a remote is configured, and nil follows the primary
remote as it stands.  Pinning is what the navigator opens a row with, since a
session id is per-host and only resumes on the host holding its log.
FORK non-nil resumes SESSION-ID under an id of its own (see
`sprig--fork-session'), so the replayed history is carried on in a session
of its own and the parent is left untouched.  The review buffer is the
only conversation surface."
  (interactive
   (let ((local current-prefix-arg))
     (list (sprig--read-review-dir (unless local (sprig--primary-remote)))
           nil local)))
  (pop-to-buffer (sprig--review-session-buffer dir session-id host fork)))

(defun sprig--login-command ()
  "Command vector running `claude auth login', local or over SSH.
Drives the paste-a-code OAuth flow (`--claudeai'), which needs no TTY: the
CLI prints the authorization URL to stdout and reads the pasted code from
stdin, so it runs down the same kind of pipe a session does.  A remote run
sets CLAUDE_CONFIG_DIR with an `env' prefix the login shell expands; a
local run gets it from the caller binding `process-environment'."
  (let ((args (list sprig-program "auth" "login" "--claudeai"))
        (remote-host (sprig--remote)))
    (if remote-host
        (let ((remote (mapconcat #'shell-quote-argument args " ")))
          (when sprig-config-directory
            (setq remote (concat "env CLAUDE_CONFIG_DIR="
                                 (sprig--remote-dir-arg sprig-config-directory)
                                 " " remote)))
          (append (list sprig-ssh-program) sprig-ssh-args
                  (list remote-host remote)))
      args)))

(defun sprig--login-url (text)
  "Return the OAuth authorization URL printed in login output TEXT, or nil."
  (and (string-match "\\(https://[^ \t\r\n]*oauth/authorize[^ \t\r\n]*\\)" text)
       (match-string 1 text)))

;;;###autoload
(defun sprig-login ()
  "Log the `claude' CLI in for sprig's config dir, without leaving Emacs.
A session runs headless over the stream-json protocol, so it cannot drive
the interactive `/login' itself.  This runs `claude auth login' down a
pipe instead, on the session host (over SSH when a remote is configured,
else locally) and with CLAUDE_CONFIG_DIR bound to `sprig-config-directory'
when it is set.  It opens the authorization URL in your local browser
\(the right place: the login is your account, not the host's), then reads
the code the browser shows back and hands it to the CLI.  Every headless
sprig session on that host then reuses the stored credentials.

Run it once per host, and again whenever `sprig-config-directory' points
at a config dir that is not yet logged in."
  (interactive)
  (let* ((remote (sprig--remote))
         ;; A local run passes CLAUDE_CONFIG_DIR through the process env
         ;; (no shell to expand `~', so expand here); a remote one sets it
         ;; in the `env' prefix of `sprig--login-command'.
         (process-environment
          (if (and sprig-config-directory (not remote))
              (cons (concat "CLAUDE_CONFIG_DIR="
                            (expand-file-name sprig-config-directory))
                    process-environment)
            process-environment))
         (proc (make-process
                :name "sprig-login"
                :buffer nil
                :command (sprig--login-command)
                :connection-type 'pipe
                :coding 'utf-8-unix
                :noquery t
                :filter (lambda (p chunk)
                          (process-put p :out
                                       (concat (process-get p :out) chunk))))))
    (unwind-protect
        (let ((url nil) (waited 0.0))
          ;; Wait for the CLI to print the authorization URL.
          (while (and (process-live-p proc)
                      (not (setq url (sprig--login-url
                                      (or (process-get proc :out) ""))))
                      (< waited 30))
            (accept-process-output proc 0.2)
            (setq waited (+ waited 0.2)))
          (unless url
            (error "sprig-login: no login URL from the CLI (see *sprig-login*)"))
          (browse-url url)
          (message "sprig-login: opened %s" url)
          (let ((code (string-trim
                       (read-string "Paste the code from the browser here: "))))
            (when (string-empty-p code)
              (error "sprig-login: no code entered"))
            (process-send-string proc (concat code "\n")))
          ;; Let the code exchange finish.
          (while (process-live-p proc)
            (accept-process-output proc 0.3))
          (sprig--login-report proc))
      (when (process-live-p proc)
        (delete-process proc)))))

(defun sprig--login-report (proc)
  "Report the outcome of finished login PROC.
On success just a message; on failure the CLI's output is shown in
`*sprig-login*' so the reason is visible."
  (if (eq (process-exit-status proc) 0)
      (message "sprig-login: logged in%s"
               (if sprig-config-directory
                   (format " (%s)" sprig-config-directory) ""))
    (with-current-buffer (get-buffer-create "*sprig-login*")
      (erase-buffer)
      (insert (or (process-get proc :out) ""))
      (goto-char (point-min)))
    (display-buffer "*sprig-login*")
    (message "sprig-login: did not complete; see *sprig-login*")))

;;;; Folding commands

;;;; Status navigator

(defconst sprig-status-buffer-name "*sprig-status*"
  "Name of the buffer showing the `sprig-status' navigator.")

(defconst sprig--status-preview-bytes 65536
  "Bytes of a session log read from one end, for two callers.
A row's scan reads this much from the head to recover its `cwd', which is
in the first record; the inline preview reads this much from the tail for
the last reply, which lives at the end.  (The title is not in either window in
general, so it is grepped whole-file.)  Local and remote read the same
amount, and either read is bounded however large the session grows.")

(defconst sprig--status-glyphs
  '((streaming    . "▶")
    (agent        . "◐")
    (waiting      . "?")
    (idle         . "●")
    (interrupted  . "◼")
    (held         . "◌")
    (disconnected . "○"))
  "Glyph shown in the status column for each session state.
`held' is a session the broker still runs on its host that no buffer here
has attached to yet (alive, but not in front of you); see `:live'.")

(defvar sprig-claude-projects-directory "~/.claude/projects"
  "Root under which the `claude' CLI stores per-project session logs.
This is the CLI's default location, used when `sprig-config-directory' is
nil.  Local sessions read it here; remote sessions read the same path on
the SSH host.  A variable, not a defcustom, so tests can redirect it; the
supported user knob is `sprig-config-directory'.")

(defun sprig--projects-directory ()
  "Root under which the session host stores per-project session logs.
When `sprig-config-directory' is set, that is its `projects/'
subdirectory; otherwise `sprig-claude-projects-directory'.  Interpreted on
the session host, so it may carry a leading `~'."
  (if sprig-config-directory
      (file-name-concat (directory-file-name sprig-config-directory) "projects")
    sprig-claude-projects-directory))

(defvar-local sprig--status-filter nil
  "Case-insensitive substring the navigator narrows rows to, or nil for all.
Matched against a row's project directory and its title.")

(defvar-local sprig--status-show-all nil
  "When non-nil, the navigator lists every session.
It lifts the `sprig-status-max-sessions' cap for its buffer.")

(defvar-local sprig--status-hide-disconnected nil
  "When non-nil, the navigator hides disconnected (`○') sessions.
`l' toggles it, leaving a live-only view; the hidden sessions' logs are
untouched and return on the next toggle.")

(defvar-local sprig--status-show-subagents nil
  "When non-nil, the navigator also lists subagents' transcripts.
The CLI logs each subagent it spawns as its own `agent-*' JSONL beside the
session that spawned it (see `sprig--log-subagent-p'); these are not
sessions you drive, so they are hidden by default and `l g' toggles them
in.  It changes the scan itself, so the toggle re-reads the logs.")

;;; Enumerating stored CLI sessions as branches (option A)
;;
;; A branch is a `claude' session; the CLI already stores each as a JSONL
;; log under `sprig-claude-projects-directory'/<encoded-cwd>/.  The
;; navigator scans every log on the host, newest first and capped, reading
;; each session's own cwd and title records; it folds in any open review
;; buffer that owns its session (so a just-started session with no log yet,
;; and live status, both show).  `/' narrows the list, `L' lifts the cap.

(defvar sprig-review--events)           ; buffer-local in sprig-review-mode.el
(defvar sprig-review--meta)             ; buffer-local in sprig-review-mode.el

(defun sprig--owning-review-buffers ()
  "Return the live review buffers that own their own session."
  (seq-filter
   (lambda (b)
     (and (buffer-live-p b)
          (eq (buffer-local-value 'sprig--sink b) #'sprig--review-sink)))
   (buffer-list)))

(declare-function sprig-review-build "sprig-review" (events))
(declare-function sprig-review-pending-dialog "sprig-review" (model))
(declare-function sprig-review--current-model "sprig-review" ())

(defun sprig--buffer-awaiting-answer-p (buf)
  "Non-nil when owning review BUF has a dialog still waiting on the user.
A pending `AskUserQuestion', plan approval, or permission prompt each
count: the CLI is stopped until it hears back, which is what the `waiting'
status flags in the navigator.

Reads BUF's memoised model (`sprig-review--current-model'), not a fresh
`sprig-review-build': this runs per buffer inside `sprig--session-status',
which the navigator collect calls twice a tick, so a fresh O(all events)
build here (and in `sprig--buffer-agent-running-p', and the inline preview)
meant several full rebuilds a tick per active session.  Sharing the memo
collapses them to one."
  (sprig-review-pending-dialog
   (with-current-buffer buf (sprig-review--current-model))))

(defun sprig--buffer-agent-running-p (buf)
  "Non-nil when a background agent BUF's session launched is still running.
Reads the buffer's own events, the same source its render and inline
preview use, so the row agrees with what the review buffer shows.  Via the
memoised model (see `sprig--buffer-awaiting-answer-p'), not a fresh build."
  (and (sprig-review-agent-running
        (with-current-buffer buf (sprig-review--current-model)))
       t))

(defun sprig--session-status (buf)
  "Return the session status for its owning review BUF (nil = not open).
One of `waiting', `streaming', `agent', `idle', or `disconnected'.
`waiting' wins over `streaming': a session stopped on a question of yours
is not working, it is on you, so the navigator says so rather than showing
it as busy.  `agent' is a turn that has ended but left a background agent
still working, which would otherwise read as plain `idle'."
  (cond
   ((not (buffer-live-p buf)) 'disconnected)
   ((and (process-live-p (buffer-local-value 'sprig--process buf))
         (sprig--buffer-awaiting-answer-p buf))
    'waiting)
   ((buffer-local-value 'sprig--busy buf) 'streaming)
   ((process-live-p (buffer-local-value 'sprig--process buf))
    ;; No turn in flight, but a background agent it launched can still be
    ;; working; that is not idle, so only claim idle once none is.
    (if (sprig--buffer-agent-running-p buf) 'agent 'idle))
   (t 'disconnected)))

(defun sprig--status-limit ()
  "Maximum number of stored sessions the navigator lists, or nil for all.
`L' in the navigator sets `sprig--status-show-all' to lift the cap;
otherwise `sprig-status-max-sessions' bounds the newest-first scan."
  (and (not sprig--status-show-all) sprig-status-max-sessions))

(defun sprig--status-hosts ()
  "Return the hosts the navigator lists, in display order.
Always the local machine (nil) first, then each of `sprig-remotes'.  Each
becomes a group with a heading of its own, so every host's sessions show
at once rather than only the configured default's, and each is scanned and
capped independently.  The group point sits in is the host `s' starts a
session on, which is the whole reason an empty group is still headed."
  (delete-dups (cons nil (copy-sequence sprig-remotes))))

(defun sprig--log-ignored-p (file)
  "Non-nil when log FILE's session is hidden per the ignore list.
Matches `sprig-status-ignore-directories' against the log's project
directory name (the CLI's encoded cwd), read straight from the path so no
log content is fetched: an ignored session costs nothing and is dropped
before the newest-N cap."
  (and sprig-status-ignore-directories
       (let ((proj (file-name-nondirectory
                    (directory-file-name (file-name-directory file)))))
         (seq-some (lambda (re) (string-match-p re proj))
                   sprig-status-ignore-directories))))

(defun sprig--log-subagent-p (file)
  "Non-nil when log FILE is a subagent's transcript, not a top-level session.
A real session's log sits directly in its project dir (`<project>/<id>.jsonl');
the CLI writes each subagent it spawns one level deeper, under
`<project>/<id>/subagents/agent-*.jsonl'.  Detected by that parent `subagents'
directory, so it costs no log content: the navigator lists sessions you drive,
so these are dropped unless `l g' (`sprig--status-show-subagents') shows them."
  (string= "subagents"
           (file-name-nondirectory
            (directory-file-name (file-name-directory file)))))

(defun sprig--log-cwd (text)
  "Return the working directory recorded in session-log TEXT, or nil.
Every CLI record carries the session's `cwd', so any slice of the log
holds it; the scan reads the head, where the first record already has it."
  (and (string-match "\"cwd\":\\(\"\\(?:[^\"\\]\\|\\\\.\\)*\"\\)" text)
       (ignore-errors (json-parse-string (match-string 1 text)))))

(defun sprig--log-created (text)
  "Return the session-creation time from log TEXT as an epoch time, or nil.
The log is append-only, so its first record dates the session's creation; its
`timestamp' is read from the same head the `cwd' is (see `sprig--log-cwd'),
the first match winning.  An epoch float, so it sorts and formats like the
scan's mtime (see `sprig--format-time-value')."
  (and text
       (string-match "\"timestamp\":\\(\"\\(?:[^\"\\]\\|\\\\.\\)*\"\\)" text)
       (ignore-errors
         (float-time
          (encode-time
           (iso8601-parse (json-parse-string (match-string 1 text))))))))

(defun sprig--log-title-field (field text)
  "Return the last value of JSON string FIELD in TEXT, or nil.
FIELD is a record key like \"aiTitle\" or \"customTitle\"; the last match
wins, since both the CLI's generated title and a user rename are appended
and re-emitted."
  (let ((title nil) (pos 0)
        (re (concat "\"" (regexp-quote field)
                    "\":\\(\"\\(?:[^\"\\]\\|\\\\.\\)*\"\\)")))
    (while (string-match re text pos)
      (setq title (match-string 1 text) pos (match-end 0)))
    (and title (ignore-errors (json-parse-string title)))))

(defun sprig--log-title (text)
  "Return the session title in session-log TEXT: user title over generated.
A user rename (`/rename', or Sprig's own retitle) appends a `customTitle';
the CLI's generated title is `aiTitle', re-emitted every turn.  A custom
title, once set, is never regenerated, so it always wins; otherwise the last
`aiTitle' does.  TEXT is a log's head or its grepped title lines."
  (or (sprig--log-title-field "customTitle" text)
      (sprig--log-title-field "aiTitle" text)))

(defun sprig--session-log-head (file)
  "Return the leading bytes of session-log FILE, local or remote, or nil.
The scan reads the head for the `cwd', which is in the first record.  The
title is not read from here (a large opening turn can push the first
`ai-title' record past the window); it is grepped whole-file instead."
  (ignore-errors
    (if (sprig--primary-remote)
        (sprig--remote-sh (format "head -c %d %s" sprig--status-preview-bytes
                                  (sprig--remote-dir-arg file)))
      (with-temp-buffer
        (let ((size (file-attribute-size (file-attributes file))))
          (insert-file-contents file nil 0 (min sprig--status-preview-bytes
                                                 size)))
        (buffer-string)))))

(defun sprig--local-title-line (file)
  "Return session-log FILE's title lines, grepped from the whole file.
Matches both the user `customTitle' and the generated `aiTitle'; the title
can sit anywhere (a large opening turn pushes the first past any head
window), so it is grepped rather than read from a slice.  Consulted for a
log past the head window, so the whole-file read is paid only when needed."
  (ignore-errors
    (with-temp-buffer
      (and (eq 0 (call-process "grep" nil t nil "-aE" "customTitle|aiTitle"
                               (expand-file-name file)))
           (buffer-string)))))

(defun sprig--session-log-tail (file)
  "Return the trailing bytes of session-log FILE, local or remote, or nil.
Used for the last-reply preview, which genuinely lives at the end; the
row scan reads the head instead (see `sprig--session-log-head')."
  (ignore-errors
    (if (sprig--primary-remote)
        (sprig--remote-sh (format "tail -c %d %s" sprig--status-preview-bytes
                                  (sprig--remote-dir-arg file)))
      (with-temp-buffer
        (let* ((size (file-attribute-size (file-attributes file)))
               (from (max 0 (- size sprig--status-preview-bytes))))
          (insert-file-contents file nil from size))
        (buffer-string)))))

(defun sprig--log-plist (file mtime head &optional title-fallback whole)
  "Build a scan plist for log FILE with MTIME and its HEAD text.
`:dir' is the session's own recorded `cwd', or nil when HEAD carries none:
the encoded log-directory name is not a real path (its separators are
lossily flattened to dashes), so it is kept only as the display-only
`:project' and never handed to a `cd'.

The title is a user `customTitle' if set, else the last `aiTitle' (see
`sprig--log-title').  When HEAD is the whole file (WHOLE) that title is
already in HEAD.  Otherwise TITLE-FALLBACK, a function returning the log's
grepped title lines (both fields) from the whole file, is preferred, so a
title past the head window, whether a re-emitted `aiTitle' or an appended
rename, still wins; HEAD's title is the backstop."
  (let* ((cwd (and head (sprig--log-cwd head)))
         (head-title (and head (sprig--log-title head)))
         (grep-title (and (not whole) title-fallback
                          (let ((lines (funcall title-fallback)))
                            (and lines (sprig--log-title lines)))))
         (title (or grep-title head-title)))
    (list :session (file-name-base file)
          :file file
          :dir cwd
          :project (or cwd
                       (file-name-nondirectory
                        (directory-file-name (file-name-directory file))))
          :mtime mtime
          :created (and head (sprig--log-created head))
          :title (or title "(untitled)"))))

(defun sprig--scan-session-logs ()
  "Return session plists for the newest stored logs on the session host.
Each plist has :session, :file, :dir (the log's recorded cwd, or nil),
:project (its display label), :mtime, :created (its first record's timestamp,
what the navigator dates and sorts by), and :title.  Sourced host-wide from
`sprig-claude-projects-directory',
newest first, capped to `sprig--status-limit' so a host with hundreds of
sessions still paints fast."
  (if (sprig--primary-remote)
      (sprig--scan-session-logs-remote (sprig--status-limit))
    (sprig--scan-session-logs-local (sprig--status-limit))))

(defun sprig--star-ids-local (root)
  "Ids of every `.sprig-star' marker anywhere under ROOT, as a hash set.
A star lives beside its session's log, but the CLI re-homes a session's log
to a new project directory when it resumes from a different working directory
\(a git worktree, say), stranding the marker in the old one.  Collecting the
ids host-wide lets a star be matched by session id, so it follows the session
across the move rather than being lost with the old directory."
  (let ((set (make-hash-table :test 'equal)))
    (when (file-directory-p root)
      (dolist (f (directory-files-recursively root "\\.sprig-star\\'"))
        (puthash (file-name-base f) t set)))
    set))

(defun sprig--scan-session-logs-local (limit)
  "Scan the LIMIT newest local logs under the session host's projects dir."
  (let* ((root (expand-file-name (sprig--projects-directory)))
         (star-ids (sprig--star-ids-local root))
         (files (seq-remove
                 (lambda (f)
                   (or (sprig--log-ignored-p f)
                       (and (not sprig--status-show-subagents)
                            (sprig--log-subagent-p f))))
                 (and (file-directory-p root)
                      (directory-files-recursively root "\\.jsonl\\'"))))
         (dated (sort (mapcar (lambda (f)
                                (cons (float-time
                                       (file-attribute-modification-time
                                        (file-attributes f)))
                                      f))
                              files)
                      (lambda (a b) (> (car a) (car b))))))
    (when limit (setq dated (seq-take dated limit)))
    (mapcar (lambda (cell)
              (let* ((f (cdr cell))
                     (size (or (file-attribute-size (file-attributes f)) 0)))
                ;; Only a log past the head window pays the whole-file title
                ;; grep; a smaller one carries its last title (re-emitted or an
                ;; appended retitle) inside the head already.
                (let ((pl (sprig--log-plist
                           f (car cell)
                           (sprig--session-log-head f)
                           (lambda () (sprig--local-title-line f))
                           (<= size sprig--status-preview-bytes))))
                  (plist-put pl :starred
                             (or (gethash (file-name-base f) star-ids)
                                 (file-exists-p (sprig--star-file f))))
                  (plist-put pl :live (file-exists-p (sprig--live-file f)))
                  pl)))
            dated)))

(defun sprig--remote-scan-cap (limit)
  "The server-side listing cap for LIMIT: LIMIT, widened for an ignore list.
The scan lists and slurps in one pass, so it cannot list uncapped and slurp
only the survivors the way a two-pass scan would; an ignore list may drop
some of the newest, so a little headroom keeps the capped set full."
  (cond ((null limit) 1000000)
        (sprig-status-ignore-directories (* 2 limit))
        (t limit)))

(defun sprig--remote-scan-all-command (root cap &optional subagents)
  "Shell command listing the CAP newest logs under ROOT with their scan fields.
One SSH round trip does the whole scan: `find | sort | head' picks the newest
logs by mtime, then each is slurped for its mtime, path, star flag, head bytes
(for the `cwd'), its title line (grepped whole-file since it can sit anywhere),
and a trailing live flag.  A user `customTitle' is preferred over the generated
`aiTitle' (see `sprig--log-title'), so the grep looks for it first.  The star
flag is `1' when a `<id>.sprig-star' marker sits beside the log (see
`sprig--star-file'); the trailing live flag is `1' when a `<id>.sprig-live'
broker marker does (see `sprig--live-file'), so the navigator learns which
sessions are still held without a separate query.  Both are tested in the same
loop, so no extra round trip is paid.  Records are RS(\\036)-separated, fields
US(\\037)-separated, for `sprig--parse-scan-rows'.

Subagent transcripts (`.../subagents/agent-*.jsonl', see
`sprig--log-subagent-p') are pruned in the `find' itself unless SUBAGENTS is
non-nil, so they never eat into the newest-N cap.

A leading `stars' record lists every `<id>.sprig-star' marker's id under ROOT,
so a star is matched by session id host-wide rather than only beside the log
it was written next to: the CLI re-homes a session's log to a new project dir
when it resumes from a different working directory (a git worktree), stranding
the marker in the old dir, and id-keying lets the star follow the session
across the move (see `sprig--parse-scan-rows').  The newest-N cap never drops
a star, since the preamble scans them whole."
  (format "printf '\\036stars\\037'; \
find %s -name '*.sprig-star' 2>/dev/null | while IFS= read -r s; do \
b=${s##*/}; printf '%%s\\037' \"${b%%.sprig-star}\"; done; \
find %s -name '*.jsonl'%s -printf '%%T@\\t%%p\\n' 2>/dev/null \
| sort -rn | head -n %d | while IFS='\t' read -r m p; do \
printf '\\036%%s\\037%%s\\037' \"$m\" \"$p\"; \
[ -e \"${p%%.jsonl}.sprig-star\" ] && printf 1; \
printf '\\037'; head -c %d \"$p\"; \
printf '\\037'; t=$(grep -a customTitle \"$p\" | tail -1); \
[ -z \"$t\" ] && t=$(grep -a aiTitle \"$p\" | tail -1); printf '%%s' \"$t\"; \
printf '\\037'; [ -e \"${p%%.jsonl}.sprig-live\" ] && printf 1; :; done"
          root
          root
          (if subagents "" " -not -path '*/subagents/*'")
          cap sprig--status-preview-bytes))

(defun sprig--parse-scan-rows (blob limit)
  "Parse BLOB from `sprig--remote-scan-all-command' into scan plists.
Records are RS(\\036)-separated; each is mtime, path, star flag, head bytes,
the `ai-title' line, and a trailing live flag, US(\\037)-separated.  The star
and live flags are `1' when a `.sprig-star' or `.sprig-live' marker sits
beside the log, else empty (live means the broker still holds the session).
The live flag is last and optional, so an older blob without it still parses,
its session simply not live.

A leading `stars' record (its first field the literal `stars', the rest a
US-separated list of ids) names every starred session host-wide; a row is
starred when its own id is in that set or its per-log star flag is `1', so a
star found by id in a re-homed session's old directory still counts (see
`sprig--remote-scan-all-command').  An older blob without the record just
falls back to the per-log flag.  Ignored logs
are
dropped and the rest capped to LIMIT, newest first, matching
`sprig--scan-session-logs'.  The head holds no US byte in any real log, so it
is bounded by the separators around it."
  (let ((chunks (and blob (split-string blob "\036" t)))
        (star-ids (make-hash-table :test 'equal))
        rows)
    (dolist (chunk chunks)
      (let ((p1 (string-search "\037" chunk)))
        (when (and p1 (equal (substring chunk 0 p1) "stars"))
          (dolist (id (split-string (substring chunk (1+ p1)) "\037" t))
            (puthash id t star-ids)))))
    (dolist (chunk chunks)
      (let ((p1 (string-search "\037" chunk)))
        (when (and p1 (not (equal (substring chunk 0 p1) "stars")))
          (let* ((mtime (string-to-number (substring chunk 0 p1)))
                 (rest1 (substring chunk (1+ p1)))
                 (p2 (string-search "\037" rest1)))
            (when p2
              (let* ((path (substring rest1 0 p2))
                     (rest2 (substring rest1 (1+ p2)))
                     (p3 (string-search "\037" rest2)))
                (when p3
                  (let* ((star (not (string-empty-p (substring rest2 0 p3))))
                         (rest3 (substring rest2 (1+ p3)))
                         (p4 (string-search "\037" rest3))
                         (head (if p4 (substring rest3 0 p4) rest3))
                         ;; The tail past the head is the title, or `title US
                         ;; live-flag' when the newer scan appended the flag; an
                         ;; older blob without it just has no live field.
                         (tail (and p4 (substring rest3 (1+ p4))))
                         (p5 (and tail (string-search "\037" tail)))
                         (live (and p5 (not (string-empty-p
                                             (substring tail (1+ p5))))))
                         (raw (string-trim (if p5 (substring tail 0 p5)
                                             (or tail ""))))
                         (title (and (not (string-empty-p raw)) raw)))
                    (unless (sprig--log-ignored-p path)
                      (let ((pl (sprig--log-plist
                                 path mtime head (lambda () title))))
                        (plist-put pl :starred
                                   (or star (gethash (plist-get pl :session)
                                                     star-ids)))
                        (push (plist-put pl :live live) rows)))))))))))
    (setq rows (nreverse rows))
    (if limit (seq-take rows limit) rows)))

(defun sprig--scan-session-logs-remote (limit)
  "Scan the newest remote logs under `sprig-claude-projects-directory'.
One SSH round trip: `sprig--remote-scan-all-command' lists the newest logs
and slurps each one's fields, and `sprig--parse-scan-rows' turns the blob into
plists.  LIMIT caps the set.  This is the synchronous entry (it blocks on the
round trip); the navigator drives the same scan in the background instead (see
`sprig--status-scan-async')."
  (let* ((root (sprig--remote-dir-arg
                (directory-file-name (sprig--projects-directory))))
         (blob (ignore-errors
                 (sprig--remote-sh
                  (sprig--remote-scan-all-command
                   root (sprig--remote-scan-cap limit)
                   sprig--status-show-subagents)))))
    (sprig--parse-scan-rows blob limit)))

;;; Last-reply preview

(defun sprig--collapse-whitespace (text)
  "Return TEXT with runs of whitespace collapsed to single spaces, trimmed."
  (string-trim (replace-regexp-in-string "[ \t\n]+" " " text)))

(defun sprig--normalize-prose (text)
  "Return TEXT with each paragraph collapsed to a re-wrappable line, or nil.
Blank-line paragraph breaks are kept (one blank line between paragraphs) so
the result fills cleanly while still reading as paragraphs; nil when empty."
  (let ((paras (delq nil
                     (mapcar (lambda (p)
                               (let ((c (sprig--collapse-whitespace p)))
                                 (unless (string-empty-p c) c)))
                             (split-string (or text "") "\n[ \t]*\n" t)))))
    (and paras (string-join paras "\n\n"))))

(defun sprig--tidy-prose (text)
  "Return TEXT trimmed with runs of blank lines squeezed to one, or nil.
Single line breaks are kept so lists and headings survive to the preview's
markdown pass; nil when TEXT holds no non-blank content."
  (let ((s (string-trim
            (replace-regexp-in-string "\n\\(?:[ \t]*\n\\)+" "\n\n" (or text "")))))
    (and (not (string-empty-p s)) s)))

(defun sprig--format-time-value (time)
  "Return TIME (any `format-time-string' value) as a short local string, or nil.
A stamp from today shows the clock alone; an older one is prefixed with its
month and day.  nil when TIME is nil."
  (and time
       (format-time-string
        (if (string= (format-time-string "%Y-%m-%d" time)
                     (format-time-string "%Y-%m-%d"))
            "%H:%M"
          "%m-%d %H:%M")
        time)))

(defun sprig--format-time (iso)
  "Return ISO, an ISO 8601 timestamp, as a short local time string, or nil.
Formatted like `sprig--format-time-value'; nil when ISO is missing or cannot
be parsed."
  (when (stringp iso)
    (ignore-errors
      (sprig--format-time-value (encode-time (iso8601-parse iso))))))

(defun sprig--events-preview (events)
  "Return a preview plist for EVENTS' conversation tail, or nil.
The plist is (:prompt STR :reply STR :time ISO :context N :done BOOL :error
BOOL :mode STR :pending BOOL :agent-running BOOL): the last user turn
collapsed to a line, the
agent's final message that answered it (only the last text block of that
turn, not the running narration between its tool calls, its structure kept
for the markdown pass), the stamp of the freshest block, and the turn's
outcome, context size, and permission mode for the preview's state line.
When the turn since your prompt carried no prose (it ended on a tool call or
a question), or there is no user turn at all, the reply falls back to the
last assistant text anywhere.  EVENTS are chronological (the review model's
input order).

Building the model is O(all events); an owning buffer already has one, so
`sprig--entry-preview' hands its cached model to `sprig--model-preview'
directly rather than rebuilding it here."
  (sprig--model-preview (ignore-errors (sprig-review-build events))))

(defun sprig--model-preview (model)
  "Return a preview plist for a built review MODEL, or nil.
The extraction half of `sprig--events-preview' (which see for the plist),
split out so a caller holding a model already built need not build another."
  (let* ((blocks (and model (plist-get model :blocks))))
    (when blocks
      (let* ((last-user (let ((pos nil) (i 0))
                          (dolist (b blocks)
                            (when (eq (plist-get b :type) 'user) (setq pos i))
                            (setq i (1+ i)))
                          pos))
             (prompt-block (and last-user (nth last-user blocks)))
             (prompt (and prompt-block
                          (sprig--collapse-whitespace
                           (plist-get prompt-block :text))))
             ;; The reply block itself, so the preview can date it (its `:time'):
             ;; the last prose of the turn that answered the prompt, or the last
             ;; prose anywhere when that turn carried none.
             (reply-block (or (and last-user
                                   (seq-find
                                    (lambda (b) (eq (plist-get b :type) 'text))
                                    (reverse (nthcdr (1+ last-user) blocks))))
                              (seq-find
                               (lambda (b) (eq (plist-get b :type) 'text))
                               (reverse blocks))))
             (reply (and reply-block (sprig--tidy-prose
                                      (plist-get reply-block :text)))))
        (let ((prompt* (and prompt (not (string-empty-p prompt)) prompt))
              (ctx (plist-get model :context))
              (done (plist-get model :done))
              (err (plist-get model :error))
              (mode (plist-get model :mode))
              (pending (and (sprig-review-pending-dialog model) t))
              (agent-running (and (sprig-review-agent-running model) t)))
          (when (or prompt* reply ctx done err pending mode agent-running)
            (list :prompt prompt* :reply reply
                  :time (plist-get (car (last blocks)) :time)
                  ;; Each side's own block time, so the navigator can date the
                  ;; prompt and the reply on their own lines (see
                  ;; `sprig--status-preview-lines').
                  :prompt-time (and prompt* (plist-get prompt-block :time))
                  :reply-time (and reply (plist-get reply-block :time))
                  :context ctx :done done :error err :mode mode
                  :pending pending :agent-running agent-running)))))))

(defun sprig--entry-preview (entry)
  "Return the inline preview plist for status ENTRY, or nil.
From the open review buffer's model when ENTRY has one, else the stored
session log's tail, read on the host that row's session ran on rather than
the configured default: with a group per host the two are often not the
same, and the wrong one has no such log.

An open buffer's model is taken from `sprig-review--current-model', which
memoises the build the buffer's own render already paid for, so the
navigator does not rebuild the whole transcript on every refresh."
  (let ((buf (plist-get entry :buffer))
        (file (plist-get entry :file))
        (sprig-remotes (list (plist-get entry :host))))
    (cond
     ((buffer-live-p buf)
      (sprig--model-preview
       (with-current-buffer buf (sprig-review--current-model))))
     (file
      (let ((tail (sprig--session-log-tail file)))
        (and tail (sprig--events-preview
                   (sprig-review-session-events (split-string tail "\n" t)))))))))

;;; Collect open buffers and stored sessions into rows

(defvar sprig--status-scan-cache nil
  "Cached log scan per host and root: an alist of (HOST . ROOT) -> (TIME . ROWS).
The navigator re-renders on every stream event (coalesced to at most one a
second), but the stored logs on disk do not change within a turn except the
live session's own, whose row is built from its owning buffer, not this scan.
So the scan is cached and reused across those live re-renders, which would
otherwise re-read every session log each second on the main thread; for a
remote host that read is a blocking SSH round trip that freezes all of Emacs.
`sprig--status-scan-invalidate' marks it stale at structural moments (a session
opening, starting, ending, or being removed, or a manual revert), keeping the
rows for display; the next render re-scans in the background (local or remote,
see `sprig--status-scan-async').  `sprig--status-scan-cache-ttl' is a
backstop.")

(defvar sprig--status-scan-cache-ttl 10.0
  "Seconds a cached navigator log scan is reused before a forced re-scan.
A backstop under the structural invalidation in `sprig--status-scan-invalidate',
so a session another process creates still surfaces during a long streaming
turn.  A live session's own row never goes through this cache, never stale.")

(defvar sprig--status-remote-scan-hosts nil
  "Hosts with a background navigator scan in flight, so one runs per host.
nil is the local machine, a valid element like any SSH destination.")

(defun sprig--status-scan-cached (host)
  "Return the cached log scan for HOST, refreshing it when it is stale.
A fresh cache (younger than `sprig--status-scan-cache-ttl' and not
invalidated) is returned as is.  When it is stale but rows are already cached,
they are returned at once and a background scan refreshes them (see
`sprig--status-scan-async'), so neither the disk read nor an SSH round trip
ever blocks the recurring render.  A cold cache with nothing to show yet scans
in the background too for a remote host, so even the first open never waits on
the network; only a cold local host scans synchronously, a cheap capped `find'
paid once at the first open so the list paints populated.
Keyed on the projects root too, so a `sprig-config-directory' switch (and each
test's own root) re-reads.  This is what keeps a streaming turn's navigator
re-render off the disk and off SSH (see `sprig--status-scan-cache')."
  (let* ((key (cons host (sprig--projects-directory)))
         (cell (assoc key sprig--status-scan-cache))
         (age (and cell (float-time (time-subtract (current-time) (cadr cell))))))
    (cond
     ((and age (< age sprig--status-scan-cache-ttl)) (cddr cell))
     ;; Stale, with rows to show: refresh in the background, never block.  This
     ;; is every recurring refresh once the cache is warm, local or remote.
     (cell
      (sprig--status-scan-async host)
      (cddr cell))
     ;; Cold remote: scan in the background too and show nothing yet, so even
     ;; the navigator's first open never waits on an SSH round trip.  The
     ;; repaint lands when the scan does.
     (host
      (sprig--status-scan-async host)
      nil)
     ;; Cold local: one synchronous disk scan, once at the navigator's first
     ;; open.  A capped local `find' is cheap and on no network, so the single
     ;; blocking read is imperceptible and keeps the first paint populated.
     ;; `sprig-remotes' is bound to the host alone (nil) so the scan runs
     ;; locally even when a remote is configured as the session default.
     (t
      (let ((rows (let ((sprig-remotes (list host))) (sprig--scan-session-logs))))
        (setf (alist-get key sprig--status-scan-cache nil nil #'equal)
              (cons (current-time) rows))
        ;; The async scan reattaches held sessions from its sentinel and
        ;; verifies their markers; this synchronous first read must do the
        ;; same, or a broker-held (or stale-marked) local session sits
        ;; unprobed and unverified until an async re-scan happens.
        (sprig--status-reattach-live host rows)
        (sprig--status-verify-live host rows)
        rows)))))

(defun sprig--status-scan-async (host)
  "Scan HOST's logs in a background process, then cache and re-render.
HOST is nil for the local machine (the scan runs in a bare `sh -c') or an SSH
destination (the same scan wrapped in `ssh').  Either way the shell does the
`find | sort | head | slurp' off the main thread, so the navigator never
blocks: `sprig--status-scan-cached' shows the last cached rows (or none yet)
and this repaints when the process lands.  One scan per host runs at a time,
so a burst of stale reads spawns just one; the sentinel drops the in-flight
mark, caches the parsed rows, and refreshes the open navigator."
  (unless (member host sprig--status-remote-scan-hosts)
    (let* ((sprig-remotes (list host))
           (limit (sprig--status-limit))
           (key (cons host (sprig--projects-directory)))
           (root (if host
                     (sprig--remote-dir-arg
                      (directory-file-name (sprig--projects-directory)))
                   (shell-quote-argument
                    (directory-file-name
                     (expand-file-name (sprig--projects-directory))))))
           (command (sprig--remote-scan-all-command
                     root (sprig--remote-scan-cap limit)
                     sprig--status-show-subagents))
           ;; A local scan must launch from a local directory: a remote
           ;; `default-directory' would send the `sh' through TRAMP and defeat
           ;; the point.  The `ssh' command is explicit, so a local cwd suits
           ;; it too.
           (default-directory temporary-file-directory)
           (buffer (generate-new-buffer " *sprig-status-scan*"))
           (proc (make-process
                  :name "sprig-status-scan" :buffer buffer :noquery t
                  :connection-type 'pipe
                  :command (if host
                               (append (list sprig-ssh-program) sprig-ssh-args
                                       (list host (concat "sh -c "
                                                          (shell-quote-argument
                                                           command))))
                             (list "sh" "-c" command)))))
      (push host sprig--status-remote-scan-hosts)
      (set-process-sentinel
       proc
       (lambda (p _event)
         (when (memq (process-status p) '(exit signal))
           (setq sprig--status-remote-scan-hosts
                 (delete host sprig--status-remote-scan-hosts))
           (when (and (eq (process-exit-status p) 0)
                      (buffer-live-p (process-buffer p)))
             (let ((rows (sprig--parse-scan-rows
                          (with-current-buffer (process-buffer p) (buffer-string))
                          limit)))
               (setf (alist-get key sprig--status-scan-cache nil nil #'equal)
                     (cons (current-time) rows))
               ;; Now that this host's rows are known, reattach any the broker
               ;; still holds (see `sprig-status-auto-reattach'), and verify
               ;; the held claims themselves (a stranded marker must not show
               ;; a dead session as running; see `sprig--status-verify-live').
               (sprig--status-reattach-live host rows)
               (sprig--status-verify-live host rows)))
           (when (buffer-live-p (process-buffer p))
             (kill-buffer (process-buffer p)))
           (sprig--status-render-if-live)))))))

(defun sprig--status-scan-invalidate ()
  "Mark every cached log scan stale so the next render re-reads it.
The rows are kept for display, only the timestamp is expired: a group then
shows its last rows while a background re-scan runs rather than blanking to
nothing.  Called when the stored set can have changed under the navigator: it
is opened or reverted, or a session starts, opens, is removed, or ends."
  (dolist (cell sprig--status-scan-cache)
    (setcar (cdr cell) 0)))

(defun sprig--status-scan-cache-set-star (host session starred)
  "Set the STARRED flag on HOST's cached scan row for SESSION, if cached.
A star toggle has to show at once, but the next render reuses the cache
while the scan that would confirm it runs in the background (see
`sprig--status-scan-cached'), so the flag is patched into the cache too,
not only written to disk beside the log."
  (let ((cell (assoc (cons host (sprig--projects-directory))
                     sprig--status-scan-cache)))
    (when cell
      (dolist (row (cddr cell))
        (when (equal (plist-get row :session) session)
          (plist-put row :starred starred))))))

(defun sprig--status-scan-cache-set-live (host session live)
  "Set the LIVE flag on HOST's cached scan row for SESSION, if cached.
A marker proven stale is removed from disk, but the cached row would keep
saying held until the next background scan; patching the cache lets the
repaint show the truth at once (compare `sprig--status-scan-cache-set-star')."
  (let ((cell (assoc (cons host (sprig--projects-directory))
                     sprig--status-scan-cache)))
    (when cell
      (dolist (row (cddr cell))
        (when (equal (plist-get row :session) session)
          (plist-put row :live live))))))

(defun sprig--verify-live-apply (host rows json)
  "Reconcile ROWS' `:live' flags against the broker's `list' answer JSON.
Every `:live' row whose session the broker does not name is stale: its
marker is removed on HOST, its cached row downgraded, and non-nil returned
so the caller repaints.  A JSON that does not parse to an `ok' listing
proves nothing and changes nothing (nil).  The held set is matched on the
broker's `cli_session_id', the same id the marker and the log carry."
  (let* ((data (ignore-errors
                 (json-parse-string json :object-type 'alist
                                    :null-object nil)))
         (ok (and data (eq (alist-get 'ok data) t)))
         (held (and ok (mapcar (lambda (s) (alist-get 'cli_session_id s))
                               (append (alist-get 'sessions data) nil))))
         (changed nil))
    (when ok
      (dolist (row rows)
        (let ((id (plist-get row :session)))
          (when (and (plist-get row :live) id (not (member id held)))
            (sprig--remove-live-marker id host)
            (sprig--status-scan-cache-set-live host id nil)
            (setq changed t)))))
    changed))

(defun sprig--status-verify-live (host rows)
  "Check HOST's broker really holds ROWS' `:live' sessions, in the background.
The scan takes a `<id>.sprig-live' marker on faith, but a daemon that died
without cleanup (a machine restart) strands its markers, and a dead session
then shows as running for good.  So one `list' query asks the broker what
it actually holds, and `sprig--verify-live-apply' cleans up any row it
cannot vouch for.  The broker's `list' answers an empty set without
starting a daemon when none runs; a transport failure exits nonzero,
proving nothing, and nothing is touched.  A no-op when no row claims to be
live or the broker does not cover HOST."
  (when (and (seq-some (lambda (r) (plist-get r :live)) rows)
             (if host (sprig--broker-remote-p) (sprig--broker-local-p)))
    (let* ((buffer (generate-new-buffer " *sprig-broker-list*"))
           (proc
            (if host
                (apply #'start-process "sprig-broker-list" buffer
                       sprig-ssh-program
                       (append sprig-ssh-args
                               (list host
                                     (concat "python3 "
                                             (sprig--remote-dir-arg
                                              sprig-broker-remote-path)
                                             " list"))))
              (let ((process-environment
                     (cons (concat "XDG_RUNTIME_DIR="
                                   (sprig--broker-local-runtime-dir))
                           process-environment)))
                (start-process "sprig-broker-list" buffer
                               "python3" (sprig--broker-local-path) "list")))))
      (set-process-query-on-exit-flag proc nil)
      (set-process-sentinel
       proc
       (lambda (p _event)
         (when (memq (process-status p) '(exit signal))
           (let ((buf (process-buffer p)))
             (when (and (eq (process-exit-status p) 0) (buffer-live-p buf))
               (when (sprig--verify-live-apply
                      host rows (with-current-buffer buf (buffer-string)))
                 (sprig--status-render-if-live)))
             (when (buffer-live-p buf) (kill-buffer buf)))))))))

(defun sprig--status-collect ()
  "Return status plists for all branches, grouped by the host they run on.
Each plist has :key, :host (nil for local, else an SSH destination),
:buffer (or nil), :file (or nil), :dir (a real working directory or nil),
:project (its display label), :title, :status, :session, :mtime (its log's
last-run time), and :created (its creation time, what the list dates and sorts
by).  An open session-owning review buffer wins over its stored log, carrying
live status and a session with no log yet.

The :key pairs the host with the session id, because an id is only unique
on the host that issued it: two hosts can hand out the same one and they
are still two different sessions.  Rows come back ordered by
`sprig--status-group-hosts', so the render can head each group in turn.
When `sprig--status-filter' is set, only rows matching it are returned; a
group filtered down to nothing keeps its heading all the same."
  (let ((table (make-hash-table :test 'equal))
        (order '())
        (buffer-hosts '()))
    (dolist (buf (sprig--owning-review-buffers))
      (let* ((host (sprig--buffer-remote buf))
             (id (buffer-local-value 'sprig--session-id buf))
             ;; A fork resumes the parent's id until the CLI answers with its
             ;; own.  Key such a fork-in-flight by its buffer, not that shared
             ;; id, so it does not mask the parent's own row (its stored log, or
             ;; its open buffer) during the handover: they would otherwise
             ;; collapse into one row and the original would look gone until the
             ;; fork got its id.  Once it does, the fork flag clears and it keys
             ;; by id like any other session.
             (forking (buffer-local-value 'sprig--fork-session buf))
             (key (cons host (if forking buf (or id buf)))))
        (push host buffer-hosts)
        (unless (gethash key table)
          (push key order)
          (puthash key
                   (list :key key :host host :buffer buf :file nil
                         :dir (buffer-local-value 'sprig--working-dir buf)
                         :project (buffer-local-value 'sprig--working-dir buf)
                         ;; A manual retitle wins; else the replayed
                         ;; `ai-title' from the buffer's events.  Still nil
                         ;; for a fresh live session, whose stream carries no
                         ;; title: the scan below borrows it from the log.
                         :title (or (plist-get (buffer-local-value
                                                'sprig-review--meta buf)
                                               :title)
                                    (sprig-review-events-title
                                     (buffer-local-value 'sprig-review--events buf)))
                         :status (sprig--session-status buf)
                         ;; Live buffer-local state, like the status: a message
                         ;; held for the running turn is invisible otherwise
                         ;; (nothing was sent), so carry its count for the state
                         ;; line the way the review buffer shows it.
                         :queued (length (buffer-local-value 'sprig--queued buf))
                         :session id)
                   table))))
    ;; Scan the configured hosts, plus any a buffer row is pinned to that is
    ;; not among them: a session opened on a host since dropped from
    ;; `sprig-remotes' still has an open buffer and a group of its own (see
    ;; `sprig--status-group-hosts'), so it must still get its log-scan pass, or
    ;; it would render with no creation time, last-run time, or log-borrowed
    ;; title.  `sprig--status-hosts' leads, so it keeps its order; the extras
    ;; follow in the order their buffers were seen.
    (dolist (host (delete-dups (append (sprig--status-hosts)
                                       (nreverse buffer-hosts))))
      ;; The scan, and everything it reaches (the head slurp, the SSH round
      ;; trips), keys off the primary remote, which `sprig--status-scan-cached'
      ;; binds per host as the sole entry: one host per pass, each with a cap
      ;; of its own so a busy host cannot crowd the other out, and each cached
      ;; so a live re-render reuses it rather than re-reading the disk.
      (dolist (e (sprig--status-scan-cached host))
        (let* ((key (cons host (plist-get e :session)))
               (existing (gethash key table)))
          (cond
           ((null existing)
            (push key order)
            (puthash key
                     (list :key key :host host :buffer nil
                           :file (plist-get e :file)
                           :dir (plist-get e :dir)
                           :project (plist-get e :project)
                           :title (plist-get e :title)
                           ;; A session the broker still holds is alive on its
                           ;; host though no buffer here owns it: `held', not
                           ;; `disconnected', so it survives the live filter and
                           ;; reads as alive.
                           :status (if (plist-get e :live) 'held 'disconnected)
                           :mtime (plist-get e :mtime)
                           :created (plist-get e :created)
                           :starred (plist-get e :starred)
                           :live (plist-get e :live)
                           :session (plist-get e :session))
                     table))
           ;; An owning buffer borrows the log's mtime (so an open row shows
           ;; when it last ran too), its creation time (what the list sorts and
           ;; dates by), and its title, if it could not title itself.
           (t
            (unless (plist-get existing :title)
              (setq existing (plist-put existing :title (plist-get e :title))))
            (unless (plist-get existing :mtime)
              (setq existing (plist-put existing :mtime (plist-get e :mtime))))
            (unless (plist-get existing :created)
              (setq existing (plist-put existing :created (plist-get e :created))))
            ;; The star lives beside the log, so an open row learns it from the
            ;; scan too, along with the log path the toggle needs to find it.
            (unless (plist-get existing :file)
              (setq existing (plist-put existing :file (plist-get e :file))))
            (setq existing (plist-put existing :starred (plist-get e :starred)))
            (setq existing (plist-put existing :live (plist-get e :live)))
            (puthash key existing table))))))
    (let ((rows (mapcar (lambda (k)
                          (let ((e (gethash k table)))
                            (if (plist-get e :title)
                                e
                              (plist-put e :title "(untitled)"))))
                        (nreverse order))))
      (when (and sprig--status-filter (not (string-empty-p sprig--status-filter)))
        (setq rows (seq-filter
                    (lambda (e) (sprig--entry-matches-filter e sprig--status-filter))
                    rows)))
      (when sprig--status-hide-disconnected
        (setq rows (seq-remove
                    (lambda (e) (eq (plist-get e :status) 'disconnected))
                    rows)))
      (sprig--status-sort-by-group (sprig--status-sort-rows rows)
                                   (sprig--status-group-hosts rows)))))

(defun sprig--status-group-hosts (rows)
  "Return the ordered group hosts for ROWS.
`sprig--status-hosts' leads, so both groups head the list even when one of
them has no rows.  Any other host a row actually came from follows: a
review buffer pinned to a host no longer in `sprig-remotes' is still a
live session you can steer, so it gets a group of its own rather than
being filed under someone else's heading."
  (let ((hosts (sprig--status-hosts)))
    (dolist (row rows)
      (let ((host (plist-get row :host)))
        (unless (member host hosts)
          (setq hosts (append hosts (list host))))))
    hosts))

(defun sprig--status-sort-by-group (rows hosts)
  "Order ROWS by their host's position in HOSTS.
`sort' is stable, so within a group the rows keep the column order
`sprig--status-sort-rows' gave them."
  (let ((rank (make-hash-table :test 'equal))
        (n 0))
    (dolist (host hosts)
      (puthash host n rank)
      (setq n (1+ n)))
    (sort (copy-sequence rows)
          (lambda (a b) (< (gethash (plist-get a :host) rank 0)
                           (gethash (plist-get b :host) rank 0))))))

(defvar-local sprig--status-sort '("Created" . t)
  "Active navigator sort as (COLUMN-NAME . DESCENDING-P).
Applied within each host group, before the stable group sort, so the two
groups stay apart while their rows order by the chosen column.  The default
sorts by `Created' descending, newest-created first: unlike a last-activity
sort, a session then keeps its place as it runs rather than jumping to the top
each turn.  `sprig-status-sort' changes it.")

(defun sprig--status-entry-created (entry)
  "Return ENTRY's sort key: its session-creation time, or now if it has none.
A live session not yet written to a log is the freshest thing there is, so it
sorts to the top of a newest-first list rather than the bottom."
  (or (plist-get entry :created) most-positive-fixnum))

(defun sprig--status-rank (status)
  "Return a sort rank for STATUS, busiest (streaming) first."
  (pcase status
    ('streaming 0) ('agent 1) ('waiting 2) ('idle 3) ('interrupted 4)
    ('held 5) (_ 6)))

(defun sprig--status-row-less (name)
  "Return an ascending `sort' predicate over status entries for column NAME."
  (pcase name
    ("Created" (lambda (a b) (< (sprig--status-entry-created a)
                                (sprig--status-entry-created b))))
    ("S" (lambda (a b) (< (sprig--status-rank (plist-get a :status))
                          (sprig--status-rank (plist-get b :status)))))
    (_ (let ((k (pcase name ("Title" :title) ("Project" :project) (_ :session))))
         (lambda (a b) (string-lessp (downcase (or (plist-get a k) ""))
                                     (downcase (or (plist-get b k) ""))))))))

(defun sprig--star-file (log)
  "Return the star-marker path beside session LOG (an `<id>.jsonl' path).
A star is simply the presence of this `<id>.sprig-star' file next to the
CLI's own log, on whichever host the log lives; the CLI ignores it."
  (concat (file-name-sans-extension log) ".sprig-star"))

(defun sprig--live-file (log)
  "Return the broker live-marker path beside session LOG (an `<id>.jsonl').
The broker touches this `<id>.sprig-live' file while it holds the session
and removes it when the session ends, so the scan learns which sessions are
still held without querying the broker (see the broker script)."
  (concat (file-name-sans-extension log) ".sprig-live"))

(defun sprig--status-starred-p (entry)
  "Non-nil when ENTRY's session carries a star marker.
The flag rides in on the log scan, which matches the star by session id
host-wide so it follows a re-homed log (see `sprig--parse-scan-rows' and
`sprig--star-ids-local'), so reading it here costs nothing."
  (plist-get entry :starred))

(defun sprig--status-sort-rows (rows)
  "Sort ROWS by `sprig--status-sort' ahead of the stable group sort, so the
column order becomes the order within each host group.  Starred sessions
float above the rest of their group whatever the column and direction,
keeping the column order among themselves."
  (pcase-let ((`(,name . ,desc) (or sprig--status-sort '("Created" . t))))
    (let ((less (sprig--status-row-less name)))
      (sort (copy-sequence rows)
            (lambda (a b)
              (let ((sa (sprig--status-starred-p a))
                    (sb (sprig--status-starred-p b)))
                (cond ((and sa (not sb)) t)
                      ((and sb (not sa)) nil)
                      (desc (funcall less b a))
                      (t (funcall less a b)))))))))

(defun sprig--entry-matches-filter (entry filter)
  "Non-nil if ENTRY's project label or title contains FILTER.
Matching is case-insensitive."
  (let ((case-fold-search t)
        (needle (regexp-quote filter)))
    (or (string-match-p needle (or (plist-get entry :project) ""))
        (string-match-p needle (or (plist-get entry :title) "")))))

;;; tabulated-list rendering

(defun sprig--status-face (status)
  "Return the face used for STATUS."
  (pcase status
    ('streaming 'warning)
    ('agent 'warning)
    ('waiting 'sprig-review-waiting)
    ('idle 'success)
    ('held 'success)
    ('interrupted 'font-lock-comment-face)
    (_ 'shadow)))

(defvar-local sprig--status-index nil
  "Hash mapping the current render's entry ids to their status plists.")

(defvar-local sprig--status-groups nil
  "Ordered host groups of the current render, from `sprig--status-group-hosts'.
The printed rows are in this order, so `sprig--status-decorate' can head
each group by walking the two in step.")

(defvar sprig--status-render-rows nil
  "Rows already collected for the render in progress, or nil.
`sprig--status-render-if-live' collects once for its signature check, then
renders; without this the render's `sprig--status-entries' would collect a
second time in the same synchronous pass (no event lands between them, so the
two are identical).  Bound to that first collect for the span of the render, it
lets the entry build reuse it rather than repeat the whole scan and status
sweep.  nil off the live path, where each caller collects fresh.")

(defun sprig--status-entries ()
  "Build `tabulated-list-entries' from `sprig--status-collect'.
Reuses `sprig--status-render-rows' when the live path already collected this
pass, else collects fresh.  The entry id is the entry's `:key' (its host paired
with its session id, else with its buffer): stable across refreshes, so point
survives."
  (let ((index (make-hash-table :test 'equal))
        (collected (or sprig--status-render-rows (sprig--status-collect)))
        rows)
    (setq sprig--status-groups (sprig--status-group-hosts collected))
    (dolist (e collected)
      (let* ((id (plist-get e :key))
             (status (plist-get e :status))
             (dir (plist-get e :project))
             (session (plist-get e :session))
             (glyph (propertize (or (alist-get status sprig--status-glyphs) "?")
                                'face (sprig--status-face status))))
        ;; Every row is indexed so its host's heading still counts it and a
        ;; later unfold can find it; a collapsed host just prints none.
        (puthash id e index)
        (unless (sprig--status-collapsed-p (plist-get e :host))
          (push (list id
                      (vector glyph
                              (let ((project (if dir (file-name-nondirectory
                                                      (directory-file-name dir))
                                               "-")))
                                (if (sprig--status-starred-p e)
                                    (concat (propertize "★ " 'face
                                                        'sprig-status-star)
                                            project)
                                  project))
                              (or (plist-get e :title) "")
                              (if (and (stringp session) (> (length session) 0))
                                  (substring session 0 (min 8 (length session)))
                                "-")
                              (propertize
                               (or (sprig--format-time-value (plist-get e :created))
                                   "-")
                               'face 'sprig-status-preview)))
                rows))))
    (setq sprig--status-index index)
    (setq mode-line-process
          (concat (and sprig--status-filter
                       (format " /%s" sprig--status-filter))
                  (and sprig--status-show-all " [all]")
                  (and sprig--status-show-subagents " [+sub]")
                  (and sprig--status-hide-disconnected " [live]")
                  (when sprig--status-sort
                    (format " %s%s" (if (cdr sprig--status-sort) "↓" "↑")
                            (car sprig--status-sort)))))
    (nreverse rows)))

;;; Inline reply previews

(defun sprig--status-entry-active-p (entry)
  "Non-nil when ENTRY is a live session rather than a disconnected log.
An active session has an owning review buffer, so its status is one of the
live states rather than `disconnected'.  The navigator keeps such a row's
inline preview open at all times; a disconnected row shows only its own
line, and you open it with RET for the full transcript."
  (not (eq (plist-get entry :status) 'disconnected)))

;;; Collapsing a host group to its heading

(defvar-local sprig--status-collapsed nil
  "Hash set of hosts whose group is folded to its heading alone.
A collapsed host keeps its rows in `sprig--status-index' (so its heading
still counts them) but contributes none to `tabulated-list-entries', so
they are simply not printed.  TAB on a heading toggles it.")

(defun sprig--status-collapsed-p (host)
  "Non-nil when HOST's group is collapsed to its heading."
  (and sprig--status-collapsed (gethash host sprig--status-collapsed)))

(defun sprig--status-toggle-collapse (host)
  "Fold or unfold HOST's group, then re-render and land on its heading.
Point is put back on the heading rather than left to `tabulated-list-print',
whose row-restore has nothing to grab when the line under point is a
heading and not a row."
  (unless sprig--status-collapsed
    (setq sprig--status-collapsed (make-hash-table :test 'equal)))
  (if (gethash host sprig--status-collapsed)
      (remhash host sprig--status-collapsed)
    (puthash host t sprig--status-collapsed))
  (sprig--status-render)
  (sprig--status-goto-heading host))

(defun sprig--status-goto-heading (host)
  "Move point to HOST's group heading; return non-nil when one was found."
  (goto-char (point-min))
  (let (found)
    (while (and (not found) (not (eobp)))
      (if (and (get-text-property (line-beginning-position) 'sprig--status-heading)
               (equal (sprig--status-host-at-point) host))
          (setq found t)
        (forward-line 1)))
    (beginning-of-line)
    found))

(defun sprig--status-reply-oneline (reply)
  "Return REPLY collapsed to a single line of prose for the inline preview.
Paragraph breaks and wrapping are dropped to whitespace, since the row
shows only a one-line teaser; RET opens the review buffer for the whole
reply."
  (sprig--collapse-whitespace (or reply "")))

(defun sprig--ellipsize (text width)
  "Return TEXT truncated to WIDTH columns, ending in an ellipsis if cut."
  (if (<= (string-width text) width)
      text
    (concat (truncate-string-to-width text (max 1 (1- width))) "…")))

(defun sprig--format-tokens (n)
  "Format N tokens compactly, in thousands or millions."
  (if (>= n 1000000) (format "%.1fM" (/ n 1000000.0))
    (format "%.1fk" (/ n 1000.0))))

(defun sprig--state-parts (state)
  "Return (GLYPH TEXT FACE) for a canonical turn STATE symbol.
The one source of truth for how a state reads on a state line, shared by
the review buffer (`sprig-review--state') and the navigator
\(`sprig--status-state-line') so the two never drift.  Each caller decides
only which STATE applies, from whatever it can see, then renders these
parts in its own medium.  STATE is one of `waiting', `compacting',
`streaming', `pending', `failed', `agent', `done', `interrupted', or
anything else for `idle'."
  (pcase state
    ('waiting     (list "?" "waiting on you"       'sprig-review-waiting))
    ('compacting  (list "▼" "compacting…"          'sprig-review-working))
    ('streaming   (list "▶" "working…"             'sprig-review-working))
    ('pending     (list "▷" "sent, awaiting reply" 'sprig-review-pending))
    ('failed      (list "✗" "turn failed"          'sprig-review-failed))
    ;; A background agent outlives the turn that launched it, so this reads
    ;; ahead of `done': work is still going on though the turn is over.
    ('agent       (list "▶" "agent working…"       'sprig-review-working))
    ('done        (list "✓" "turn over"            'sprig-review-done))
    ('interrupted (list "◼" "interrupted"          'font-lock-comment-face))
    (_            (list "●" "idle"                 'sprig-review-idle))))

(defun sprig--status-state-line (entry preview)
  "Return the preview's leading state line for ENTRY, or nil.
Mirrors the review buffer's state line: a glyph and word for what the turn
is doing or how it ended, then the permission mode when it is a notable one,
then the context in use.  The glyph, word, and face are `sprig--state-parts',
shared with the review buffer so the two agree; only which state applies is
decided here.  The live streaming and waiting states come from ENTRY's own
status, as the row glyph does; the turn's outcome, permission mode, and
context size come from PREVIEW's model fields.  nil when there is no status
and no model at all (nothing to say)."
  (let ((status (plist-get entry :status))
        (queued (plist-get entry :queued))
        (ctx (plist-get preview :context))
        (mode (sprig--notable-mode (plist-get preview :mode))))
    (when (or status ctx mode (and queued (> queued 0))
              (plist-get preview :done) (plist-get preview :error)
              (plist-get preview :pending) (plist-get preview :agent-running))
      (pcase-let
          ((`(,glyph ,text ,face)
            (sprig--state-parts
             (cond
              ((eq status 'streaming) 'streaming)
              ((or (eq status 'waiting) (plist-get preview :pending)) 'waiting)
              ((plist-get preview :error) 'failed)
              ((or (eq status 'agent) (plist-get preview :agent-running)) 'agent)
              ((plist-get preview :done) 'done)
              ((eq status 'interrupted) 'interrupted)
              (t 'idle)))))
        (concat (propertize (format "     %s  %s" glyph text) 'face face)
                ;; A queued message is invisible otherwise (nothing was sent),
                ;; and it fires on its own when the turn ends, so flag it here
                ;; the way the review buffer's state line does, in its own face.
                (when (and queued (> queued 0))
                  (concat (propertize "  ·  " 'face face)
                          (propertize (format "%d queued" queued)
                                      'face 'sprig-review-pending)))
                ;; The permission mode rides its own tag, coloured on its own
                ;; terms rather than the turn's, the way the review buffer's
                ;; mode line carries `[plan]'.  Only the notable modes show.
                (when mode
                  (concat (propertize "  ·  " 'face face)
                          (propertize mode 'face 'sprig-mode-tag)))
                (when (and (numberp ctx) (> ctx 0))
                  (concat (propertize "  ·  " 'face face)
                          ;; Colour the count on its own terms, escalating past
                          ;; the large / very-large marks the way the review
                          ;; buffer's state line does, rather than in the
                          ;; turn's face.
                          (propertize (sprig--format-tokens ctx)
                                      'face (sprig--status-context-face ctx)))))))))

(defun sprig--notable-mode (mode)
  "Return MODE when it is worth flagging on a state line, else nil.
The everyday modes (nil, and the CLI's own auto / default / manual) say
nothing worth the space; plan and the auto-approving ones do, so only those
show.  Shared by the navigator state line, the review state line, and the
review header, so all three agree on what counts as notable."
  (and (stringp mode)
       (not (member mode '("auto" "default" "manual")))
       mode))

(defun sprig--status-context-face (tokens)
  "Return the state-line face for TOKENS of context, escalating with size.
Mirrors the review buffer's readout: plain while the context is small,
amber past `sprig-context-large-tokens', red past `sprig-context-huge-tokens'.
Those thresholds and the escalated faces belong to `sprig-review-mode'; when
it is not loaded there is nothing to escalate to, so the count stays in the
plain `sprig-review-context' face, exactly as the plain readout already does."
  (let ((large (bound-and-true-p sprig-context-large-tokens))
        (huge (bound-and-true-p sprig-context-huge-tokens)))
    (cond
     ((and huge (>= tokens huge)) 'sprig-review-context-huge)
     ((and large (>= tokens large)) 'sprig-review-context-large)
     (t 'sprig-review-context))))

(defun sprig--status-preview-lines (entry)
  "Return the propertized display lines for ENTRY's inline preview.
A leading state line (what the turn is doing or how it ended, and the context
in use), then the last exchange, indented: your last prompt as one line, then
the agent's reply as one line, each dated with its own time (`HH:MM', muted)
and trimmed with an ellipsis where it runs past the window.  The times ride
the lines themselves rather than the row's own column, which now dates the
session's creation instead.  Both are teasers: open the row with RET for the
whole transcript.  A row with no reply yet shows a single muted placeholder.

The reply updates live as the turn streams, so the row shows the last message
as it grows under the `working…' state line, not only once the turn settles:
a one-line teaser is cheap to refresh and the point of watching a row run is
to see what it is saying now."
  (let* ((preview (sprig--entry-preview entry))
         (prompt (plist-get preview :prompt))
         (reply (plist-get preview :reply))
         (ptime (sprig--format-time (plist-get preview :prompt-time)))
         (rtime (sprig--format-time (plist-get preview :reply-time)))
         (state (sprig--status-state-line entry preview))
         (width (max 24 (- (min 100 (window-width)) 6)))
         (lines '()))
    (when state (push state lines))
    (cond
     ((not (or prompt reply))
      (push (propertize "     (no reply yet)" 'face 'sprig-status-preview) lines))
     (t
      (when prompt
        (let* ((stamp (if ptime (concat ptime " ") ""))
               (line (propertize
                      (concat "     " stamp "» "
                              (sprig--ellipsize prompt
                                                (- width 2 (string-width stamp))))
                      'face 'sprig-status-preview-prompt)))
          ;; The stamp reads muted, the prompt in its own face; the whole line
          ;; is prompt-faced first so its indentation carries it (that is what
          ;; the row's preview id and scroll anchor hang off), then the stamp is
          ;; toned down over the top.
          (when (> (length stamp) 0)
            (put-text-property 5 (+ 5 (length stamp)) 'face
                               'sprig-status-preview line))
          (push line lines)))
      (when reply
        (let ((stamp (if rtime (concat rtime " ") "")))
          ;; The reply and its stamp share the muted preview face, so no
          ;; two-tone is needed here.
          (push (propertize
                 (concat "     " stamp
                         (sprig--ellipsize (sprig--status-reply-oneline reply)
                                           (- width (string-width stamp))))
                 'face 'sprig-status-preview)
                lines)))))
    (nreverse lines)))

;;; Host group headings

(defun sprig--status-group-counts ()
  "Hash of host -> how many rows the current render put in its group."
  (let ((counts (make-hash-table :test 'equal)))
    (when sprig--status-index
      (maphash (lambda (_ entry)
                 (let ((host (plist-get entry :host)))
                   (puthash host (1+ (gethash host counts 0)) counts)))
               sprig--status-index))
    counts))

(defun sprig--status-group-label (host count)
  "Return the heading text for HOST's group, holding COUNT rows.
A leading fold glyph shows the group's state (`▾' open, `▸' collapsed),
the way `magit' heads a foldable section.  An empty group reads `none'
rather than `0', since the point of heading it at all is that you can
still press `s' under it."
  (format "%s %s (%s)"
          (if (sprig--status-collapsed-p host) "▸" "▾")
          (if host (concat "remote " host) "local")
          (if (zerop count) "none" count)))

(defun sprig--status-stamp-group (from to host)
  "Mark the text between FROM and TO as belonging to HOST's group.
Every navigator line carries this, headings and rows and previews alike,
so `sprig--status-host-at-point' is a property read rather than a search
back up the buffer.  The value is a plist because nil is a real host (the
local machine) and would be indistinguishable from an absent property."
  (put-text-property from to 'sprig--status-group (list :host host)))

(defun sprig--status-insert-group (host counts)
  "Insert HOST's group heading at point, sized from the COUNTS table.
The heading carries `sprig--status-heading', which is what tells TAB it is
sitting on a foldable heading rather than a session row."
  (let ((from (point)))
    (insert (propertize (sprig--status-group-label host (gethash host counts 0))
                        'face 'sprig-status-group)
            "\n")
    (sprig--status-stamp-group from (point) host)
    (put-text-property from (point) 'sprig--status-heading t)))

(defun sprig--status-decorate ()
  "Head each host group and insert the active rows' inline previews.
Runs after `tabulated-list-print', which erases both.  The printed rows
are in `sprig--status-groups' order, so the two are walked in step: a
heading falls due whenever a row's host advances past the group last
headed, and the groups left over at the end are the empty ones, which are
headed all the same because the heading is what you press `s' under.

The inserted lines carry no entry id, so navigation and the next reprint
skip them cleanly.  Point is held by a marker of insertion type t, so a
heading inserted at the very position point was restored to leaves point
on its row rather than stranding it on the heading."
  (let ((inhibit-read-only t)
        (home (copy-marker (point) t))
        (pending (or sprig--status-groups (sprig--status-hosts)))
        (counts (sprig--status-group-counts))
        (headed 'none))
    (unwind-protect
        (progn
          (goto-char (point-min))
          (while (not (eobp))
            (let* ((id (tabulated-list-get-id))
                   (entry (and id sprig--status-index
                               (gethash id sprig--status-index))))
              (when entry
                (let ((host (plist-get entry :host)))
                  ;; A heading falls due only when the host changes, and
                  ;; then every group that sorts before this row's is due
                  ;; too: those are the empty ones, headed here so they
                  ;; land in place rather than at the end of the buffer.
                  (unless (equal headed host)
                    (while (and pending (not (equal (car pending) host)))
                      (sprig--status-insert-group (car pending) counts)
                      (pop pending))
                    (sprig--status-insert-group host counts)
                    (when pending (pop pending))
                    (setq headed host))
                  (sprig--status-stamp-group (line-beginning-position)
                                             (min (point-max)
                                                  (1+ (line-end-position)))
                                             host)
                  (when (sprig--status-entry-active-p entry)
                    (save-excursion
                      (forward-line 1)
                      (let ((from (point)))
                        (insert (mapconcat #'identity
                                           (sprig--status-preview-lines entry)
                                           "\n")
                                "\n")
                        (sprig--status-stamp-group from (point) host)
                        ;; Carry the row's id onto its preview lines so a verb
                        ;; keyed on point (c c, a a, RET) finds the same
                        ;; session there as on the row itself.
                        (put-text-property from (point)
                                           'sprig--status-preview-id id)))))))
            (forward-line 1))
          ;; Whatever is left took no rows this render; head it anyway.
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (while pending
            (sprig--status-insert-group (car pending) counts)
            (pop pending)))
      (goto-char home)
      (set-marker home nil))))

(defun sprig--status-host-at-point ()
  "Return the host of the group point is in, nil for the local machine.
Read from the group property every decorated line carries; on the
buffer's trailing empty line, from the nearest line above that has one."
  (let ((group (or (get-text-property (line-beginning-position)
                                      'sprig--status-group)
                   (save-excursion
                     (let (found)
                       (while (and (not found) (zerop (forward-line -1)))
                         (setq found (get-text-property (line-beginning-position)
                                                        'sprig--status-group)))
                       found)))))
    (plist-get group :host)))

(defun sprig--status-id-at (pos)
  "Return the session id owning the line at POS, or nil.
A printed row carries it as `tabulated-list-id'; a preview line under one
carries it as `sprig--status-preview-id'.  nil on a group heading, a blank
line, or in an empty buffer."
  (save-excursion
    (goto-char pos)
    (let ((bol (line-beginning-position)))
      (or (tabulated-list-get-id bol)
          (get-text-property bol 'sprig--status-preview-id)))))

(defun sprig--status-scroll-anchor (pos)
  "Return (ID . DELTA) anchoring buffer POS to the nearest row at or below it.
ID is the session of the first row whose line lies at or below POS's line;
DELTA is how many lines POS's line sits above that row.  nil when no row
lies below POS.  Used to pin a window's top edge to a row that survives a
reprint even as rows above it come and go."
  (save-excursion
    (goto-char pos)
    (beginning-of-line)
    (let ((delta 0) id)
      (while (and (not (setq id (sprig--status-id-at (point))))
                  (zerop (forward-line 1)))
        (setq delta (1+ delta)))
      (and id (cons id delta)))))

(defun sprig--status-id-line-position (id)
  "Return the buffer position starting the row that owns ID, or nil.
Rows precede their own preview lines, so the top-down scan lands on the
printed row rather than one of its preview lines."
  (save-excursion
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (not (eobp)))
        (if (equal (sprig--status-id-at (point)) id)
            (setq found (line-beginning-position))
          (forward-line 1)))
      found)))

(defun sprig--status-window-anchors ()
  "Snapshot the scroll and point anchors of every window showing the navigator.
Returns a list of (WINDOW START-ANCHOR POINT-ID): START-ANCHOR pins the
window's top edge (see `sprig--status-scroll-anchor'), POINT-ID the row
under its point.  Both are ids, so `sprig--status-restore-window-anchor' can
re-find them in the freshly printed buffer."
  (mapcar (lambda (win)
            (list win
                  (sprig--status-scroll-anchor (window-start win))
                  (sprig--status-id-at (window-point win))))
          (get-buffer-window-list (current-buffer) nil t)))

(defun sprig--status-restore-window-anchor (win start-anchor point-id)
  "Restore WIN's point and scroll position from an id-keyed anchor.
The row under point and the row at the top edge keep their places even as
rows above them come and go across a reprint; a row that vanished is simply
not restored, leaving that window to redisplay's own default."
  (when (window-live-p win)
    (when point-id
      (let ((pos (sprig--status-id-line-position point-id)))
        (when pos (set-window-point win pos))))
    (when start-anchor
      (let ((pos (sprig--status-id-line-position (car start-anchor))))
        (when pos
          (set-window-start
           win (save-excursion
                 (goto-char pos)
                 (forward-line (- (cdr start-anchor)))
                 (point))))))))

(defvar-local sprig--status-last-signature 'none
  "Signature of the navigator's last painted content, for the live path.
`sprig--status-render-if-live' fires on every coalesced stream tick; when the
freshly computed signature matches this, nothing visible changed, so the
reprint and its preview rebuild are skipped.  `none' until the first paint, so
the first tick always renders.")

(defun sprig--status-render-signature (collected)
  "Return a value capturing everything COLLECTED would paint in the navigator.
Compared with `equal' to decide whether a live tick can skip its reprint (see
`sprig--status-render-if-live').  Covers each row's visible fields, its group's
fold state, its inline preview when active, plus the view flags, so any change
that alters the display changes the signature.  The row's own time is its
creation time, which never moves; the times that do change ride the inline
preview lines (the last exchange's stamps), captured with the preview."
  (list sprig--status-filter
        sprig--status-show-all
        sprig--status-hide-disconnected
        sprig--status-sort
        (mapcar
         (lambda (e)
           (let ((host (plist-get e :host)))
             (list (plist-get e :key)
                   (plist-get e :status)
                   (plist-get e :title)
                   (plist-get e :project)
                   (plist-get e :session)
                   (sprig--format-time-value (plist-get e :created))
                   (plist-get e :queued)
                   (sprig--status-collapsed-p host)
                   (and (sprig--status-entry-active-p e)
                        (not (sprig--status-collapsed-p host))
                        (sprig--status-preview-lines e)))))
         collected)))

(defun sprig--status-render ()
  "Reprint the navigator, then head its groups and re-insert its previews.
Every navigator refresh path routes through here so both survive a reprint.
`tabulated-list-print' keeps point on its row by id; on top of that each
window showing the navigator keeps its scroll position, anchored to the id
of the row at its top edge, so a background refresh does not jump the view
to the buffer's head."
  (let ((anchors (sprig--status-window-anchors)))
    (tabulated-list-print t)
    (sprig--status-decorate)
    (dolist (a anchors)
      (apply #'sprig--status-restore-window-anchor a))))

;;; Major mode, verbs, and the entry command

(defvar sprig-status-mode-map (make-sparse-keymap)
  "Keymap for `sprig-status-mode'.")

;; Bound at top level so reloading the file refreshes the bindings.
;; `g' (revert) and `q' (quit-window) are inherited from tabulated-list-mode.
(define-key sprig-status-mode-map (kbd "RET") #'sprig-status-open)
(define-key sprig-status-mode-map (kbd "o")   #'sprig-status-open)
(define-key sprig-status-mode-map (kbd "TAB") #'sprig-status-toggle-preview)
(define-key sprig-status-mode-map (kbd "n")   #'sprig-status-next)
(define-key sprig-status-mode-map (kbd "p")   #'sprig-status-previous)
;; Transients mirror the review buffer's steering surface, each acting on
;; the session under point: `s' starts (`s n' new, `s c' new-then-compose,
;; `s p' new-then-plan, `s f' fork), `c' steers (`c c' composes), `a' answers,
;; `P' sets the permission mode (`P p' plan, `P a' auto, ...), `d' removes
;; (`d d' disconnects, `d D' deletes), and `l' switches the view (`l l'
;; live-only, `l a' show all, `l g' show subagents).
;; Interrupt is `c i'; connect is `c o'.  `/' (filter) stays top-level, and
;; `S S' opens the host's session roots (sort lives on `l s' and a header click).
(define-key sprig-status-mode-map (kbd "s")   #'sprig-status-start)
(define-key sprig-status-mode-map (kbd "c")   #'sprig-status-dispatch)
(define-key sprig-status-mode-map (kbd "a")   #'sprig-status-answer-dispatch)
(define-key sprig-status-mode-map (kbd "P")   #'sprig-status-permission-mode)
(define-key sprig-status-mode-map (kbd "d")   #'sprig-status-remove)
(define-key sprig-status-mode-map (kbd "l")   #'sprig-status-view)
(define-key sprig-status-mode-map (kbd "/")   #'sprig-status-filter)
(define-key sprig-status-mode-map (kbd "S")   #'sprig-status-show)
(define-key sprig-status-mode-map (kbd "T")   #'sprig-status-title-dispatch)
;; `*' pins the session under point to the top of its group and saves it.
(define-key sprig-status-mode-map (kbd "*")   #'sprig-status-star)
;; The columns are unsortable to `tabulated-list', so a header click falls
;; through to here rather than its native sort, which would break the groups.
(define-key sprig-status-mode-map [header-line mouse-1] #'sprig-status-sort)
(define-key sprig-status-mode-map [header-line mouse-2] #'sprig-status-sort)
(define-key sprig-status-mode-map (kbd "?")   #'describe-mode)

(defun sprig--status-apply-format ()
  "Set the navigator's column format and (re)initialise its header.
Split from the mode so `sprig-reload' can re-apply an edited column layout to
an already-open navigator, whose header is otherwise fixed at mode init."
  (setq tabulated-list-format
        [("S" 2 t)
         ("Project" 24 t)
         ("Title" 32 t)
         ("Session" 9 nil)
         ("Created" 11 nil)]
        tabulated-list-padding 1
        tabulated-list-sort-key nil
        tabulated-list-entries #'sprig--status-entries)
  (tabulated-list-init-header))

(define-derived-mode sprig-status-mode tabulated-list-mode "Sprig-Status"
  "Major mode listing Sprig conversations and their live status.
\\<sprig-status-mode-map>Open with \\[sprig-status-open], steer the session
under point with \\[sprig-status-dispatch] (its `c c' composes, `c o'
connects), answer its waiting question with \\[sprig-status-answer-dispatch],
interrupt with \\[sprig-status-interrupt], refresh with \\[revert-buffer]."
  (setq-local revert-buffer-function #'sprig--status-revert)
  (sprig--status-apply-format))

(defun sprig--status-revert (&rest _)
  "Revert the navigator (the `g' / `revert-buffer' path), keeping previews.
Drops the cached log scan first, so `g' always re-reads the disk: it is the
explicit \"show me what is there now\" gesture, cache or no cache.  It
re-arms auto-reattach the same way opening afresh does (see
`sprig--status-reattach-attempted'): a probe that failed earlier gets one
new try, so a broker that has since come back is picked up, and a stale
marker gets another chance to be proven stale and cleaned."
  (setq sprig--status-reattach-attempted nil)
  (sprig--status-scan-invalidate)
  (sprig--status-render))

(defun sprig--status-render-if-live ()
  "Re-render the `*sprig-status*' navigator if it is open and something changed.
A no-op, and thus free, when the navigator is not open.  Reuses the cached log
scan (see `sprig--status-scan-cache'), and skips the reprint entirely when the
freshly computed content signature matches the last paint (see
`sprig--status-render-signature'), so a stream tick that changes nothing
visible costs one collect and no buffer work.  This is the cheap path the live
per-event tick and the structural refresh both take."
  (let ((buf (get-buffer sprig-status-buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (derived-mode-p 'sprig-status-mode)
          (let ((sig (sprig--status-render-signature (sprig--status-collect))))
            (unless (equal sig sprig--status-last-signature)
              (setq sprig--status-last-signature sig)
              (sprig--status-render))))))))

(defun sprig--status-refresh ()
  "Re-scan the stored logs and re-render the navigator if it is open.
Called from session lifecycle points, so a stream finishing in a buffer you
are not viewing still updates the list.  Drops the cached log scan first, so
a structural change (a session opening, ending, or being removed) is picked
up from disk; the coalesced live tick uses `sprig--status-render-if-live'
instead, which keeps the cache and so never re-reads the disk mid-turn."
  (sprig--status-scan-invalidate)
  (sprig--status-render-if-live))

(defun sprig--status-refresh-deferred ()
  "Refresh the navigator on the next idle moment.
Used from `kill-buffer-hook', which runs while the dying buffer is still
live and listed; deferring lets it drop from the list first."
  (run-at-time 0 nil #'sprig--status-refresh))

(defvar sprig--status-refresh-timer nil
  "Pending coalesced live-refresh timer for the navigator, or nil.
One global timer, since the navigator is a single buffer; held here so a
burst of stream events schedules just one render (see
`sprig--status-refresh-soon').")

(defun sprig--status-refresh-cancel ()
  "Drop any pending coalesced navigator refresh."
  (when sprig--status-refresh-timer
    (cancel-timer sprig--status-refresh-timer)
    (setq sprig--status-refresh-timer nil)))

(defun sprig--status-refresh-soon ()
  "Refresh the navigator soon, coalescing a burst of events into one render.
A streaming turn fires many events a second, so this renders at most once per
`sprig-status-live-refresh-interval' rather than once per event.  It takes the
cheap `sprig--status-render-if-live' path, which reuses the cached log scan:
the live session's row is rebuilt from its owning buffer, and the stored logs
do not change mid-turn, so a live tick never touches the disk.  A no-op, and
thus free, when the interval is nil or the navigator is not open."
  (when (and sprig-status-live-refresh-interval
             (null sprig--status-refresh-timer)
             (get-buffer sprig-status-buffer-name))
    (setq sprig--status-refresh-timer
          (run-at-time sprig-status-live-refresh-interval nil
                       (lambda ()
                         (setq sprig--status-refresh-timer nil)
                         (sprig--status-render-if-live))))))

(defun sprig--status-id-at-point ()
  "Return the session id of the row at point, reached from a preview line too.
`tabulated-list-get-id' has it on a printed row; a preview line under a row
carries it as a text property, so a verb keyed on point finds the same
session whether point sits on the row or in its inline preview."
  (or (tabulated-list-get-id)
      (get-text-property (line-beginning-position) 'sprig--status-preview-id)))

(defun sprig--status-entry-at-point ()
  "Return the status plist for the row at point, or signal an error."
  (let ((id (sprig--status-id-at-point)))
    (or (and id sprig--status-index (gethash id sprig--status-index))
        (user-error "No Sprig session on this line"))))

(defun sprig--status-entry-host-arg (entry)
  "Return the host argument that pins a session to ENTRY's host.
Pinned to the host the row's log was scanned on, not to whatever
the primary remote happens to be: a session id only resumes on the host
that issued it, and now that every host is listed the two are routinely
different.  Local is the symbol t (force local), a remote is its string."
  (or (plist-get entry :host) t))

(defun sprig--status-review-buffer (entry)
  "Return the review buffer for ENTRY, opening it from the log if needed.
An open owning buffer is reused; otherwise a review buffer is opened that
owns the session, replaying its stored log."
  (let ((buf (plist-get entry :buffer)))
    (if (buffer-live-p buf)
        buf
      (sprig-review-session (plist-get entry :dir) (plist-get entry :session)
                            (sprig--status-entry-host-arg entry)))))

(defun sprig--status-session-buffer (entry)
  "Return the review buffer for ENTRY, built undisplayed if it is not open.
Like `sprig--status-review-buffer' but it never pops the buffer up: a verb
run from the navigator steers the session in the background, and only the
verb's own compose or answer buffer shows."
  (let ((buf (plist-get entry :buffer)))
    (if (buffer-live-p buf)
        buf
      (sprig--review-session-buffer (plist-get entry :dir)
                                    (plist-get entry :session)
                                    (sprig--status-entry-host-arg entry) nil))))

(defun sprig--status-owning-buffer (entry)
  "Return ENTRY's open owning review buffer, or signal that it is not open."
  (let ((buf (plist-get entry :buffer)))
    (if (buffer-live-p buf) buf
      (user-error "That session is not open (open it first)"))))

(defun sprig--status-steer (command)
  "Run review COMMAND on the session of the row at point, from the navigator.
The row's review buffer is resolved (built undisplayed when the session is
not already open) and COMMAND is called there, so a message composes,
a question answers, or a turn is steered without first opening the buffer.
COMMAND's own compose or answer buffer, if any, still pops up as usual.
The navigator refreshes after, so a glyph that the verb moved is redrawn."
  (let ((buf (sprig--status-session-buffer (sprig--status-entry-at-point))))
    (with-current-buffer buf
      (call-interactively command)))
  (sprig--status-refresh))

(defmacro sprig--status-define-steer (name command &optional doc)
  "Define NAME as a navigator verb that steers the row's session with COMMAND.
A thin wrapper so the navigator's `c' and `a' transients can offer the
review buffer's own verbs, each acting on the session at point.  DOC is the
command's docstring."
  (declare (indent 2) (doc-string 3))
  `(defun ,name ()
     ,(or doc (format "Run `%s' on the session of the row at point." command))
     (interactive)
     (sprig--status-steer #',command)))

(sprig--status-define-steer sprig-status-message sprig-review-message
  "Compose a message and send it to the row's session (`c c').")
(sprig--status-define-steer sprig-status-queue sprig-review-queue
  "Compose a message and queue it for after the running turn (`c q').")
(sprig--status-define-steer sprig-status-drop-queue sprig-review-drop-queue
  "Drop the messages queued on the row's session (`c Q').")
(sprig--status-define-steer sprig-status-accept sprig-review-accept
  "Answer the row's session yes / accept (`c y').")
(sprig--status-define-steer sprig-status-decline sprig-review-decline
  "Answer the row's session no / decline (`c n').")
(sprig--status-define-steer sprig-status-message-plan sprig-review-message-plan
  "Compose a message for the row's session in plan mode (`c p').")
(sprig--status-define-steer sprig-status-retry sprig-review-retry
  "Resend the last turn of the row's session (`c r').")
(sprig--status-define-steer sprig-status-compact sprig-review-compact
  "Compact the context of the row's session (`c z').")
(sprig--status-define-steer sprig-status-btw sprig-review-btw
  "Ask a side question about the row's session, disturbing nothing (`c b').")
(sprig--status-define-steer sprig-status-answer sprig-review-answer
  "Answer the row's session's waiting question, one at a time (`a a').")
(sprig--status-define-steer sprig-status-answer-recommended
    sprig-review-answer-recommended
  "Take every recommended option on the row's session's question (`a r').")
(sprig--status-define-steer sprig-status-answer-skip sprig-review-answer-skip
  "Skip the row's session's waiting question (`a s').")
(sprig--status-define-steer sprig-status-plan-mode sprig-review-plan-mode
  "Put the row's session into plan mode (`P p').")
(sprig--status-define-steer sprig-status-auto-mode sprig-review-auto-mode
  "Put the row's session into auto mode (`P a').")
(sprig--status-define-steer sprig-status-accept-edits-mode
    sprig-review-accept-edits-mode
  "Put the row's session into accept-edits mode (`P e').")
(sprig--status-define-steer sprig-status-manual-mode sprig-review-manual-mode
  "Put the row's session into manual mode (`P m').")
(sprig--status-define-steer sprig-status-bypass-mode sprig-review-bypass-mode
  "Put the row's session into bypass mode (`P b').")

(defun sprig--status-goto-row (dir)
  "Move point DIR (+1 or -1) session rows, skipping preview lines.
The id-less inline preview lines are skipped.  Return non-nil on success;
leave point put when there is no further row."
  (let ((origin (point))
        found)
    (while (and (not found) (zerop (forward-line dir)))
      (when (tabulated-list-get-id)
        (setq found t)))
    (if found
        (progn (beginning-of-line) t)
      (goto-char origin)
      nil)))

(defun sprig-status-next (&optional n)
  "Move to the Nth next Sprig session row, skipping inline preview lines.
N defaults to 1; a negative N moves to previous rows."
  (interactive "p")
  (let* ((n (or n 1))
         (dir (if (< n 0) -1 1)))
    (dotimes (_ (abs n))
      (sprig--status-goto-row dir))))

(defun sprig-status-previous (&optional n)
  "Move to the Nth previous Sprig session row, skipping inline preview lines."
  (interactive "p")
  (sprig-status-next (- (or n 1))))

(defun sprig-status-open ()
  "Open the review buffer for the session on the current line.
Reuses an open owning buffer, or replays the stored log into a new one.
Point lands on the last message, so the newest reply is what you see, and
the view keeps following the tail as a live turn streams in, rather than
opening at the top of a long transcript."
  (interactive)
  (let ((buf (sprig--status-review-buffer (sprig--status-entry-at-point))))
    (pop-to-buffer buf)
    (goto-char (point-max))
    (let ((win (get-buffer-window buf)))
      (when win (set-window-point win (point-max))))
    (sprig--status-refresh)))

(defun sprig-status-connect ()
  "Open the session on the current line and start or resume it.
Connecting by hand lifts any do-not-reattach mark a deliberate disconnect
left (see `sprig--status-reattach-attempted'), so auto-reattach serves the
session again should this connection drop."
  (interactive)
  (let ((entry (sprig--status-entry-at-point)))
    (when-let* ((id (plist-get entry :session)))
      (setq sprig--status-reattach-attempted
            (delete id sprig--status-reattach-attempted)))
    (let ((buf (sprig--status-review-buffer entry)))
      (with-current-buffer buf
        (unless (process-live-p sprig--process) (sprig-review-connect)))
      (sprig--status-refresh))))

(defun sprig-status-interrupt ()
  "Interrupt the streaming session on the current line."
  (interactive)
  (with-current-buffer (sprig--status-owning-buffer (sprig--status-entry-at-point))
    (sprig-review-interrupt))
  (sprig--status-refresh))

(defun sprig-status-disconnect ()
  "Disconnect the session on the current line (its log is kept).
A broker-held session is stopped on its host too: the broker closes the
child's stdin so `claude' exits and the session is dropped, rather than
kept running detached (see `sprig--broker-stop-session'); the log
survives, so the next `o' resumes it fresh.  Works on a held row whether
or not its buffer is open here.  The id is also marked against
auto-reattach (`sprig--status-reattach-attempted'), so a background scan
that still sees the live marker while the stop settles cannot race it
back to life."
  (interactive)
  (let* ((entry (sprig--status-entry-at-point))
         (id (plist-get entry :session))
         (host (plist-get entry :host))
         (buf (plist-get entry :buffer))
         (had-live (and (buffer-live-p buf)
                        (process-live-p
                         (buffer-local-value 'sprig--process buf))))
         ;; Brokered when the broker covers this host and either the scan saw
         ;; the live marker or this Emacs holds a live connection (a session
         ;; spawned moments ago can be held before any scan reports it).
         (brokered (and id
                        (if host (sprig--broker-remote-p)
                          (sprig--broker-local-p))
                        (or (plist-get entry :live) had-live))))
    (unless (or had-live brokered)
      (user-error "That session is not connected"))
    (when id
      (unless (member id sprig--status-reattach-attempted)
        (push id sprig--status-reattach-attempted)))
    (when had-live
      (with-current-buffer buf (sprig--teardown-process)))
    (when brokered
      (if (sprig--broker-stop-session id host)
          (message "sprig: session stopped (its log is kept)")
        (message "sprig: disconnected, but the broker stop failed")))
    (sprig--status-refresh)))

(defun sprig--delete-session-log (entry)
  "Permanently delete ENTRY's stored session log and transcripts beside it.
Runs on ENTRY's host: a local log is removed by path, a remote one over
SSH.  The per-session `<id>/' directory of subagent transcripts sits
beside the log and goes with it.  Signals when the log cannot be found."
  (let ((host (plist-get entry :host))
        (id (plist-get entry :session)))
    (unless id (user-error "sprig: session has no stored log to delete"))
    ;; Bind the host so every path helper below resolves against it: the
    ;; navigator lists every host, so the row's host, not the primary
    ;; remote, is the one whose log is deleted.
    (let ((sprig-remotes (list host)))
      (if host
          (let* ((root (sprig--remote-dir-arg (sprig--projects-directory)))
                 (name (shell-quote-argument (concat id ".jsonl")))
                 (path (string-trim
                        (sprig--remote-sh
                         (format "find %s -name %s -print -quit" root name)))))
            (when (string-empty-p path)
              (user-error "sprig: no session log for %s on %s" id host))
            (sprig--remote-sh
             (format "rm -f %s && rm -rf %s"
                     (shell-quote-argument path)
                     (shell-quote-argument (file-name-sans-extension path)))))
        (let ((file (car (directory-files-recursively
                          (expand-file-name (sprig--projects-directory))
                          (concat "\\`" (regexp-quote id) "\\.jsonl\\'")))))
          (unless file (user-error "sprig: no session log for %s" id))
          (delete-file file)
          (let ((dir (file-name-sans-extension file)))
            (when (file-directory-p dir) (delete-directory dir t))))))))

(defun sprig-status-delete ()
  "Permanently delete the session on the current line, log and all.
Where `d' (disconnect) keeps the CLI's session log, this removes it, so
the session is gone for good and does not return on the next refresh.  A
live session is torn down and its buffer killed first, and a broker-held
one is stopped on its host (else its `claude' child would linger, running
against a log that no longer exists), so nothing writes the log back.
Asks first, since there is no undo."
  (interactive)
  (let* ((entry (sprig--status-entry-at-point))
         (title (plist-get entry :title))
         (id (plist-get entry :session))
         (host (plist-get entry :host)))
    (when (yes-or-no-p
           (format "Permanently delete session %s (%s)? "
                   (if (and title (not (string-empty-p title)))
                       (format "%S" title) "untitled")
                   (if id (substring id 0 (min 8 (length id))) "no log")))
      (let ((buf (plist-get entry :buffer)))
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (when (process-live-p sprig--process) (sprig--teardown-process)))
          (kill-buffer buf)))
      (when (and id (plist-get entry :live)
                 (if host (sprig--broker-remote-p) (sprig--broker-local-p)))
        (sprig--broker-stop-session id host))
      (when id (sprig--delete-session-log entry))
      (sprig--status-refresh)
      (message "Deleted session %s"
               (if (and title (not (string-empty-p title))) title (or id ""))))))

(defun sprig-status-toggle-disconnected ()
  "Toggle whether disconnected (`○') sessions are listed.
Hiding them leaves a live-only view; the hidden sessions' logs are
untouched and return on the next toggle."
  (interactive)
  (setq sprig--status-hide-disconnected (not sprig--status-hide-disconnected))
  (sprig--status-render)
  (message (if sprig--status-hide-disconnected
               "Hiding disconnected sessions"
             "Showing disconnected sessions")))

(defun sprig--status-sort-read-column (event)
  "Return the column to sort by: the header EVENT clicked, else one prompted.
On a header-line mouse click the column name rides the header text
`tabulated-list' stamps on it; otherwise (a keypress) the user picks one."
  (or (and (mouse-event-p event)
           (let* ((pos (event-start event))
                  (obj (posn-object pos)))
             (and obj (get-text-property (cdr obj) 'tabulated-list-column-name
                                         (car obj)))))
      (completing-read "Sort by column: "
                       (mapcar #'car (append tabulated-list-format nil))
                       nil t nil nil (car sprig--status-sort))))

(defun sprig-status-sort (&optional column)
  "Sort the navigator within each host group by COLUMN, then re-render.
Interactively, sort by the header column clicked, or prompt for one; choosing
the column that is already active flips its direction.  `Created' and the
status column default to descending (newest, busiest first), the text columns
to ascending.  The groups stay apart: the sort is within each, so local and
remote never intermix."
  (interactive (list (sprig--status-sort-read-column last-command-event)))
  (setq sprig--status-sort
        (if (equal column (car sprig--status-sort))
            (cons column (not (cdr sprig--status-sort)))
          (cons column (and (member column '("Created" "S")) t))))
  (sprig--status-render))

;; Defined here, after the connect / interrupt / disconnect verbs they list,
;; so every suffix command is known by the time the prefix is compiled.
(transient-define-prefix sprig-status-dispatch ()
  "Steer the session on the row at point, without leaving the navigator.
The same message verbs the review buffer's `c' offers, each acting on the
session under point.  The change-touching verbs (reject, commit, run) are
not here: they act on a diff section, which the navigator has none of."
  [["Message"
    ("c" "compose & send (steers a running turn)" sprig-status-message)
    ("q" "compose & queue (after this turn)" sprig-status-queue)
    ("Q" "drop the queued messages" sprig-status-drop-queue)
    ("y" "yes / accept" sprig-status-accept)
    ("n" "no / decline" sprig-status-decline)
    ("p" "compose in plan mode" sprig-status-message-plan)
    ("r" "resend last turn" sprig-status-retry)
    ("i" "interrupt turn (any queued message then goes)" sprig-status-interrupt)
    ("z" "compact context" sprig-status-compact)
    ("b" "by the way: side question (writes no log)" sprig-status-btw)]
   ["Session"
    ("o" "open & connect" sprig-status-connect)
    ("d" "disconnect (stops a held session)" sprig-status-disconnect)]])

(transient-define-prefix sprig-status-answer-dispatch ()
  "Answer the question the session on the row at point is waiting on.
The review buffer's `a', acting on the session under point."
  [["Answer"
    ("a" "answer, one question at a time" sprig-status-answer)
    ("r" "take every recommended option" sprig-status-answer-recommended)
    ("s" "skip; go on unanswered" sprig-status-answer-skip)]])

(transient-define-prefix sprig-status-permission-mode ()
  "Set the permission mode of the session on the row at point.
The review buffer's `P', acting on the session under point; it must be open
and live, since the mode is a session-level setting the CLI tracks."
  [["Permission mode"
    ("p" "plan (agent plans, makes no edits)" sprig-status-plan-mode)
    ("a" "auto (normal: allowed tools run, rest prompt)" sprig-status-auto-mode)
    ("e" "accept edits (auto-approve file edits)" sprig-status-accept-edits-mode)
    ("m" "manual (prompt for every tool call)" sprig-status-manual-mode)
    ("b" "bypass (auto-approve everything, incl. shell)" sprig-status-bypass-mode)]])

(transient-define-prefix sprig-status-title-dispatch ()
  "Retitle the session on the row at point, saving the new title to its log."
  [["Title"
    ("a" "ask the agent, then save" sprig-status-retitle)
    ("m" "set by hand, then save" sprig-status-set-title)]])

(defun sprig-status-toggle-preview ()
  "Fold the host group under point to its heading, or unfold it again.
On a host heading (`local' or `remote HOST') or any row within a group, TAB
collapses that whole group to its heading and expands it again, the way
`magit' folds a section; the count stays on a collapsed heading, so
`▸ remote you@your-server (12)' tells you what is hidden.  A live session's
last exchange shows inline under its row on its own, with no per-row toggle;
open the session with \\[sprig-status-open] for the full transcript."
  (interactive)
  (if (get-text-property (line-beginning-position) 'sprig--status-group)
      (sprig--status-toggle-collapse (sprig--status-host-at-point))
    (user-error "No Sprig host group on this line")))

(defun sprig--status-new-session-args (local)
  "Return (HOST . DEFAULT-DIR) for a fresh session started at point.
HOST is the group point is in, unless LOCAL forces this machine.
DEFAULT-DIR seeds the directory prompt from the session row at point when
there is one, so a fresh session starts alongside it in the same place."
  (let* ((host (unless local (sprig--status-host-at-point)))
         (id (sprig--status-id-at-point))
         (entry (and id sprig--status-index (gethash id sprig--status-index))))
    (cons host (and entry (plist-get entry :dir)))))

(defun sprig-status-new (&optional local)
  "Start a fresh session on the host of the group point is in.
Point under the `local' heading starts the session on this machine; under
a `remote' one, on that host.  Which is why an empty group is still
headed: the heading is the place you stand to start the first session
there.  Opens a review buffer that owns the new session; it appears under
its own group and streams like any other.  The working-directory prompt
completes directories (against the local filesystem, or over SSH for a
remote host) and suggests the host's existing session roots.  With a prefix
argument, LOCAL forces the session
onto this machine wherever point happens to be.  When point is on a
session row, its directory seeds the prompt, so `s n' on a session starts
a fresh one alongside it in the same directory."
  (interactive "P")
  (let ((args (sprig--status-new-session-args local)))
    (sprig-review-session (sprig--read-review-dir (car args) (cdr args))
                          nil (or (car args) t)))
  (sprig--status-refresh))

(defun sprig--status-new-message (local plan)
  "Start a fresh session at point (like `s n') and open its first prompt.
Rather than leaving you in the empty review buffer, this opens the compose
buffer straight away, so the opening message is one prompt rather than an
extra keystroke away.  LOCAL forces the session onto this machine; PLAN
opens the compose buffer in plan mode.  A session row at point seeds the
directory prompt, as with `s n'."
  (let* ((args (sprig--status-new-session-args local))
         (host (car args))
         (buf (sprig--review-session-buffer
               (sprig--read-review-dir host (cdr args)) nil (or host t) nil)))
    (sprig--status-refresh)
    (pop-to-buffer buf)
    (with-current-buffer buf (sprig-review-message plan))))

(defun sprig-status-new-message (&optional local)
  "Start a fresh session and open a prompt for its first message (`s c').
Like `s n', but drops you straight into the compose buffer instead of the
empty review buffer.  With a prefix argument, LOCAL forces the session onto
this machine; a session row at point seeds the directory prompt."
  (interactive "P")
  (sprig--status-new-message local nil))

(defun sprig-status-new-message-plan (&optional local)
  "Start a fresh session and compose its first message in plan mode (`s p').
Like `s c', but the opening turn is sent in plan mode.  With a prefix
argument, LOCAL forces the session onto this machine; a session row at
point seeds the directory prompt."
  (interactive "P")
  (sprig--status-new-message local t))

(defun sprig-status-fork ()
  "Fork the session on the current line into one of its own (`s f').
The new buffer replays this session's history and carries it on under a
session id of its own, so the two diverge from here; the parent's log is
never written to again.  The CLI forks from the end of a session, so the
branch starts where the conversation now stands, and the fork itself is
only made on its first send.  Pinned to the parent's host, since the fork
resumes the parent's id and that only exists there."
  (interactive)
  (let* ((entry (sprig--status-entry-at-point))
         (id (plist-get entry :session)))
    (unless id
      (user-error "That session has no id yet; open and send it first, then fork"))
    (sprig-review-session (plist-get entry :dir) id
                          (sprig--status-entry-host-arg entry) t)
    (message "sprig: forked; the branch starts at its first send"))
  (sprig--status-refresh))

;; Defined after the verbs it lists, as with `sprig-status-dispatch'.
(transient-define-prefix sprig-status-start ()
  "Start a session from the navigator.
`s n' starts a fresh conversation on the group point is in (`C-u s n'
forces it local, and a session row seeds the directory prompt); `s c' does
the same but drops you straight into a prompt for the first message, and
`s p' into a plan-mode prompt; `s f' forks the session at point into one of
its own."
  [["Start"
    ("n" "new conversation" sprig-status-new)
    ("c" "new, then compose the first message" sprig-status-new-message)
    ("p" "new, then compose in plan mode" sprig-status-new-message-plan)
    ("f" "fork the session at point" sprig-status-fork)]])

(defun sprig--status-project-candidates ()
  "Distinct project directories among the rows in the current render."
  (let (dirs)
    (when sprig--status-index
      (maphash (lambda (_ e)
                 (let ((d (plist-get e :dir))) (when d (push d dirs))))
               sprig--status-index))
    (seq-uniq dirs)))

(defun sprig-status-filter (filter)
  "Narrow the navigator to sessions whose project or title match FILTER.
Reads a case-insensitive substring, completing over the projects now
listed; an empty string clears the filter."
  (interactive
   (list (completing-read
          "Filter (project or title, empty to clear): "
          (sprig--status-project-candidates) nil nil sprig--status-filter)))
  (setq sprig--status-filter (and (not (string-empty-p filter)) filter))
  (sprig--status-render)
  (if sprig--status-filter
      (message "Filtering on %S" sprig--status-filter)
    (message "Filter cleared")))

(defun sprig-status-show-all ()
  "Toggle listing every stored session against the capped newest set."
  (interactive)
  (setq sprig--status-show-all (not sprig--status-show-all))
  ;; The cap bounds the scan itself, so lifting it needs a fresh, wider read;
  ;; the cached scan holds only the capped set.
  (sprig--status-scan-invalidate)
  (sprig--status-render)
  (message (if sprig--status-show-all
               "Listing every session"
             (format "Listing the %s newest sessions" sprig-status-max-sessions))))

(defun sprig-status-show-subagents ()
  "Toggle listing subagents' `agent-*' transcripts alongside real sessions.
They are hidden by default (they are not sessions you drive); see
`sprig--log-subagent-p'.  It changes the scan set, so a fresh read runs."
  (interactive)
  (setq sprig--status-show-subagents (not sprig--status-show-subagents))
  ;; The subagent logs are pruned in the scan itself (the `find', and the
  ;; local `directory-files-recursively' filter), so showing them needs a
  ;; fresh read; the cached scan holds only the pruned set.
  (sprig--status-scan-invalidate)
  (sprig--status-render)
  (message (if sprig--status-show-subagents
               "Listing subagents too"
             "Hiding subagents")))

;; Defined after the verbs they list, so every suffix command is known by the
;; time the prefix is compiled (as with `sprig-status-dispatch').
(transient-define-prefix sprig-status-remove ()
  "Take the session on the row at point out of the navigator.
`d d' disconnects the live process, stopping a broker-held session on its
host too, but keeps the CLI's log, so the session returns on the next
refresh and resumes fresh; `d D' also deletes the log, so it is gone for
good.  Deleting asks first, since there is no undo."
  [["Remove"
    ("d" "disconnect (stop a held session; keep the log)"
     sprig-status-disconnect)
    ("D" "delete (disconnect, then remove the log; no undo)"
     sprig-status-delete)]])

(defun sprig--status-view-desc (label var)
  "Describe a `sprig-status-view' toggle: LABEL, flagged `[on]' when VAR is set.
VAR is read from the navigator buffer by name, since a transient's
description runs with its own popup buffer current, not the navigator's."
  (let* ((buf (get-buffer sprig-status-buffer-name))
         (on (and buf (buffer-local-value var buf))))
    (concat label (and on (propertize "  [on]" 'face 'transient-value)))))

(transient-define-prefix sprig-status-show ()
  "Inspect a host's session roots, or the plan's usage limits.
`S S' pops the roots view for the host of the group point is in (see
`sprig-status-roots'); `S u' the account's rolling usage gauges (see
`sprig-usage').  Sorting lives under `l s' and a column-header click."
  [["Show"
    ("S" "session roots on this host" sprig-status-roots)
    ("u" "plan usage limits" sprig-usage)]])

(transient-define-prefix sprig-status-view ()
  "Switch how the navigator lists its sessions.
Pure view state; no session is touched.  `l l' toggles a live-only view
that hides disconnected sessions, `l a' toggles the newest-N cap, and `l g'
toggles the CLI's subagent (`agent-*') transcripts in; each shows `[on]'
while active.  Sort and filter are here too (`l s' sorts, and a column-header
click does as well); filter also stays top-level on `/', being frequent."
  [["View"
    ("l" sprig-status-toggle-disconnected
     :description (lambda () (sprig--status-view-desc
                             "live-only (hide disconnected)"
                             'sprig--status-hide-disconnected)))
    ("a" sprig-status-show-all
     :description (lambda () (sprig--status-view-desc
                             "show all (lift the cap)"
                             'sprig--status-show-all)))
    ("g" sprig-status-show-subagents
     :description (lambda () (sprig--status-view-desc
                             "show subagents (agent-* transcripts)"
                             'sprig--status-show-subagents)))
    ("s" "sort by column" sprig-status-sort)
    ("/" "filter by project or title" sprig-status-filter)]])

(defvar sprig-roots-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'sprig-roots-visit)
    (define-key map (kbd "o")   #'sprig-roots-visit)
    map)
  "Keymap for `sprig-roots-mode'.")

(define-derived-mode sprig-roots-mode special-mode "Sprig-Roots"
  "Major mode for the session-roots view (see `sprig-status-roots').
Read-only: each line is a directory the host's sessions run in, and `RET'
\(or `o') starts a fresh session there."
  (setq-local truncate-lines t))

(defun sprig-roots-visit ()
  "Start a fresh session in the root directory on the line at point.
Reads the directory and host the line was built with, so it launches on the
same host the roots view was opened for (a local line pins to this machine)."
  (interactive)
  (let ((dir (get-text-property (point) 'sprig-root-dir))
        (host (get-text-property (point) 'sprig-root-host)))
    (unless dir (user-error "No root on this line"))
    (sprig-review-session dir nil (or host t))
    (sprig--status-refresh)))

(defun sprig-status-roots ()
  "Show the working directories the host's sessions run in (`S r').
Pops a `*sprig-roots*' buffer listing the distinct roots for the host of the
group point is in (see `sprig--host-dir-candidates'); `RET' on a line starts
a fresh session there.  The list is the navigator's own cached scan, so a
remote host whose cache is still warming may show none yet."
  (interactive)
  (let* ((host (sprig--status-host-at-point))
         (label (if host (concat "remote " host) "local"))
         (roots (sprig--host-dir-candidates host))
         (buf (get-buffer-create "*sprig-roots*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (sprig-roots-mode)
        (insert (propertize (format "Session roots on %s\n" label) 'face 'bold))
        (insert (propertize "RET start a session here   q quit\n\n" 'face 'shadow))
        (if (null roots)
            (insert (propertize
                     "No session directories known yet (the scan may be warming).\n"
                     'face 'shadow))
          (dolist (dir roots)
            (let ((beg (point)))
              (insert dir "\n")
              (add-text-properties beg (1- (point))
                                   (list 'sprig-root-dir dir
                                         'sprig-root-host host)))))
        (goto-char (point-min))
        (when roots (forward-line 3))))
    (pop-to-buffer buf)))

;;;###autoload
(defun sprig-status ()
  "Open the `*sprig-status*' navigator listing Sprig sessions.
Lists every stored `claude' session on the host, newest first and capped
to `sprig-status-max-sessions', plus any open review buffer that owns a
live session.  Narrow with `/', lift the cap with `l a'."
  (interactive)
  (let ((buf (get-buffer-create sprig-status-buffer-name))
        (seed (and sprig-status-directories
                   (file-name-nondirectory
                    (directory-file-name (car sprig-status-directories))))))
    (with-current-buffer buf
      (unless (derived-mode-p 'sprig-status-mode)
        (sprig-status-mode)
        (when (and seed (not (string-empty-p seed)))
          (setq sprig--status-filter seed)))
      ;; Opening is a "show me now" gesture, and the cache may hold a scan from
      ;; an earlier viewing, so read the disk fresh.
      (sprig--status-scan-invalidate)
      ;; Re-arm auto-reattach: a fresh open may reattach sessions a prior
      ;; viewing already tried and then disconnected from.
      (setq sprig--status-reattach-attempted nil)
      (sprig--status-render))
    (pop-to-buffer buf)))

;;;; Plan usage
;;
;; The CLI's `/usage' panel is a render of one HTTP call: GET
;; https://api.anthropic.com/api/oauth/usage with the login's OAuth token
;; (and the CLI's oauth beta header).  Sprig asks the same endpoint, so the
;; plan's rolling limits (session, weekly, per-model) are a keystroke away
;; instead of a trip through an interactive `claude'.  The limits are
;; account-wide, so the local login's token answers for every host; nothing
;; here reads a session or touches a remote.

(defconst sprig-usage-buffer-name "*sprig-usage*"
  "Name of the plan-usage buffer.")

(defconst sprig--usage-endpoint "https://api.anthropic.com/api/oauth/usage"
  "The account usage endpoint behind the CLI's `/usage' panel.")

(defvar url-http-end-of-headers)
(defvar url-http-response-status)
(defvar url-request-extra-headers)

(defun sprig--usage-token ()
  "The local login's OAuth access token, or nil when not logged in.
Read from the CLI's credential store under `sprig-config-directory' (default
~/.claude).  Never logged or displayed; it leaves Emacs only as the
Authorization header of the usage request."
  (let ((file (expand-file-name
               ".credentials.json"
               (or sprig-config-directory "~/.claude"))))
    (and (file-readable-p file)
         (ignore-errors
           (let-alist (with-temp-buffer
                        (insert-file-contents file)
                        (json-parse-string (buffer-string)
                                           :object-type 'alist
                                           :null-object nil))
             .claudeAiOauth.accessToken)))))

(defun sprig--usage-bar (percent)
  "A ten-cell bar showing PERCENT of a limit consumed."
  (let ((cells (max 0 (min 10 (round (or percent 0) 10)))))
    (concat "[" (make-string cells ?█) (make-string (- 10 cells) ?░) "]")))

(defun sprig--usage-label (limit)
  "Human label for LIMIT, a row of the endpoint's `limits' array."
  (let-alist limit
    (pcase .kind
      ("session" "Session (5h)")
      ("weekly_all" "Week (all models)")
      ("weekly_scoped" (format "Week (%s)" (or .scope.model.display_name
                                               "scoped")))
      (_ (or .kind "?")))))

(defun sprig--usage-countdown (time)
  "TIME's distance from now as a short \"3h 40m\" string, or nil when past."
  (let ((secs (floor (float-time (time-subtract time nil)))))
    (cond ((< secs 0) nil)
          ((>= secs 86400) (format "%dd %dh" (/ secs 86400)
                                   (/ (% secs 86400) 3600)))
          ((>= secs 3600) (format "%dh %dm" (/ secs 3600)
                                  (/ (% secs 3600) 60)))
          (t (format "%dm" (max 1 (/ secs 60)))))))

(defun sprig--usage-money (money)
  "The endpoint's MONEY object (minor units and an exponent) as a string.
nil when MONEY is missing or malformed."
  (let-alist money
    (when (numberp .amount_minor)
      (let ((exponent (if (numberp .exponent) .exponent 2)))
        (format (format "%%.%df %%s" exponent)
                (/ .amount_minor (expt 10.0 exponent))
                (or .currency ""))))))

(defun sprig--usage-render (data)
  "Render DATA, the parsed usage endpoint reply, into the current buffer.
The `limits' array is the panel: one gauge per rolling limit, coloured by
the endpoint's own severity.  The spend block (usage credits past the plan)
follows when the account has it enabled."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Plan usage\n" 'face 'bold)
            (propertize "g refresh   q quit\n\n" 'face 'shadow))
    (let-alist data
      (if (null .limits)
          (insert (propertize "No limits reported.\n" 'face 'shadow))
        (dolist (limit .limits)
          (let-alist limit
            (insert
             (format "  %-20s" (sprig--usage-label limit))
             (propertize (format "%s %3d%%" (sprig--usage-bar .percent)
                                 (or .percent 0))
                         'face (pcase .severity
                                 ("normal" 'success)
                                 ("warning" 'warning)
                                 (_ 'error)))
             (let ((time (and (stringp .resets_at)
                              (ignore-errors
                                (encode-time (iso8601-parse .resets_at))))))
               (if (not time) ""
                 (propertize
                  (format "   resets %s%s"
                          (sprig--format-time-value time)
                          (let ((left (sprig--usage-countdown time)))
                            (if left (format " (in %s)" left) "")))
                  'face 'shadow)))
             "\n"))))
      (when (eq .spend.enabled t)
        (insert "\n  "
                (format "%-20s" "Extra usage")
                (or (sprig--usage-money .spend.used) "?") " of "
                (or (sprig--usage-money .spend.limit) "?") "\n")))
    ;; The consumption count is still out (see `sprig--usage-consumption');
    ;; its sentinel replaces this line, found by its property.
    (insert (propertize "\nCounting local consumption...\n"
                        'face 'shadow 'sprig-usage-consumption t))
    (insert (propertize (format "\nFetched %s\n" (format-time-string "%H:%M"))
                        'face 'shadow))
    (goto-char (point-min))))

(defconst sprig--usage-consumption-script "
import json, glob, os, sys, collections
root = os.path.expanduser(sys.argv[1])
days = collections.defaultdict(
    lambda: collections.defaultdict(lambda: [0, 0, 0]))
seen = set()
for path in glob.glob(os.path.join(root, '*', '*.jsonl')):
    try:
        with open(path, 'rb') as f:
            for line in f:
                if b'\"usage\"' not in line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get('type') != 'assistant':
                    continue
                msg = rec.get('message') or {}
                usage = msg.get('usage') or {}
                model = msg.get('model') or '?'
                if not usage or model == '<synthetic>':
                    continue
                key = (msg.get('id'), rec.get('requestId'))
                if key[0] and key in seen:
                    continue
                seen.add(key)
                cell = days[(rec.get('timestamp') or '?')[:10]][model]
                cell[0] += ((usage.get('input_tokens') or 0)
                            + (usage.get('cache_creation_input_tokens') or 0))
                cell[1] += usage.get('cache_read_input_tokens') or 0
                cell[2] += usage.get('output_tokens') or 0
    except OSError:
        pass
print(json.dumps([
    {'day': d, 'model': m, 'fresh': c[0], 'read': c[1], 'out': c[2]}
    for d in sorted(days)[-7:] for m, c in sorted(days[d].items())]))
"
  "Python that sums token usage by day and model across a host's logs.
Argv: the projects root.  Reads every session's JSONL (subagent transcripts
too: their calls bill like any other), counts each (message id, request id)
pair once (a reply's record can repeat as it streams), and prints the last
seven active days as JSON.  Cache reads are kept apart from fresh input:
they cost a tenth, so one number would mislead.")

(defun sprig--usage-consumption-insert (rows)
  "Replace the view's counting placeholder with the consumption ROWS.
Called in the usage buffer.  ROWS nil (python missing, or a root with no
logs) leaves a shrug rather than a stuck \"Counting...\"."
  (let ((at (text-property-any (point-min) (point-max)
                               'sprig-usage-consumption t))
        (inhibit-read-only t))
    (when at
      (save-excursion
        (goto-char at)
        (delete-region at (or (text-property-not-all
                               at (point-max) 'sprig-usage-consumption t)
                              (point-max)))
        (insert "\n")
        (if (null rows)
            (insert (propertize "No local consumption found.\n" 'face 'shadow))
          (insert (propertize "Local consumption (last 7 active days)\n"
                              'face 'bold))
          (dolist (row rows)
            (let-alist row
              (insert
               (propertize (format "  %-6s %-19s"
                                   (if (> (length .day) 5) (substring .day 5)
                                     .day)
                                   (string-remove-prefix "claude-" .model))
                           'face 'shadow)
               (format " %8s in %9s cached %8s out\n"
                       (sprig--format-tokens .fresh)
                       (sprig--format-tokens .read)
                       (sprig--format-tokens .out))))))))))

(defun sprig--usage-consumption (buf)
  "Sum the local logs' token consumption and add it to BUF, asynchronously.
Local logs only: the gauges above are account-wide already, and a remote
host's logs would double-count the sessions this machine also ran.  The
count is a python pass over every JSONL (`sprig--usage-consumption-script'),
off the Emacs thread because the logs run to megabytes."
  (let ((out (generate-new-buffer " *sprig-usage-count*")))
    (make-process
     :name "sprig-usage-count" :buffer out :noquery t
     :command (list "python3" "-c" sprig--usage-consumption-script
                    (expand-file-name (sprig--projects-directory)))
     :sentinel
     (lambda (proc _event)
       (unless (process-live-p proc)
         (let ((rows (and (eq (process-exit-status proc) 0)
                          (ignore-errors
                            (with-current-buffer out
                              (json-parse-string (buffer-string)
                                                 :object-type 'alist
                                                 :array-type 'list
                                                 :null-object nil))))))
           (kill-buffer out)
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (sprig--usage-consumption-insert rows)))))))))

(define-derived-mode sprig-usage-mode special-mode "Sprig-Usage"
  "Major mode for the plan-usage view (see `sprig-usage').
Read-only gauges; `g' refetches."
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function (lambda (&rest _) (sprig-usage))))

;;;###autoload
(defun sprig-usage ()
  "Show the plan's rolling usage limits (the CLI's `/usage', as a buffer).
Fetches the account usage endpoint with the local login's token,
asynchronously, and renders the reply into `*sprig-usage*'; also on the
navigator's `S u'.  Needs a `claude' login on this machine (the plain CLI's
or `sprig-config-directory''s); the limits shown are account-wide, so they
cover remote hosts too."
  (interactive)
  (let ((token (sprig--usage-token))
        (buf (get-buffer-create sprig-usage-buffer-name)))
    (unless token
      (user-error "No Claude login found (no readable .credentials.json)"))
    (with-current-buffer buf
      (unless (derived-mode-p 'sprig-usage-mode) (sprig-usage-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Fetching plan usage...\n" 'face 'shadow))))
    (pop-to-buffer buf)
    (let ((url-request-extra-headers
           `(("Authorization" . ,(concat "Bearer " token))
             ("anthropic-beta" . "oauth-2025-04-20"))))
      (url-retrieve
       sprig--usage-endpoint
       (lambda (status)
         ;; In the retrieval buffer.  Take what the render needs out of it,
         ;; kill it, then paint the view; a dead view buffer just drops the
         ;; reply.
         (let* ((code (and (boundp 'url-http-response-status)
                           url-http-response-status))
                (data (and (not (plist-get status :error))
                           (eq code 200)
                           (ignore-errors
                             (goto-char url-http-end-of-headers)
                             (json-parse-string
                              (decode-coding-string
                               (buffer-substring-no-properties
                                (point) (point-max))
                               'utf-8)
                              :object-type 'alist :array-type 'list
                              :null-object nil)))))
           (kill-buffer (current-buffer))
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (if data
                   (progn (sprig--usage-render data)
                          (sprig--usage-consumption buf))
                 (let ((inhibit-read-only t))
                   (erase-buffer)
                   (insert (propertize
                            (if (eq code 401)
                                "Login token rejected (HTTP 401): run the \
`claude' CLI once to refresh it, then `g'.\n"
                              (format "Usage fetch failed%s.\n"
                                      (if code (format " (HTTP %s)" code) "")))
                            'face 'error))))))))
       nil t t))))

;;;; Development

(defconst sprig--source-directory
  (file-name-directory (or load-file-name buffer-file-name
                           (locate-library "sprig")))
  "Directory sprig's own source files were loaded from, for `sprig-reload'.")

(defvar sprig--source-files
  '("sprig-review" "sprig" "sprig-review-mode")
  "Sprig's own source files, in dependency load order, for `sprig-reload'.")

(defun sprig--undefine-faces ()
  "Drop the definitions of sprig's own faces, so a reload re-applies them.
`defface' declares a face only when it is not already defined, so simply
re-loading a file leaves an edited face spec with its stale attributes
until Emacs restarts, which is the very thing `sprig-reload' is meant to
spare you.  Clearing `face-defface-spec' makes the next `defface' take.
A face customized or themed by the user keeps that, since those specs
override the defface one anyway."
  (dolist (face (face-list))
    (when (string-prefix-p "sprig-" (symbol-name face))
      (put face 'face-defface-spec nil))))

(declare-function sprig-review--suppress-section-highlight "sprig-review-mode")

(defun sprig--resettle-review-buffers ()
  "Re-apply the review mode's settings in buffers already in that mode.
A major mode body runs once, when the buffer is created, so a review
buffer opened before an edit keeps the settings the old body gave it: a
reload alone cannot reach them, the way it cannot reach faces (see
`sprig--undefine-faces').  Re-applying beats re-running the mode, which
would take the buffer's session and section state down with it."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'sprig-review-mode)
        (sprig-review--suppress-section-highlight)))))

;;;###autoload
(defun sprig-reload ()
  "Reload sprig's source files from disk, in dependency order.
A development convenience: after editing any of `sprig-review', `sprig',
or `sprig-review-mode', re-load all three from `sprig--source-directory'
so the change takes effect without restarting Emacs.  The `.el' source is
loaded, not any stale byte code beside it.  Edited faces take effect too
\(see `sprig--undefine-faces'), as do the review mode's settings (see
`sprig--resettle-review-buffers').  Open buffers keep their state; only
their behaviour picks up the new definitions."
  (interactive)
  (sprig--undefine-faces)
  (dolist (file sprig--source-files)
    (load (expand-file-name (concat file ".el") sprig--source-directory) nil t))
  (sprig--resettle-review-buffers)
  ;; The navigator's column format is fixed at mode init, so an open one keeps
  ;; a stale header across a reload; re-apply it and repaint, keeping the
  ;; buffer's fold, filter, and preview state.
  (when-let ((buf (get-buffer sprig-status-buffer-name)))
    (with-current-buffer buf
      (when (derived-mode-p 'sprig-status-mode)
        (sprig--status-apply-format)
        (sprig--status-scan-invalidate)
        (sprig--status-render))))
  (message "sprig: reloaded %d files from %s"
           (length sprig--source-files) sprig--source-directory))

(provide 'sprig)
;;; sprig.el ends here
