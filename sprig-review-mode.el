;;; sprig-review-mode.el --- Read-only review buffer for sprig -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.4.1
;; Package-Requires: ((emacs "28.1") (magit-section "4.0.0"))
;; Keywords: tools, convenience, ai

;;; Commentary:

;; The read-only, Magit-like review buffer (see DESIGN.md, "Current
;; direction: the review buffer").  It projects a review model built by
;; `sprig-review-build' into `magit-section' rows: a metadata header,
;; assistant prose, and tool calls whose file changes render as a foldable
;; diff with their result.  The buffer is read-only; you move a cursor
;; over it and fold with the usual magit-section keys (TAB / C-TAB).
;;
;; This file is the *view*.  It carries the model's plists on each
;; section's `value' slot (an Edit's hunk lives on its hunk section, a
;; tool call on its tool section), so the mark-and-instruction verbs that
;; come next can read the object under point without re-parsing text.
;;
;; The offline ERT suite for the pure model and diff engine
;; (sprig-review.el) needs no magit-section; the tests for this renderer
;; live in sprig-review-mode-tests.el and load magit-section, so they run
;; separately from the process-free suite.

;;; Code:

(require 'magit-section)
(require 'diff-mode)                     ; for the diff-* faces
(require 'sprig-review)
(require 'subr-x)
(require 'eieio)

;;;; Faces

(defface sprig-review-tool '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a tool-call heading in the review buffer."
  :group 'sprig)

(defface sprig-review-file '((t :inherit diff-file-header))
  "Face for a changed file's path."
  :group 'sprig)

(defface sprig-review-added '((t :inherit diff-added))
  "Face for an added line in a reconstructed hunk."
  :group 'sprig)

(defface sprig-review-removed '((t :inherit diff-removed))
  "Face for a removed line in a reconstructed hunk."
  :group 'sprig)

(defface sprig-review-role '((t :inherit magit-section-secondary-heading))
  "Face for an assistant-turn label."
  :group 'sprig)

(defface sprig-review-user '((t :inherit magit-section-secondary-heading :slant italic))
  "Face for a user-turn label."
  :group 'sprig)

(defface sprig-review-thinking '((t :inherit shadow :slant italic))
  "Face for a thinking-block label."
  :group 'sprig)

(defface sprig-review-meta-key '((t :inherit font-lock-comment-face))
  "Face for a metadata key in the header."
  :group 'sprig)

;;;; Heading helpers

(defun sprig-review--stat-string (change)
  "Return a \"(+A -B)\" line-count summary for CHANGE."
  (let ((s (sprig-review-change-stat change)))
    (format "(+%d -%d)" (car s) (cdr s))))

(defun sprig-review--input-summary (name input)
  "Return a one-line summary of tool NAME's INPUT, or nil.
Shows the command for `Bash'; file tools are summarised by their diff
header instead, so they return nil here."
  (when (equal name "Bash")
    (let ((obj (sprig-review--parse-input input)))
      (when-let ((cmd (alist-get 'command obj)))
        (car (split-string cmd "\n"))))))

(defun sprig-review--tool-heading (block)
  "Return the single-line heading string for tool BLOCK."
  (let* ((name (or (plist-get block :name) "tool"))
         (changes (plist-get block :changes))
         (summary (sprig-review--input-summary name (plist-get block :input)))
         (err (plist-get (plist-get block :result) :error)))
    (concat
     (propertize (concat "🔧 " name) 'face 'sprig-review-tool)
     (cond
      (changes
       (let ((c (car changes)))
         (concat "  " (plist-get c :file) "  " (sprig-review--stat-string c))))
      (summary (concat "  " summary))
      (t ""))
     (if err (propertize "  [error]" 'face 'error) ""))))

;;;; Section insertion

(defun sprig-review--insert-hunk (hunk)
  "Insert HUNK as removed lines then added lines, each a coloured section line."
  (magit-insert-section (sprig-hunk hunk)
    (dolist (l (plist-get hunk :old))
      (insert (propertize (concat "-" l) 'face 'sprig-review-removed) "\n"))
    (dolist (l (plist-get hunk :new))
      (insert (propertize (concat "+" l) 'face 'sprig-review-added) "\n"))))

(defun sprig-review--insert-change (change)
  "Insert CHANGE as a foldable file section holding its hunks."
  (magit-insert-section (sprig-change change)
    (magit-insert-heading
      (propertize (plist-get change :file) 'face 'sprig-review-file))
    (dolist (hunk (plist-get change :hunks))
      (sprig-review--insert-hunk hunk))))

(defun sprig-review--insert-result (result)
  "Insert RESULT as a section, folded by default since results can be large."
  (magit-insert-section (sprig-result result t)
    (magit-insert-heading
      (format "↳ result%s" (if (plist-get result :error) " (error)" "")))
    (let ((text (string-trim-right (or (plist-get result :text) ""))))
      (unless (string-empty-p text)
        (insert text "\n")))))

(defun sprig-review--insert-tool (block)
  "Insert tool BLOCK: heading, its file-change diffs, then its result."
  (magit-insert-section (sprig-tool block)
    (magit-insert-heading (sprig-review--tool-heading block))
    (dolist (change (plist-get block :changes))
      (sprig-review--insert-change change))
    (when-let ((result (plist-get block :result)))
      (sprig-review--insert-result result))))

(defun sprig-review--insert-text (block)
  "Insert an assistant text BLOCK under a foldable role label."
  (magit-insert-section (sprig-text block)
    (magit-insert-heading (propertize "assistant" 'face 'sprig-review-role))
    (insert (string-trim-right (plist-get block :text)) "\n")))

(defun sprig-review--insert-user (block)
  "Insert a user-turn BLOCK under a foldable role label."
  (magit-insert-section (sprig-user block)
    (magit-insert-heading (propertize "user" 'face 'sprig-review-user))
    (insert (string-trim-right (plist-get block :text)) "\n")))

(defun sprig-review--insert-thinking (block)
  "Insert a thinking BLOCK, folded by default since it is verbose."
  (magit-insert-section (sprig-thinking block t)
    (magit-insert-heading (propertize "thinking" 'face 'sprig-review-thinking))
    (insert (string-trim-right (plist-get block :text)) "\n")))

(defun sprig-review--insert-error (block)
  "Insert an error BLOCK."
  (magit-insert-section (sprig-error block)
    (magit-insert-heading (propertize "error" 'face 'error))
    (insert (string-trim-right (or (plist-get block :text) "")) "\n")))

(defun sprig-review--meta-line (key value)
  "Return a header line pairing KEY with VALUE, or nil when VALUE is blank."
  (when (and value (not (string-empty-p (format "%s" value))))
    (concat (propertize (format "%-9s" (concat key ":")) 'face 'sprig-review-meta-key)
            (format "%s" value) "\n")))

(defun sprig-review--insert-headers (model meta)
  "Insert the metadata header from MODEL and the META plist.
META may carry :title, :project, :model, and :status."
  (magit-insert-section (sprig-headers)
    (dolist (line (list
                   (sprig-review--meta-line
                    "Title" (or (plist-get meta :title) (plist-get model :title)))
                   (sprig-review--meta-line "Project" (plist-get meta :project))
                   (sprig-review--meta-line "Model"   (plist-get meta :model))
                   (sprig-review--meta-line "Status"  (plist-get meta :status))
                   (sprig-review--meta-line "Session" (plist-get model :session))
                   (sprig-review--meta-line
                    "Cost" (when (plist-get model :cost)
                             (format "$%.4f" (plist-get model :cost))))))
      (when line (insert line)))
    (insert "\n")))

;;;; Rendering entry points

(defun sprig-review-render (model &optional meta)
  "Render review MODEL into the current buffer as magit-sections.
META is an optional plist of display metadata (see
`sprig-review--insert-headers').  The buffer should already be in
`sprig-review-mode'."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (sprig-review)
      (sprig-review--insert-headers model meta)
      (dolist (block (plist-get model :blocks))
        (pcase (plist-get block :type)
          ('user     (sprig-review--insert-user block))
          ('text     (sprig-review--insert-text block))
          ('thinking (sprig-review--insert-thinking block))
          ('tool     (sprig-review--insert-tool block))
          ('error    (sprig-review--insert-error block)))))
    (goto-char (point-min))))

;;;; Live sink: accumulate events, refresh the buffer
;;
;; The transport (sprig.el) emits the same backend-neutral events the
;; Markdown sink consumes; a review buffer folds them into its model and
;; re-renders.  `sprig-review-consume' is the counterpart of the Markdown
;; sink's `sprig--dispatch': the transport calls it once per event.
;;
;; Refresh rebuilds from the whole event list rather than mutating the
;; buffer in place.  That reuses the tested renderer verbatim and keeps
;; the buffer a pure projection of the model.  magit-section makes the
;; re-render cheap where it matters: user folds survive it (the
;; visibility cache is keyed by a section's stable ident), and point is
;; carried to the same section when it still exists.
;;
;; A full re-render is O(conversation), and a live turn emits many events
;; per second, so `sprig-review-consume' does not render on each event.
;; It marks the buffer dirty and arms a short timer; the timer coalesces a
;; burst of events into a single render (`sprig-review-flush'), capping the
;; re-render rate during streaming.  `seed'/`reset' render synchronously,
;; since they are one-shot.

(defcustom sprig-review-refresh-delay 0.1
  "Seconds to coalesce streamed events before re-rendering the review buffer.
A live turn emits many events per second; batching them into one render at
this cadence keeps a long conversation from re-rendering per token.  Lower
is more responsive but re-renders more often."
  :type 'number
  :group 'sprig)

(defvar-local sprig-review--events nil
  "Transport events consumed by this review buffer, most recent first.")
(defvar-local sprig-review--meta nil
  "Display-metadata plist feeding this review buffer's header.")
(defvar-local sprig-review--dirty nil
  "Non-nil when events have arrived since the last render.")
(defvar-local sprig-review--timer nil
  "Pending coalescing-refresh timer for this buffer, or nil.")

(defun sprig-review--refresh ()
  "Rebuild the model from accumulated events and re-render in place.
Keep folds (via magit-section's visibility cache) and restore point to
the same section, or to its previous position when that section is gone."
  ;; Do not bind `magit-insert-section--oldroot' here: the
  ;; `magit-insert-section' macro captures it from `magit-root-section'
  ;; itself, and only then advances `magit-root-section' to the new root.
  ;; Pre-binding it leaves the root stale and breaks section finishing.
  (let* ((model (sprig-review-build (reverse sprig-review--events)))
         (section (magit-current-section))
         (ident (and section (magit-section-ident section)))
         (offset (and section (- (point) (oref section start))))
         (pos (point)))
    (sprig-review-render model sprig-review--meta)
    (let ((found (and ident (magit-get-section ident))))
      (goto-char
       (if found
           (min (+ (oref found start) (max 0 (or offset 0)))
                (or (oref found end) (point-max)))
         (min pos (point-max)))))))

(defun sprig-review--cancel-timer ()
  "Cancel this buffer's pending coalescing-refresh timer, if any."
  (when sprig-review--timer
    (cancel-timer sprig-review--timer)
    (setq sprig-review--timer nil)))

(defun sprig-review-flush (&optional buffer)
  "Render events pending in BUFFER since the last refresh, now.
Called by the coalescing timer, and usable to force a render immediately."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (sprig-review--cancel-timer)
        (when sprig-review--dirty
          (setq sprig-review--dirty nil)
          (sprig-review--refresh))))))

(defun sprig-review-consume (event)
  "Fold transport EVENT into the current review buffer, coalescing renders.
The buffer is marked dirty and a short timer armed; a burst of events thus
renders once (see `sprig-review-refresh-delay'), not once per event."
  (push event sprig-review--events)
  (setq sprig-review--dirty t)
  (unless sprig-review--timer
    (setq sprig-review--timer
          (run-with-timer sprig-review-refresh-delay nil
                          #'sprig-review-flush (current-buffer)))))

(defun sprig-review-reset (&optional meta)
  "Drop this review buffer's accumulated events and render empty.
With META, replace the header metadata plist."
  (sprig-review--cancel-timer)
  (setq sprig-review--events nil sprig-review--dirty nil)
  (when meta (setq sprig-review--meta meta))
  (sprig-review--refresh))

(defun sprig-review-seed (events &optional meta)
  "Seed this review buffer with EVENTS (in order) and refresh synchronously.
Use this to replay history before the live sink appends more, so a later
`sprig-review-consume' rebuilds from history plus the new event."
  (sprig-review--cancel-timer)
  (setq sprig-review--events (reverse events) sprig-review--dirty nil)
  (when meta (setq sprig-review--meta meta))
  (sprig-review--refresh))

(defun sprig-review-buffer (name)
  "Return a buffer named NAME, put into `sprig-review-mode'."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'sprig-review-mode) (sprig-review-mode)))
    buffer))

;;;; Major mode

(defvar sprig-review-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    map)
  "Keymap for `sprig-review-mode'.
Inherits magit-section's navigation and folding; the sprig verbs are
added on top as they land.")

(define-derived-mode sprig-review-mode magit-section-mode "Sprig-Review"
  "Major mode for reviewing an agent conversation as read-only sections.
Built on `magit-section-mode': move with \\`n' / \\`p', fold with TAB."
  :group 'sprig
  (setq-local revert-buffer-function #'ignore))

(defun sprig-review-show (model &optional meta name)
  "Show review MODEL in a review buffer named NAME and select it.
META is passed to `sprig-review-render'."
  (let ((buffer (get-buffer-create (or name "*sprig-review*"))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'sprig-review-mode)
        (sprig-review-mode))
      (sprig-review-render model meta))
    (pop-to-buffer buffer)))

(defun sprig-review-read-session-lines (file)
  "Return the non-empty JSONL lines of session-log FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (split-string (buffer-string) "\n" t)))

;;;###autoload
(defun sprig-review-open-file (file)
  "Open a read-only review of a stored `claude' session-log FILE.
Replays the whole transcript from the log; see `sprig-review-session-events'.
This is the local-read path.  A remote session's log lives on the SSH host
and is fetched by the integration layer, not here."
  (interactive "fSession log (.jsonl): ")
  (let ((buffer (sprig-review-buffer
                 (format "*sprig-review: %s*" (file-name-base file)))))
    (with-current-buffer buffer
      (sprig-review-seed (sprig-review-session-events
                          (sprig-review-read-session-lines file))))
    (pop-to-buffer buffer)))

(provide 'sprig-review-mode)
;;; sprig-review-mode.el ends here
