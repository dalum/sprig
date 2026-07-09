;;; sprig.el --- Chat with a Claude Code session from Org, over SSH -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, convenience, ai

;;; Commentary:

;; A minimal Org-native client for a persistent Claude Code session.
;;
;; It speaks the `claude' CLI's stream-json protocol over stdio:
;;
;;   claude -p --input-format stream-json --output-format stream-json \
;;          --include-partial-messages --verbose
;;
;; Because the transport is plain stdio, the same process can run locally
;; or on a remote host via `ssh HOST claude ...' -- set `sprig-remote'.
;; The CLI uses whatever it is logged in as (e.g. a Pro/Max subscription),
;; so no API key is required.
;;
;; One Org buffer == one conversation.  Connect with `sprig-connect',
;; then send the region or the current subtree with `sprig-send-dwim'
;; (C-c C-a C-c).  Replies stream into the buffer live.  The session id is
;; stored as a `#+CLAUDE_SESSION:' keyword so the conversation survives an
;; Emacs restart and reconnects with --resume.
;;
;; This is a chat client: tools are disabled (`--allowedTools ""'), so
;; Claude answers in text and does not edit files.  For agentic work use
;; claude-code-ide.el instead.

;;; Code:

(require 'json)
(require 'subr-x)
(eval-when-compile (require 'let-alist))

(defgroup sprig nil
  "Chat with a Claude Code session from Org."
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
  "You are chatting inside an Emacs Org-mode buffer. Answer concisely in Org-formatted text."
  "Text appended to the system prompt, or nil to skip."
  :type '(choice (const :tag "None" nil) string))

(defcustom sprig-extra-args nil
  "Extra arguments appended to the `claude' command line."
  :type '(repeat string))

(defcustom sprig-response-heading "** Claude"
  "Org heading inserted before a streamed reply."
  :type 'string)

(defcustom sprig-prompt-heading "** You"
  "Org heading inserted after a reply, ready for your next message."
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
  (sprig--emit
   (concat "\n\n" sprig-prompt-heading "\n"))
  ;; Leave point ready for the next message.
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

;;;; Session-id persistence via an Org keyword

(defun sprig--buffer-session-id ()
  "Return the `#+CLAUDE_SESSION:' id in the current buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^#\\+CLAUDE_SESSION:[ \t]*\\([-0-9a-fA-F]+\\)" nil t)
      (match-string 1))))

(defun sprig--save-session-id (id)
  "Store ID as a `#+CLAUDE_SESSION:' keyword at the top of the buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((inhibit-read-only t))
      (if (re-search-forward "^#\\+CLAUDE_SESSION:.*$" nil t)
          (replace-match (concat "#+CLAUDE_SESSION: " id))
        (goto-char (point-min))
        (insert "#+CLAUDE_SESSION: " id "\n")))))

;;;; Public commands

;;;###autoload
(defun sprig-connect ()
  "Start (or resume) a Claude session bound to the current buffer."
  (interactive)
  (when (process-live-p sprig--process)
    (user-error "This buffer already has a live Claude session"))
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

(defun sprig--start-reply ()
  "Insert the reply scaffold at end of buffer and arm the marker."
  (goto-char (point-max))
  (unless (bolp) (insert "\n"))
  (insert "\n" sprig-response-heading "\n")
  (setq sprig--marker (copy-marker (point) t)))

(defun sprig-send-string (text)
  "Send TEXT as a message and stream the reply into this buffer."
  (sprig--ensure)
  (when sprig--busy
    (user-error "A turn is already in flight"))
  (setq text (string-trim text))
  (when (string-empty-p text)
    (user-error "Nothing to send"))
  (setq sprig--busy t)
  (sprig--start-reply)
  (sprig--send-user text))

;;;###autoload
(defun sprig-send-region (beg end)
  "Send the region BEG..END to Claude."
  (interactive "r")
  (sprig-send-string (buffer-substring-no-properties beg end)))

(defun sprig--subtree-body ()
  "Return the body text of the Org subtree at point (heading excluded)."
  (if (and (derived-mode-p 'org-mode) (fboundp 'org-back-to-heading))
      (save-excursion
        (org-back-to-heading t)
        (let ((beg (line-beginning-position 2)))
          (org-end-of-subtree t t)
          (buffer-substring-no-properties beg (point))))
    ;; Fallback: current paragraph.
    (save-excursion
      (let ((beg (progn (backward-paragraph) (point)))
            (end (progn (forward-paragraph) (point))))
        (buffer-substring-no-properties beg end)))))

;;;###autoload
(defun sprig-send-subtree ()
  "Send the body of the current Org subtree (or paragraph) to Claude."
  (interactive)
  (sprig-send-string (sprig--subtree-body)))

;;;###autoload
(defun sprig-send-dwim ()
  "Send the active region if any, otherwise the current subtree."
  (interactive)
  (if (use-region-p)
      (sprig-send-region (region-beginning) (region-end))
    (sprig-send-subtree)))

;;;###autoload
(defun sprig-disconnect ()
  "Stop the Claude session for this buffer (the conversation is kept)."
  (interactive)
  (if (process-live-p sprig--process)
      (progn (delete-process sprig--process)
             (setq sprig--process nil sprig--busy nil)
             (message "sprig: disconnected"))
    (message "sprig: no live session")))

;;;; Minor mode / keymap

(defvar sprig-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-a C-c") #'sprig-send-dwim)
    (define-key map (kbd "C-c C-a C-o") #'sprig-connect)
    (define-key map (kbd "C-c C-a C-k") #'sprig-disconnect)
    map)
  "Keymap for `sprig-mode'.")

;;;###autoload
(define-minor-mode sprig-mode
  "Minor mode for chatting with a Claude session in this Org buffer."
  :lighter " Sprig"
  :keymap sprig-mode-map)

(provide 'sprig)
;;; sprig.el ends here
