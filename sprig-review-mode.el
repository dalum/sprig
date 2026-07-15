;;; sprig-review-mode.el --- Read-only review buffer for sprig -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.6.1
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
(require 'iso8601)                       ; for the log's own timestamps
(require 'sprig-review)
(require 'subr-x)
(require 'eieio)
(require 'transient)
(require 'seq)

(declare-function sprig--review-deliver "sprig" (text &optional mode))
(declare-function sprig--review-interrupt-owned "sprig" ())
(declare-function sprig--mode-line-permission "sprig" ())
;; Transport state, defined in sprig.el; a session-owning review buffer
;; carries these buffer-locally, so silence the byte-compiler here.
(defvar sprig--process)
(defvar sprig--sink)

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

(defface sprig-review-user
  '((((class color) (background light)) :background "#eaeef8" :extend t)
    (((class color) (background dark))  :background "#2b3040" :extend t)
    (t :inherit region :extend t))
  "Face for a user turn's prose: the tint that marks it as yours.
This is the only thing telling a user turn from the agent's output, so it
carries no label; tinted is you, untinted is the agent.  Applied beneath
any markdown faces, so the prose keeps its own styling on top.  `:extend'
runs the tint to the window edge."
  :group 'sprig)

(defface sprig-review-user-highlight
  '((((class color) (background light)) :background "#ccd8f0" :extend t)
    (((class color) (background dark))  :background "#3c465e" :extend t)
    (t :inherit magit-section-highlight :extend t))
  "Face for the user turn under point.
A stronger take on `sprig-review-user', rather than the shared
`magit-section-highlight' every other section gets, so the turn under
point still reads as yours instead of losing its tint to the cursor."
  :group 'sprig)

(defface sprig-review-thinking '((t :inherit shadow :slant italic))
  "Face for a thinking-block label."
  :group 'sprig)

(defface sprig-review-meta-key '((t :inherit font-lock-comment-face))
  "Face for a metadata key in the header."
  :group 'sprig)

(defface sprig-review-time '((t :inherit font-lock-comment-face))
  "Face for a block's timestamp in the left margin."
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
`sprig-review-render' sets it to the end of the last text section when a
turn is streaming into this buffer, so consecutive `text' events extend
that section without a full re-render.  Any structural event clears it.")

(defvar-local sprig-review--streaming nil
  "Non-nil while a turn is streaming into this buffer.
Only then does `sprig-review-render' open the last text block as the live
tail, which costs that block its markdown fontification (see
`sprig-review--insert-text').  A settled or replayed conversation is not
streaming, so every one of its blocks renders fontified.  Liveness cannot
be read off the model instead: a replayed session log carries no `done'
event, so its last block would otherwise pass for a live tail forever.")
(defvar-local sprig-review--marks nil
  "Idents (per `magit-section-ident') of the marked sections.
Idents rather than section objects, so marks survive a re-render.")
(defvar-local sprig-review--remote nil
  "SSH destination of the session host, or nil for local.
Set by `sprig-review-set-remote' so visiting a file reaches it over TRAMP.")

;;;; Options

(defcustom sprig-review-heading-max-width 80
  "Maximum width of a tool-call heading before it is truncated with an ellipsis.
Keeps a long `Bash' command or file path on a single line; the full text
is one TAB away, since the tool section folds to its heading."
  :type 'integer
  :group 'sprig)

(defcustom sprig-review-expand-diffs nil
  "When non-nil, a tool call that reconstructs a diff renders expanded.
By default every tool section folds to its one-line heading, so a long
turn reads as a list of what the agent did rather than as pages of diff;
TAB opens the one you want to review."
  :type 'boolean
  :group 'sprig)

(defcustom sprig-review-timestamp-format "%H:%M"
  "Time format for the left-margin timestamp against each block.
A `format-time-string' format, rendered in local time.  nil shows no
timestamps and takes the margin back.  Widen it (say \"%m-%d %H:%M\") to
date a conversation spanning days; the margin sizes itself to fit.

Replayed history is dated from the session log's own record timestamps;
a live turn is dated when its first event reaches the buffer."
  :type '(choice (const :tag "No timestamps" nil) string)
  :group 'sprig)

(defcustom sprig-review-fontify-markdown t
  "When non-nil, render user and assistant prose with `markdown-mode' faces.
Markup characters (`*', `#', ...) are hidden.  Has no effect when
`markdown-mode' is not installed."
  :type 'boolean
  :group 'sprig)

;;;; Face helpers
;;
;; Everything rendered here carries its colours as `font-lock-face', not
;; `face'.  `magit-section-mode' deliberately turns font-lock on (with no
;; keywords) so that `font-lock-face' is honoured, and font-lock's
;; unfontify pass strips the plain `face' property off every region it
;; redisplays (see `font-lock-default-unfontify-region').  Text propertized
;; with `face' therefore loses its colours the moment the window scrolls
;; over it; `font-lock-face' survives and displays identically.

(defun sprig-review--face (string face)
  "Return STRING carrying FACE, as a property the buffer's font-lock keeps."
  (propertize string 'font-lock-face face))

(defun sprig-review--add-face (beg end face)
  "Add FACE beneath the faces already on the buffer text between BEG and END.
Appending rather than replacing leaves a foreground set by, say, markdown
fontification in front of FACE's background."
  (let ((pos beg))
    (while (< pos end)
      (let ((next (next-single-property-change pos 'font-lock-face nil end))
            (val (get-text-property pos 'font-lock-face)))
        (put-text-property pos next 'font-lock-face
                           (append (ensure-list val) (list face)))
        (setq pos next)))))

(defun sprig-review--adopt-faces (string)
  "Return STRING with each `face' property moved over to `font-lock-face'.
Font-lock fontifies with `face', so a string fontified elsewhere (see
`sprig-review--fontify-markdown') needs this before it is inserted here."
  (let ((pos 0) (end (length string)))
    (while (< pos end)
      (let ((next (next-single-property-change pos 'face string end))
            (val (get-text-property pos 'face string)))
        (when val
          (put-text-property pos next 'font-lock-face val string)
          (remove-list-of-text-properties pos next '(face) string))
        (setq pos next)))
    string))

;;;; Timestamp margin
;;
;; A block's time shows in the left margin, the way magit-log shows a
;; commit's date: it dates every row without spending a column of the
;; prose itself, and it cannot be confused for something the agent said.
;; The stamp rides on an overlay's `before-string', so it stays out of the
;; buffer text, and out of the way of the verbs that read that text.

(defun sprig-review--time-string (iso)
  "Return ISO, an ISO 8601 stamp, formatted per `sprig-review-timestamp-format'.
Returns nil when timestamps are off, or when ISO is missing or unparsable
\(a hand-edited log, or a record shape we have not seen), since a block
with no time is worth more than a render that dies over one."
  (when (and sprig-review-timestamp-format (stringp iso))
    (ignore-errors
      (format-time-string sprig-review-timestamp-format
                          (encode-time (iso8601-parse iso))))))

(defun sprig-review--margin-width ()
  "Return the columns the timestamp margin needs, or 0 when it is off."
  (if sprig-review-timestamp-format
      ;; Formatted now, purely to measure the format; every stamp it makes
      ;; is the same width, bar a format holding a variable-width field.
      (1+ (string-width (format-time-string sprig-review-timestamp-format)))
    0))

(defun sprig-review--update-margin ()
  "Size the left margin of every window showing this buffer to fit a stamp.
`left-margin-width' alone only reaches a window on the next
`set-window-buffer', so the live windows are set too, and a change to
`sprig-review-timestamp-format' shows on the next render."
  (setq left-margin-width (sprig-review--margin-width))
  (dolist (win (get-buffer-window-list nil nil t))
    (set-window-margins win left-margin-width right-margin-width)))

(defun sprig-review--insert-margin-time (pos iso)
  "Show ISO's time in the left margin, against the line holding POS."
  (when-let ((stamp (sprig-review--time-string iso)))
    (let ((ov (make-overlay pos (min (1+ pos) (point-max)))))
      (overlay-put ov 'sprig-review-margin t)
      (overlay-put ov 'before-string
                   (propertize " " 'display
                               ;; `face', not `font-lock-face': an overlay
                               ;; string is not buffer text, so font-lock
                               ;; never sees it to strip it.
                               `((margin left-margin)
                                 ,(propertize stamp 'face 'sprig-review-time)))))))

;;;; Heading helpers

(defun sprig-review--stat-string (change)
  "Return a \"(+A -B)\" line-count summary for CHANGE."
  (let ((s (sprig-review-change-stat change)))
    (format "(+%d -%d)" (car s) (cdr s))))

(defun sprig-review--truncate (s width)
  "Return S truncated to WIDTH columns, ending in an ellipsis when shortened."
  (if (> (string-width s) width)
      (truncate-string-to-width s width nil nil "…")
    s))

(defun sprig-review--input-summary (name input)
  "Return a one-line summary of tool NAME's INPUT, or nil.
Shows the command for `Bash'; other non-diff tools fall back to a salient
input field (path, pattern, query, ...).  File tools that render a diff
header instead pass their changes in, so this is only reached without one."
  (let* ((obj (sprig-review--parse-input input))
         (val (if (equal name "Bash")
                  (alist-get 'command obj)
                (seq-some (lambda (k) (alist-get k obj))
                          '(file_path path pattern query url description prompt)))))
    (when (stringp val)
      (car (split-string val "\n")))))

(defun sprig-review--tool-heading (block)
  "Return the single-line heading string for tool BLOCK."
  (let* ((name (or (plist-get block :name) "tool"))
         (changes (plist-get block :changes))
         (summary (sprig-review--input-summary name (plist-get block :input)))
         (err (plist-get (plist-get block :result) :error)))
    (concat
     (sprig-review--face name 'sprig-review-tool)
     (cond
      (changes
       (let ((c (car changes)))
         (concat "  " (plist-get c :file) "  " (sprig-review--stat-string c))))
      (summary (concat "  " (sprig-review--truncate
                             summary sprig-review-heading-max-width)))
      (t ""))
     (if err (sprig-review--face "  [error]" 'error) ""))))

;;;; Section insertion

(defun sprig-review--insert-hunk (hunk)
  "Insert HUNK as removed lines then added lines, each a coloured section line."
  (magit-insert-section (sprig-hunk hunk)
    (dolist (l (plist-get hunk :old))
      (insert (sprig-review--face (concat "-" l) 'sprig-review-removed) "\n"))
    (dolist (l (plist-get hunk :new))
      (insert (sprig-review--face (concat "+" l) 'sprig-review-added) "\n"))))

(defun sprig-review--insert-change (change)
  "Insert CHANGE as a foldable file section holding its hunks."
  (magit-insert-section (sprig-change change)
    (magit-insert-heading
      (sprig-review--face (plist-get change :file) 'sprig-review-file))
    (dolist (hunk (plist-get change :hunks))
      (sprig-review--insert-hunk hunk))))

(defun sprig-review--insert-result (result)
  "Insert RESULT as a section, folded by default since results can be large."
  (magit-insert-section (sprig-result result t)
    (magit-insert-heading
      (format "↳ result%s" (if (plist-get result :error) " (error)" "")))
    ;; Deferred so a folded result keeps its body out of the buffer; magit
    ;; only draws the fold when the body goes through `magit-insert-section-body'.
    (magit-insert-section-body
      (let ((text (string-trim-right (or (plist-get result :text) ""))))
        (unless (string-empty-p text)
          (insert text "\n"))))))

(defun sprig-review--insert-tool (block)
  "Insert tool BLOCK: heading, its file-change diffs, then its result.
Every tool folds to its one-line heading, so a turn reads as a list of
what the agent did; TAB opens the change you want.  Set
`sprig-review-expand-diffs' to render diff-bearing tools open instead."
  (magit-insert-section (sprig-tool block
                                    (not (and sprig-review-expand-diffs
                                              (plist-get block :changes))))
    (magit-insert-heading (sprig-review--tool-heading block))
    ;; Deferred so a folded tool keeps its body out of the buffer; magit only
    ;; draws the fold when the body goes through `magit-insert-section-body'.
    (magit-insert-section-body
      (dolist (change (plist-get block :changes))
        (sprig-review--insert-change change))
      (when-let ((result (plist-get block :result)))
        (sprig-review--insert-result result)))))

(defvar markdown-hide-markup)
(declare-function markdown-mode "markdown-mode" ())
(declare-function markdown-toggle-markup-hiding "markdown-mode" (&optional arg))

(defun sprig-review--fontify-markdown (text)
  "Return TEXT fontified with `markdown-mode', its markup characters hidden.
Fontifies in a reusable hidden buffer and copies the propertized string,
so the `*'/`#' markup carries an `invisible' property the review buffer's
invisibility spec then hides (see `sprig-review-mode').  The copy's faces
are adopted onto `font-lock-face', without which this buffer's font-lock
would strip them (see `sprig-review--adopt-faces').  Returns TEXT
unchanged when `sprig-review-fontify-markdown' is nil or markdown-mode is
not installed."
  (if (and sprig-review-fontify-markdown
           (require 'markdown-mode nil t))
      (with-current-buffer (get-buffer-create " *sprig-review-markdown*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (delay-mode-hooks (markdown-mode))
          (setq-local markdown-hide-markup t)
          ;; The toggle wires markup hiding fully (invisibility spec plus the
          ;; refontify hooks) where merely setting the flag may not.
          (when (fboundp 'markdown-toggle-markup-hiding)
            (ignore-errors (markdown-toggle-markup-hiding 1)))
          (insert text)
          (font-lock-ensure)
          (sprig-review--adopt-faces (buffer-string))))
    text))

(defun sprig-review--text-body (text)
  "Return TEXT with trailing newlines normalised to exactly one.
Trailing spaces are kept (a streamed delta may legitimately end in one),
so this matches what the in-place append path produces."
  (concat (string-trim-right text "[\n]+") "\n"))

(defun sprig-review--insert-text (block &optional open)
  "Insert an assistant text BLOCK as bare prose.
It carries no label: a user turn is the tinted one, so the agent's output
is simply what is not tinted.  The section has no heading either, which
costs it nothing but the ability to fold, and prose is what you came to
read.  When OPEN, this is the live streaming block: render its text raw
\(plus a trailing newline) and record the tail (`sprig-review--tail') just
before that newline, so `sprig-review--append-streamed' and a later full
refresh produce identical text.  A settled block is normalised for tidy
display."
  (magit-insert-section (sprig-text block)
    (if open
        ;; The live block renders raw so the fast in-place append path and a
        ;; later full rebuild agree; it gains markdown faces once it settles.
        (progn
          (insert (plist-get block :text) "\n")
          (setq sprig-review--tail (copy-marker (1- (point)) t)))
      (insert (sprig-review--fontify-markdown
               (sprig-review--text-body (plist-get block :text)))))))

(defun sprig-review--insert-user (block)
  "Insert a user-turn BLOCK as prose carrying the `sprig-review-user' tint.
The tint is what tells your turn from the agent's output, so the block
needs no label, and no heading beyond its own first line.
`heading-highlight-face' is what magit paints over the section under
point; naming our own keeps the turn tinted there too.  With no heading
to confine it to, magit paints it over the whole section, which is what
we want."
  (magit-insert-section (sprig-user block nil
                         :heading-highlight-face 'sprig-review-user-highlight)
    (let ((beg (point)))
      (insert (sprig-review--fontify-markdown
               (sprig-review--text-body (plist-get block :text))))
      (sprig-review--add-face beg (point) 'sprig-review-user))))

(defun sprig-review--insert-thinking (block)
  "Insert a thinking BLOCK, folded by default since it is verbose."
  (magit-insert-section (sprig-thinking block t)
    (magit-insert-heading (sprig-review--face "thinking" 'sprig-review-thinking))
    (magit-insert-section-body
      (insert (string-trim-right (plist-get block :text)) "\n"))))

(defun sprig-review--insert-error (block)
  "Insert an error BLOCK."
  (magit-insert-section (sprig-error block)
    (magit-insert-heading (sprig-review--face "error" 'error))
    (insert (string-trim-right (or (plist-get block :text) "")) "\n")))

(defun sprig-review--meta-line (key value)
  "Return a header line pairing KEY with VALUE, or nil when VALUE is blank."
  (when (and value (not (string-empty-p (format "%s" value))))
    (concat (sprig-review--face (format "%-9s" (concat key ":"))
                                'sprig-review-meta-key)
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
                   (sprig-review--meta-line
                    "Mode" (let ((m (plist-get model :mode)))
                             (unless (member m '(nil "auto" "default" "manual")) m)))
                   (sprig-review--meta-line "Session" (plist-get model :session))
                   (sprig-review--meta-line
                    "Cost" (when (plist-get model :cost)
                             (format "$%.4f" (plist-get model :cost))))))
      (when line (insert line)))
    (insert "\n")))

(defun sprig-review--prose-block-p (block)
  "Return non-nil when BLOCK reads as prose rather than as a one-line row.
A tool call or a thinking block folds to a single line, and a run of them
reads as one list of what the agent did.  Prose is what you actually
read.  `sprig-review-render' spaces the two apart on this."
  (memq (plist-get block :type) '(user text error)))

;;;; Rendering entry points

(defun sprig-review-render (model &optional meta)
  "Render review MODEL into the current buffer as magit-sections.
META is an optional plist of display metadata (see
`sprig-review--insert-headers').  The buffer should already be in
`sprig-review-mode'."
  (let* ((inhibit-read-only t)
         (blocks (plist-get model :blocks))
         (last (car (last blocks)))
         (prev nil)
         (first t))
    (setq sprig-review--tail nil)
    ;; Before the erase: these hang off buffer text that is about to go.
    (remove-overlays (point-min) (point-max) 'sprig-review-margin t)
    (erase-buffer)
    (magit-insert-section (sprig-review)
      (sprig-review--insert-headers model meta)
      (dolist (block blocks)
        ;; A blank line at every boundary prose is on either side of, which
        ;; is to say: around prose, and so above the first row of a run of
        ;; tool calls, but never between two of those rows.  A turn's tool
        ;; calls then sit as one block with air around it, rather than as a
        ;; ladder down the buffer.  The line goes before the block rather
        ;; than after, which would sit between the live text section's end
        ;; and `sprig-review--tail'.
        (when (and (not first)
                   (or (sprig-review--prose-block-p block)
                       (sprig-review--prose-block-p prev)))
          (insert "\n"))
        (setq first nil prev block)
        ;; Held from before the block is drawn, so the stamp lands against
        ;; its first line rather than against whatever follows it.
        (let ((start (point)))
          (pcase (plist-get block :type)
            ('user     (sprig-review--insert-user block))
            ;; The live tail is the last block, when it is text, and only
            ;; while a turn is actually streaming in.
            ('text     (sprig-review--insert-text
                        block (and sprig-review--streaming (eq block last))))
            ('thinking (sprig-review--insert-thinking block))
            ('tool     (sprig-review--insert-tool block))
            ('error    (sprig-review--insert-error block)))
          (sprig-review--insert-margin-time start (plist-get block :time)))))
    (sprig-review--update-margin)
    (goto-char (point-min))))

;;;; Live sink: accumulate events, refresh the buffer
;;
;; The transport (sprig.el) emits a backend-neutral event vocabulary; a
;; review buffer folds those events into its model and re-renders.
;; `sprig-review-consume' is the buffer's sink: the transport calls it once
;; per event (see `sprig--review-sink', which wraps it with the owning
;; buffer's transport bookkeeping).
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

(defun sprig-review--stamp-arrival (event)
  "Push a `time' event dating EVENT's arrival, unless it inherits one.
The wire carries no times, so a live turn is dated when it reaches the
buffer, and dated here rather than at render, since the model is rebuilt
from this event list every render and a time read off the clock there
would tick forward under a finished conversation.  One stamp per block is
enough: only the first `text' of a run opens a block, and the deltas
extending it are contiguous, so a `text' behind a `text' takes the stamp
already in the list rather than adding thousands of its own."
  (unless (and (eq (car event) 'text)
               (eq (car-safe (car sprig-review--events)) 'text))
    (push (list 'time (format-time-string "%FT%T.%3NZ" nil t))
          sprig-review--events)))

(defun sprig-review-consume (event)
  "Fold transport EVENT into the current review buffer.
A streamed `text' delta extends the live text section in place, with no
re-render, whenever a tail is established.  Every other event, and the
first `text' of a run, clears the tail and schedules a coalesced render
\(see `sprig-review-refresh-delay'), which re-establishes the tail."
  (sprig-review--stamp-arrival event)
  (push event sprig-review--events)
  ;; Track whether a turn is in flight, so a settled block renders fontified
  ;; rather than as a raw live tail (see `sprig-review--streaming').
  (pcase (car event)
    ('text (setq sprig-review--streaming t))
    ((or 'done 'error) (setq sprig-review--streaming nil))
    (_ nil))
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
  (setq sprig-review--events nil sprig-review--dirty nil
        sprig-review--streaming nil)
  (when meta (setq sprig-review--meta meta))
  (sprig-review--refresh))

(defun sprig-review-seed (events &optional meta)
  "Seed this review buffer with EVENTS (in order) and refresh synchronously.
Use this to replay history before the live sink appends more, so a later
`sprig-review-consume' rebuilds from history plus the new event.  Replayed
history is settled, so it renders with no live tail."
  (sprig-review--cancel-timer)
  (setq sprig-review--events (reverse events) sprig-review--dirty nil
        sprig-review--streaming nil)
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
  (setq-local revert-buffer-function #'ignore)
  ;; Surface the session's Claude permission mode (plan, auto, ...) in the
  ;; mode line; nil for an offline file review, which owns no session.
  (setq-local mode-line-process '(:eval (sprig--mode-line-permission)))
  ;; Prose wraps on word boundaries; tool headings are pre-truncated to one
  ;; line (see `sprig-review-heading-max-width'), so wrapping suits the body.
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  ;; Markdown markup (`*', `#', ...) carries `invisible markdown-markup' from
  ;; `sprig-review--fontify-markdown'; hide it here so only the styling shows.
  (add-to-invisibility-spec 'markdown-markup)
  ;; Claim the margin the timestamps hang in before the buffer is displayed,
  ;; so its first window comes up with the right width.
  (setq-local left-margin-width (sprig-review--margin-width)))

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

;;;; Steering: send through the owned session

(defun sprig-review-set-remote (remote)
  "Record REMOTE, the session host's SSH destination (nil when local).
Used to reach a changed file over TRAMP when visiting it."
  (setq sprig-review--remote remote))

(defun sprig-review--send (text &optional mode)
  "Send TEXT as a user instruction steering this review's session.
MODE, when given (e.g. \"plan\"), sets the permission mode for the turn.
Starts or resumes the session if it is not already live."
  (sprig--review-deliver text mode)
  (message "sprig: sent%s" (if mode (format " (%s mode)" mode) "")))

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

(defun sprig-review-set-title (title)
  "Set this review's display TITLE in the header.
The stored session's own ai-title (owned by the CLI) is left untouched, so
this affects only what the navigator and header show for the open buffer."
  (interactive
   (list (read-string "Title: " (plist-get sprig-review--meta :title))))
  (setq sprig-review--meta (plist-put sprig-review--meta :title title))
  (sprig-review--refresh))

(defun sprig-review-retry ()
  "Re-send the most recent user turn."
  (interactive)
  (let* ((model (sprig-review-build (reverse sprig-review--events)))
         (last-user (seq-find (lambda (b) (eq (plist-get b :type) 'user))
                              (reverse (plist-get model :blocks)))))
    (unless last-user (user-error "No previous user turn to resend"))
    (sprig-review--send (plist-get last-user :text))))

(defun sprig-review-interrupt ()
  "Interrupt the in-flight turn on this review's session."
  (interactive)
  (sprig--review-interrupt-owned))

(defun sprig-review--section-file (section)
  "Return the file path SECTION refers to, or nil."
  (and section
       (pcase (oref section type)
         ('sprig-hunk (plist-get (oref (oref section parent) value) :file))
         ('sprig-change (plist-get (oref section value) :file))
         ('sprig-tool (plist-get (car (plist-get (oref section value) :changes))
                                 :file))
         (_ nil))))

(defun sprig-review--file-location (path)
  "Return PATH, as a TRAMP name on the session host when the session is remote."
  (if sprig-review--remote (format "/ssh:%s:%s" sprig-review--remote path) path))

(defun sprig-review-visit ()
  "Visit the file the section at point refers to.
On a diff hunk, best-effort move point to the first changed line."
  (interactive)
  (let* ((section (magit-current-section))
         (file (sprig-review--section-file section)))
    (unless file (user-error "No file to visit here"))
    (find-file (sprig-review--file-location file))
    (when (eq (oref section type) 'sprig-hunk)
      (when-let* ((hunk (oref section value))
                  (anchor (car (or (plist-get hunk :new) (plist-get hunk :old))))
                  (needle (string-trim-left anchor)))
        (unless (string-empty-p needle)
          (goto-char (point-min))
          (when (search-forward needle nil t)
            (beginning-of-line)))))))

;;;; Compose buffer (the c c message)

(defvar-local sprig-review--compose-target nil
  "Review buffer a compose buffer sends to.")
(defvar-local sprig-review--compose-context nil
  "Marked-section context prepended to the composed message, or nil.")
(defvar-local sprig-review--compose-mode nil
  "Permission mode for the composed message (e.g. \"plan\"), or nil.")

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

(defun sprig-review-message (&optional plan)
  "Compose a message and send it to this review's session.
Any marked sections are attached as context (see DESIGN.md's `c c').
With PLAN non-nil, send the turn in plan mode (`c p')."
  (interactive)
  (let ((review (current-buffer))
        (context (sprig-review--marked-context))
        (buf (get-buffer-create "*sprig-message*")))
    (with-current-buffer buf
      (sprig-review-compose-mode)
      (erase-buffer)
      (setq sprig-review--compose-target review
            sprig-review--compose-context context
            sprig-review--compose-mode (and plan "plan")))
    (pop-to-buffer buf)
    (message "%s%sC-c C-c to send, C-c C-k to cancel"
             (if plan "PLAN mode.  " "")
             (if context (format "%d section(s) attached.  "
                                 (length (sprig-review--marked-sections)))
               ""))))

(defun sprig-review-message-plan ()
  "Compose a message and send it in plan mode (`c p')."
  (interactive)
  (sprig-review-message t))

(defun sprig-review-compose-send ()
  "Send the composed message (with any attached context) to the conversation."
  (interactive)
  (let ((text (string-trim (buffer-substring-no-properties
                            (point-min) (point-max))))
        (review sprig-review--compose-target)
        (context sprig-review--compose-context)
        (mode sprig-review--compose-mode))
    (when (string-empty-p text) (user-error "Empty message"))
    (unless (buffer-live-p review) (user-error "The review buffer is gone"))
    (quit-window t)
    (with-current-buffer review
      (sprig-review--send
       (if context (format "Regarding:\n\n%s\n\n%s" context text) text)
       mode))))

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
    ("p" "compose in plan mode" sprig-review-message-plan)
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
(define-key sprig-review-mode-map (kbd "C")   #'sprig-review-commit)
(define-key sprig-review-mode-map (kbd "x")   #'sprig-review-run)
(define-key sprig-review-mode-map (kbd "RET") #'sprig-review-visit)
(define-key sprig-review-mode-map (kbd "t")   #'sprig-review-set-title)

(provide 'sprig-review-mode)
;;; sprig-review-mode.el ends here
