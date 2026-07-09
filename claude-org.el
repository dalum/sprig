;;; claude-org.el --- Chat with a Claude Code session from Org, over SSH -*- lexical-binding: t; -*-

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
;; or on a remote host via `ssh HOST claude ...' -- set `claude-org-remote'.
;; The CLI uses whatever it is logged in as (e.g. a Pro/Max subscription),
;; so no API key is required.
;;
;; One Org buffer == one conversation.  Connect with `claude-org-connect',
;; then send the region or the current subtree with `claude-org-send-dwim'
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

(defgroup claude-org nil
  "Chat with a Claude Code session from Org."
  :group 'tools
  :prefix "claude-org-")

(defcustom claude-org-program "claude"
  "Path to the `claude' CLI (on the machine where the session runs)."
  :type 'string)

(defcustom claude-org-remote nil
  "If non-nil, an SSH destination (e.g. \"user@host\") to run `claude' on.
When nil, the session runs locally."
  :type '(choice (const :tag "Local" nil) (string :tag "SSH destination")))

(defcustom claude-org-ssh-program "ssh"
  "SSH client used when `claude-org-remote' is set."
  :type 'string)

(defcustom claude-org-ssh-args '("-T")
  "Extra arguments passed to SSH (before the destination).
`-T' disables pseudo-tty allocation, which is what we want for a pipe."
  :type '(repeat string))

(defcustom claude-org-model "claude-opus-4-8"
  "Model id, or nil to let the CLI choose its default."
  :type '(choice (const :tag "CLI default" nil) (string :tag "Model id")))

(defcustom claude-org-system-prompt
  "You are chatting inside an Emacs Org-mode buffer. Answer concisely in Org-formatted text."
  "Text appended to the system prompt, or nil to skip."
  :type '(choice (const :tag "None" nil) string))

(defcustom claude-org-extra-args nil
  "Extra arguments appended to the `claude' command line."
  :type '(repeat string))

(defcustom claude-org-response-heading "** Claude"
  "Org heading inserted before a streamed reply."
  :type 'string)

(defcustom claude-org-prompt-heading "** You"
  "Org heading inserted after a reply, ready for your next message."
  :type 'string)

;;;; Buffer-local state

(defvar-local claude-org--process nil
  "The stream-json `claude' process bound to this conversation buffer.")
(defvar-local claude-org--session-id nil
  "Session id captured from the CLI, used for --resume.")
(defvar-local claude-org--marker nil
  "Marker where streamed reply text is inserted.")
(defvar-local claude-org--busy nil
  "Non-nil while a turn is in flight.")

;;;; Command construction

(defun claude-org--base-args ()
  "The `claude' argument list (without program / ssh wrapping)."
  (append
   (list "-p"
         "--input-format" "stream-json"
         "--output-format" "stream-json"
         "--include-partial-messages"
         "--verbose"
         "--allowedTools" "")           ; chat-only: no tool use
   (when claude-org-model (list "--model" claude-org-model))
   (when claude-org-system-prompt
     (list "--append-system-prompt" claude-org-system-prompt))
   (when claude-org--session-id
     (list "--resume" claude-org--session-id))
   claude-org-extra-args))

(defun claude-org--command ()
  "Full command vector for `make-process', local or via SSH."
  (let ((args (cons claude-org-program (claude-org--base-args))))
    (if claude-org-remote
        (append (list claude-org-ssh-program)
                claude-org-ssh-args
                (list claude-org-remote
                      (mapconcat #'shell-quote-argument args " ")))
      args)))

;;;; Process I/O

(defun claude-org--filter (proc chunk)
  "Accumulate CHUNK from PROC and dispatch complete JSON lines."
  (let* ((acc (concat (or (process-get proc :acc) "") chunk))
         (lines (split-string acc "\n")))
    ;; Last element is the (possibly empty) incomplete tail.
    (process-put proc :acc (car (last lines)))
    (dolist (line (butlast lines))
      (setq line (string-trim line))
      (unless (string-empty-p line)
        (claude-org--handle proc line)))))

(defun claude-org--handle (proc line)
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
            (when (and .session_id (not claude-org--session-id))
              (setq claude-org--session-id .session_id)
              (claude-org--save-session-id .session_id)))
           ;; Streaming text delta.
           ((equal .type "stream_event")
            (when (and (equal .event.type "content_block_delta")
                       (equal .event.delta.type "text_delta")
                       .event.delta.text)
              (claude-org--emit .event.delta.text)))
           ;; Turn complete.
           ((equal .type "result")
            (claude-org--finish-turn .total_cost_usd .is_error))
           ;; Fallback: a non-streamed error surfaced as a result-less error.
           ((and (equal .type "system") (equal .subtype "error"))
            (claude-org--emit (format "\n[error] %s\n" (or .message line))))))))))

(defun claude-org--emit (text)
  "Insert streamed TEXT at the reply marker in the current buffer."
  (when (and claude-org--marker (marker-buffer claude-org--marker))
    (save-excursion
      (goto-char claude-org--marker)
      (let ((inhibit-read-only t))
        (insert text))
      (set-marker claude-org--marker (point)))))

(defun claude-org--finish-turn (cost is-error)
  "Close out the current turn.  COST and IS-ERROR come from the result event."
  (setq claude-org--busy nil)
  (claude-org--emit
   (concat "\n\n" claude-org-prompt-heading "\n"))
  ;; Leave point ready for the next message.
  (when (and claude-org--marker (marker-buffer claude-org--marker))
    (goto-char claude-org--marker))
  (message "claude-org: turn done%s%s"
           (if cost (format " ($%.4f)" cost) "")
           (if is-error " [error]" "")))

(defun claude-org--sentinel (proc event)
  "Report PROC lifecycle EVENT."
  (let ((buf (process-get proc :conv-buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (memq (process-status proc) '(exit signal))
          (setq claude-org--process nil
                claude-org--busy nil)
          (message "claude-org: session ended (%s)" (string-trim event)))))))

;;;; Session-id persistence via an Org keyword

(defun claude-org--buffer-session-id ()
  "Return the `#+CLAUDE_SESSION:' id in the current buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^#\\+CLAUDE_SESSION:[ \t]*\\([-0-9a-fA-F]+\\)" nil t)
      (match-string 1))))

(defun claude-org--save-session-id (id)
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
(defun claude-org-connect ()
  "Start (or resume) a Claude session bound to the current buffer."
  (interactive)
  (when (process-live-p claude-org--process)
    (user-error "This buffer already has a live Claude session"))
  (setq claude-org--session-id (claude-org--buffer-session-id))
  (let ((proc (make-process
               :name "claude-org"
               :buffer nil
               :command (claude-org--command)
               :connection-type 'pipe
               :coding 'utf-8-unix
               :noquery t
               :filter #'claude-org--filter
               :sentinel #'claude-org--sentinel)))
    (process-put proc :conv-buffer (current-buffer))
    (setq claude-org--process proc)
    (message "claude-org: %s (%s)"
             (if claude-org--session-id "resuming session" "new session")
             (if claude-org-remote (concat "ssh " claude-org-remote) "local"))))

(defun claude-org--ensure ()
  "Ensure a live session, connecting if needed."
  (unless (process-live-p claude-org--process)
    (claude-org-connect)))

(defun claude-org--send-user (text)
  "Send TEXT to the session as a user message."
  (let ((json (json-serialize
               `(:type "user"
                 :message (:role "user"
                           :content [(:type "text" :text ,text)])))))
    (process-send-string claude-org--process (concat json "\n"))))

(defun claude-org--start-reply ()
  "Insert the reply scaffold at end of buffer and arm the marker."
  (goto-char (point-max))
  (unless (bolp) (insert "\n"))
  (insert "\n" claude-org-response-heading "\n")
  (setq claude-org--marker (copy-marker (point) t)))

(defun claude-org-send-string (text)
  "Send TEXT as a message and stream the reply into this buffer."
  (claude-org--ensure)
  (when claude-org--busy
    (user-error "A turn is already in flight"))
  (setq text (string-trim text))
  (when (string-empty-p text)
    (user-error "Nothing to send"))
  (setq claude-org--busy t)
  (claude-org--start-reply)
  (claude-org--send-user text))

;;;###autoload
(defun claude-org-send-region (beg end)
  "Send the region BEG..END to Claude."
  (interactive "r")
  (claude-org-send-string (buffer-substring-no-properties beg end)))

(defun claude-org--subtree-body ()
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
(defun claude-org-send-subtree ()
  "Send the body of the current Org subtree (or paragraph) to Claude."
  (interactive)
  (claude-org-send-string (claude-org--subtree-body)))

;;;###autoload
(defun claude-org-send-dwim ()
  "Send the active region if any, otherwise the current subtree."
  (interactive)
  (if (use-region-p)
      (claude-org-send-region (region-beginning) (region-end))
    (claude-org-send-subtree)))

;;;###autoload
(defun claude-org-disconnect ()
  "Stop the Claude session for this buffer (the conversation is kept)."
  (interactive)
  (if (process-live-p claude-org--process)
      (progn (delete-process claude-org--process)
             (setq claude-org--process nil claude-org--busy nil)
             (message "claude-org: disconnected"))
    (message "claude-org: no live session")))

;;;; Minor mode / keymap

(defvar claude-org-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-a C-c") #'claude-org-send-dwim)
    (define-key map (kbd "C-c C-a C-o") #'claude-org-connect)
    (define-key map (kbd "C-c C-a C-k") #'claude-org-disconnect)
    map)
  "Keymap for `claude-org-mode'.")

;;;###autoload
(define-minor-mode claude-org-mode
  "Minor mode for chatting with a Claude session in this Org buffer."
  :lighter " Claude"
  :keymap claude-org-mode-map)

(provide 'claude-org)
;;; claude-org.el ends here
