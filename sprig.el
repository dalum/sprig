;;; sprig.el --- Non-linear agent conversations in Markdown -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.2.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, convenience, ai

;;; Commentary:

;; Sprig is an Emacs interface for conversing with an LLM agent.  A
;; conversation branch is a plain Markdown file you edit directly: you
;; type your turns as prose, and the agent's replies stream in wrapped
;; in `<details>' blocks that fold in the editor and collapse on GitHub.
;;
;; Today the transport is the `claude' CLI's stream-json protocol over
;; stdio, local or via `ssh HOST claude ...' (set `sprig-remote').  The
;; CLI uses whatever it is logged in as (e.g. a Pro/Max subscription),
;; so no API key is required.  Tools are disabled, so the agent answers
;; in text and does not edit files.
;;
;; One buffer is one branch.  Connect with `sprig-connect', type a
;; message below the last reply, and send it with `sprig-send'
;; (C-c C-c).  The reply streams into a new `<details>' block.  The CLI
;; session id is stored in the file's YAML frontmatter (`claude_session')
;; so the conversation survives an Emacs restart and reconnects with
;; --resume.
;;
;; Design note: the CLI keeps conversation memory server-side and
;; resumes by session id, so `sprig-send' transmits only the new user
;; turn.  The intended "context is the whole file" model from DESIGN.md
;; (needed for fork-by-copy) wants a full-transcript replay, which suits
;; a stateless messages backend.  `sprig--turns' assembles that
;; role-tagged message list already; wiring it to a stateless backend,
;; plus the fork-by-copy navigator, is the next slice.

;;; Code:

(require 'json)
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

(defcustom sprig-assistant-summary "assistant"
  "Summary label used in the `<details>' block wrapping an agent reply."
  :type 'string)

;;;; Buffer-local state

(defvar-local sprig--process nil
  "The stream-json `claude' process bound to this conversation buffer.")
(defvar-local sprig--session-id nil
  "Session id captured from the CLI, used for --resume.")
(defvar-local sprig--marker nil
  "Marker where streamed reply text is inserted.")
(defvar-local sprig--busy nil
  "Non-nil while a turn is in flight.")

;;;; Command construction

(defun sprig--base-args ()
  "The `claude' argument list (without program / ssh wrapping)."
  (append
   (list "-p"
         "--input-format" "stream-json"
         "--output-format" "stream-json"
         "--include-partial-messages"
         "--verbose"
         "--allowedTools" "")           ; chat-only: no tool use
   (when sprig-model (list "--model" sprig-model))
   (when sprig-system-prompt
     (list "--append-system-prompt" sprig-system-prompt))
   (when sprig--session-id
     (list "--resume" sprig--session-id))
   sprig-extra-args))

(defun sprig--command ()
  "Full command vector for `make-process', local or via SSH."
  (let ((args (cons sprig-program (sprig--base-args))))
    (if sprig-remote
        (append (list sprig-ssh-program)
                sprig-ssh-args
                (list sprig-remote
                      (mapconcat #'shell-quote-argument args " ")))
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

(defconst sprig--block-open-re "^<details><summary>\\(.*?\\)</summary>[ \t]*$"
  "Regexp matching the opening line of an assistant `<details>' block.")
(defconst sprig--block-close-re "^</details>[ \t]*$"
  "Regexp matching the closing line of an assistant `<details>' block.")

(defun sprig--strip-reply-marker (text)
  "Remove a leading `<!-- sprig:reply ... -->' marker line from TEXT."
  (string-trim
   (replace-regexp-in-string
    "\\`[ \t\n]*<!--[ \t]*sprig:reply[^>]*-->[ \t]*\n?" "" text)))

(defun sprig--turns ()
  "Parse the buffer body into an ordered list of (ROLE . TEXT) turns.
ROLE is `user' or `assistant'.  Blank user turns are skipped.  This is
the role-tagged message list a stateless backend would send verbatim."
  (let ((turns '()))
    (save-excursion
      (goto-char (sprig--body-start))
      (let ((pos (point)))
        (while (re-search-forward sprig--block-open-re nil t)
          (let ((user-text (buffer-substring-no-properties pos (match-beginning 0)))
                (body-beg (progn (forward-line 1) (point))))
            (when (string-match-p "[^ \t\n]" user-text)
              (push (cons 'user (string-trim user-text)) turns))
            (if (re-search-forward sprig--block-close-re nil t)
                (let ((atext (buffer-substring-no-properties
                              body-beg (match-beginning 0))))
                  (push (cons 'assistant (sprig--strip-reply-marker atext)) turns)
                  (forward-line 1)
                  (setq pos (point)))
              ;; Unterminated block (a reply still streaming): take the rest.
              (let ((atext (buffer-substring-no-properties body-beg (point-max))))
                (push (cons 'assistant (sprig--strip-reply-marker atext)) turns)
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
           ;; Streaming text delta.
           ((equal .type "stream_event")
            (when (and (equal .event.type "content_block_delta")
                       (equal .event.delta.type "text_delta")
                       .event.delta.text)
              (sprig--emit .event.delta.text)))
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
      (set-marker sprig--marker (point)))))

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

;;;; Reply scaffolding

(defun sprig--next-reply-id ()
  "Return a fresh reply id like \"r3\", one past the highest in the buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((n 0))
      (while (re-search-forward "<!--[ \t]*sprig:reply" nil t)
        (setq n (1+ n)))
      (format "r%d" (1+ n)))))

(defun sprig--start-reply ()
  "Insert an assistant `<details>' scaffold at end of buffer, arm the marker."
  (let ((id (sprig--next-reply-id)))
    (goto-char (point-max))
    (skip-chars-backward " \t\n")
    (delete-region (point) (point-max))
    (let ((inhibit-read-only t))
      (insert "\n\n"
              "<details><summary>" sprig-assistant-summary "</summary>\n"
              "<!-- sprig:reply id=" id " -->\n\n"))
    (setq sprig--marker (copy-marker (point) t))))

(defun sprig--close-reply (&optional interrupted)
  "Close the current reply block.  With INTERRUPTED, flag the reply marker."
  (when (and sprig--marker (marker-buffer sprig--marker))
    (goto-char sprig--marker)
    (let ((inhibit-read-only t))
      (insert "\n</details>\n\n"))
    (set-marker sprig--marker (point))
    (when interrupted (sprig--flag-interrupted))))

(defun sprig--flag-interrupted ()
  "Add an `interrupted' flag to the most recent reply marker."
  (save-excursion
    (when (and sprig--marker (marker-buffer sprig--marker))
      (goto-char sprig--marker))
    (when (re-search-backward
           "\\(<!--[ \t]*sprig:reply\\)\\([^>]*?\\)[ \t]*-->" nil t)
      (unless (string-match-p "interrupted" (match-string 2))
        (let ((inhibit-read-only t))
          (replace-match "\\1\\2 interrupted -->"))))))

;;;; Session-id persistence via YAML frontmatter

(defun sprig--frontmatter-end ()
  "Return the position of the closing `---' line, or nil if no frontmatter."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at-p "^---[ \t]*$")
      (forward-line 1)
      (when (re-search-forward "^---[ \t]*$" nil t)
        (line-beginning-position)))))

(defun sprig--buffer-session-id ()
  "Return the `claude_session' id from the YAML frontmatter, or nil."
  (let ((end (sprig--frontmatter-end)))
    (when end
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward "^claude_session:[ \t]*\\(.+\\)$" end t)
          (string-trim (match-string 1)))))))

(defun sprig--save-session-id (id)
  "Store ID as `claude_session' in the buffer's YAML frontmatter."
  (save-excursion
    (let ((inhibit-read-only t)
          (end (sprig--frontmatter-end)))
      (if end
          (if (progn (goto-char (point-min))
                     (re-search-forward "^claude_session:.*$" end t))
              (replace-match (concat "claude_session: " id))
            (goto-char (point-min))
            (forward-line 1)
            (insert "claude_session: " id "\n"))
        (goto-char (point-min))
        (insert "---\nclaude_session: " id "\n---\n\n")))))

;;;; Public commands

;;;###autoload
(defun sprig-connect ()
  "Start (or resume) an agent session bound to the current buffer."
  (interactive)
  (when (process-live-p sprig--process)
    (user-error "This buffer already has a live session"))
  (setq sprig--session-id (sprig--buffer-session-id))
  (let ((proc (make-process
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
    (message "sprig: %s (%s)"
             (if sprig--session-id "resuming session" "new session")
             (if sprig-remote (concat "ssh " sprig-remote) "local"))))

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

;;;; Minor mode / keymap

(defvar sprig-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c")     #'sprig-send)
    (define-key map (kbd "C-c C-a C-o") #'sprig-connect)
    (define-key map (kbd "C-c C-k")     #'sprig-interrupt)
    (define-key map (kbd "C-c C-a C-k") #'sprig-disconnect)
    map)
  "Keymap for `sprig-mode'.")

;;;###autoload
(define-minor-mode sprig-mode
  "Minor mode for conversing with an agent in a Markdown buffer."
  :lighter " Sprig"
  :keymap sprig-mode-map)

(provide 'sprig)
;;; sprig.el ends here
