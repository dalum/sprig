;;; sprig.el --- Non-linear agent conversations in Markdown -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.4.1
;; Package-Requires: ((emacs "28.1") (magit-section "4.0.0"))
;; Keywords: tools, convenience, ai

;;; Commentary:

;; Sprig is an Emacs interface for conversing with an LLM agent.  A
;; conversation branch is a plain Markdown file you edit directly: you
;; type your turns as prose and the agent's replies stream in below them.
;;
;; Structure lives in invisible HTML-comment sentinels, never in the
;; prose, so tool output can't be mistaken for markup:
;;
;;   <!-- sprig:reply id=r1 -->      ... <!-- sprig:end id=r1 -->
;;   <!-- sprig:tool id=t1 name=Bash --> ... <!-- sprig:tool-end id=t1 -->
;;   <!-- sprig:result id=t1 -->     ... <!-- sprig:result-end id=t1 -->
;;
;; A reply is the prose (plus tool blocks) between a `reply' and its
;; `end'; your turns are the gaps.  Tool input and output sit in fenced
;; code blocks between the tool/result sentinels.  `sprig-mode' hides the
;; sentinels behind overlay "chrome" -- a `\U0001F527' header per tool
;; call, a `↳ result' header per result, a faint rule between turns --
;; and folds each tool body to its header (C-c C-f toggles).  The files
;; are meant for Emacs, not GitHub.
;;
;; Tool activity can be verbose, so `sprig-render-tools' (default
;; `none': omit tool calls and results) controls how much lands in the
;; transcript.  A file overrides it with a `sprig_tools:'
;; frontmatter line (none / calls / full), or `M-x sprig-set-tool-display'
;; sets it.  The setting affects only turns rendered afterwards.
;;
;; Today the transport is the `claude' CLI's stream-json protocol over
;; stdio, local or via `ssh HOST claude ...' (set `sprig-remote').  The
;; CLI uses whatever it is logged in as (e.g. a Pro/Max subscription), so
;; no API key is required.  The agent runs with its normal tools, so a
;; reply may run commands and edit files.  It works in the conversation
;; file's directory unless a `working_dir:' frontmatter line (or the
;; `sprig-directory' default) points it elsewhere.  Starting a new
;; session prompts for that directory and records the answer in the
;; frontmatter.
;;
;; One buffer is one branch.  Connect with `sprig-connect', type a
;; message below the last reply, and send it with `sprig-send' (C-c C-c).
;; The CLI session id is stored in the file's YAML frontmatter
;; (`claude_session') so the conversation survives an Emacs restart and
;; reconnects with --resume.
;;
;; Design note: the CLI keeps conversation memory server-side and resumes
;; by session id, so `sprig-send' transmits only the new user turn.  The
;; intended "context is the whole file" model from DESIGN.md (needed for
;; fork-by-copy) wants a full-transcript replay, which suits a stateless
;; messages backend.  `sprig--turns' assembles that role-tagged message
;; list already; wiring it to a stateless backend, plus the fork-by-copy
;; navigator, is the next slice.

;;; Code:

(require 'json)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'sprig-review)                  ; pure data layer; no magit-section
(eval-when-compile (require 'let-alist))

(defgroup sprig nil
  "Non-linear agent conversations in Markdown."
  :group 'tools
  :prefix "sprig-")

(defcustom sprig-program "claude"
  "Path to the `claude' CLI (on the machine where the session runs)."
  :type 'string)

(defcustom sprig-remote nil
  "If non-nil, an SSH destination (e.g. \"user@host\") to run `claude' on.
When nil, the session runs locally."
  :type '(choice (const :tag "Local" nil) (string :tag "SSH destination")))

(defcustom sprig-ssh-program "ssh"
  "SSH client used when `sprig-remote' is set."
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

(defcustom sprig-model "claude-opus-4-8"
  "Model id, or nil to let the CLI choose its default."
  :type '(choice (const :tag "CLI default" nil) (string :tag "Model id")))

(defcustom sprig-system-prompt
  "You are chatting inside a Markdown buffer. Answer concisely in Markdown."
  "Text appended to the system prompt, or nil to skip."
  :type '(choice (const :tag "None" nil) string))

(defcustom sprig-extra-args nil
  "Extra arguments appended to the `claude' command line."
  :type '(repeat string))

(defcustom sprig-auto-title t
  "When non-nil, name a titleless buffer after its first reply.
A short side query (a throwaway `claude' run using `sprig-model') turns
the first exchange into a label, stored as a `title:' frontmatter line
and shown in the `sprig-status' navigator.  A `title:' you set by hand
is always left untouched."
  :type 'boolean)

(defcustom sprig-fold-tool-calls t
  "When non-nil, fold tool-call and result blocks to their header.
Folding hides the body in this buffer only; the full content stays in
the file.  Toggle the block at point with `sprig-toggle-fold', or use
`sprig-fold-all' / `sprig-unfold-all'."
  :type 'boolean)

(defcustom sprig-render-tools 'none
  "How much tool activity to render into the transcript.
`none'   -- omit tool calls and results entirely.
`calls'  -- show each tool call, omit its (often large) result.
`full'   -- show tool calls and their results.

A file overrides this in its YAML frontmatter with a `sprig_tools:' line
whose value is none, calls, or full.  Because results are omitted rather
than hidden, the setting affects only turns rendered after it is set."
  :type '(choice (const :tag "None" none)
                 (const :tag "Calls only" calls)
                 (const :tag "Calls and results" full)))

(defcustom sprig-hide-sentinels t
  "When non-nil, hide the `sprig:' comment sentinels behind overlay chrome.
Each tool/result sentinel is replaced by a header line and the reply
sentinel by a rule.  Set nil to see the raw sentinels (e.g. debugging)."
  :type 'boolean)

(defcustom sprig-reply-divider t
  "When non-nil, draw a faint rule where each reply begins and ends."
  :type 'boolean)

(defcustom sprig-highlight-user-input t
  "When non-nil, give your typed turns the `sprig-user-input' face.
This sets them off from the agent's replies (the gaps between an `end'
sentinel and the next `reply')."
  :type 'boolean)

(defcustom sprig-error-buffer "*sprig-errors*"
  "Name of the buffer where session failures are logged.
When a session exits abnormally, its command, exit status, and captured
stderr are appended here and the buffer is displayed."
  :type 'string)

(defcustom sprig-show-cost nil
  "When non-nil, append each turn's reported cost to the done message.
The CLI's `total_cost_usd' is a notional API-equivalent figure, not real
spend on a Pro/Max subscription, so it is off by default."
  :type 'boolean)

(defcustom sprig-status-directories nil
  "Directories the `sprig-status' navigator scans for branch files.
When nil, scan the directories of the open Sprig buffers plus
`sprig-directory' (skipped for a remote session, whose files live on the
SSH host).  Each entry may use a leading `~'."
  :type '(choice (const :tag "Auto (open buffers + sprig-directory)" nil)
                 (repeat directory)))

(defcustom sprig-status-preview-max-lines 3
  "Maximum number of lines shown in a navigator inline reply preview.
`sprig-status-toggle-preview' (bound to TAB) expands the row at point to
show the tail of that session's last reply, filled to this many lines."
  :type 'integer)

(defface sprig-tool '((t :inherit font-lock-keyword-face :weight bold))
  "Face for tool-call and result header labels.")

(defface sprig-status-preview '((t :inherit shadow :slant italic))
  "Face for the inline reply preview shown under an expanded navigator row.")

(defface sprig-divider '((t :inherit shadow))
  "Face for the rule drawn at the start of a reply.")

(defface sprig-user-input '((t :slant italic))
  "Face for your typed turns, distinguishing them from agent replies.
The default sets only the slant so Markdown's own colouring shows through;
customise it (e.g. add a background) to taste.")

;;;; Buffer-local state

(defvar-local sprig--process nil
  "The stream-json `claude' process bound to this conversation buffer.")
(defvar-local sprig--session-id nil
  "Session id captured from the CLI, used for --resume.")
(defvar-local sprig--marker nil
  "Marker where streamed reply text is inserted.")
(defvar-local sprig--busy nil
  "Non-nil while a turn is in flight.")
(defvar-local sprig--reply-id nil
  "Id of the reply currently streaming, e.g. \"r3\".")
(defvar-local sprig--emitted nil
  "Non-nil once the current reply has had text inserted.
Used to separate consecutive content blocks with a paragraph break.")
(defvar-local sprig--blocks nil
  "Alist of in-flight streaming tool-use blocks, keyed by block index.
Each entry is (INDEX :id ID :name NAME :json ACC), where ACC accumulates
the streamed `input_json_delta' fragments until the block closes.")
(defvar-local sprig--undo-handle nil
  "Change-group handle bracketing the in-flight turn's edits.
Opened in `sprig--start-reply' and amalgamated in `sprig--close-reply' so
a whole streamed reply collapses to a single undo step.")
(defvar-local sprig--title-process nil
  "In-flight side process generating this buffer's `title:', or nil.")
(defvar-local sprig--review-buffer nil
  "Attached read-only review buffer mirroring this conversation, or nil.
When set, `sprig--handle' tees each transport event to it, so a live turn
streams into the review buffer as well as the Markdown transcript.")
(defvar-local sprig--permission-mode nil
  "The session's current permission mode, tracked from `status' events.
nil until the CLI reports one; \"plan\" while a plan turn is in effect.")
(defvar-local sprig--control-counter 0
  "Monotonic counter for control-request ids on this buffer's session.")
(defvar-local sprig--sink #'sprig--markdown-sink
  "Function applied to each transport event in this session-owning buffer.
The Markdown surface renders events into the transcript and tees them to
any attached review buffer; a review buffer that owns its own session
sets this to fold the events straight into its model instead.")
(defvar-local sprig--connect-fn #'sprig-connect
  "Command that (re)starts this buffer's session, called with a NO-PROMPT arg.
Lets the transport reconnect a stale session without caring whether the
owning buffer is a Markdown transcript or a review buffer.")
(defvar-local sprig--working-dir nil
  "Working directory for a session not backed by a Markdown file.
A review buffer owns its session directly and has no frontmatter, so it
records the session's directory here for `sprig--directory'.")

;;;; Sentinel grammar

;; Structural markers.  Always an HTML comment, alone on its line, at
;; column 0.  The KIND alternation lists the `-end' variants first so a
;; `tool-end' line is never misread as `tool'.
(defconst sprig--sentinel-re
  "^<!-- sprig:\\(reply\\|end\\|tool-end\\|tool\\|result-end\\|result\\)\\([^\n]*?\\) *-->[ \t]*$"
  "Regexp matching any `sprig:' sentinel line.
Group 1 is the kind, group 2 the attribute text (id, name, flags).")
(defconst sprig--reply-open-re "^<!-- sprig:reply\\b\\([^\n]*?\\) *-->[ \t]*$"
  "Regexp matching a reply-open sentinel line.  Group 1 is its attribute text.")
(defconst sprig--reply-end-re "^<!-- sprig:end\\b[^\n]*-->[ \t]*$"
  "Regexp matching a reply-close sentinel line.")
(defconst sprig--tool-open-re "^<!-- sprig:\\(?:tool\\|result\\) "
  "Regexp matching a tool-call or result open sentinel line.")
(defconst sprig--tool-close-re "^<!-- sprig:\\(?:tool\\|result\\)-end\\b"
  "Regexp matching a tool-call or result close sentinel line.")

;;;; Command construction

(defun sprig--base-args ()
  "The `claude' argument list (without program / ssh wrapping)."
  (append
   (list "-p"
         "--input-format" "stream-json"
         "--output-format" "stream-json"
         "--include-partial-messages"
         "--verbose")           ; tools follow the CLI's own permission config
   (when sprig-model (list "--model" sprig-model))
   (when sprig-system-prompt
     (list "--append-system-prompt" sprig-system-prompt))
   (when sprig--session-id
     (list "--resume" sprig--session-id))
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

(defun sprig--command ()
  "Full command vector for `make-process', local or via SSH.
A local session's working directory is set by `sprig-connect' binding
`default-directory'; a remote session's is set here by prefixing a `cd'."
  (let ((args (cons sprig-program (sprig--base-args)))
        (dir (sprig--directory)))
    (if sprig-remote
        (let ((remote (mapconcat #'shell-quote-argument args " ")))
          (when dir
            (setq remote (concat "cd " (sprig--remote-dir-arg dir)
                                 " && exec " remote)))
          (append (list sprig-ssh-program)
                  sprig-ssh-args
                  (list sprig-remote remote)))
      args)))

;;;; Buffer parsing: frontmatter, turns

(defun sprig--body-start ()
  "Return the position where the body begins, after any YAML frontmatter.
This is the line after the closing `---', or `point-min' when there is
no frontmatter."
  (let ((end (sprig--frontmatter-end)))
    (if end
        (save-excursion (goto-char end) (forward-line 1) (point))
      (point-min))))

(defun sprig--clean-reply (text)
  "Strip tool and result blocks from reply TEXT, leaving prose."
  (string-trim
   (replace-regexp-in-string
    "\n\\{3,\\}" "\n\n"
    (replace-regexp-in-string
     "<!-- sprig:\\(?:tool\\|result\\)\\b\\(?:.\\|\n\\)*?<!-- sprig:\\(?:tool\\|result\\)-end[^\n]*-->[ \t]*\n?"
     "" text))))

(defun sprig--turns ()
  "Parse the buffer body into an ordered list of (ROLE . TEXT) turns.
ROLE is `user' or `assistant'.  Blank user turns are skipped.  Assistant
text has its tool/result blocks stripped.  This is the role-tagged
message list a stateless backend would send verbatim."
  (let ((turns '()))
    (save-excursion
      (goto-char (sprig--body-start))
      (let ((pos (point)))
        (while (re-search-forward sprig--reply-open-re nil t)
          (let ((user-text (buffer-substring-no-properties pos (match-beginning 0)))
                (reply-beg (progn (forward-line 1) (point))))
            (when (string-match-p "[^ \t\n]" user-text)
              (push (cons 'user (string-trim user-text)) turns))
            (if (re-search-forward sprig--reply-end-re nil t)
                (let ((atext (buffer-substring-no-properties
                              reply-beg (match-beginning 0))))
                  (push (cons 'assistant (sprig--clean-reply atext)) turns)
                  (forward-line 1)
                  (setq pos (point)))
              ;; Unterminated reply (still streaming): take the rest.
              (let ((atext (buffer-substring-no-properties reply-beg (point-max))))
                (push (cons 'assistant (sprig--clean-reply atext)) turns)
                (goto-char (point-max))
                (setq pos (point))))))
        (let ((tail (buffer-substring-no-properties pos (point-max))))
          (when (string-match-p "[^ \t\n]" tail)
            (push (cons 'user (string-trim tail)) turns)))))
    (nreverse turns)))

(defun sprig--pending-user-text ()
  "Return the trailing user turn (text typed after the last reply), or nil."
  (let ((last (car (last (sprig--turns)))))
    (when (eq (car last) 'user) (cdr last))))

;;;; Transport and sink
;;
;; The transport turns the backend's raw output lines into a small,
;; backend-neutral event vocabulary; the sink applies those events to the
;; conversation buffer.  `sprig--handle' is the seam.  Only the
;; `sprig--claude-*' functions know the `claude' CLI's stream-json wire
;; format, so another backend means another parser emitting the same
;; events, with the sink (`sprig--dispatch' and the emit functions)
;; untouched.
;;
;; An event is a list whose car is the tag:
;;   (session ID)              session id captured from the backend
;;   (text-block)              a new text block began; separate it
;;   (text STR)                assistant text to insert
;;   (tool-call ID NAME INPUT) a completed tool-use call (INPUT is JSON)
;;   (tool-result ID ERR TEXT) a tool result (ERR non-nil means error)
;;   (done COST ERR)           the turn finished
;;   (mode MODE)               the session's permission mode (e.g. "plan")
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

(defun sprig--markdown-sink (event)
  "Default sink: render EVENT into the Markdown transcript, tee to review."
  (sprig--dispatch event)
  (sprig--tee-review event))

(defun sprig--tee-review (event)
  "Forward EVENT to this buffer's attached review buffer, if any."
  (when (and sprig--review-buffer (buffer-live-p sprig--review-buffer)
             (fboundp 'sprig-review-consume))
    (with-current-buffer sprig--review-buffer
      (sprig-review-consume event))))

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
         ;; a `set_permission_mode' control request switches to plan.
         ((and (equal .type "system") (equal .subtype "status") .permissionMode)
          (list (list 'mode .permissionMode)))
         ;; Streaming assistant content (text and tool-use blocks).
         ((equal .type "stream_event")
          (cond
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
         ((equal .type "user")
          (sprig--claude-tool-results
           (and (listp .message) (alist-get 'content .message))))
         ;; Turn complete.
         ((equal .type "result")
          (list (list 'done .total_cost_usd .is_error)))
         ;; A non-streamed error surfaced as a result-less error.
         ((and (equal .type "system") (equal .subtype "error"))
          (list (list 'error (or .message line)))))))))

;;; Sink: apply a normalised event to the conversation buffer

(defun sprig--dispatch (event)
  "Apply one normalised transport EVENT to the current conversation buffer."
  (pcase event
    (`(session ,id)
     (when (and id (not sprig--session-id))
       (setq sprig--session-id id)
       (sprig--save-session-id id)))
    (`(text-block) (sprig--block-separator))
    (`(text ,text) (sprig--emit text))
    (`(tool-call ,id ,name ,input) (sprig--emit-tool-call id name input))
    (`(tool-result ,id ,is-error ,text)
     (sprig--emit-tool-result id is-error text))
    (`(done ,cost ,is-error) (sprig--finish-turn cost is-error))
    (`(mode ,mode) (setq sprig--permission-mode mode))
    (`(error ,message) (sprig--emit (format "\n[error] %s\n" message)))))

(defun sprig--emit (text)
  "Insert streamed TEXT at the reply marker in the current buffer."
  (when (and sprig--marker (marker-buffer sprig--marker))
    (save-excursion
      (goto-char sprig--marker)
      (let ((inhibit-read-only t))
        (insert text))
      (set-marker sprig--marker (point)))
    (setq sprig--emitted t)))

(defun sprig--block-separator ()
  "Put exactly one blank line before a new block.
No-op until the reply has already emitted content, so it never disturbs
the scaffold that precedes the first block."
  (when (and sprig--emitted sprig--marker (marker-buffer sprig--marker))
    (let (line-beg)
      (save-excursion
        (goto-char sprig--marker)
        (let ((inhibit-read-only t))
          (skip-chars-backward " \t\n")
          (setq line-beg (line-beginning-position))
          (delete-region (point) (marker-position sprig--marker))
          (insert "\n\n"))
        (set-marker sprig--marker (point)))
      ;; The line we backed onto may be a hidden `-end' sentinel whose
      ;; trailing newline this rewrite just displaced; re-chrome it so the
      ;; sentinel stays swallowed rather than surfacing as a blank line.
      (sprig--decorate-region line-beg (marker-position sprig--marker)))))

(defun sprig--pretty-json (raw)
  "Pretty-print RAW JSON text; return it trimmed if it will not parse."
  (let ((s (string-trim (or raw ""))))
    (if (string-empty-p s)
        "{}"
      (condition-case nil
          (with-temp-buffer
            (insert s)
            (json-pretty-print-buffer)
            (string-trim (buffer-string)))
        (error s)))))

(defun sprig--tool-result-text (content)
  "Flatten a tool_result CONTENT field (string or block list) to text."
  (cond
   ((stringp content) content)
   ((listp content)
    (mapconcat (lambda (b)
                 (if (stringp b) b (let-alist b (or .text ""))))
               content ""))
   (t (format "%S" content))))

(defun sprig--tool-input (name json)
  "Return (LANG . BODY) for how to render tool NAME's input JSON.
Shows the command for Bash, the path for file tools, else pretty JSON."
  (let ((obj (ignore-errors
               (json-parse-string
                (if (string-empty-p (string-trim (or json ""))) "{}" json)
                :object-type 'alist :null-object nil :false-object nil))))
    (cond
     ((and (equal name "Bash") (alist-get 'command obj))
      (cons "bash" (alist-get 'command obj)))
     ((and (member name '("Read" "Edit" "Write" "NotebookEdit"))
           (alist-get 'file_path obj))
      (cons "" (alist-get 'file_path obj)))
     (t (cons "json" (sprig--pretty-json json))))))

;;;; Rendering: sentinel-delimited fenced blocks

(defun sprig--emit-block (open lang body end)
  "Insert an OPEN..END sentinel pair wrapping a fenced BODY, then decorate.
LANG is the fence info string.  When folding is on, the body is folded."
  (when (and sprig--marker (marker-buffer sprig--marker))
    (sprig--block-separator)
    (let (open-bol)
      (save-excursion
        (goto-char sprig--marker)
        (setq open-bol (point))
        (let ((inhibit-read-only t))
          ;; The trailing newline completes the hidden END sentinel's line
          ;; now, so `sprig--decorate-region' can swallow it; the separator
          ;; before the next block normalises the whitespace away again.
          (insert open "\n"
                  "```" (or lang "") "\n" body "\n```\n"
                  end "\n")
          (set-marker sprig--marker (point))
          (setq sprig--emitted t)
          (when sprig-fold-tool-calls
            (sprig--fold-block-at open-bol))))
      (sprig--decorate-region open-bol (marker-position sprig--marker)))))

(defun sprig--emit-tool-call (id name json)
  "Render a tool-call block for tool NAME (id ID) with input JSON.
Skipped when `sprig--tool-display' is `none'."
  (unless (eq (sprig--tool-display) 'none)
    (let ((in (sprig--tool-input name json)))
      (sprig--emit-block
       (format "<!-- sprig:tool id=%s name=%s -->" (or id "t") (or name "tool"))
       (car in) (cdr in)
       (format "<!-- sprig:tool-end id=%s -->" (or id "t"))))))

(defun sprig--emit-tool-result (id is-error text)
  "Render a tool result block (ID, IS-ERROR flag, TEXT body).
Rendered only when `sprig--tool-display' is `full'."
  (when (eq (sprig--tool-display) 'full)
    (sprig--emit-block
     (format "<!-- sprig:result id=%s%s -->" (or id "t") (if is-error " error" ""))
     "" text
     (format "<!-- sprig:result-end id=%s -->" (or id "t")))))

(defun sprig--finish-turn (cost is-error)
  "Close out the current turn.  COST and IS-ERROR come from the result event."
  (setq sprig--busy nil)
  (sprig--close-reply)
  (when (and sprig--marker (marker-buffer sprig--marker))
    (goto-char sprig--marker))
  (message "sprig: turn done%s%s"
           (if (and sprig-show-cost cost) (format " ($%.4f)" cost) "")
           (if is-error " [error]" ""))
  (unless is-error (sprig--maybe-generate-title))
  (sprig--status-refresh))

;;;; Auto title

(defun sprig--truncate (s n)
  "Return the first N characters of S."
  (if (> (length s) n) (substring s 0 n) s))

(defun sprig--truncate-words (s n)
  "Truncate S to at most N characters, backing off to a word boundary.
A back-off happens only when the cut falls inside a word, so a label that
ends cleanly at the limit is kept whole."
  (if (<= (length s) n) s
    (let ((cut (substring s 0 n)))
      (if (and (not (string-match-p "\\s-" (substring s n (1+ n))))
               (string-match-p "\\s-" cut))
          (replace-regexp-in-string "\\s-+\\S-*\\'" "" cut)
        cut))))

(defun sprig--title-prompt (user reply)
  "Build the naming prompt from the first USER turn and first REPLY.
Mirrors the CLI's own session-naming recipe: the opening exchange plus an
instruction to answer with only a short, specific label."
  (concat "User: \"" (sprig--truncate (string-trim user) 300) "\""
          (if (and reply (not (string-empty-p (string-trim reply))))
              (concat "\nAgent: \"" (sprig--truncate (string-trim reply) 300) "\"")
            "")
          "\n\nGenerate a short label (2-5 words) naming this conversation. "
          "Include the MOST SPECIFIC identifier (component/file/feature). "
          "Skip generic verbs like fix/add/update. Respond with ONLY the label."))

(defun sprig--title-command (prompt)
  "Command vector for a throwaway `claude' run that answers PROMPT.
No session resume, no tools, plain-text output; SSH-wrapped like a session
when `sprig-remote' is set."
  (let ((args (append (list sprig-program "-p" prompt "--allowedTools" "")
                      (when sprig-model (list "--model" sprig-model)))))
    (if sprig-remote
        (append (list sprig-ssh-program) sprig-ssh-args
                (list sprig-remote (mapconcat #'shell-quote-argument args " ")))
      args)))

(defun sprig--clean-title (raw)
  "Normalise RAW model output into a session label, or nil if degenerate.
Takes the first non-empty line, strips surrounding quotes, lower-cases it,
and caps it at 40 characters, matching the CLI's post-processing."
  (let ((line (seq-find (lambda (l) (not (string-empty-p l)))
                        (mapcar #'string-trim (split-string (or raw "") "\n")))))
    (when line
      (let ((s (string-trim
                (replace-regexp-in-string "\\`[\"'`]+\\|[\"'`.]+\\'" ""
                                          (downcase line)))))
        (when (string-match-p "[a-z0-9]" s)
          (sprig--truncate-words s 40))))))

(defun sprig--maybe-generate-title ()
  "Start async title generation for a titleless buffer, if warranted.
No-op when `sprig-auto-title' is off, a `title:' already exists, a
generation is already in flight, or there is no user turn to summarise."
  (when (and sprig-auto-title
             (not (sprig--frontmatter-get "title"))
             (not (process-live-p sprig--title-process)))
    (let ((turns (sprig--turns)))
      (let ((user (cdr (assq 'user turns)))
            (reply (cdr (assq 'assistant turns))))
        (when (and user (not (string-empty-p (string-trim user))))
          (sprig--start-title-generation user reply))))))

(defun sprig--start-title-generation (user reply)
  "Spawn the side query that names this buffer from USER and REPLY."
  (let ((conv (current-buffer))
        (out (generate-new-buffer " *sprig-title*")))
    (setq sprig--title-process
          (make-process
           :name "sprig-title"
           :buffer out
           :command (sprig--title-command (sprig--title-prompt user reply))
           :connection-type 'pipe
           :coding 'utf-8-unix
           :noquery t
           :stderr (make-pipe-process :name "sprig-title-stderr" :buffer nil
                                      :noquery t :filter #'ignore :sentinel #'ignore)
           :sentinel (lambda (proc _event)
                       (unless (process-live-p proc)
                         (sprig--title-finish conv proc)))))))

(defun sprig--title-finish (conv proc)
  "Apply PROC's output as CONV's `title:', unless one appeared meanwhile."
  (let ((raw (and (buffer-live-p (process-buffer proc))
                  (with-current-buffer (process-buffer proc) (buffer-string)))))
    (when (buffer-live-p (process-buffer proc))
      (kill-buffer (process-buffer proc)))
    (when (buffer-live-p conv)
      (with-current-buffer conv
        (setq sprig--title-process nil)
        (let ((label (sprig--clean-title raw)))
          (when (and label (not (sprig--frontmatter-get "title")))
            (sprig--frontmatter-set "title" label)
            (sprig--status-refresh)))))))

(defun sprig--make-stderr ()
  "Return a pipe process that accumulates the session's stderr.
Routing stderr here keeps its non-JSON diagnostics out of `sprig--filter',
which would otherwise silently drop them.  The text is read back from the
process property `:acc' when the main process exits."
  (make-pipe-process
   :name "sprig-stderr"
   :buffer nil
   :noquery t
   :coding 'utf-8-unix
   :filter (lambda (proc chunk)
             (process-put proc :acc (concat (or (process-get proc :acc) "") chunk)))
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
      (let ((err (and stderr-proc (process-get stderr-proc :acc)))
            (status (process-exit-status proc))
            (deliberate (process-get proc :deliberate)))
        (when (process-live-p stderr-proc)
          (delete-process stderr-proc))
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (setq sprig--process nil
                  sprig--busy nil)
            (sprig--status-refresh)
            (cond
             ;; A clean, expected teardown: interrupt, disconnect, or exit 0.
             ((or deliberate (and (eq (process-status proc) 'exit)
                                  (zerop status)))
              (message "sprig: session ended (%s)" (string-trim event)))
             ;; Stale/foreign resume id: the session does not exist on this
             ;; host.  Drop it and reconnect fresh so the user is not stuck;
             ;; the transcript in the file is kept, and the new session's id
             ;; overwrites the stale one on init.  Only server-side memory of
             ;; the prior turns is lost, and that was already gone.
             ((and err sprig--session-id
                   (string-match-p sprig--session-not-found-re err))
              (let ((stale sprig--session-id))
                (sprig--clear-session-id)
                (message "sprig: session %s not found here; starting fresh (prior turns are not replayed)"
                         stale)
                (funcall sprig--connect-fn t)))
             ;; An unexpected exit: surface why in the error buffer.
             (t
              (sprig--log-error
               buf (format "session %s" (string-trim event)) err)
              (message "sprig: session failed (%s); see %s"
                       (string-trim event) sprig-error-buffer)))))))))

;;;; Overlay chrome: hide sentinels, show headers and rules

(defun sprig--ensure-invisibility ()
  "Make sure this buffer honours the `sprig-fold' and `sprig-chrome' specs.
Registers them if missing, so display works even when the code is
reloaded while `sprig-mode' is already on."
  (unless (and (listp buffer-invisibility-spec)
               (assq 'sprig-fold buffer-invisibility-spec))
    (add-to-invisibility-spec '(sprig-fold . t)))     ; folds show an ellipsis
  (unless (and (listp buffer-invisibility-spec)
               (memq 'sprig-chrome buffer-invisibility-spec))
    (add-to-invisibility-spec 'sprig-chrome)))         ; sentinels just vanish

(defun sprig--divider (&optional suffix)
  "Return a faint horizontal rule, with optional trailing SUFFIX text."
  (propertize (concat (make-string 48 ?─) (or suffix ""))
              'face 'sprig-divider))

(defun sprig--sentinel-label (kind attrs)
  "Return the display string for a sentinel of KIND with ATTRS, or nil.
The reply-open and reply-end sentinels become a rule, tool/result opens a
header line; the remaining close sentinels return nil (hidden)."
  ;; Labels carry no trailing newline: the sentinel line's own newline is
  ;; kept visible (see `sprig--decorate') so point can land after the header.
  (cond
   ((equal kind "reply")
    (when sprig-reply-divider
      (sprig--divider (if (string-match-p "interrupted" attrs)
                          "  (interrupted)" ""))))
   ((equal kind "end")
    (when sprig-reply-divider (sprig--divider)))
   ((equal kind "tool")
    (let ((name (and (string-match "name=\\(\\S-+\\)" attrs)
                     (match-string 1 attrs))))
      (propertize (concat "\U0001F527 " (or name "tool"))
                  'face 'sprig-tool)))
   ((equal kind "result")
    (propertize (concat "↳ result"
                        (if (string-match-p "error" attrs) " [error]" ""))
                'face 'sprig-tool))
   (t nil)))

(defun sprig--face-user (beg end)
  "Overlay the user-turn text in BEG..END with `sprig-user-input'.
Leading and trailing blank lines are trimmed so only real text is faced."
  (save-excursion
    (goto-char beg) (skip-chars-forward " \t\n") (setq beg (point))
    (goto-char end) (skip-chars-backward " \t\n" beg) (setq end (point))
    (when (< beg end)
      ;; Rear-advance so appending to a turn keeps the face.
      (let ((ov (make-overlay beg end nil nil t)))
        (overlay-put ov 'sprig-user t)
        (overlay-put ov 'face 'sprig-user-input)
        (overlay-put ov 'evaporate t)))))

(defun sprig--refresh-pending-face (&rest _)
  "Re-face the trailing user turn as it is typed.
Runs from `after-change-functions', so the text you type below the last
reply is faced live.  Only the pending region (after the last `end'
sentinel) is rescanned; settled turns are handled by `sprig--decorate'."
  (when (and sprig-highlight-user-input (not sprig--busy))
    (save-excursion
      (goto-char (point-max))
      (let ((beg (if (re-search-backward sprig--reply-end-re nil t)
                     (min (point-max) (1+ (line-end-position)))
                   (sprig--body-start))))
        (remove-overlays beg (point-max) 'sprig-user t)
        (sprig--face-user beg (point-max))))))

(defun sprig--decorate-user-turns ()
  "Face every user turn -- the gaps outside each reply..end span."
  (remove-overlays (point-min) (point-max) 'sprig-user t)
  (when sprig-highlight-user-input
    (save-excursion
      (goto-char (sprig--body-start))
      (let ((gap-beg (point)))
        (while (re-search-forward sprig--reply-open-re nil t)
          (sprig--face-user gap-beg (match-beginning 0))
          (if (re-search-forward sprig--reply-end-re nil t)
              (setq gap-beg (min (point-max) (1+ (point))))
            (setq gap-beg (point-max))
            (goto-char (point-max))))
        (sprig--face-user gap-beg (point-max))))))

(defun sprig--decorate-sentinels (beg end)
  "Give every `sprig:' sentinel line within BEG..END its chrome overlay.
The caller clears any existing chrome in the region first; BEG and END
should already bound whole lines.  Fold overlays are left untouched."
  (save-excursion
    (goto-char beg)
    (while (re-search-forward sprig--sentinel-re end t)
      ;; Capture the match bounds first: `sprig--sentinel-label' runs
      ;; `string-match' internally, which would clobber the match data.
      (let* ((mb (match-beginning 0))
             (me (match-end 0))
             (label (sprig--sentinel-label (match-string 1) (match-string 2)))
             ;; A labeled sentinel leaves its terminating newline visible so
             ;; point has somewhere to rest and vertical motion can cross the
             ;; header; an unlabeled (hidden) one swallows the newline so the
             ;; whole line disappears.
             (ov-end (if label me (min (point-max) (1+ me))))
             (ov (make-overlay mb ov-end)))
        (overlay-put ov 'sprig-chrome t)
        (overlay-put ov 'invisible 'sprig-chrome)
        (overlay-put ov 'evaporate t)
        (overlay-put ov 'modification-hooks '(sprig--edit-guard))
        (when label
          (overlay-put ov 'before-string label)
          ;; The sentinel's terminating newline is left visible (so point
          ;; can cross the header); guard just that char so it can't be
          ;; deleted, which would merge the next line into the hidden line.
          (when (< me (point-max))
            (let ((g (make-overlay me (1+ me))))
              (overlay-put g 'sprig-chrome t)
              (overlay-put g 'evaporate t)
              (overlay-put g 'modification-hooks '(sprig--edit-guard)))))))))

(defun sprig--decorate ()
  "Rebuild the chrome and user-turn overlays across the whole buffer.
Hides each sentinel line and, for open sentinels, shows a header or rule
in its place; faces the user turns between replies.  Leaves the fold
overlays untouched.  Used on mode enable and when reopening a file; the
streaming paths use `sprig--decorate-region' to stay bounded."
  (sprig--decorate-user-turns)
  (when sprig-hide-sentinels
    (sprig--ensure-invisibility)
    (remove-overlays (point-min) (point-max) 'sprig-chrome t)
    (sprig--decorate-sentinels (point-min) (point-max))))

(defun sprig--decorate-region (beg end)
  "Re-apply sentinel chrome to the whole lines spanned by BEG..END.
Bounded counterpart to `sprig--decorate' for a streamed insertion: a
reply that emits many tool blocks re-chromes each block's own lines
instead of rescanning the buffer, so decoration cost stays proportional
to the insertion, not the transcript.  User-turn faces are left alone,
since streamed content lands inside a reply span, never in a user gap."
  (when sprig-hide-sentinels
    (sprig--ensure-invisibility)
    (save-excursion
      (goto-char beg) (setq beg (line-beginning-position))
      ;; Extend END past the final line's newline so the removal sweeps up
      ;; any newline-guard overlay a labeled sentinel left there; otherwise
      ;; re-chroming the line would duplicate the guard.
      (goto-char end) (setq end (min (point-max) (1+ (line-end-position))))
      (remove-overlays beg end 'sprig-chrome t)
      (sprig--decorate-sentinels beg end))))

;;;; Folding

(defun sprig--edit-guard (_ov after _beg _end &optional _len)
  "Refuse interactive edits that would corrupt sprig's hidden structure.
A modification-hook shared by the fold overlays and the chrome sentinel
overlays: it fires before the change (AFTER nil) and aborts it, so a
stray DEL or backspace at a boundary cannot silently delete a folded
body or a hidden sentinel and break parsing.  Sprig's own writes bind
`inhibit-read-only', which opts out."
  (unless (or after inhibit-read-only)
    (user-error "Protected sprig structure here (unfold the block first if folded)")))

(defun sprig--fold-region (beg end)
  "Create (or refresh) a fold overlay hiding BEG..END."
  (sprig--ensure-invisibility)
  (when (< beg end)
    (remove-overlays beg end 'sprig-fold t)
    (let ((ov (make-overlay beg end)))
      (overlay-put ov 'invisible 'sprig-fold)
      (overlay-put ov 'sprig-fold t)
      (overlay-put ov 'evaporate t)
      (overlay-put ov 'modification-hooks '(sprig--edit-guard)))))

(defun sprig--fold-block-at (open-bol)
  "Fold the tool/result block whose open sentinel starts at OPEN-BOL.
The body runs from the end of the open line to the matching close
sentinel, so it is delimited by sentinels -- fences or `</details>' in
the tool output cannot move the boundary."
  (save-excursion
    (goto-char open-bol)
    (let ((fold-beg (line-end-position)))
      (forward-line 1)
      (when (re-search-forward sprig--tool-close-re nil t)
        (sprig--fold-region fold-beg (line-beginning-position))))))

(defun sprig--tool-block-at-point ()
  "Return the open-sentinel start of the tool block containing point, or nil.
Works from the header line or anywhere in the body."
  (let ((orig (point)))
    (save-excursion
      (end-of-line)
      (when (re-search-backward sprig--tool-open-re nil t)
        (let ((beg (line-beginning-position)))
          (forward-line 1)
          (when (re-search-forward sprig--tool-close-re nil t)
            (when (<= orig (line-end-position))
              beg)))))))

;;;; Reply scaffolding

(defun sprig--next-reply-id ()
  "Return a fresh reply id like \"r3\", one past the highest in the buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((n 0))
      (while (re-search-forward sprig--reply-open-re nil t)
        (setq n (1+ n)))
      (format "r%d" (1+ n)))))

(defun sprig--start-reply ()
  "Open a reply sentinel at end of buffer and arm the marker."
  (setq sprig--reply-id (sprig--next-reply-id))
  ;; Bracket every edit this turn makes (scaffold, streamed tokens, close
  ;; sentinel) so the whole reply collapses to one undo step, instead of
  ;; leaving hundreds of per-token entries in the undo history.
  (setq sprig--undo-handle (prepare-change-group))
  (goto-char (point-max))
  (skip-chars-backward " \t\n")
  (delete-region (point) (point-max))
  (let ((beg (point))
        (inhibit-read-only t))
    (insert "\n\n<!-- sprig:reply id=" sprig--reply-id " -->\n\n")
    (setq sprig--marker (copy-marker (point) t))
    (setq sprig--emitted nil)
    (setq sprig--blocks nil)
    ;; The user turn just above keeps its live-typed face; only the new
    ;; reply-open line needs chrome, so a bounded decorate suffices.
    (sprig--decorate-region beg (point))))

(defun sprig--close-reply (&optional interrupted)
  "Close the current reply.  With INTERRUPTED, flag the reply sentinel."
  (when (and sprig--marker (marker-buffer sprig--marker))
    (goto-char sprig--marker)
    (let ((inhibit-read-only t)
          beg)
      (skip-chars-backward " \t\n")
      (setq beg (point))
      (delete-region (point) (marker-position sprig--marker))
      (insert "\n<!-- sprig:end id=" (or sprig--reply-id "r") " -->\n")
      (set-marker sprig--marker (point))
      ;; `sprig--flag-interrupted' re-chromes the reply-open line it edits,
      ;; so here we only need to chrome the freshly inserted end sentinel.
      (when interrupted (sprig--flag-interrupted))
      (sprig--decorate-region beg (point))))
  ;; Fold the turn's edits into a single undo boundary.  Both the normal
  ;; finish and the interrupt path reach here; an unexpected process death
  ;; skips it, leaving ordinary per-edit undo for that partial reply.
  (when sprig--undo-handle
    (undo-amalgamate-change-group sprig--undo-handle)
    (setq sprig--undo-handle nil)))

(defun sprig--flag-interrupted ()
  "Add an `interrupted' flag to the current reply's open sentinel."
  (save-excursion
    (goto-char (if (and sprig--marker (marker-buffer sprig--marker))
                   (marker-position sprig--marker)
                 (point-max)))
    (when (re-search-backward sprig--reply-open-re nil t)
      (unless (string-match-p "interrupted" (match-string 1))
        (let ((inhibit-read-only t))
          (replace-match "<!-- sprig:reply\\1 interrupted -->"))
        ;; The edit evaporated this line's old chrome; re-chrome it so the
        ;; divider picks up the "(interrupted)" suffix.
        (sprig--decorate-region (line-beginning-position)
                                (line-end-position))))))

;;;; Session-id persistence via YAML frontmatter

(defun sprig--frontmatter-end ()
  "Return the position of the closing `---' line, or nil if no frontmatter."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at-p "^---[ \t]*$")
      (forward-line 1)
      (when (re-search-forward "^---[ \t]*$" nil t)
        (line-beginning-position)))))

(defun sprig--frontmatter-get (key)
  "Return the value of KEY in the YAML frontmatter, or nil."
  (let ((end (sprig--frontmatter-end)))
    (when end
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward
               (concat "^" (regexp-quote key) ":[ \t]*\\(.+\\)$") end t)
          (string-trim (match-string-no-properties 1)))))))

(defun sprig--frontmatter-set (key value)
  "Set KEY to VALUE in the YAML frontmatter, creating frontmatter if absent."
  (save-excursion
    (let ((inhibit-read-only t)
          (end (sprig--frontmatter-end))
          (line (concat key ": " value)))
      (if end
          (if (progn (goto-char (point-min))
                     (re-search-forward
                      (concat "^" (regexp-quote key) ":.*$") end t))
              (replace-match line t t)
            (goto-char (point-min))
            (forward-line 1)
            (insert line "\n"))
        (goto-char (point-min))
        (insert "---\n" line "\n---\n\n")))))

(defun sprig--frontmatter-remove (key)
  "Delete KEY's line from the YAML frontmatter, if present."
  (save-excursion
    (let ((inhibit-read-only t)
          (end (sprig--frontmatter-end)))
      (when end
        (goto-char (point-min))
        (when (re-search-forward
               (concat "^" (regexp-quote key) ":.*\n?") end t)
          (replace-match ""))))))

(defun sprig--buffer-session-id ()
  "Return the `claude_session' id from the YAML frontmatter, or nil."
  (sprig--frontmatter-get "claude_session"))

(defun sprig--save-session-id (id)
  "Store ID as `claude_session' in the buffer's YAML frontmatter."
  (sprig--frontmatter-set "claude_session" id))

(defun sprig--clear-session-id ()
  "Forget this buffer's session id, in memory and in the frontmatter.
Used when a stored id no longer resolves on the session host, so the next
connect starts a fresh session instead of resuming a dead one."
  (setq sprig--session-id nil)
  (sprig--frontmatter-remove "claude_session"))

(defun sprig--tool-display ()
  "Return the effective tool-render level for this buffer.
A `sprig_tools:' frontmatter line (none, calls, or full) overrides the
`sprig-render-tools' default."
  (let ((v (sprig--frontmatter-get "sprig_tools")))
    (if (member v '("none" "calls" "full"))
        (intern v)
      sprig-render-tools)))

(defun sprig--directory ()
  "Return the working directory configured for this buffer, or nil.
A `working_dir:' frontmatter line overrides the `sprig-directory' default.
The raw string is returned unexpanded, so a leading `~' or an
environment variable is resolved wherever the session runs."
  (let ((v (or sprig--working-dir
               (sprig--frontmatter-get "working_dir")
               sprig-directory)))
    (unless (or (null v) (string-empty-p (string-trim v)))
      (string-trim v))))

(defun sprig--save-working-directory (dir)
  "Record DIR as this buffer's `working_dir:' frontmatter.
A blank DIR removes the line so the session host's default is used."
  (if (and dir (not (string-empty-p (string-trim dir))))
      (sprig--frontmatter-set "working_dir" (string-trim dir))
    (sprig--frontmatter-remove "working_dir")))

(defun sprig--read-working-directory ()
  "Prompt for and record this buffer's working directory for a new session.
The minibuffer is seeded with the directory `sprig--directory' would use.
A remote directory is read as plain text since it lives on the SSH host;
a local one is completed against the filesystem."
  (let* ((current (sprig--directory))
         (input (if sprig-remote
                    (read-string
                     "Working directory (remote, blank = login dir): "
                     current)
                  (read-directory-name
                   "Working directory: "
                   (and current (file-name-as-directory
                                 (expand-file-name current)))))))
    (sprig--save-working-directory input)))

;;;; Public commands

;;;###autoload
(defun sprig-connect (&optional no-prompt)
  "Start (or resume) an agent session bound to the current buffer.
Starting a new session prompts for the working directory and records it
in the buffer's frontmatter; NO-PROMPT skips that (used by the automatic
reconnect after a stale resume id)."
  (interactive)
  (when (process-live-p sprig--process)
    (user-error "This buffer already has a live session"))
  (setq sprig--session-id (sprig--buffer-session-id))
  (unless (or no-prompt sprig--session-id)
    (sprig--read-working-directory))
  (sprig--spawn)
  (let ((dir (sprig--directory)))
    (message "sprig: %s (%s%s)"
             (if sprig--session-id "resuming session" "new session")
             (if sprig-remote (concat "ssh " sprig-remote) "local")
             (if dir (concat " in " dir) "")))
  (sprig--status-refresh))

(defun sprig--spawn ()
  "Start the CLI session process for the current buffer and bind it.
Reads the resume id from `sprig--session-id' (nil for a fresh session)
and the working directory from `sprig--directory', both already resolved
by the caller.  Sets and returns `sprig--process'.  Buffer-agnostic: the
Markdown transcript and a session-owning review buffer share it."
  (let* ((dir (sprig--directory))
         ;; Local sessions inherit `default-directory'; a configured dir
         ;; overrides it.  Remote sessions get their `cd' in `sprig--command'.
         (default-directory
          (if (and dir (not sprig-remote))
              (let ((expanded (file-name-as-directory (expand-file-name dir))))
                (unless (file-directory-p expanded)
                  (user-error "sprig: no such directory: %s" expanded))
                expanded)
            default-directory))
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
    (setq sprig--process proc)))

;;;###autoload
(defun sprig-new (&optional dont-connect no-pop)
  "Create a fresh in-memory Sprig conversation and switch to it.
The buffer visits no file: converse now and, if you want to keep it,
save it later with \\[write-file] (its frontmatter and transcript ride
along).  Unless DONT-CONNECT, start the session at once, prompting for
its working directory, the same as `sprig-connect'.  Unless NO-POP,
select the new conversation buffer; either way return it."
  (interactive)
  (let ((buf (generate-new-buffer "*sprig: untitled*"))
        (dir (or (and sprig-directory (not sprig-remote)
                      (expand-file-name sprig-directory))
                 default-directory)))
    (with-current-buffer buf
      (when (fboundp 'markdown-mode) (markdown-mode))
      (setq default-directory (file-name-as-directory dir))
      (unless (bound-and-true-p sprig-mode) (sprig-mode 1))
      (unless dont-connect (sprig-connect)))
    (unless no-pop (pop-to-buffer buf))
    buf))

(defun sprig--title-slug (title)
  "Return a filesystem-friendly slug for TITLE, or nil when it is empty.
Lower-cases, collapses non-alphanumerics to single hyphens, and trims
leading and trailing hyphens."
  (when title
    (let ((s (string-trim
              (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase title))
              "-+" "-+")))
      (unless (string-empty-p s) s))))

;;;###autoload
(defun sprig-save ()
  "Save this conversation to a file, defaulting the name to a title slug.
For an in-memory branch this prompts for a filename, seeded from the
branch `title:' under the first navigator scan directory (or a local
`sprig-directory'); for a branch already backed by a file it just writes
pending edits."
  (interactive)
  (if buffer-file-name
      (save-buffer)
    (let* ((dir (file-name-as-directory
                 (or (car sprig-status-directories)
                     (and sprig-directory (not sprig-remote)
                          (expand-file-name sprig-directory))
                     default-directory)))
           (name (concat (or (sprig--title-slug (sprig--frontmatter-get "title"))
                             "conversation")
                         ".md"))
           (file (read-file-name "Save conversation to: " dir name nil name)))
      (when (file-directory-p file)
        (user-error "sprig: %s is a directory" file))
      (write-file file t)
      (sprig--status-refresh)
      (message "sprig: saved to %s" (abbreviate-file-name file)))))

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
`set_permission_mode' request is how a turn is put into plan mode."
  (let ((json (json-serialize
               (list :type "control_request"
                     :request_id (format "sprig-%d"
                                          (setq sprig--control-counter
                                                (1+ sprig--control-counter)))
                     :request request))))
    (process-send-string sprig--process (concat json "\n"))))

(defun sprig--set-permission-mode (mode)
  "Ask the session to switch to permission MODE (e.g. \"plan\", \"auto\")."
  (sprig--send-control (list :subtype "set_permission_mode" :mode mode))
  (setq sprig--permission-mode mode))

(defun sprig--send-text (text &optional mode)
  "Send TEXT as this buffer's next user turn programmatically.
Unlike `sprig-send', which sends prose already typed in the buffer, this
appends TEXT as a user turn first, then streams the reply.  It is how the
review buffer's verbs steer the conversation (see `sprig-review').

MODE, when given, sets the permission mode first (e.g. \"plan\").  With no
MODE, a session left in plan mode is returned to \"auto\", so a plain send
after a plan turn resumes normal execution."
  (sprig--ensure)
  (when sprig--busy
    (user-error "A turn is already in flight"))
  (cond ((and mode (not (equal mode sprig--permission-mode)))
         (sprig--set-permission-mode mode))
        ((and (null mode) (equal sprig--permission-mode "plan"))
         (sprig--set-permission-mode "auto")))
  (save-excursion
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert text "\n"))
  (setq sprig--busy t)
  (sprig--start-reply)
  (sprig--send-user text)
  (sprig--tee-review (list 'user text))
  (sprig--status-refresh))

;;;###autoload
(defun sprig-send ()
  "Send the pending user turn and stream the reply into a new block.
The pending turn is the prose typed after the last reply."
  (interactive)
  (sprig--ensure)
  (when sprig--busy
    (user-error "A turn is already in flight"))
  (let ((text (sprig--pending-user-text)))
    (when (or (null text) (string-empty-p text))
      (user-error "No pending message: type below the last reply first"))
    (setq sprig--busy t)
    (sprig--start-reply)
    (sprig--send-user text)
    (sprig--tee-review (list 'user text))
    (sprig--status-refresh)))

;;;###autoload
(defun sprig-interrupt ()
  "Abort the in-flight turn, keeping and marking the partial reply."
  (interactive)
  (if (not sprig--busy)
      (message "sprig: nothing to interrupt")
    (sprig--teardown-process)
    (sprig--close-reply t)
    (when (and sprig--marker (marker-buffer sprig--marker))
      (goto-char sprig--marker))
    (message "sprig: interrupted (session resumes on next send)")
    (sprig--status-refresh)))

;;;###autoload
(defun sprig-disconnect ()
  "Stop the session for this buffer (the conversation is kept)."
  (interactive)
  (if (process-live-p sprig--process)
      (progn (sprig--teardown-process)
             (message "sprig: disconnected")
             (sprig--status-refresh))
    (message "sprig: no live session")))

;;;###autoload
(defun sprig-set-tool-display (level)
  "Set this file's tool-render LEVEL and record it in the frontmatter.
LEVEL is `none' (no tool blocks), `calls' (calls only), or `full' (calls
and results).  It applies to turns rendered from now on; blocks already
omitted are not recovered."
  (interactive
   (list (intern (completing-read
                  "Tool display: " '("none" "calls" "full") nil t nil nil
                  (symbol-name (sprig--tool-display))))))
  (sprig--frontmatter-set "sprig_tools" (symbol-name level))
  (message "sprig: tool display -> %s (applies to new turns)" level))

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
(declare-function sprig-review-attach "sprig-review-mode" (conversation &optional remote))
(declare-function sprig-review-session-events "sprig-review" (lines))

(defun sprig--remote-sh (command)
  "Run shell COMMAND on the session host via SSH; return stdout.
Signals if SSH exits non-zero."
  (with-temp-buffer
    (let ((status (apply #'call-process sprig-ssh-program nil t nil
                         (append sprig-ssh-args (list sprig-remote command)))))
      (unless (eq status 0)
        (error "sprig: remote command failed (%s): %s"
               status (string-trim (buffer-string))))
      (buffer-string))))

(defun sprig--session-log-lines ()
  "Return the stored session-log lines for this buffer's session.
Locates the log by session id under ~/.claude/projects on the session
host (local or over SSH), so the working-directory encoding never has to
be reproduced.  Signals a `user-error' when there is no id or no log."
  (let ((id (or sprig--session-id (sprig--buffer-session-id)
                (user-error "sprig: no session id yet; connect first"))))
    (if sprig-remote
        (let* ((name (shell-quote-argument (concat id ".jsonl")))
               (path (string-trim
                      (sprig--remote-sh
                       (format "find ~/.claude/projects -name %s -print -quit"
                               name)))))
          (when (string-empty-p path)
            (user-error "sprig: no session log for %s on %s" id sprig-remote))
          (split-string (sprig--remote-sh
                         (format "cat %s" (shell-quote-argument path)))
                        "\n" t))
      (let ((file (car (directory-files-recursively
                        (expand-file-name "~/.claude/projects")
                        (concat "\\`" (regexp-quote id) "\\.jsonl\\'")))))
        (unless file
          (user-error "sprig: no session log for %s" id))
        (with-temp-buffer
          (insert-file-contents file)
          (split-string (buffer-string) "\n" t))))))

;;;###autoload
(defun sprig-review ()
  "Open a read-only review buffer for this conversation.
Replays the whole transcript from the CLI's stored session log, then
attaches so the in-flight turn streams in live."
  (interactive)
  (require 'sprig-review-mode)
  (let* ((conversation (current-buffer))
         ;; A just-created scratch branch has no session id or stored log
         ;; yet; open an empty review that the live turn streams into.
         (lines (ignore-errors (sprig--session-log-lines)))
         (events (and lines (sprig-review-session-events lines)))
         (meta (list :title (sprig--buffer-title)
                     :project (sprig--directory)))
         (name (format "*sprig-review: %s*" (sprig--buffer-title)))
         (buffer (sprig-review-buffer name)))
    (with-current-buffer buffer
      (sprig-review-seed events meta)
      (sprig-review-attach conversation sprig-remote))
    (setq sprig--review-buffer buffer)
    (pop-to-buffer buffer)))

;; A review buffer can also own its session outright, with no Markdown
;; transcript behind it: the transport routes events to `sprig--review-sink'
;; and its verbs steer the session directly.  This is the sprig-mode-free
;; path (see DESIGN.md, option A: CLI sessions are the branches).

(defun sprig--review-sink (event)
  "Sink for a review buffer that owns its session: track state, then consume.
Keeps the transport bookkeeping (session id, permission mode, busy flag)
in step without a Markdown transcript, then folds EVENT into the review
model via `sprig-review-consume'."
  (pcase event
    (`(session ,id) (when (and id (not sprig--session-id))
                      (setq sprig--session-id id)))
    (`(mode ,m) (setq sprig--permission-mode m))
    (`(done ,_ ,_) (setq sprig--busy nil) (sprig--status-refresh)))
  (sprig-review-consume event))

(defun sprig--review-owns-session-p ()
  "Non-nil when the current review buffer owns its session (vs attached)."
  (eq sprig--sink #'sprig--review-sink))

(defun sprig--read-review-dir ()
  "Prompt for a session working directory, returning the string.
Unlike `sprig--read-working-directory' this records nothing in
frontmatter; a session-owning review buffer keeps its directory in the
buffer-local `sprig--working-dir' instead."
  (if sprig-remote
      (read-string "Working directory (remote, blank = login dir): ")
    (read-directory-name "Working directory: ")))

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
    (setq sprig--working-dir (sprig--read-review-dir)))
  (sprig--spawn)
  (message "sprig: %s (%s%s)"
           (if sprig--session-id "resuming session" "new session")
           (if sprig-remote (concat "ssh " sprig-remote) "local")
           (if sprig--working-dir (concat " in " sprig--working-dir) ""))
  (sprig--status-refresh))

(defun sprig--review-deliver (text &optional mode)
  "Send TEXT as this review buffer's own next user turn, echoing it locally.
Used when the review buffer owns the session.  MODE, when given, sets the
permission mode first (e.g. \"plan\"); with none, a session left in plan
mode is returned to \"auto\"."
  (sprig--ensure)
  (when sprig--busy
    (user-error "A turn is already in flight"))
  (cond ((and mode (not (equal mode sprig--permission-mode)))
         (sprig--set-permission-mode mode))
        ((and (null mode) (equal sprig--permission-mode "plan"))
         (sprig--set-permission-mode "auto")))
  (setq sprig--busy t)
  (sprig--send-user text)
  (sprig-review-consume (list 'user text))
  (sprig--status-refresh))

(defun sprig--review-interrupt-owned ()
  "Interrupt the in-flight turn on a review buffer that owns its session."
  (if sprig--busy
      (progn (sprig--teardown-process)
             (sprig--status-refresh)
             (message "sprig: interrupted (session resumes on next send)"))
    (message "sprig: nothing to interrupt")))

;;;###autoload
(defun sprig-review-session (dir &optional session-id)
  "Open a review buffer that owns a session in working directory DIR.
With SESSION-ID, replay that stored session's log and resume it on the
next send; without, the buffer starts empty and a send opens a fresh
session.  This is the sprig-mode-free way to start or continue a branch."
  (interactive (list (sprig--read-review-dir)))
  (require 'sprig-review-mode)
  (let* ((name (format "*sprig-review: %s*"
                       (or session-id
                           (file-name-nondirectory (directory-file-name dir)))))
         (buffer (sprig-review-buffer name)))
    (with-current-buffer buffer
      (setq sprig--session-id session-id
            sprig--working-dir dir
            sprig--sink #'sprig--review-sink
            sprig--connect-fn #'sprig-review-connect)
      (let* ((lines (and session-id (ignore-errors (sprig--session-log-lines))))
             (events (and lines (sprig-review-session-events lines))))
        (sprig-review-seed events (list :project dir)))
      (sprig-review-attach nil sprig-remote))
    (pop-to-buffer buffer)))

;;;; Folding commands

;;;###autoload
(defun sprig-fold-all ()
  "Fold every tool-call and result block in the buffer to its header.
Re-hides blocks that already have an overlay and scans to create
overlays for any that lack one, e.g. in a reopened file."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward sprig--tool-open-re nil t)
      (let* ((beg (line-beginning-position))
             (ov (seq-find (lambda (o) (overlay-get o 'sprig-fold))
                           (overlays-in beg (1+ (line-end-position))))))
        (if ov
            (overlay-put ov 'invisible 'sprig-fold)
          (sprig--fold-block-at beg))))))

;;;###autoload
(defun sprig-unfold-all ()
  "Expand every folded tool block in the buffer, keeping the overlays."
  (interactive)
  (dolist (o (overlays-in (point-min) (point-max)))
    (when (overlay-get o 'sprig-fold)
      (overlay-put o 'invisible nil))))

;;;###autoload
(defun sprig-toggle-fold ()
  "Toggle folding of the tool block at point.
Works from the header line or anywhere in the body."
  (interactive)
  (let ((ov (seq-find (lambda (o) (overlay-get o 'sprig-fold))
                      (overlays-in (line-beginning-position)
                                   (1+ (line-end-position))))))
    (cond
     ;; A fold overlay covers this line: flip its visibility.  The overlay
     ;; spans the body whether shown or hidden, so no boundary re-search is
     ;; needed and tool output cannot fake a delimiter.
     (ov (overlay-put ov 'invisible
                      (and (not (overlay-get ov 'invisible)) 'sprig-fold)))
     ;; No overlay yet (e.g. a reopened buffer): create one by scanning.
     (t (let ((beg (sprig--tool-block-at-point)))
          (if beg
              (sprig--fold-block-at beg)
            (user-error "Not on a tool-call block")))))))

;;;; Status navigator

(defconst sprig-status-buffer-name "*sprig-status*"
  "Name of the buffer showing the `sprig-status' navigator.")

(defconst sprig--status-scan-bytes 8192
  "Leading bytes of a candidate .md file read when scanning for branches.")

(defconst sprig--status-preview-bytes 65536
  "Trailing bytes of a branch file read to preview its last reply.
Large enough to hold the last reply-open sentinel for a typical turn; a
reply longer than this simply shows no preview.")

(defconst sprig--status-glyphs
  '((streaming    . "▶")
    (idle         . "●")
    (interrupted  . "◼")
    (disconnected . "○"))
  "Glyph shown in the status column for each session state.")

;;; Enumeration and per-buffer status

(defun sprig--conversation-buffer-p (buf)
  "Non-nil if BUF is a live Sprig conversation buffer.
Keys on `sprig-mode' or lingering session state, so the `*sprig-status*'
buffer (a major-mode buffer with no sprig state) never qualifies."
  (and (buffer-live-p buf)
       (or (buffer-local-value 'sprig-mode buf)
           (buffer-local-value 'sprig--process buf)
           (buffer-local-value 'sprig--session-id buf))))

(defun sprig--conversation-buffers ()
  "Return the list of live Sprig conversation buffers."
  (seq-filter #'sprig--conversation-buffer-p (buffer-list)))

(defun sprig--last-reply-interrupted-p ()
  "Non-nil if the buffer's last reply-open sentinel carries `interrupted'.
Cheap: `re-search-backward' from `point-max' stops at the last reply."
  (save-excursion
    (goto-char (point-max))
    (and (re-search-backward sprig--reply-open-re nil t)
         (string-match-p "\\binterrupted\\b"
                         (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position))))))

(defun sprig--buffer-status (&optional buf)
  "Return the status of conversation BUF.
One of `streaming', `idle', `interrupted', or `disconnected'.  Cheapest
checks first; the interrupted scan is reached only when no process lives."
  (with-current-buffer (or buf (current-buffer))
    (cond
     (sprig--busy 'streaming)
     ((process-live-p sprig--process) 'idle)
     ((sprig--last-reply-interrupted-p) 'interrupted)
     (t 'disconnected))))

(defun sprig--buffer-title (&optional buf)
  "Return BUF's display title: `title' frontmatter, else a name fallback."
  (with-current-buffer (or buf (current-buffer))
    (or (sprig--frontmatter-get "title")
        (and buffer-file-name (file-name-base buffer-file-name))
        (buffer-name))))

;;; Last-reply preview

(defun sprig--last-paragraph (text)
  "Return the last non-empty paragraph of TEXT, or nil.
Sentinel lines are dropped and the surviving line breaks collapsed to
single spaces, so the paragraph can be re-wrapped for display."
  (let (result)
    (dolist (para (split-string text "\n[ \t]*\n" t))
      (let* ((lines (seq-remove (lambda (l) (string-match-p sprig--sentinel-re l))
                                (split-string para "\n")))
             (collapsed (string-trim
                         (replace-regexp-in-string
                          "[ \t]+" " " (mapconcat #'identity lines " ")))))
        (unless (string-empty-p collapsed)
          (setq result collapsed))))
    result))

(defun sprig--reply-preview-here ()
  "Return the last paragraph of the last reply in the current buffer, or nil.
Scans back from `point-max' to the last reply-open sentinel and reads to
its matching close, or to buffer end for a still-streaming reply."
  (save-excursion
    (goto-char (point-max))
    (when (re-search-backward sprig--reply-open-re nil t)
      (let ((start (line-beginning-position 2))
            (end (save-excursion
                   (if (re-search-forward sprig--reply-end-re nil t)
                       (line-beginning-position)
                     (point-max)))))
        (and (< start end)
             (sprig--last-paragraph
              (buffer-substring-no-properties start end)))))))

(defun sprig--reply-preview-from-file (file)
  "Return the last-reply preview read from FILE's trailing bytes, or nil."
  (ignore-errors
    (with-temp-buffer
      (let* ((size (file-attribute-size (file-attributes file)))
             (from (max 0 (- size sprig--status-preview-bytes))))
        (insert-file-contents file nil from size))
      (sprig--reply-preview-here))))

(defun sprig--entry-preview (entry)
  "Return the inline reply preview for status ENTRY, or nil.
Reads the live buffer when ENTRY has one, else the on-disk file's tail."
  (let ((buf (plist-get entry :buffer))
        (file (plist-get entry :file)))
    (cond ((buffer-live-p buf)
           (with-current-buffer buf (sprig--reply-preview-here)))
          (file (sprig--reply-preview-from-file file)))))

;;; On-disk branch-file scan

(defmacro sprig--with-file-head (file &rest body)
  "Run BODY in a temp buffer holding the leading bytes of FILE."
  (declare (indent 1) (debug (form body)))
  `(with-temp-buffer
     (insert-file-contents ,file nil 0 sprig--status-scan-bytes)
     ,@body))

(defun sprig--branch-file-p (file)
  "Non-nil if FILE looks like a Sprig branch file.
True when its head carries a `claude_session:' frontmatter key or a
`sprig:reply' sentinel.  Reads only the leading bytes; a plain Markdown
file (even one with a `title:') is skipped."
  (ignore-errors
    (sprig--with-file-head file
      (goto-char (point-min))
      (or (re-search-forward "^claude_session:[ \t]*\\S-" nil t)
          (re-search-forward "^<!-- sprig:reply\\b" nil t)))))

(defun sprig--file-frontmatter-get (file key)
  "Read KEY from FILE's YAML frontmatter without visiting it."
  (ignore-errors
    (sprig--with-file-head file (sprig--frontmatter-get key))))

(defun sprig--status-scan-directories ()
  "Resolve the directories to scan for branch files, deduped by truename.
When `sprig-status-directories' is nil, use the directories of the open
Sprig buffers plus `sprig-directory' (skipped for a remote session)."
  (let ((dirs (if sprig-status-directories
                  (mapcar #'expand-file-name sprig-status-directories)
                (append
                 (and sprig-directory (not sprig-remote)
                      (list (expand-file-name sprig-directory)))
                 (delq nil
                       (mapcar (lambda (b)
                                 (let ((f (buffer-local-value 'buffer-file-name b)))
                                   (and f (file-name-directory f))))
                               (sprig--conversation-buffers)))))))
    (seq-uniq (delq nil (mapcar (lambda (d)
                                  (and (file-directory-p d) (file-truename d)))
                                dirs))
              #'string=)))

(defun sprig--scan-branch-files ()
  "Return the Sprig branch files under `sprig--status-scan-directories'.
Non-recursive; unreadable files are skipped."
  (let (files)
    (dolist (dir (sprig--status-scan-directories))
      (dolist (f (ignore-errors (directory-files dir t "\\.md\\'" t)))
        (when (and (file-regular-p f) (sprig--branch-file-p f))
          (push f files))))
    files))

;;; Merge open buffers and on-disk files into rows

(defun sprig--status-collect ()
  "Return status plists for all sessions, deduped by file truename.
Each plist has :key, :buffer (or nil), :file (or nil), :title, :status,
and :session.  An open buffer wins over its on-disk file."
  (let ((table (make-hash-table :test 'equal))
        (order '()))
    (dolist (buf (sprig--conversation-buffers))
      (let* ((file (buffer-local-value 'buffer-file-name buf))
             (key (if file (file-truename file) buf)))
        (unless (gethash key table)
          (push key order)
          (puthash key
                   (list :key key :buffer buf :file file
                         :title (sprig--buffer-title buf)
                         :status (sprig--buffer-status buf)
                         :session (buffer-local-value 'sprig--session-id buf))
                   table))))
    (dolist (file (sprig--scan-branch-files))
      (let ((key (file-truename file)))
        (unless (gethash key table)
          (push key order)
          (puthash key
                   (list :key key :buffer nil :file file
                         :title (or (sprig--file-frontmatter-get file "title")
                                    (file-name-base file))
                         :status 'disconnected
                         :session (sprig--file-frontmatter-get file "claude_session"))
                   table))))
    (mapcar (lambda (k) (gethash k table)) (nreverse order))))

;;; tabulated-list rendering

(defun sprig--status-face (status)
  "Return the face used for STATUS."
  (pcase status
    ('streaming 'warning)
    ('idle 'success)
    ('interrupted 'font-lock-comment-face)
    (_ 'shadow)))

(defvar-local sprig--status-index nil
  "Hash mapping the current render's entry ids to their status plists.")

(defun sprig--status-entries ()
  "Build `tabulated-list-entries' from a fresh `sprig--status-collect'.
The entry id is the entry's `:key' (a file's truename, else its buffer):
canonical and stable across refreshes, so point and inline-preview state
survive.  Stale ids are pruned from `sprig--status-expanded' so it never
outlives the row it belongs to."
  (let ((index (make-hash-table :test 'equal))
        rows)
    (dolist (e (sprig--status-collect))
      (let* ((id (plist-get e :key))
             (status (plist-get e :status))
             (file (plist-get e :file))
             (session (plist-get e :session))
             (glyph (propertize (or (alist-get status sprig--status-glyphs) "?")
                                'face (sprig--status-face status))))
        (puthash id e index)
        (push (list id
                    (vector glyph
                            (or (plist-get e :title) "")
                            (if file (file-name-nondirectory file) "(no file)")
                            (if (and session (> (length session) 0))
                                (substring session 0 (min 8 (length session)))
                              "-")))
              rows)))
    (setq sprig--status-index index)
    (sprig--status-prune-expanded index)
    (nreverse rows)))

;;; Inline reply previews

(defvar-local sprig--status-expanded nil
  "Hash table of navigator entry ids currently showing an inline preview.")

(defun sprig--status-prune-expanded (index)
  "Drop ids from `sprig--status-expanded' absent from INDEX.
An entry's id changes when it flips identity (a scratch buffer saved to a
file), which would otherwise strand its expanded flag and desync the hash
from the screen, so a later TAB toggles the phantom instead of the row."
  (when sprig--status-expanded
    (let (stale)
      (maphash (lambda (id _)
                 (unless (gethash id index) (push id stale)))
               sprig--status-expanded)
      (dolist (id stale) (remhash id sprig--status-expanded)))))

(defun sprig--status-toggle-id (id)
  "Toggle inline-preview state for entry ID; return the new state."
  (unless sprig--status-expanded
    (setq sprig--status-expanded (make-hash-table :test 'equal)))
  (if (gethash id sprig--status-expanded)
      (progn (remhash id sprig--status-expanded) nil)
    (puthash id t sprig--status-expanded) t))

(defun sprig--status-preview-lines (entry)
  "Return the propertized display lines for ENTRY's inline preview.
The last reply's tail is filled to `sprig-status-preview-max-lines' and
indented; a row with no reply yet shows a single muted placeholder."
  (let* ((text (sprig--entry-preview entry))
         (width (max 24 (- (min 100 (window-width)) 6)))
         (lines (if (and text (not (string-empty-p text)))
                    (with-temp-buffer
                      (insert text)
                      (let ((fill-column width))
                        (fill-region (point-min) (point-max)))
                      (split-string (buffer-string) "\n" t))
                  (list "(no reply yet)"))))
    (when (> (length lines) sprig-status-preview-max-lines)
      (setq lines (seq-take lines sprig-status-preview-max-lines))
      (setcar (last lines) (concat (car (last lines)) " …")))
    (mapcar (lambda (l)
              (propertize (concat "     " l) 'face 'sprig-status-preview))
            lines)))

(defun sprig--status-insert-previews ()
  "Insert inline preview lines under each expanded row.
Runs after `tabulated-list-print', which erases prior previews; the
inserted lines carry no entry id, so navigation and the next reprint
skip them cleanly."
  (when (and sprig--status-expanded
             (> (hash-table-count sprig--status-expanded) 0)
             sprig--status-index)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (let* ((id (tabulated-list-get-id))
                 (entry (and id (gethash id sprig--status-expanded)
                             (gethash id sprig--status-index))))
            (when entry
              (save-excursion
                (end-of-line)
                (insert "\n" (mapconcat #'identity
                                        (sprig--status-preview-lines entry)
                                        "\n")))))
          (forward-line 1))))))

(defun sprig--status-render ()
  "Reprint the navigator and re-insert its inline previews.
Every navigator refresh path routes through here so previews survive a
reprint; point is kept on its row by `tabulated-list-print'."
  (tabulated-list-print t)
  (sprig--status-insert-previews))

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
(define-key sprig-status-mode-map (kbd "s")   #'sprig-status-new)
(define-key sprig-status-mode-map (kbd "c")   #'sprig-status-connect)
(define-key sprig-status-mode-map (kbd "k")   #'sprig-status-interrupt)
(define-key sprig-status-mode-map (kbd "d")   #'sprig-status-disconnect)
(define-key sprig-status-mode-map (kbd "w")   #'sprig-status-write)
(define-key sprig-status-mode-map (kbd "f")   #'sprig-status-fork)
(define-key sprig-status-mode-map (kbd "r")   #'sprig-status-rename)
(define-key sprig-status-mode-map (kbd "x")   #'sprig-status-prune)
(define-key sprig-status-mode-map (kbd "?")   #'describe-mode)

(define-derived-mode sprig-status-mode tabulated-list-mode "Sprig-Status"
  "Major mode listing Sprig conversations and their live status.
\\<sprig-status-mode-map>Open with \\[sprig-status-open], connect with
\\[sprig-status-connect], interrupt with \\[sprig-status-interrupt],
disconnect with \\[sprig-status-disconnect], refresh with \\[revert-buffer]."
  (setq tabulated-list-format
        [("S" 2 t)
         ("Title" 28 t)
         ("File" 28 t)
         ("Session" 9 nil)]
        tabulated-list-padding 1
        tabulated-list-sort-key '("Title" . nil)
        tabulated-list-entries #'sprig--status-entries)
  (setq-local revert-buffer-function #'sprig--status-revert)
  (tabulated-list-init-header))

(defun sprig--status-revert (&rest _)
  "Revert the navigator (the `g' / `revert-buffer' path), keeping previews."
  (sprig--status-render))

(defun sprig--status-refresh ()
  "Re-render the `*sprig-status*' navigator if it is live; else do nothing.
Called from session lifecycle points, so a stream finishing in a buffer
you are not viewing still updates the list.  A no-op, and thus free, when
the navigator is not open."
  (let ((buf (get-buffer sprig-status-buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (derived-mode-p 'sprig-status-mode)
          (sprig--status-render))))))

(defun sprig--status-refresh-deferred ()
  "Refresh the navigator on the next idle moment.
Used from `kill-buffer-hook', which runs while the dying buffer is still
live and listed; deferring lets it drop from the list first."
  (run-at-time 0 nil #'sprig--status-refresh))

(defun sprig--status-entry-at-point ()
  "Return the status plist for the row at point, or signal an error."
  (let ((id (tabulated-list-get-id)))
    (or (and id sprig--status-index (gethash id sprig--status-index))
        (user-error "No Sprig session on this line"))))

(defun sprig--status-buffer-at-point (&optional create)
  "Return the live conversation buffer for the row at point, or nil.
With CREATE, open the row's on-disk file when it has no live buffer."
  (let* ((e (sprig--status-entry-at-point))
         (buf (plist-get e :buffer))
         (file (plist-get e :file)))
    (cond ((buffer-live-p buf) buf)
          ((and create file) (find-file-noselect file))
          (t nil))))

(defun sprig--status-run (command not-connected)
  "Run COMMAND in the conversation buffer for the row at point, then refresh.
Signal NOT-CONNECTED as a `user-error' when the row has no live buffer."
  (let ((buf (sprig--status-buffer-at-point)))
    (unless buf (user-error "%s" not-connected))
    (with-current-buffer buf (funcall command))
    (sprig--status-refresh)))

(defun sprig--status-goto-row (dir)
  "Move point DIR (+1 or -1) session rows, skipping inline preview lines.
Return non-nil on success; leave point put when there is no further row."
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
  "Visit the conversation on the current line."
  (interactive)
  (let ((buf (sprig--status-buffer-at-point t)))
    (if buf (pop-to-buffer buf) (user-error "Nothing to open here"))))

(defun sprig-status-connect ()
  "Connect the session on the current line, opening its file if needed."
  (interactive)
  (with-current-buffer (or (sprig--status-buffer-at-point t)
                           (user-error "No file to connect here"))
    (unless (bound-and-true-p sprig-mode) (sprig-mode 1))
    (sprig-connect))
  (sprig--status-refresh))

(defun sprig-status-interrupt ()
  "Interrupt the streaming session on the current line."
  (interactive)
  (sprig--status-run #'sprig-interrupt "That row is not a connected session"))

(defun sprig-status-disconnect ()
  "Disconnect the session on the current line."
  (interactive)
  (sprig--status-run #'sprig-disconnect "That row is not a connected session"))

(defun sprig-status-toggle-preview ()
  "Toggle an inline preview of the last reply for the row at point.
Shows the tail of that session's last reply, filled to
`sprig-status-preview-max-lines' lines; press again to hide it."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (unless id (user-error "No Sprig session on this line"))
    (sprig--status-toggle-id id)
    (sprig--status-render)))

(defun sprig-status-new ()
  "Start a fresh in-memory conversation and open its review buffer.
The new branch visits no file until you save it; it appears in the
navigator immediately and streams like any other.  You land in the
read-only review buffer, not the Markdown transport."
  (interactive)
  (with-current-buffer (sprig-new nil t)
    (sprig-review))
  (sprig--status-refresh))

(defun sprig-status-write ()
  "Save the conversation on the current line to a file.
An in-memory branch is prompted for a filename (defaulting to a title
slug); a branch already backed by a file writes its pending edits."
  (interactive)
  (sprig--status-run #'sprig-save "That row is already an on-disk file"))

(defun sprig-status-fork ()
  "Fork the branch on the current line (not implemented yet)."
  (interactive)
  (user-error "sprig: fork is not implemented yet (planned; see DESIGN.md)"))

(defun sprig-status-rename ()
  "Rename the branch on the current line (not implemented yet)."
  (interactive)
  (user-error "sprig: rename is not implemented yet"))

(defun sprig-status-prune ()
  "Prune the branch on the current line (not implemented yet)."
  (interactive)
  (user-error "sprig: prune is not implemented yet"))

;;;###autoload
(defun sprig-status ()
  "Open the `*sprig-status*' navigator listing Sprig sessions.
Lists every open conversation buffer with its live status, plus unopened
branch files found under `sprig-status-directories'."
  (interactive)
  (let ((buf (get-buffer-create sprig-status-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'sprig-status-mode) (sprig-status-mode))
      (sprig--status-render))
    (pop-to-buffer buf)))

;;;; Minor mode / keymap

(defvar sprig-mode-map (make-sparse-keymap)
  "Keymap for `sprig-mode'.")

;; Bind at top level (not inside the `defvar') so reloading the file
;; refreshes the bindings; `defvar' would not reassign the live keymap.
(define-key sprig-mode-map (kbd "C-c C-c")     #'sprig-send)
(define-key sprig-mode-map (kbd "C-c C-a C-o") #'sprig-connect)
(define-key sprig-mode-map (kbd "C-c C-k")     #'sprig-interrupt)
(define-key sprig-mode-map (kbd "C-c C-a C-k") #'sprig-disconnect)
(define-key sprig-mode-map (kbd "C-c C-a C-r") #'sprig-review)
(define-key sprig-mode-map (kbd "C-c C-f")     #'sprig-toggle-fold)

(defun sprig--mode-line ()
  "Return the `sprig-mode' lighter reflecting this buffer's live status.
Kept cheap: reads only `sprig--busy' and the process handle (it runs on
every redisplay), never the interrupted scan."
  (concat " Sprig"
          (cond (sprig--busy ":▶")
                ((process-live-p sprig--process) ":●")
                (t ""))))

(defun sprig--kill-buffer-query ()
  "Guard against silently losing an unsaved in-memory conversation.
Returns t (allow the kill) unless this is a file-less conversation
buffer holding a transcript or a live session id, in which case it asks
to confirm.  A saved branch, or an empty scratch buffer with nothing to
lose, is killed without a prompt."
  (or buffer-file-name
      (not (sprig--conversation-buffer-p (current-buffer)))
      (and (not sprig--session-id)
           (string-empty-p (string-trim (buffer-string))))
      (yes-or-no-p "This conversation is not saved to a file; kill and lose it? ")))

;;;###autoload
(define-minor-mode sprig-mode
  "Minor mode for conversing with an agent in a Markdown buffer."
  :lighter (:eval (sprig--mode-line))
  :keymap sprig-mode-map
  (if sprig-mode
      (progn
        (add-to-invisibility-spec 'sprig-chrome)
        (add-to-invisibility-spec '(sprig-fold . t))
        (add-hook 'after-change-functions #'sprig--refresh-pending-face nil t)
        (add-hook 'kill-buffer-hook #'sprig--status-refresh-deferred nil t)
        (add-hook 'kill-buffer-query-functions #'sprig--kill-buffer-query nil t)
        (sprig--decorate)
        (when sprig-fold-tool-calls (sprig-fold-all)))
    (remove-hook 'after-change-functions #'sprig--refresh-pending-face t)
    (remove-hook 'kill-buffer-hook #'sprig--status-refresh-deferred t)
    (remove-hook 'kill-buffer-query-functions #'sprig--kill-buffer-query t)
    (remove-from-invisibility-spec 'sprig-chrome)
    (remove-from-invisibility-spec '(sprig-fold . t))
    (remove-overlays (point-min) (point-max) 'sprig-chrome t)
    (remove-overlays (point-min) (point-max) 'sprig-fold t)
    (remove-overlays (point-min) (point-max) 'sprig-user t)))

(provide 'sprig)
;;; sprig.el ends here
