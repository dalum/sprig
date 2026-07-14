;;; sprig.el --- Transport and navigator for reviewing agent sessions -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.5.0
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
;; via `ssh HOST claude ...' (set `sprig-remote').  `sprig--claude-parse-line'
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

(defcustom sprig-error-buffer "*sprig-errors*"
  "Name of the buffer where session failures are logged.
When a session exits abnormally, its command, exit status, and captured
stderr are appended here and the buffer is displayed."
  :type 'string)

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

(defcustom sprig-status-preview-max-lines 3
  "Maximum number of lines shown in a navigator inline reply preview.
`sprig-status-toggle-preview' (bound to TAB) expands the row at point to
show the tail of that session's last reply, filled to this many lines."
  :type 'integer)

(defface sprig-status-preview '((t :inherit shadow :slant italic))
  "Face for the inline reply preview shown under an expanded navigator row.")

;;;; Buffer-local state

(defvar-local sprig--process nil
  "The stream-json `claude' process bound to this conversation buffer.")
(defvar-local sprig--session-id nil
  "Session id captured from the CLI, used for --resume.")
(defvar-local sprig--busy nil
  "Non-nil while a turn is in flight.")
(defvar-local sprig--blocks nil
  "Alist of in-flight streaming tool-use blocks, keyed by block index.
Each entry is (INDEX :id ID :name NAME :json ACC), where ACC accumulates
the streamed `input_json_delta' fragments until the block closes.")
(defvar-local sprig--permission-mode nil
  "The session's current permission mode, tracked from `status' events.
nil until the CLI reports one; \"plan\" while a plan turn is in effect.")
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
A local session's working directory is set by `sprig--spawn' binding
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

;;;; Session lifecycle

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
(declare-function sprig-review-set-remote "sprig-review-mode" (remote))
(declare-function sprig-review-session-events "sprig-review" (lines))
(declare-function sprig-review-interrupt "sprig-review-mode" ())

(defun sprig--remote-sh (command)
  "Run shell COMMAND on the session host via SSH; return stdout.
COMMAND is POSIX-sh syntax, so it is wrapped in `sh -c' rather than left
to the host's login shell: a non-POSIX login shell such as fish rejects
the scan's `for'-loop outright, which would silently strip every session
of its recorded cwd.  Signals if SSH exits non-zero."
  (with-temp-buffer
    (let ((status (apply #'call-process sprig-ssh-program nil t nil
                         (append sprig-ssh-args
                                 (list sprig-remote
                                       (concat "sh -c "
                                               (shell-quote-argument command)))))))
      (unless (eq status 0)
        (error "sprig: remote command failed (%s): %s"
               status (string-trim (buffer-string))))
      (buffer-string))))

(defun sprig--session-log-lines ()
  "Return the stored session-log lines for this buffer's session.
Locates the log by session id under ~/.claude/projects on the session
host (local or over SSH), so the working-directory encoding never has to
be reproduced.  Signals a `user-error' when there is no id or no log."
  (let ((id (or sprig--session-id
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

;; A review buffer owns its session outright: the transport routes events
;; to `sprig--review-sink' and its verbs steer the session directly (see
;; DESIGN.md, option A: CLI sessions are the branches).

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
DIR may be nil when it is unknown (a stored session whose log carried no
cwd), in which case the session runs in the host's login directory.  With
SESSION-ID, replay that stored session's log and resume it on the next
send; without, the buffer starts empty and a send opens a fresh session.
The review buffer is the only conversation surface."
  (interactive (list (sprig--read-review-dir)))
  (require 'sprig-review-mode)
  (let* ((name (format "*sprig-review: %s*"
                       (or session-id
                           (and dir (file-name-nondirectory
                                     (directory-file-name dir)))
                           "new")))
         (buffer (sprig-review-buffer name)))
    (with-current-buffer buffer
      (setq sprig--session-id session-id
            sprig--working-dir dir
            sprig--sink #'sprig--review-sink
            sprig--connect-fn #'sprig-review-connect)
      (let* ((lines (and session-id (ignore-errors (sprig--session-log-lines))))
             (events (and lines (sprig-review-session-events lines))))
        (sprig-review-seed events (list :project dir)))
      (sprig-review-set-remote sprig-remote))
    (pop-to-buffer buffer)))

;;;; Folding commands

;;;; Status navigator

(defconst sprig-status-buffer-name "*sprig-status*"
  "Name of the buffer showing the `sprig-status' navigator.")

(defconst sprig--status-preview-bytes 65536
  "Bytes of a session log read from one end, for two callers.
A row's scan reads this much from the head to recover its `cwd', which is
in the first record; a `TAB' preview reads this much from the tail for the
last reply, which lives at the end.  (The title is not in either window in
general, so it is grepped whole-file.)  Local and remote read the same
amount, and either read is bounded however large the session grows.")

(defconst sprig--status-glyphs
  '((streaming    . "▶")
    (idle         . "●")
    (interrupted  . "◼")
    (disconnected . "○"))
  "Glyph shown in the status column for each session state.")

(defvar sprig-claude-projects-directory "~/.claude/projects"
  "Root under which the `claude' CLI stores per-project session logs.
Local sessions read it here; remote sessions read the same path on the
SSH host.  A variable, not a defcustom, so tests can redirect it.")

(defvar-local sprig--status-filter nil
  "Case-insensitive substring the navigator narrows rows to, or nil for all.
Matched against a row's project directory and its title.")

(defvar-local sprig--status-show-all nil
  "When non-nil, the navigator lists every session.
It lifts the `sprig-status-max-sessions' cap for its buffer.")

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

(defun sprig--session-status (buf)
  "Return the session status for its owning review BUF (nil = not open).
One of `streaming', `idle', or `disconnected'."
  (cond
   ((not (buffer-live-p buf)) 'disconnected)
   ((buffer-local-value 'sprig--busy buf) 'streaming)
   ((process-live-p (buffer-local-value 'sprig--process buf)) 'idle)
   (t 'disconnected)))

(defun sprig--status-limit ()
  "Maximum number of stored sessions the navigator lists, or nil for all.
`L' in the navigator sets `sprig--status-show-all' to lift the cap;
otherwise `sprig-status-max-sessions' bounds the newest-first scan."
  (and (not sprig--status-show-all) sprig-status-max-sessions))

(defun sprig--log-cwd (text)
  "Return the working directory recorded in session-log TEXT, or nil.
Every CLI record carries the session's `cwd', so any slice of the log
holds it; the scan reads the head, where the first record already has it."
  (and (string-match "\"cwd\":\\(\"\\(?:[^\"\\]\\|\\\\.\\)*\"\\)" text)
       (ignore-errors (json-parse-string (match-string 1 text)))))

(defun sprig--log-title (text)
  "Return the last `aiTitle' recorded in session-log TEXT, or nil.
TEXT is either a log's head or its grepped `ai-title' lines; the CLI
re-emits the same title each turn, so the last match wins in either."
  (let ((title nil) (pos 0))
    (while (string-match "\"aiTitle\":\\(\"\\(?:[^\"\\]\\|\\\\.\\)*\"\\)" text pos)
      (setq title (match-string 1 text) pos (match-end 0)))
    (and title (ignore-errors (json-parse-string title)))))

(defun sprig--session-log-head (file)
  "Return the leading bytes of session-log FILE, local or remote, or nil.
The scan reads the head for the `cwd', which is in the first record.  The
title is not read from here (a large opening turn can push the first
`ai-title' record past the window); it is grepped whole-file instead."
  (ignore-errors
    (if sprig-remote
        (sprig--remote-sh (format "head -c %d %s" sprig--status-preview-bytes
                                  (sprig--remote-dir-arg file)))
      (with-temp-buffer
        (let ((size (file-attribute-size (file-attributes file))))
          (insert-file-contents file nil 0 (min sprig--status-preview-bytes
                                                 size)))
        (buffer-string)))))

(defun sprig--local-title-line (file)
  "Return session-log FILE's `aiTitle' lines, grepped from the whole file.
The title can sit anywhere (a large opening turn pushes the first one well
past any head window), so it is grepped rather than read from a slice.
Consulted only when the head carries no title, so the whole-file read is
paid only for the rare session that needs it."
  (ignore-errors
    (with-temp-buffer
      (and (eq 0 (call-process "grep" nil t nil "-a" "aiTitle"
                               (expand-file-name file)))
           (buffer-string)))))

(defun sprig--session-log-tail (file)
  "Return the trailing bytes of session-log FILE, local or remote, or nil.
Used for the last-reply preview, which genuinely lives at the end; the
row scan reads the head instead (see `sprig--session-log-head')."
  (ignore-errors
    (if sprig-remote
        (sprig--remote-sh (format "tail -c %d %s" sprig--status-preview-bytes
                                  (sprig--remote-dir-arg file)))
      (with-temp-buffer
        (let* ((size (file-attribute-size (file-attributes file)))
               (from (max 0 (- size sprig--status-preview-bytes))))
          (insert-file-contents file nil from size))
        (buffer-string)))))

(defun sprig--log-plist (file mtime head &optional title-fallback)
  "Build a scan plist for log FILE with MTIME and its HEAD text.
`:dir' is the session's own recorded `cwd', or nil when HEAD carries none:
the encoded log-directory name is not a real path (its separators are
lossily flattened to dashes), so it is kept only as the display-only
`:project' and never handed to a `cd'.  The title is read from HEAD when it
is there; otherwise TITLE-FALLBACK, a function returning grepped `ai-title'
lines, is consulted, so a title pushed past the head window is still found."
  (let ((cwd (and head (sprig--log-cwd head)))
        (title (or (and head (sprig--log-title head))
                   (and title-fallback
                        (let ((lines (funcall title-fallback)))
                          (and lines (sprig--log-title lines)))))))
    (list :session (file-name-base file)
          :file file
          :dir cwd
          :project (or cwd
                       (file-name-nondirectory
                        (directory-file-name (file-name-directory file))))
          :mtime mtime
          :title (or title "(untitled)"))))

(defun sprig--scan-session-logs ()
  "Return session plists for the newest stored logs on the session host.
Each plist has :session, :file, :dir (the log's recorded cwd, or nil),
:project (its display label), :mtime, and :title.  Sourced host-wide from
`sprig-claude-projects-directory',
newest first, capped to `sprig--status-limit' so a host with hundreds of
sessions still paints fast."
  (if sprig-remote
      (sprig--scan-session-logs-remote (sprig--status-limit))
    (sprig--scan-session-logs-local (sprig--status-limit))))

(defun sprig--scan-session-logs-local (limit)
  "Scan the LIMIT newest local logs under `sprig-claude-projects-directory'."
  (let* ((root (expand-file-name sprig-claude-projects-directory))
         (files (and (file-directory-p root)
                     (directory-files-recursively root "\\.jsonl\\'")))
         (dated (sort (mapcar (lambda (f)
                                (cons (float-time
                                       (file-attribute-modification-time
                                        (file-attributes f)))
                                      f))
                              files)
                      (lambda (a b) (> (car a) (car b))))))
    (when limit (setq dated (seq-take dated limit)))
    (mapcar (lambda (cell)
              (sprig--log-plist (cdr cell) (car cell)
                                (sprig--session-log-head (cdr cell))
                                (lambda () (sprig--local-title-line (cdr cell)))))
            dated)))

(defun sprig--scan-session-logs-remote (limit)
  "Scan the LIMIT newest remote logs under `sprig-claude-projects-directory'.
Two SSH round trips whatever LIMIT is: one lists the newest logs by mtime,
one slurps each log's head (for the cwd) and its last `ai-title' line (for
the title, grepped whole-file since it can sit anywhere)."
  (let* ((root (sprig--remote-dir-arg
                (directory-file-name sprig-claude-projects-directory)))
         (listing (ignore-errors
                    (sprig--remote-sh
                     (format "find %s -name '*.jsonl' -printf '%%T@\\t%%p\\n' \
2>/dev/null | sort -rn | head -n %d"
                             root (or limit 1000000)))))
         (dated (delq nil
                      (mapcar (lambda (line)
                                (when (string-match "\\`\\([0-9.]+\\)\t\\(.+\\)\\'"
                                                    line)
                                  (cons (string-to-number (match-string 1 line))
                                        (match-string 2 line))))
                              (split-string (or listing "") "\n" t)))))
    (when dated
      (let* ((paths (mapcar #'cdr dated))
             (blob (ignore-errors
                     (sprig--remote-sh (sprig--remote-scan-command paths))))
             (scan (sprig--parse-scan-blob blob)))
        (mapcar (lambda (cell)
                  (let ((fields (gethash (cdr cell) scan)))
                    (sprig--log-plist (cdr cell) (car cell)
                                      (car fields)
                                      (lambda () (cdr fields)))))
                dated)))))

(defun sprig--remote-scan-command (paths)
  "Shell command printing each of PATHS' scan fields, record-separated.
Per file: RS, path, US, its head bytes (for the `cwd'), US, then its last
`ai-title' line grepped from the whole file (for the title, wherever it
sits).  The set returns in one SSH round trip for `sprig--parse-scan-blob'."
  (concat "for f in " (mapconcat #'shell-quote-argument paths " ")
          (format "; do printf '\\036%%s\\037' \"$f\"; head -c %d \"$f\"; \
printf '\\037'; grep -a aiTitle \"$f\" | tail -1; done"
                  sprig--status-preview-bytes)))

(defun sprig--parse-scan-blob (blob)
  "Parse BLOB from `sprig--remote-scan-command' into path -> (head . title).
Each record is path, then its head bytes, then its `ai-title' line, split
on the US byte; the title is nil when the file had none."
  (let ((map (make-hash-table :test 'equal)))
    (dolist (chunk (and blob (split-string blob "\036" t)))
      (let ((us (string-search "\037" chunk)))
        (when us
          (let* ((path (substring chunk 0 us))
                 (rest (substring chunk (1+ us)))
                 (us2 (string-search "\037" rest)))
            (puthash path
                     (if us2
                         (let ((title (substring rest (1+ us2))))
                           (cons (substring rest 0 us2)
                                 (unless (string-empty-p title) title)))
                       (cons rest nil))
                     map)))))
    map))

;;; Last-reply preview

(defun sprig--last-paragraph (text)
  "Return the last non-empty paragraph of TEXT, or nil.
Line breaks within the paragraph are collapsed to single spaces, so it can
be re-wrapped for display."
  (let (result)
    (dolist (para (split-string text "\n[ \t]*\n" t))
      (let ((collapsed (string-trim
                        (replace-regexp-in-string "[ \t\n]+" " " para))))
        (unless (string-empty-p collapsed)
          (setq result collapsed))))
    result))

(defun sprig--events-last-text (events)
  "Return the last assistant text block's last paragraph from EVENTS, or nil.
EVENTS are in chronological order (the review model's input order)."
  (let* ((model (ignore-errors (sprig-review-build events)))
         (blocks (and model (plist-get model :blocks)))
         (last (seq-find (lambda (b) (eq (plist-get b :type) 'text))
                         (reverse blocks))))
    (and last (sprig--last-paragraph (plist-get last :text)))))

(defun sprig--entry-preview (entry)
  "Return the inline reply preview for status ENTRY, or nil.
From the open review buffer's events when ENTRY has one, else the stored
session log's tail."
  (let ((buf (plist-get entry :buffer))
        (file (plist-get entry :file)))
    (cond
     ((buffer-live-p buf)
      (sprig--events-last-text
       (reverse (buffer-local-value 'sprig-review--events buf))))
     (file
      (let ((tail (sprig--session-log-tail file)))
        (and tail (sprig--events-last-text
                   (sprig-review-session-events (split-string tail "\n" t)))))))))

;;; Collect open buffers and stored sessions into rows

(defun sprig--status-collect ()
  "Return status plists for all branches, deduped by session id.
Each plist has :key, :buffer (or nil), :file (or nil), :dir (a real
working directory or nil), :project (its display label), :title, :status,
and :session.  An open session-owning review buffer wins over
its stored log, carrying live status and a session with no log yet.  When
`sprig--status-filter' is set, only rows matching it are returned."
  (let ((table (make-hash-table :test 'equal))
        (order '()))
    (dolist (buf (sprig--owning-review-buffers))
      (let* ((id (buffer-local-value 'sprig--session-id buf))
             (key (or id buf)))
        (unless (gethash key table)
          (push key order)
          (puthash key
                   (list :key key :buffer buf :file nil
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
                         :session id)
                   table))))
    (dolist (e (sprig--scan-session-logs))
      (let* ((key (plist-get e :session))
             (existing (gethash key table)))
        (cond
         ((null existing)
          (push key order)
          (puthash key
                   (list :key key :buffer nil :file (plist-get e :file)
                         :dir (plist-get e :dir)
                         :project (plist-get e :project)
                         :title (plist-get e :title)
                         :status 'disconnected
                         :session (plist-get e :session))
                   table))
         ;; An owning buffer that could not title itself borrows the log's.
         ((null (plist-get existing :title))
          (puthash key (plist-put existing :title (plist-get e :title))
                   table)))))
    (let ((rows (mapcar (lambda (k)
                          (let ((e (gethash k table)))
                            (if (plist-get e :title)
                                e
                              (plist-put e :title "(untitled)"))))
                        (nreverse order))))
      (if (and sprig--status-filter (not (string-empty-p sprig--status-filter)))
          (seq-filter (lambda (e) (sprig--entry-matches-filter e sprig--status-filter))
                      rows)
        rows))))

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
    ('idle 'success)
    ('interrupted 'font-lock-comment-face)
    (_ 'shadow)))

(defvar-local sprig--status-index nil
  "Hash mapping the current render's entry ids to their status plists.")

(defun sprig--status-entries ()
  "Build `tabulated-list-entries' from a fresh `sprig--status-collect'.
The entry id is the entry's `:key' (its session id, else its buffer):
stable across refreshes, so point and inline-preview state survive.  Stale
ids are pruned from `sprig--status-expanded' so it never outlives its row."
  (let ((index (make-hash-table :test 'equal))
        rows)
    (dolist (e (sprig--status-collect))
      (let* ((id (plist-get e :key))
             (status (plist-get e :status))
             (dir (plist-get e :project))
             (session (plist-get e :session))
             (glyph (propertize (or (alist-get status sprig--status-glyphs) "?")
                                'face (sprig--status-face status))))
        (puthash id e index)
        (push (list id
                    (vector glyph
                            (or (plist-get e :title) "")
                            (if dir (file-name-nondirectory
                                     (directory-file-name dir))
                              "-")
                            (if (and (stringp session) (> (length session) 0))
                                (substring session 0 (min 8 (length session)))
                              "-")))
              rows)))
    (setq sprig--status-index index)
    (setq mode-line-process
          (concat (and sprig--status-filter
                       (format " /%s" sprig--status-filter))
                  (and sprig--status-show-all " [all]")))
    (sprig--status-prune-expanded index)
    (nreverse rows)))

;;; Inline reply previews

(defvar-local sprig--status-expanded nil
  "Hash table of navigator entry ids currently showing an inline preview.")

(defun sprig--status-prune-expanded (index)
  "Drop ids from `sprig--status-expanded' absent from INDEX.
An entry's id changes when it flips identity (an owning buffer gains a
session id once its log exists), which would otherwise strand its expanded
flag and desync the hash from the screen, so a later TAB toggles the
phantom instead of the row."
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
(define-key sprig-status-mode-map (kbd "/")   #'sprig-status-filter)
(define-key sprig-status-mode-map (kbd "L")   #'sprig-status-show-all)
(define-key sprig-status-mode-map (kbd "?")   #'describe-mode)

(define-derived-mode sprig-status-mode tabulated-list-mode "Sprig-Status"
  "Major mode listing Sprig conversations and their live status.
\\<sprig-status-mode-map>Open with \\[sprig-status-open], connect with
\\[sprig-status-connect], interrupt with \\[sprig-status-interrupt],
disconnect with \\[sprig-status-disconnect], refresh with \\[revert-buffer]."
  (setq tabulated-list-format
        [("S" 2 t)
         ("Title" 32 t)
         ("Project" 24 t)
         ("Session" 9 nil)]
        tabulated-list-padding 1
        tabulated-list-sort-key nil
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

(defun sprig--status-review-buffer (entry)
  "Return the review buffer for ENTRY, opening it from the log if needed.
An open owning buffer is reused; otherwise a review buffer is opened that
owns the session, replaying its stored log."
  (let ((buf (plist-get entry :buffer)))
    (if (buffer-live-p buf)
        buf
      (sprig-review-session (plist-get entry :dir) (plist-get entry :session)))))

(defun sprig--status-owning-buffer (entry)
  "Return ENTRY's open owning review buffer, or signal that it is not open."
  (let ((buf (plist-get entry :buffer)))
    (if (buffer-live-p buf) buf
      (user-error "That session is not open (open it first)"))))

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
  "Open the review buffer for the session on the current line.
Reuses an open owning buffer, or replays the stored log into a new one."
  (interactive)
  (pop-to-buffer (sprig--status-review-buffer (sprig--status-entry-at-point)))
  (sprig--status-refresh))

(defun sprig-status-connect ()
  "Open the session on the current line and start or resume it."
  (interactive)
  (let ((buf (sprig--status-review-buffer (sprig--status-entry-at-point))))
    (with-current-buffer buf
      (unless (process-live-p sprig--process) (sprig-review-connect)))
    (sprig--status-refresh)))

(defun sprig-status-interrupt ()
  "Interrupt the streaming session on the current line."
  (interactive)
  (with-current-buffer (sprig--status-owning-buffer (sprig--status-entry-at-point))
    (sprig-review-interrupt))
  (sprig--status-refresh))

(defun sprig-status-disconnect ()
  "Disconnect the session on the current line (its log is kept)."
  (interactive)
  (with-current-buffer (sprig--status-owning-buffer (sprig--status-entry-at-point))
    (when (process-live-p sprig--process) (sprig--teardown-process)))
  (sprig--status-refresh))

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
  "Start a fresh session, prompting for its working directory.
Opens a review buffer that owns the new session; it appears in the
navigator and streams like any other."
  (interactive)
  (sprig-review-session (sprig--read-review-dir))
  (sprig--status-refresh))

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
  (sprig--status-render)
  (message (if sprig--status-show-all
               "Listing every session"
             (format "Listing the %s newest sessions" sprig-status-max-sessions))))

;;;###autoload
(defun sprig-status ()
  "Open the `*sprig-status*' navigator listing Sprig sessions.
Lists every stored `claude' session on the host, newest first and capped
to `sprig-status-max-sessions', plus any open review buffer that owns a
live session.  Narrow with `/', lift the cap with `L'."
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
      (sprig--status-render))
    (pop-to-buffer buf)))

;;;; Development

(defconst sprig--source-directory
  (file-name-directory (or load-file-name buffer-file-name
                           (locate-library "sprig")))
  "Directory sprig's own source files were loaded from, for `sprig-reload'.")

(defvar sprig--source-files '("sprig-review" "sprig" "sprig-review-mode")
  "Sprig's own source files, in dependency load order, for `sprig-reload'.")

;;;###autoload
(defun sprig-reload ()
  "Reload sprig's source files from disk, in dependency order.
A development convenience: after editing any of `sprig-review', `sprig',
or `sprig-review-mode', re-load all three from `sprig--source-directory'
so the change takes effect without restarting Emacs.  The `.el' source is
loaded, not any stale byte code beside it.  Open buffers keep their state;
only their behaviour picks up the new definitions."
  (interactive)
  (dolist (file sprig--source-files)
    (load (expand-file-name (concat file ".el") sprig--source-directory) nil t))
  (message "sprig: reloaded %d files from %s"
           (length sprig--source-files) sprig--source-directory))

(provide 'sprig)
;;; sprig.el ends here
