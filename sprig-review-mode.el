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
                   (sprig-review--meta-line "Title"   (plist-get meta :title))
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
          ('text  (sprig-review--insert-text block))
          ('tool  (sprig-review--insert-tool block))
          ('error (sprig-review--insert-error block)))))
    (goto-char (point-min))))

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

(provide 'sprig-review-mode)
;;; sprig-review-mode.el ends here
