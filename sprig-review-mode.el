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
(require 'transient)
(require 'seq)

(declare-function sprig--send-text "sprig" (text))
(declare-function sprig-interrupt "sprig" ())

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

(defface sprig-review-marked '((t :inherit highlight))
  "Face for the heading of a marked section."
  :group 'sprig)

;;;; Buffer-local state

(defvar-local sprig-review--events nil
  "Transport events consumed by this review buffer, most recent first.")
(defvar-local sprig-review--meta nil
  "Display-metadata plist feeding this review buffer's header.")
(defvar-local sprig-review--dirty nil
  "Non-nil when events have arrived since the last render.")
(defvar-local sprig-review--timer nil
  "Pending coalescing-refresh timer for this buffer, or nil.")
(defvar-local sprig-review--tail nil
  "Marker where streamed text is appended in place, or nil.
`sprig-review-render' sets it to the end of the last text section when the
conversation ends in assistant text, so consecutive `text' events extend
that section without a full re-render.  Any structural event clears it.")
(defvar-local sprig-review--marks nil
  "Idents (per `magit-section-ident') of the marked sections.
Idents rather than section objects, so marks survive a re-render.")
(defvar-local sprig-review--conversation nil
  "The sprig conversation buffer this review steers, or nil.
Set by `sprig-review-attach'; the verbs send instructions through it.")

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

(defun sprig-review--text-body (text)
  "Return TEXT with trailing newlines normalised to exactly one.
Trailing spaces are kept (a streamed delta may legitimately end in one),
so this matches what the in-place append path produces."
  (concat (string-trim-right text "[\n]+") "\n"))

(defun sprig-review--insert-text (block &optional open)
  "Insert an assistant text BLOCK under a foldable role label.
When OPEN, this is the live streaming block: render its text raw (plus a
trailing newline) and record the tail (`sprig-review--tail') just before
that newline, so `sprig-review--append-streamed' and a later full refresh
produce identical text.  A settled block is normalised for tidy display."
  (magit-insert-section (sprig-text block)
    (magit-insert-heading (propertize "assistant" 'face 'sprig-review-role))
    (if open
        (progn
          (insert (plist-get block :text) "\n")
          (setq sprig-review--tail (copy-marker (1- (point)) t)))
      (insert (sprig-review--text-body (plist-get block :text))))))

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
  (let* ((inhibit-read-only t)
         (blocks (plist-get model :blocks))
         (last (car (last blocks))))
    (setq sprig-review--tail nil)
    (erase-buffer)
    (magit-insert-section (sprig-review)
      (sprig-review--insert-headers model meta)
      (dolist (block blocks)
        (pcase (plist-get block :type)
          ('user     (sprig-review--insert-user block))
          ;; Only the last block, when it is text, is the live tail.
          ('text     (sprig-review--insert-text block (eq block last)))
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
;; A full re-render is O(conversation), too costly to run per streamed
;; token in a long session, so `sprig-review-consume' avoids it two ways:
;;
;; - Streamed `text' deltas, the high-frequency case, extend the last text
;;   section in place at `sprig-review--tail', with no re-render at all.
;; - Structural events (a new tool call, a result, the user turn, done)
;;   mark the buffer dirty and arm a short timer that coalesces a burst
;;   into one render (`sprig-review-flush').  That render re-establishes
;;   the tail, so the following text deltas take the fast path again.
;;
;; So the re-render count is bounded by the number of structural events in
;; a turn, not the number of tokens.  `seed'/`reset' render synchronously,
;; being one-shot.

(defcustom sprig-review-refresh-delay 0.1
  "Seconds to coalesce structural events before re-rendering the review buffer.
Batching them into one render at this cadence keeps a long conversation
from re-rendering repeatedly.  Lower is more responsive but renders more
often.  Streamed text does not wait on this; it appends in place."
  :type 'number
  :group 'sprig)

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
         (min pos (point-max)))))
    (sprig-review--apply-marks)))

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

(defun sprig-review--append-streamed (s)
  "Append streamed text S at the live text tail, without a re-render."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char sprig-review--tail)
      (insert s))))          ; the type-t tail marker advances past S

(defun sprig-review--schedule ()
  "Mark the buffer dirty and arm the coalescing refresh timer."
  (setq sprig-review--dirty t)
  (unless sprig-review--timer
    (setq sprig-review--timer
          (run-with-timer sprig-review-refresh-delay nil
                          #'sprig-review-flush (current-buffer)))))

(defun sprig-review-consume (event)
  "Fold transport EVENT into the current review buffer.
A streamed `text' delta extends the live text section in place, with no
re-render, whenever a tail is established.  Every other event, and the
first `text' of a run, clears the tail and schedules a coalesced render
\(see `sprig-review-refresh-delay'), which re-establishes the tail."
  (push event sprig-review--events)
  (if (and (eq (car event) 'text)
           sprig-review--tail (marker-position sprig-review--tail))
      (sprig-review--append-streamed (cadr event))
    (unless (eq (car event) 'text)
      (setq sprig-review--tail nil))
    (sprig-review--schedule)))

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

;;;; Marks
;;
;; Marking is the review buffer's one selection primitive (see DESIGN.md):
;; a verb acts on the marked sections, or on the section at point when
;; nothing is marked.  Marks are stored as section idents so they survive
;; a re-render, and re-applied by `sprig-review--refresh'.

(defun sprig-review--apply-marks ()
  "Highlight the marked sections; drop marks whose section no longer exists."
  (remove-overlays (point-min) (point-max) 'sprig-review-mark t)
  (setq sprig-review--marks (seq-filter #'magit-get-section sprig-review--marks))
  (dolist (ident sprig-review--marks)
    (let* ((sec (magit-get-section ident))
           (beg (oref sec start))
           (end (save-excursion (goto-char beg)
                                (min (1+ (line-end-position)) (point-max))))
           (ov (make-overlay beg end)))
      (overlay-put ov 'sprig-review-mark t)
      (overlay-put ov 'face 'sprig-review-marked)
      (overlay-put ov 'before-string (propertize "▸" 'face 'sprig-review-marked)))))

(defun sprig-review-toggle-mark ()
  "Toggle the mark on the section at point, then move to the next section."
  (interactive)
  (when-let ((sec (magit-current-section)))
    (let ((ident (magit-section-ident sec)))
      (setq sprig-review--marks
            (if (member ident sprig-review--marks)
                (delete ident sprig-review--marks)
              (cons ident sprig-review--marks))))
    (sprig-review--apply-marks)
    (ignore-errors (magit-section-forward))))

(defun sprig-review-unmark-all ()
  "Clear all marks."
  (interactive)
  (setq sprig-review--marks nil)
  (sprig-review--apply-marks))

(defun sprig-review--marked-sections ()
  "Return the marked sections, or the section at point if none are marked."
  (or (let (secs)
        (dolist (ident (reverse sprig-review--marks))
          (when-let ((s (magit-get-section ident))) (push s secs)))
        (nreverse secs))
      (when-let ((s (magit-current-section))) (list s))))

(defun sprig-review--sections-of-type (sections type)
  "Return the members of SECTIONS whose section type is TYPE."
  (seq-filter (lambda (s) (eq (oref s type) type)) sections))

(defun sprig-review--unmark-sections (sections)
  "Drop the marks on SECTIONS and refresh the highlighting."
  (dolist (s sections)
    (setq sprig-review--marks
          (delete (magit-section-ident s) sprig-review--marks)))
  (sprig-review--apply-marks))

;;;; Instruction builders
;;
;; Every change-touching verb is sugar over a message to the agent (see
;; DESIGN.md, "Verbs are canned instructions").  These builders are pure:
;; they turn the object(s) under point or marked into the instruction text.

(defcustom sprig-review-commit-instruction
  "Please commit the current changes with a suitable commit message."
  "Instruction the commit verb sends to the agent."
  :type 'string
  :group 'sprig)

(defun sprig-review-reject-instruction (changes)
  "Return an instruction asking the agent to undo CHANGES.
CHANGES is a list of (FILE . HUNK-PLIST)."
  (concat
   (if (cdr changes) "Please undo these changes:\n\n"
     "Please undo this change:\n\n")
   (mapconcat
    (lambda (fc)
      (format "In `%s`:\n```diff\n%s\n```"
              (car fc) (sprig-review--format-hunk (cdr fc))))
    changes "\n\n")))

(defun sprig-review-run-instruction (command)
  "Return an instruction asking the agent to run COMMAND."
  (format "Please run:\n```\n%s\n```" command))

;;;; Steering: send through the attached conversation

(defun sprig-review-attach (conversation)
  "Attach this review buffer to its CONVERSATION buffer, so verbs can steer it."
  (setq sprig-review--conversation conversation))

(defun sprig-review--send (text)
  "Send TEXT as a user instruction through the attached conversation."
  (unless (buffer-live-p sprig-review--conversation)
    (user-error "This review is not attached to a live conversation"))
  (with-current-buffer sprig-review--conversation
    (sprig--send-text text))
  (message "sprig: sent"))

;;;; Verbs

(defun sprig-review--reject-pairs (sections)
  "Return (FILE . HUNK) pairs for the hunk SECTIONS."
  (delq nil
        (mapcar (lambda (s)
                  (when (eq (oref s type) 'sprig-hunk)
                    (cons (plist-get (oref (oref s parent) value) :file)
                          (oref s value))))
                sections)))

(defun sprig-review-reject ()
  "Ask the agent to undo the marked diff hunks, or the hunk at point.
On a mixed mark set, confirms and acts only on the hunks (see DESIGN.md)."
  (interactive)
  (let* ((sections (sprig-review--marked-sections))
         (pairs (sprig-review--reject-pairs sections)))
    (unless pairs (user-error "No diff hunk marked or at point"))
    (when (and sprig-review--marks (< (length pairs) (length sections))
               (not (y-or-n-p
                     (format "Reject %d hunk(s), ignoring %d other mark(s)? "
                             (length pairs) (- (length sections) (length pairs))))))
      (user-error "Cancelled"))
    (sprig-review--send (sprig-review-reject-instruction pairs))
    (sprig-review--unmark-sections
     (sprig-review--sections-of-type sections 'sprig-hunk))))

(defun sprig-review-commit ()
  "Ask the agent to commit the current changes."
  (interactive)
  (sprig-review--send sprig-review-commit-instruction))

(defun sprig-review-run ()
  "Ask the agent to run the command of the tool call marked or at point."
  (interactive)
  (let* ((sections (sprig-review--marked-sections))
         (tool (seq-find (lambda (s) (eq (oref s type) 'sprig-tool)) sections)))
    (unless tool (user-error "No tool call marked or at point"))
    (let ((cmd (alist-get 'command
                          (sprig-review--parse-input
                           (plist-get (oref tool value) :input)))))
      (unless cmd (user-error "That tool call has no command to run"))
      (sprig-review--send (sprig-review-run-instruction cmd)))))

(defun sprig-review-accept ()
  "Accept the changes under review: clear the marks, send nothing, commit nothing."
  (interactive)
  (sprig-review-unmark-all)
  (message "sprig: accepted (marks cleared; commit is a separate verb)"))

(defun sprig-review-retry ()
  "Re-send the most recent user turn."
  (interactive)
  (let* ((model (sprig-review-build (reverse sprig-review--events)))
         (last-user (seq-find (lambda (b) (eq (plist-get b :type) 'user))
                              (reverse (plist-get model :blocks)))))
    (unless last-user (user-error "No previous user turn to resend"))
    (sprig-review--send (plist-get last-user :text))))

(defun sprig-review-interrupt ()
  "Interrupt the in-flight turn in the attached conversation."
  (interactive)
  (unless (buffer-live-p sprig-review--conversation)
    (user-error "This review is not attached to a live conversation"))
  (with-current-buffer sprig-review--conversation (sprig-interrupt)))

;;;; Compose buffer (the c c message)

(defvar-local sprig-review--compose-target nil
  "Review buffer a compose buffer sends to.")
(defvar-local sprig-review--compose-context nil
  "Marked-section context prepended to the composed message, or nil.")

(defvar sprig-review-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'sprig-review-compose-send)
    (define-key map (kbd "C-c C-k") #'sprig-review-compose-abort)
    map)
  "Keymap for `sprig-review-compose-mode'.")

(define-derived-mode sprig-review-compose-mode text-mode "Sprig-Msg"
  "Compose a message to send to a sprig conversation.
\\<sprig-review-compose-mode-map>\\[sprig-review-compose-send] sends, \
\\[sprig-review-compose-abort] cancels.")

(defun sprig-review--marked-context ()
  "Return the text of the marked sections as a context string, or nil.
Uses only real marks, not the section-at-point fallback."
  (when sprig-review--marks
    (let ((secs (sprig-review--marked-sections)))
      (mapconcat (lambda (s)
                   (string-trim (buffer-substring-no-properties
                                 (oref s start) (oref s end))))
                 secs "\n\n"))))

(defun sprig-review-message ()
  "Compose a message and send it to the attached conversation.
Any marked sections are attached as context (see DESIGN.md's `c c')."
  (interactive)
  (unless (buffer-live-p sprig-review--conversation)
    (user-error "This review is not attached to a live conversation"))
  (let ((review (current-buffer))
        (context (sprig-review--marked-context))
        (buf (get-buffer-create "*sprig-message*")))
    (with-current-buffer buf
      (sprig-review-compose-mode)
      (erase-buffer)
      (setq sprig-review--compose-target review
            sprig-review--compose-context context))
    (pop-to-buffer buf)
    (message "%sC-c C-c to send, C-c C-k to cancel"
             (if context (format "%d section(s) attached.  "
                                 (length (sprig-review--marked-sections)))
               ""))))

(defun sprig-review-compose-send ()
  "Send the composed message (with any attached context) to the conversation."
  (interactive)
  (let ((text (string-trim (buffer-substring-no-properties
                            (point-min) (point-max))))
        (review sprig-review--compose-target)
        (context sprig-review--compose-context))
    (when (string-empty-p text) (user-error "Empty message"))
    (unless (buffer-live-p review) (user-error "The review buffer is gone"))
    (quit-window t)
    (with-current-buffer review
      (sprig-review--send
       (if context (format "Regarding:\n\n%s\n\n%s" context text) text)))))

(defun sprig-review-compose-abort ()
  "Cancel the message compose."
  (interactive)
  (quit-window t)
  (message "sprig: message cancelled"))

;;;; The c transient

(transient-define-prefix sprig-review-dispatch ()
  "Steer the conversation from the review buffer."
  [["Message"
    ("c" "compose & send" sprig-review-message)
    ("r" "resend last turn" sprig-review-retry)
    ("i" "interrupt turn" sprig-review-interrupt)]
   ["Changes (agent instructions)"
    ("k" "reject / undo" sprig-review-reject)
    ("a" "accept (clear marks)" sprig-review-accept)
    ("C" "commit" sprig-review-commit)
    ("x" "run command" sprig-review-run)]])

;;;; Verb keybindings

(define-key sprig-review-mode-map (kbd "SPC") #'sprig-review-toggle-mark)
(define-key sprig-review-mode-map (kbd "m")   #'sprig-review-toggle-mark)
(define-key sprig-review-mode-map (kbd "U")   #'sprig-review-unmark-all)
(define-key sprig-review-mode-map (kbd "c")   #'sprig-review-dispatch)
(define-key sprig-review-mode-map (kbd "k")   #'sprig-review-reject)
(define-key sprig-review-mode-map (kbd "a")   #'sprig-review-accept)
(define-key sprig-review-mode-map (kbd "x")   #'sprig-review-run)

(provide 'sprig-review-mode)
;;; sprig-review-mode.el ends here
