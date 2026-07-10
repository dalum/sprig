;;; sprig.el --- Non-linear agent conversations in Markdown -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.4.0
;; Package-Requires: ((emacs "27.1"))
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
;; `sprig-directory' default) points it elsewhere.
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

(defcustom sprig-ssh-args '("-T")
  "Extra arguments passed to SSH (before the destination).
`-T' disables pseudo-tty allocation, which is what we want for a pipe."
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

(defface sprig-tool '((t :inherit font-lock-keyword-face :weight bold))
  "Face for tool-call and result header labels.")

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

;;;; Sentinel grammar

;; Structural markers.  Always an HTML comment, alone on its line, at
;; column 0.  The KIND alternation lists the `-end' variants first so a
;; `tool-end' line is never misread as `tool'.
(defconst sprig--sentinel-re
  "^<!-- sprig:\\(reply\\|end\\|tool-end\\|tool\\|result-end\\|result\\)\\([^\n]*?\\) *-->[ \t]*$"
  "Regexp matching any `sprig:' sentinel line.
Group 1 is the kind, group 2 the attribute text (id, name, flags).")
(defconst sprig--reply-open-re "^<!-- sprig:reply\\b[^\n]*-->[ \t]*$"
  "Regexp matching a reply-open sentinel line.")
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
  "Return the position where the body begins, after any YAML frontmatter."
  (save-excursion
    (goto-char (point-min))
    (if (looking-at-p "^---[ \t]*$")
        (progn
          (forward-line 1)
          (if (re-search-forward "^---[ \t]*$" nil t)
              (progn (forward-line 1) (point))
            (point-min)))
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

;;;; Process I/O

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
  "Parse one JSON LINE from PROC and act on it."
  (let ((buf (process-get proc :conv-buffer))
        (ev (condition-case nil
                (json-parse-string line :object-type 'alist :array-type 'list
                                   :null-object nil :false-object nil)
              (error nil))))
    (when (and ev (buffer-live-p buf))
      (with-current-buffer buf
        (let-alist ev
          (cond
           ;; Session init: capture and persist the session id.
           ((and (equal .type "system") (equal .subtype "init"))
            (when (and .session_id (not sprig--session-id))
              (setq sprig--session-id .session_id)
              (sprig--save-session-id .session_id)))
           ;; Streaming assistant content (text and tool-use blocks).
           ((equal .type "stream_event")
            (cond
             ;; A new text block after earlier text (e.g. prose resuming
             ;; after a tool use): separate them with a paragraph break.
             ((and (equal .event.type "content_block_start")
                   (equal .event.content_block.type "text"))
              (sprig--block-separator))
             ;; A tool-use block opens: start accumulating its input JSON.
             ((and (equal .event.type "content_block_start")
                   (equal .event.content_block.type "tool_use"))
              (push (list .event.index
                          :id (or .event.content_block.id
                                  (format "t%d" .event.index))
                          :name .event.content_block.name
                          :json "")
                    sprig--blocks))
             ;; Text delta.
             ((and (equal .event.type "content_block_delta")
                   (equal .event.delta.type "text_delta")
                   .event.delta.text)
              (sprig--emit .event.delta.text))
             ;; Tool-input delta: append to the block's accumulator.
             ((and (equal .event.type "content_block_delta")
                   (equal .event.delta.type "input_json_delta")
                   .event.delta.partial_json)
              (let ((blk (assq .event.index sprig--blocks)))
                (when blk
                  (plist-put (cdr blk) :json
                             (concat (plist-get (cdr blk) :json)
                                     .event.delta.partial_json)))))
             ;; Block closes: if it was a tracked tool-use, render it now.
             ((equal .event.type "content_block_stop")
              (let ((blk (assq .event.index sprig--blocks)))
                (when blk
                  (sprig--emit-tool-call (plist-get (cdr blk) :id)
                                         (plist-get (cdr blk) :name)
                                         (plist-get (cdr blk) :json))
                  (setq sprig--blocks
                        (assq-delete-all .event.index sprig--blocks)))))))
           ;; Tool results come back as a `user' message; render them.
           ((equal .type "user")
            (sprig--emit-tool-results .message.content))
           ;; Turn complete.
           ((equal .type "result")
            (sprig--finish-turn .total_cost_usd .is_error))
           ;; Fallback: a non-streamed error surfaced as a result-less error.
           ((and (equal .type "system") (equal .subtype "error"))
            (sprig--emit (format "\n[error] %s\n" (or .message line))))))))))

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
    (save-excursion
      (goto-char sprig--marker)
      (let ((inhibit-read-only t))
        (skip-chars-backward " \t\n")
        (delete-region (point) (marker-position sprig--marker))
        (insert "\n\n"))
      (set-marker sprig--marker (point)))))

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
    (save-excursion
      (goto-char sprig--marker)
      (let ((inhibit-read-only t)
            (open-bol (point)))
        (insert open "\n"
                "```" (or lang "") "\n" body "\n```\n"
                end)
        (set-marker sprig--marker (point))
        (setq sprig--emitted t)
        (when sprig-fold-tool-calls
          (sprig--fold-block-at open-bol))))
    (sprig--decorate)))

(defun sprig--emit-tool-call (id name json)
  "Render a tool-call block for tool NAME (id ID) with input JSON.
Skipped when `sprig--tool-display' is `none'."
  (unless (eq (sprig--tool-display) 'none)
    (let ((in (sprig--tool-input name json)))
      (sprig--emit-block
       (format "<!-- sprig:tool id=%s name=%s -->" (or id "t") (or name "tool"))
       (car in) (cdr in)
       (format "<!-- sprig:tool-end id=%s -->" (or id "t"))))))

(defun sprig--emit-tool-results (content)
  "Render every tool_result block found in message CONTENT (a block list).
Rendered only when `sprig--tool-display' is `full'."
  (when (and (eq (sprig--tool-display) 'full) (listp content))
    (dolist (block content)
      (when (consp block)
        (let-alist block
          (when (equal .type "tool_result")
            (let ((id (or .tool_use_id "t")))
              (sprig--emit-block
               (format "<!-- sprig:result id=%s%s -->" id
                       (if .is_error " error" ""))
               ""
               (string-trim (sprig--tool-result-text .content))
               (format "<!-- sprig:result-end id=%s -->" id)))))))))

(defun sprig--finish-turn (cost is-error)
  "Close out the current turn.  COST and IS-ERROR come from the result event."
  (setq sprig--busy nil)
  (sprig--close-reply)
  (when (and sprig--marker (marker-buffer sprig--marker))
    (goto-char sprig--marker))
  (message "sprig: turn done%s%s"
           (if cost (format " ($%.4f)" cost) "")
           (if is-error " [error]" "")))

(defun sprig--sentinel (proc event)
  "Report PROC lifecycle EVENT."
  (let ((buf (process-get proc :conv-buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (memq (process-status proc) '(exit signal))
          (setq sprig--process nil
                sprig--busy nil)
          (message "sprig: session ended (%s)" (string-trim event)))))))

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

(defun sprig--decorate ()
  "Rebuild the chrome and user-turn overlays from the buffer's sentinels.
Hides each sentinel line and, for open sentinels, shows a header or rule
in its place; faces the user turns between replies.  Leaves the fold
overlays untouched."
  (sprig--decorate-user-turns)
  (when sprig-hide-sentinels
    (sprig--ensure-invisibility)
    (remove-overlays (point-min) (point-max) 'sprig-chrome t)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward sprig--sentinel-re nil t)
        ;; Capture the match bounds first: `sprig--sentinel-label' runs
        ;; `string-match' internally, which would clobber the match data.
        (let* ((mb (match-beginning 0))
               (me (match-end 0))
               (label (sprig--sentinel-label (match-string 1) (match-string 2)))
               ;; A labeled sentinel leaves its terminating newline visible so
               ;; point has somewhere to rest and vertical motion can cross the
               ;; header; an unlabeled (hidden) one swallows the newline so the
               ;; whole line disappears.
               (end (if label me (min (point-max) (1+ me))))
               (ov (make-overlay mb end)))
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
                (overlay-put g 'modification-hooks '(sprig--edit-guard))))))))))

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
      (while (re-search-forward "^<!-- sprig:reply\\b" nil t)
        (setq n (1+ n)))
      (format "r%d" (1+ n)))))

(defun sprig--start-reply ()
  "Open a reply sentinel at end of buffer and arm the marker."
  (setq sprig--reply-id (sprig--next-reply-id))
  (goto-char (point-max))
  (skip-chars-backward " \t\n")
  (delete-region (point) (point-max))
  (let ((inhibit-read-only t))
    (insert "\n\n<!-- sprig:reply id=" sprig--reply-id " -->\n\n"))
  (setq sprig--marker (copy-marker (point) t))
  (setq sprig--emitted nil)
  (setq sprig--blocks nil)
  (sprig--decorate))

(defun sprig--close-reply (&optional interrupted)
  "Close the current reply.  With INTERRUPTED, flag the reply sentinel."
  (when (and sprig--marker (marker-buffer sprig--marker))
    (goto-char sprig--marker)
    (let ((inhibit-read-only t))
      (skip-chars-backward " \t\n")
      (delete-region (point) (marker-position sprig--marker))
      (insert "\n<!-- sprig:end id=" (or sprig--reply-id "r") " -->\n"))
    (set-marker sprig--marker (point))
    (when interrupted (sprig--flag-interrupted)))
  (sprig--decorate))

(defun sprig--flag-interrupted ()
  "Add an `interrupted' flag to the current reply's open sentinel."
  (save-excursion
    (goto-char (if (and sprig--marker (marker-buffer sprig--marker))
                   (marker-position sprig--marker)
                 (point-max)))
    (when (re-search-backward
           "^<!-- sprig:reply\\b\\([^\n]*?\\) *-->[ \t]*$" nil t)
      (unless (string-match-p "interrupted" (match-string 1))
        (let ((inhibit-read-only t))
          (replace-match "<!-- sprig:reply\\1 interrupted -->"))))))

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
          (string-trim (match-string 1)))))))

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

(defun sprig--buffer-session-id ()
  "Return the `claude_session' id from the YAML frontmatter, or nil."
  (sprig--frontmatter-get "claude_session"))

(defun sprig--save-session-id (id)
  "Store ID as `claude_session' in the buffer's YAML frontmatter."
  (sprig--frontmatter-set "claude_session" id))

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
  (let ((v (or (sprig--frontmatter-get "working_dir") sprig-directory)))
    (unless (or (null v) (string-empty-p (string-trim v)))
      (string-trim v))))

;;;; Public commands

;;;###autoload
(defun sprig-connect ()
  "Start (or resume) an agent session bound to the current buffer."
  (interactive)
  (when (process-live-p sprig--process)
    (user-error "This buffer already has a live session"))
  (setq sprig--session-id (sprig--buffer-session-id))
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
         (proc (make-process
                :name "sprig"
                :buffer nil
                :command (sprig--command)
                :connection-type 'pipe
                :coding 'utf-8-unix
                :noquery t
                :filter #'sprig--filter
                :sentinel #'sprig--sentinel)))
    (process-put proc :conv-buffer (current-buffer))
    (setq sprig--process proc)
    (message "sprig: %s (%s%s)"
             (if sprig--session-id "resuming session" "new session")
             (if sprig-remote (concat "ssh " sprig-remote) "local")
             (if dir (concat " in " dir) ""))))

(defun sprig--ensure ()
  "Ensure a live session, connecting if needed."
  (unless (process-live-p sprig--process)
    (sprig-connect)))

(defun sprig--send-user (text)
  "Send TEXT to the session as a user message."
  (let ((json (json-serialize
               `(:type "user"
                 :message (:role "user"
                           :content [(:type "text" :text ,text)])))))
    (process-send-string sprig--process (concat json "\n"))))

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
    (sprig--send-user text)))

;;;###autoload
(defun sprig-interrupt ()
  "Abort the in-flight turn, keeping and marking the partial reply."
  (interactive)
  (if (not sprig--busy)
      (message "sprig: nothing to interrupt")
    (when (process-live-p sprig--process)
      (delete-process sprig--process))
    (setq sprig--process nil sprig--busy nil)
    (sprig--close-reply t)
    (when (and sprig--marker (marker-buffer sprig--marker))
      (goto-char sprig--marker))
    (message "sprig: interrupted (session resumes on next send)")))

;;;###autoload
(defun sprig-disconnect ()
  "Stop the session for this buffer (the conversation is kept)."
  (interactive)
  (if (process-live-p sprig--process)
      (progn (delete-process sprig--process)
             (setq sprig--process nil sprig--busy nil)
             (message "sprig: disconnected"))
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

;;;; Minor mode / keymap

(defvar sprig-mode-map (make-sparse-keymap)
  "Keymap for `sprig-mode'.")

;; Bind at top level (not inside the `defvar') so reloading the file
;; refreshes the bindings; `defvar' would not reassign the live keymap.
(define-key sprig-mode-map (kbd "C-c C-c")     #'sprig-send)
(define-key sprig-mode-map (kbd "C-c C-a C-o") #'sprig-connect)
(define-key sprig-mode-map (kbd "C-c C-k")     #'sprig-interrupt)
(define-key sprig-mode-map (kbd "C-c C-a C-k") #'sprig-disconnect)
(define-key sprig-mode-map (kbd "C-c C-f")     #'sprig-toggle-fold)

;;;###autoload
(define-minor-mode sprig-mode
  "Minor mode for conversing with an agent in a Markdown buffer."
  :lighter " Sprig"
  :keymap sprig-mode-map
  (if sprig-mode
      (progn
        (add-to-invisibility-spec 'sprig-chrome)
        (add-to-invisibility-spec '(sprig-fold . t))
        (add-hook 'after-change-functions #'sprig--refresh-pending-face nil t)
        (sprig--decorate)
        (when sprig-fold-tool-calls (sprig-fold-all)))
    (remove-hook 'after-change-functions #'sprig--refresh-pending-face t)
    (remove-from-invisibility-spec 'sprig-chrome)
    (remove-from-invisibility-spec '(sprig-fold . t))
    (remove-overlays (point-min) (point-max) 'sprig-chrome t)
    (remove-overlays (point-min) (point-max) 'sprig-fold t)
    (remove-overlays (point-min) (point-max) 'sprig-user t)))

(provide 'sprig)
;;; sprig.el ends here
