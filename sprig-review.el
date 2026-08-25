;;; sprig-review.el --- Changeset review with draft line comments -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (magit-section "4.0.0"))
;; Keywords: tools, convenience, ai

;;; Commentary:

;; The changeset review buffer: everything the agent (and you) have
;; changed in the working tree, as one navigable diff you annotate line by
;; line and then hand back in a single round.  This is the surface the
;; name `review' belongs to; the transcript is `sprig-session-mode'.
;;
;; The loop it exists for:
;;
;;   d          open the review over the session's working tree
;;   n / p      walk the changed files; TAB folds one away
;;   c c        comment on the line at point, or on the region
;;   e          hand-author a hunk instead of describing it
;;   c p        publish: every draft comment, in one turn, to the agent
;;
;; Three things make that more than a diff viewer.
;;
;; *Comments are drafts.*  Nothing reaches the agent until you publish, so
;; a review is composed as a whole rather than dribbled out a message at a
;; time.  This is Gerrit's model, and it is the reason the buffer is worth
;; having: reviewing is a pass over a changeset, not a chat.
;;
;; *Comments are anchored, and honestly so.*  A draft records the file,
;; the side, the line range, and the text of the lines it was written
;; against.  A refresh re-anchors it: same text at the same place keeps the
;; line, text that moved re-points to where it went, and text that is gone
;; is marked orphaned and floated at the top of its file rather than
;; silently dropped.  A review tool that quietly loses your comments is
;; worse than one that has none.
;;
;; *Positions come from git, not from tool payloads.*  An `Edit' payload
;; knows the bytes it replaced but never the line they sat on, so
;; line-anchored review can only ride the working-tree diff (source 2 in
;; DESIGN.md).  Sprig reads that diff itself, which the instruction
;; invariant permits: a read is fine, and only writes must go through the
;; agent.  Remotely it rides the session's own SSH transport, never TRAMP.
;; Publishing is an instruction like every other verb, so nothing here
;; touches the repository.

;;; Code:

(require 'cl-lib)
(require 'magit-section)
(require 'seq)
(require 'subr-x)
(require 'eieio)
(require 'transient)
(require 'sprig-change)
(require 'sprig-render)

(declare-function sprig--remote "sprig" ())
(declare-function sprig--remote-sh "sprig" (command host))
(declare-function sprig--remote-dir-arg "sprig" (dir))
(declare-function sprig--directory "sprig" ())
(declare-function sprig-session--compose "sprig-session-mode"
                  (target context &optional plan queue format label))
(declare-function sprig-session--open-stage-buffer "sprig-session-mode"
                  (review file anchor))

;;;; Options

(defcustom sprig-review-base "HEAD"
  "Git revision the changeset review diffs against (`d').
The default `\"HEAD\"' reviews the net *uncommitted* changes since the
last commit.  Set it to a branch such as `\"main\"' to review everything
the branch has changed on top of it, or to a range like `\"main...HEAD\"'
for the committed changes alone.  It is passed to `git diff' verbatim."
  :type 'string
  :group 'sprig)

(defcustom sprig-review-quote-lines 6
  "How many annotated lines a published comment quotes back at the agent.
A comment cites its line numbers exactly, but numbers alone are brittle
if the agent has moved things since, so the lines themselves ride along.
A long region is truncated to this many with an ellipsis."
  :type 'integer
  :group 'sprig)

;;;; Faces

(defface sprig-review-lineno '((t :inherit line-number))
  "Face for the old/new line-number columns beside a reviewed diff line."
  :group 'sprig)

(defface sprig-review-hunk '((t :inherit font-lock-comment-face))
  "Face for a hunk's `@@' heading in the review buffer."
  :group 'sprig)

(defface sprig-review-index '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the changed-file index heading at the top of the review."
  :group 'sprig)

(defface sprig-review-comment-body '((t :inherit font-lock-doc-face))
  "Face for the body of a draft review comment."
  :group 'sprig)

(defface sprig-review-comment-heading '((t :inherit font-lock-builtin-face
                                           :weight bold))
  "Face for a draft comment's heading line."
  :group 'sprig)

(defface sprig-review-orphan '((t :inherit warning :weight bold))
  "Face for a draft comment whose lines no longer exist in the diff."
  :group 'sprig)

;;;; Buffer-local state

(defvar-local sprig-review--session nil
  "The `sprig-session-mode' buffer this review publishes to.")

(defvar-local sprig-review--remote nil
  "SSH host the reviewed tree lives on, or nil when it is local.")

(defvar-local sprig-review--root nil
  "Top-level directory of the reviewed repository, on the session host.")

(defvar-local sprig-review--changes nil
  "The parsed changes currently rendered (see `sprig-parse-diff').")

(defvar-local sprig-review--drafts nil
  "Draft comments not yet published, oldest first.
Each is a plist

  (:id N :file PATH :side new|old :start N :end N :text S
   :anchor LINES :orphan BOOL)

where :start and :end are line numbers on :side, :anchor the text of
those lines when the comment was written, and :orphan non-nil once a
refresh could no longer find that text (see `sprig-review--reanchor').")

(defvar-local sprig-review--next-id 1
  "Counter handing each draft comment an id unique within the buffer.")

;;;; Reading the tree
;;
;; The one thing sprig runs itself.  A read of the working tree is what
;; DESIGN.md's invariant permits (only writes must go through the agent),
;; and it rides the session's own SSH transport for a remote tree, so
;; neither path needs TRAMP or a local checkout.

(defun sprig-review--run-git (remote dir args)
  "Run git ARGS in DIR and return stdout, on REMOTE over SSH or locally.
REMOTE nil runs git in DIR through `process-file'; a host runs `cd DIR &&
git ARGS' over the session's own SSH transport (`sprig--remote-sh').
Signals on a non-zero git exit."
  (if remote
      (sprig--remote-sh
       (concat "cd " (sprig--remote-dir-arg dir) " && "
               (mapconcat #'shell-quote-argument (cons "git" args) " "))
       remote)
    (let ((default-directory (file-name-as-directory dir)))
      (with-temp-buffer
        (if (zerop (apply #'process-file "git" nil t nil args))
            (buffer-string)
          (error "git %s failed: %s" (string-join args " ")
                 (string-trim (buffer-string))))))))

(defun sprig-review--toplevel (remote dir)
  "Return the git top-level directory containing DIR on REMOTE, or nil."
  (let ((out (ignore-errors
               (sprig-review--run-git remote dir '("rev-parse" "--show-toplevel")))))
    (when out
      (let ((root (string-trim out)))
        (unless (string-empty-p root) root)))))

(defun sprig-review--git (remote root)
  "Return `git diff' output for the repo at ROOT on REMOTE.
The diff is against `sprig-review-base'; untracked files are not shown,
since `git diff' omits them and staging them would touch the index."
  (sprig-review--run-git remote root (list "diff" sprig-review-base)))

;;;; Drafts: anchoring
;;
;; A draft remembers the text it was written against, not just where it
;; sat.  Line numbers are the first thing a fresh diff invalidates, so on
;; refresh the text is what finds the comment its new home; the numbers
;; are only a hint about where to look first.

(defun sprig-review--side-key (side)
  "Return the line-plist key for SIDE, which reads as `old' or `new'."
  (if (eq side 'old) :old :new))

(defun sprig-review--change-for (file changes)
  "Return the change for FILE among CHANGES, or nil."
  (seq-find (lambda (c) (equal (plist-get c :file) file)) changes))

(defun sprig-review--change-lines (change side)
  "Return CHANGE's unified lines that exist on SIDE, in order.
SIDE is `old' or `new'; a line exists on the side that carries a number
for it, so an added line is absent from `old' and a removed one from
`new'."
  (let (out)
    (dolist (u (plist-get change :unified))
      (dolist (l (plist-get u :lines))
        (when (plist-get l (sprig-review--side-key side)) (push l out))))
    (nreverse out)))

(defun sprig-review--text-at (change side start end)
  "Return the text of CHANGE's SIDE lines numbered START..END, in order."
  (let (out)
    (dolist (l (sprig-review--change-lines change side))
      (let ((n (plist-get l (sprig-review--side-key side))))
        (when (and (>= n start) (<= n end)) (push (plist-get l :text) out))))
    (nreverse out)))

(defun sprig-review--find-anchor (change side anchor)
  "Find ANCHOR, a list of line texts, among CHANGE's SIDE lines.
Returns (START . END), the SIDE line numbers of the run whose texts match
ANCHOR exactly, or nil when it is nowhere in the diff.  Used to re-point a
draft whose lines moved."
  (let* ((lines (sprig-review--change-lines change side))
         (texts (mapcar (lambda (l) (plist-get l :text)) lines))
         (n (length anchor))
         (hit nil))
    (when (> n 0)
      (cl-loop for i from 0 to (- (length texts) n)
               until hit
               when (equal (seq-subseq texts i (+ i n)) anchor)
               do (let ((k (sprig-review--side-key side)))
                    (setq hit (cons (plist-get (nth i lines) k)
                                    (plist-get (nth (+ i n -1) lines) k))))))
    hit))

(defun sprig-review--reanchor (drafts changes)
  "Return DRAFTS re-anchored against CHANGES, in place where they still fit.
Three outcomes per draft, and the third is the point of the exercise:
its lines still read the same, so it keeps them; its text moved, so it
follows; or its text is gone from the diff, so it is flagged `:orphan'
and kept.  A comment you wrote is never dropped on your behalf."
  (mapcar
   (lambda (d)
     (let* ((d (copy-sequence d))
            (change (sprig-review--change-for (plist-get d :file) changes))
            (side (plist-get d :side))
            (anchor (plist-get d :anchor))
            (here (and change (sprig-review--text-at
                               change side (plist-get d :start)
                               (plist-get d :end)))))
       (cond
        ((null change) (plist-put d :orphan t))
        ((and here (equal here anchor)) (plist-put d :orphan nil))
        (t (if-let ((hit (sprig-review--find-anchor change side anchor)))
               (progn (plist-put d :start (car hit))
                      (plist-put d :end (cdr hit))
                      (plist-put d :orphan nil))
             (plist-put d :orphan t))))))
   drafts))

;;;; Drafts: what point is on

(defun sprig-review--line-at (&optional pos)
  "Return the diff-line plist rendered at POS (default point), or nil.
The plist is (:file F :kind K :old N :new N), put on the line as a text
property when it was drawn."
  (get-text-property (save-excursion (goto-char (or pos (point)))
                                     (line-beginning-position))
                     'sprig-review-line))

(defun sprig-review--region-lines ()
  "Return (FILE SIDE START END ANCHOR) for the line at point or the region.
With an active region, the span it covers; otherwise the single line at
point.  SIDE is `old' only when every covered line is a removal, since a
deletion exists on no other side; anything else anchors to `new', the
post-image, which is what the file on disk actually reads.  Signals a
`user-error' when the selection covers no diff line."
  (let* ((beg (if (use-region-p) (region-beginning) (point)))
         (end (if (use-region-p) (region-end) (point)))
         (lines nil))
    (save-excursion
      (goto-char beg)
      (beginning-of-line)
      (let ((done nil))
        (while (and (not done) (<= (point) end))
          (when-let ((l (sprig-review--line-at))) (push l lines))
          (when (or (eobp) (/= 0 (forward-line 1))) (setq done t)))))
    (setq lines (nreverse lines))
    (unless lines
      (user-error "Point is not on a line of the diff"))
    (let* ((file (plist-get (car lines) :file))
           (lines (seq-filter (lambda (l) (equal (plist-get l :file) file)) lines))
           (side (if (seq-every-p (lambda (l) (eq (plist-get l :kind) 'del)) lines)
                     'old 'new))
           (key (sprig-review--side-key side))
           (ns (delq nil (mapcar (lambda (l) (plist-get l key)) lines))))
      (unless ns (user-error "That selection has no line on the %s side" side))
      (list file side (apply #'min ns) (apply #'max ns)
            (mapcar (lambda (l) (plist-get l :text))
                    (seq-filter (lambda (l) (plist-get l key)) lines))))))

(defun sprig-review--draft-at-point ()
  "Return the draft comment the section at point belongs to, or nil."
  (let ((sec (magit-current-section)))
    (while (and sec (not (eq (oref sec type) 'sprig-review-draft)))
      (setq sec (oref sec parent)))
    (and sec (oref sec value))))

(defun sprig-review--drafts-at (file side line)
  "Return the drafts on FILE whose SIDE range ends at LINE, in id order."
  (seq-filter (lambda (d)
                (and (equal (plist-get d :file) file)
                     (eq (plist-get d :side) side)
                     (not (plist-get d :orphan))
                     (= (plist-get d :end) line)))
              sprig-review--drafts))

;;;; Rendering

(defun sprig-review--lineno (n)
  "Return N right-aligned in the line-number column, blank when nil."
  (sprig--face (format "%5s" (or n "")) 'sprig-review-lineno))

(defun sprig-review--insert-draft (draft)
  "Insert DRAFT as its own foldable section under the line it annotates."
  (magit-insert-section (sprig-review-draft draft)
    (let* ((orphan (plist-get draft :orphan))
           (start (plist-get draft :start))
           (end (plist-get draft :end))
           (where (if (= start end) (format "line %d" start)
                    (format "lines %d-%d" start end))))
      (magit-insert-heading
        (concat "      "
                (sprig--face (format "↳ comment (%s%s)"
                                     (if orphan "orphaned, was " "") where)
                             (if orphan 'sprig-review-orphan
                               'sprig-review-comment-heading))))
      (dolist (l (split-string (plist-get draft :text) "\n"))
        (insert "        " (sprig--face l 'sprig-review-comment-body) "\n")))))

(defun sprig-review--insert-uline (file line)
  "Insert one unified diff LINE of FILE, with its number columns and drafts."
  (let* ((kind (plist-get line :kind))
         (marker (pcase kind ('add "+") ('del "-") (_ " ")))
         (face (pcase kind ('add 'sprig-diff-added) ('del 'sprig-diff-removed)
                      (_ 'default)))
         (beg (point)))
    (insert (sprig-review--lineno (plist-get line :old))
            (sprig-review--lineno (plist-get line :new))
            "  "
            (sprig--face (concat marker (plist-get line :text)) face)
            "\n")
    ;; The whole line carries what it is, so a comment at point (or over a
    ;; region) can read its file, side, and number straight off the buffer.
    (put-text-property beg (point) 'sprig-review-line
                       (list :file file :kind kind
                             :old (plist-get line :old)
                             :new (plist-get line :new)
                             :text (plist-get line :text)))
    (dolist (d (sprig-review--drafts-at
                file (if (eq kind 'del) 'old 'new)
                (or (plist-get line (if (eq kind 'del) :old :new)) -1)))
      (sprig-review--insert-draft d))))

(defun sprig-review--insert-uhunk (file uhunk)
  "Insert UHUNK of FILE as a foldable section headed by its `@@' line."
  (magit-insert-section (sprig-review-hunk uhunk)
    (magit-insert-heading
      (sprig--face
       (format "  @@ -%d,%d +%d,%d @@%s"
               (plist-get uhunk :old-start) (plist-get uhunk :old-count)
               (plist-get uhunk :new-start) (plist-get uhunk :new-count)
               (if-let ((h (plist-get uhunk :heading))) (concat " " h) ""))
       'sprig-review-hunk))
    (dolist (l (plist-get uhunk :lines))
      (sprig-review--insert-uline file l))))

(defun sprig-review--insert-orphans (file)
  "Insert FILE's orphaned drafts, if any, above its hunks.
An orphan has no line left to sit under, so it floats to the top of the
file it was written against rather than vanishing."
  (when-let ((orphans (seq-filter
                       (lambda (d) (and (equal (plist-get d :file) file)
                                        (plist-get d :orphan)))
                       sprig-review--drafts)))
    (dolist (d orphans) (sprig-review--insert-draft d))))

(defun sprig-review--insert-file (change)
  "Insert CHANGE as a foldable file section of unified hunks."
  (magit-insert-section (sprig-change change)
    (magit-insert-heading
      (concat (sprig--face (plist-get change :file) 'sprig-diff-file)
              "  " (sprig--stat-string change)))
    (sprig-review--insert-orphans (plist-get change :file))
    (if-let ((unified (plist-get change :unified)))
        (dolist (u unified) (sprig-review--insert-uhunk
                             (plist-get change :file) u))
      (insert "  (no textual hunks)\n"))))

(defun sprig-review--insert-index (changes)
  "Insert the changed-file index: one line per file in CHANGES, with its stat."
  (magit-insert-section (sprig-review-index)
    (magit-insert-heading
      (sprig--face (format "Changed files (%d)" (length changes))
                   'sprig-review-index))
    (dolist (c changes)
      (let ((n (length (seq-filter
                        (lambda (d) (equal (plist-get d :file)
                                           (plist-get c :file)))
                        sprig-review--drafts))))
        (insert "  " (sprig--stat-string c) "  "
                (sprig--face (plist-get c :file) 'sprig-diff-file)
                (if (zerop n) ""
                  (sprig--face (format "  (%d comment%s)" n
                                       (if (= n 1) "" "s"))
                               'sprig-review-comment-heading))
                "\n")))
    (insert "\n")))

(defun sprig-review--render ()
  "Redraw the review buffer from `sprig-review--changes' and its drafts."
  (let ((inhibit-read-only t)
        (changes sprig-review--changes))
    (remove-overlays (point-min) (point-max) 'sprig-mark t)
    (setq sprig--marks nil)
    (erase-buffer)
    (magit-insert-section (sprig-review-root)
      (if (null changes)
          (insert (format "No changes against %s.\n" sprig-review-base))
        (sprig-review--insert-index changes)
        (dolist (c changes) (sprig-review--insert-file c))))
    (goto-char (point-min))))

(defun sprig-review--reload (&optional keep-point)
  "Re-read the diff, re-anchor the drafts, and redraw; KEEP-POINT restores point."
  (let ((pos (and keep-point (point))))
    (setq sprig-review--changes
          (sprig-parse-diff (sprig-review--git sprig-review--remote
                                               sprig-review--root))
          sprig-review--drafts
          (sprig-review--reanchor sprig-review--drafts sprig-review--changes))
    (sprig-review--render)
    (when pos (goto-char (min pos (point-max))))))

;;;; Writing a comment

(defvar-local sprig-review--comment-target nil
  "Review buffer a comment buffer files its draft in.")
(defvar-local sprig-review--comment-draft nil
  "The draft plist being written, complete but for its `:text'.")

(defvar sprig-review-comment-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'sprig-review-comment-save)
    (define-key map (kbd "C-c C-k") #'sprig-review-comment-abort)
    map)
  "Keymap for `sprig-review-comment-mode'.")

(define-derived-mode sprig-review-comment-mode text-mode "Sprig-Comment"
  "Major mode for writing one draft review comment.
\\<sprig-review-comment-mode-map>`\\[sprig-review-comment-save]' files the \
draft, `\\[sprig-review-comment-abort]' throws it away.  Nothing reaches \
the agent until the review is published."
  :group 'sprig)

(defun sprig-review--edit-comment (draft &optional existing)
  "Pop a buffer to write DRAFT's text; EXISTING non-nil is a re-edit."
  (let ((review (current-buffer))
        (buf (get-buffer-create "*sprig-comment*")))
    (with-current-buffer buf
      (sprig-review-comment-mode)
      (erase-buffer)
      (when-let ((text (plist-get draft :text))) (insert text))
      (setq sprig-review--comment-target review
            sprig-review--comment-draft draft)
      (goto-char (point-max)))
    (pop-to-buffer buf)
    (message "%s %s:%s.  C-c C-c to file the draft, C-c C-k to discard"
             (if existing "Editing comment on" "Comment on")
             (file-name-nondirectory (plist-get draft :file))
             (if (= (plist-get draft :start) (plist-get draft :end))
                 (plist-get draft :start)
               (format "%d-%d" (plist-get draft :start) (plist-get draft :end))))))

(defun sprig-review-comment-save ()
  "File the comment being written as a draft on its review buffer."
  (interactive)
  (let ((text (string-trim (buffer-substring-no-properties
                            (point-min) (point-max))))
        (review sprig-review--comment-target)
        (draft sprig-review--comment-draft))
    (when (string-empty-p text) (user-error "Empty comment"))
    (unless (buffer-live-p review) (user-error "The review buffer is gone"))
    (plist-put draft :text text)
    (with-current-buffer review
      (setq sprig-review--drafts
            (append (seq-remove (lambda (d) (eq (plist-get d :id)
                                                (plist-get draft :id)))
                                sprig-review--drafts)
                    (list draft)))
      (sprig-review--render))
    (quit-window t)
    (message "sprig: draft comment filed; `c p' publishes the review")))

(defun sprig-review-comment-abort ()
  "Discard the comment being written."
  (interactive)
  (quit-window t)
  (message "sprig: comment discarded"))

(defun sprig-review-comment ()
  "Comment on the line at point, or on the region (`c c').
The draft records the file, the side, the line range, and the text of
those lines, so a later refresh can find it again even if the agent has
moved things.  It goes nowhere until you publish."
  (interactive)
  (unless (derived-mode-p 'sprig-review-mode)
    (user-error "Not in a sprig review buffer"))
  (pcase-let ((`(,file ,side ,start ,end ,anchor) (sprig-review--region-lines)))
    (when (use-region-p) (deactivate-mark))
    (sprig-review--edit-comment
     (list :id (prog1 sprig-review--next-id (cl-incf sprig-review--next-id))
           :file file :side side :start start :end end
           :text nil :anchor anchor :orphan nil))))

(defun sprig-review-comment-edit ()
  "Re-open the draft comment at point for editing (`c e')."
  (interactive)
  (let ((draft (or (sprig-review--draft-at-point)
                   (user-error "Point is not on a draft comment"))))
    (sprig-review--edit-comment (copy-sequence draft) t)))

(defun sprig-review-comment-delete ()
  "Take back the draft comment at point (`k').
The same take-it-back gesture that unstages a queued message: a draft is
another thing point can sit on, and nothing has been sent."
  (interactive)
  (let ((draft (or (sprig-review--draft-at-point)
                   (user-error "Point is not on a draft comment"))))
    (setq sprig-review--drafts
          (seq-remove (lambda (d) (eq (plist-get d :id) (plist-get draft :id)))
                      sprig-review--drafts))
    (sprig-review--render)
    (message "sprig: comment taken back")))

(defun sprig-review-discard-drafts ()
  "Discard every draft comment in this review (`c Q')."
  (interactive)
  (let ((n (length sprig-review--drafts)))
    (when (zerop n) (user-error "No draft comments to discard"))
    (when (yes-or-no-p (format "Discard %d draft comment%s? "
                               n (if (= n 1) "" "s")))
      (setq sprig-review--drafts nil)
      (sprig-review--render)
      (message "sprig: %d draft%s discarded" n (if (= n 1) "" "s")))))

;;;; Publishing

(defun sprig-review--quote (draft)
  "Return DRAFT's anchored lines as quoted text, truncated for length."
  (let* ((all (plist-get draft :anchor))
         (shown (seq-take all sprig-review-quote-lines))
         (more (- (length all) (length shown))))
    (concat (mapconcat (lambda (l) (concat "> " l)) shown "\n")
            (if (> more 0) (format "\n> … (%d more line%s)"
                                   more (if (= more 1) "" "s"))
              ""))))

(defun sprig-review--publish-file (file drafts)
  "Return the published section for FILE's DRAFTS."
  (concat
   (format "## %s\n" file)
   (mapconcat
    (lambda (d)
      (let ((start (plist-get d :start)) (end (plist-get d :end)))
        (format "\n### %s%s\n\n%s\n\n%s\n"
                (if (= start end) (format "Line %d" start)
                  (format "Lines %d-%d" start end))
                (pcase (plist-get d :side)
                  ('old " (a removed line, numbered in the pre-image)")
                  (_ ""))
                (sprig-review--quote d)
                (plist-get d :text))))
    drafts "")))

(defun sprig-review--publish-text (drafts)
  "Return the review body for DRAFTS: every comment, grouped by file, in order.
Orphans go in a section of their own at the end, named as such, since a
comment whose lines have moved out from under it is still worth reading
but should not claim a line number it no longer owns."
  (let* ((live (seq-remove (lambda (d) (plist-get d :orphan)) drafts))
         (orphans (seq-filter (lambda (d) (plist-get d :orphan)) drafts))
         (files (seq-uniq (mapcar (lambda (d) (plist-get d :file)) live))))
    (concat
     (mapconcat
      (lambda (f)
        (sprig-review--publish-file
         f (seq-sort-by (lambda (d) (plist-get d :start)) #'<
                        (seq-filter (lambda (d) (equal (plist-get d :file) f))
                                    live))))
      files "\n")
     (when orphans
       (concat
        "\n## Comments whose lines have since moved\n\n"
        "These were written against text that is no longer where it was, so "
        "they carry the text rather than a line number:\n"
        (mapconcat (lambda (d)
                     (format "\n- In `%s`:\n\n%s\n\n%s\n"
                             (plist-get d :file)
                             (sprig-review--quote d)
                             (plist-get d :text)))
                   orphans ""))))))

(defun sprig-review--publish-format (text body)
  "Frame a published review: covering note TEXT over the comment BODY."
  (format "I have reviewed the current changes and left comments on \
specific lines. Address each one, then tell me briefly what you changed \
for each. Where you disagree with a comment, say so rather than changing \
the code.

%s

---

%s" text body))

(defun sprig-review-publish ()
  "Publish this review: every draft comment, in one turn, to the session (`c p').
Opens the ordinary compose buffer with the comments attached, so you write
the covering note and see exactly what goes out before it does.  Sending
clears the drafts, since they are then the agent's problem rather than
yours."
  (interactive)
  (unless (derived-mode-p 'sprig-review-mode)
    (user-error "Not in a sprig review buffer"))
  (unless sprig-review--drafts
    (user-error "No draft comments; `c c' writes one, `c m' sends a plain message"))
  (unless (buffer-live-p sprig-review--session)
    (user-error "The session this review belongs to is gone"))
  (let* ((drafts sprig-review--drafts)
         (n (length drafts))
         (body (sprig-review--publish-text drafts))
         (review (current-buffer)))
    (sprig-session--compose
     sprig-review--session body nil nil
     (lambda (text ctx)
       ;; Clearing on send, not on compose: an aborted compose must leave
       ;; the review exactly as it was, drafts and all.
       (when (buffer-live-p review)
         (with-current-buffer review
           (setq sprig-review--drafts nil)
           (sprig-review--render)))
       (sprig-review--publish-format text ctx))
     (format "%d comment%s" n (if (= n 1) "" "s")))
    (with-current-buffer "*sprig-message*"
      (when (= (buffer-size) 0)
        (insert (format "%d comment%s on the changes below."
                        n (if (= n 1) "" "s")))))))

;;;; Plain messages, and hand-authoring

(defun sprig-review-message (&optional queue)
  "Send a plain message about the marked hunks to the session (`c m').
The escape hatch from the comment loop: some feedback is about the change
as a whole rather than a line of it.  With QUEUE non-nil, hold it until
the running turn ends."
  (interactive)
  (unless (buffer-live-p sprig-review--session)
    (user-error "The session this review belongs to is gone"))
  (sprig-session--compose sprig-review--session (sprig--marked-context)
                          nil queue))

(defun sprig-review-message-queue ()
  "Send a plain message about the marked hunks, queued (`c M')."
  (interactive)
  (sprig-review-message t))

(defun sprig-review--line-at-first (section)
  "Return the diff-line plist of SECTION's first rendered line, or nil."
  (save-excursion
    (goto-char (oref section start))
    (or (sprig-review--line-at)
        (progn (forward-line 1) (sprig-review--line-at)))))

(defun sprig-review-stage-hunk ()
  "Hand-author the hunk at point instead of describing it (`e').
Seeds the staging buffer with the hunk's *new* side, the context and
added lines as they now stand on disk, so your edit replaces exactly
that.  You edit locally and the agent writes it, as ever."
  (interactive)
  (let ((sec (magit-current-section)))
    (while (and sec (not (eq (oref sec type) 'sprig-review-hunk)))
      (setq sec (oref sec parent)))
    (unless sec (user-error "Point is not on a hunk"))
    (unless (buffer-live-p sprig-review--session)
      (user-error "The session this review belongs to is gone"))
    (let* ((uhunk (oref sec value))
           (file (plist-get (sprig-review--line-at-first sec) :file))
           (text (mapconcat (lambda (l) (plist-get l :text))
                            (seq-filter (lambda (l)
                                          (memq (plist-get l :kind)
                                                '(context add)))
                                        (plist-get uhunk :lines))
                            "\n")))
      (when (string-empty-p text)
        (user-error "This hunk is a pure deletion; there is nothing to edit"))
      (sprig-session--open-stage-buffer sprig-review--session file text))))

;;;; Visiting and refreshing

(defun sprig-review-visit ()
  "Visit the file at point, at the line under point where there is one (`RET')."
  (interactive)
  (let* ((line (sprig-review--line-at))
         (file (or (and line (plist-get line :file))
                   (sprig--section-file (magit-current-section))
                   (user-error "Nothing to visit here")))
         (path (expand-file-name file default-directory)))
    (find-file-other-window path)
    (when-let ((n (and line (plist-get line :new))))
      (goto-char (point-min))
      (forward-line (1- n)))))

(defun sprig-review-refresh (&rest _)
  "Re-run `git diff', re-anchor the drafts, and redraw (`g')."
  (interactive)
  (unless (derived-mode-p 'sprig-review-mode)
    (user-error "Not in a sprig review buffer"))
  (sprig-review--reload t)
  (let ((orphans (seq-count (lambda (d) (plist-get d :orphan))
                            sprig-review--drafts)))
    (message "sprig: review refreshed%s"
             (if (zerop orphans) ""
               (format "; %d comment%s no longer match their lines"
                       orphans (if (= orphans 1) "" "s"))))))

;;;; The mode

(defvar sprig-review-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "SPC")     #'sprig-toggle-mark)
    (define-key map (kbd "m")       #'sprig-toggle-mark)
    (define-key map (kbd "U")       #'sprig-unmark-all)
    (define-key map (kbd "c")       #'sprig-review-dispatch)
    (define-key map (kbd "C-c C-c") #'sprig-review-publish)
    (define-key map (kbd "k")       #'sprig-review-comment-delete)
    (define-key map (kbd "e")       #'sprig-review-stage-hunk)
    (define-key map (kbd "g")       #'sprig-review-refresh)
    (define-key map (kbd "RET")     #'sprig-review-visit)
    (define-key map (kbd "q")       #'quit-window)
    map)
  "Keymap for `sprig-review-mode'.")

(define-derived-mode sprig-review-mode magit-section-mode "Sprig-Review"
  "Major mode for reviewing a changeset and annotating it line by line.

Move with \\`n' / \\`p', fold with \\`TAB', \\`g' re-reads the diff, and
\\`RET' visits the file at the line under point.  The verbs live on the
\\`c' transient:

  c c   comment on the line at point, or on the region
  c e   re-edit the draft comment at point (\\`k' takes it back)
  c p   publish every draft to the session, as one turn
  c Q   discard every draft
  c m   plain message about the marked hunks (\\`SPC' marks)

\\`e' hand-authors the hunk at point instead of describing it, and
\\`C-c C-c' publishes, the way it sends everywhere else in sprig.

Nothing here writes to the repository: publishing is an instruction to the
agent, like every other sprig verb."
  :group 'sprig
  (setq-local revert-buffer-function #'sprig-review-refresh)
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (sprig--suppress-section-highlight))

(transient-define-prefix sprig-review-dispatch ()
  "Review the changes, then hand the whole review back in one turn."
  [["Comment"
    ("c" "on the line or region" sprig-review-comment)
    ("e" "edit the draft at point" sprig-review-comment-edit)
    ("k" "take back the draft at point" sprig-review-comment-delete)]
   ["Publish"
    ("p" "publish the review (all drafts)" sprig-review-publish)
    ("Q" "discard every draft" sprig-review-discard-drafts)]
   ["Plain message"
    ("m" "about the marked hunks" sprig-review-message)
    ("M" "…queued for after this turn" sprig-review-message-queue)]])

;;;###autoload
(defun sprig-session-review ()
  "Open the changeset review for this session's working tree (`d').
Every change in the tree against `sprig-review-base', as one navigable
diff you annotate line by line and publish in a single turn.  Reads the
diff itself, which the invariant permits, over the session's own SSH
transport when the tree is remote."
  (interactive)
  (unless (derived-mode-p 'sprig-session-mode)
    (user-error "Not in a sprig session buffer"))
  (let* ((remote (sprig--remote))
         (dir (or (sprig--directory)
                  (and (not remote) default-directory)
                  (user-error "This session has no working directory")))
         (root (or (sprig-review--toplevel remote dir)
                   (user-error "Not inside a git repository: %s" dir)))
         (session (current-buffer))
         (buf (get-buffer-create
               (format "*sprig-review: %s*" (buffer-name session)))))
    (with-current-buffer buf
      (unless (derived-mode-p 'sprig-review-mode) (sprig-review-mode))
      (setq sprig-review--session session
            sprig-review--remote remote
            sprig-review--root root
            ;; `default-directory' anchors a `RET' file visit: a TRAMP name
            ;; on the host for a remote session, the plain root locally.
            ;; The bulk diff read does not use it.
            default-directory (file-name-as-directory
                               (if remote (format "/ssh:%s:%s" remote root) root)))
      (sprig-review--reload))
    (pop-to-buffer buf)))

(provide 'sprig-review)
;;; sprig-review.el ends here
