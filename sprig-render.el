;;; sprig-render.el --- Shared rendering grammar for sprig's surfaces -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (magit-section "4.0.0"))
;; Keywords: tools, convenience, ai

;;; Commentary:

;; Sprig has three surfaces that all render the same changes and select
;; them the same way: the session transcript (`sprig-session-mode'), the
;; changeset review (`sprig-review-mode'), and the working-tree diff.
;; What they share lives here, so none of them has to require another.
;;
;; Three things:
;;
;; 1. Faces for a change, and the helpers that apply them.  Everything is
;;    propertized with `font-lock-face' rather than `face'; see the Face
;;    helpers section for why that is load-bearing rather than a style.
;;
;; 2. Change sections.  A change (see sprig-change.el) renders as a
;;    foldable file heading holding its hunks, identically wherever it
;;    appears.
;;
;; 3. Marks.  Marking is sprig's one selection primitive (see DESIGN.md):
;;    a verb acts on the marked sections, or on the section at point when
;;    nothing is marked.  Marks are stored as section idents, so they
;;    survive a re-render and are re-applied after one.

;;; Code:

(require 'magit-section)
(require 'diff-mode)                     ; for the diff-* faces
(require 'seq)
(require 'subr-x)
(require 'eieio)
(require 'sprig-change)

;;;; Faces

(defface sprig-diff-file '((t :inherit diff-file-header))
  "Face for a changed file's path."
  :group 'sprig)

(defface sprig-diff-added '((t :inherit diff-added))
  "Face for an added line in a reconstructed hunk."
  :group 'sprig)

(defface sprig-diff-removed '((t :inherit diff-removed))
  "Face for a removed line in a reconstructed hunk."
  :group 'sprig)

(defface sprig-diff-stat-added '((t :inherit success :weight normal))
  "Face for the added-line count in a tool heading.
Foreground only, unlike `sprig-diff-added': a count sits in a heading,
where the diff faces' backgrounds would be a stripe across it."
  :group 'sprig)

(defface sprig-diff-stat-removed '((t :inherit error :weight normal))
  "Face for the removed-line count in a tool heading."
  :group 'sprig)

(defface sprig-marked '((t :inherit highlight))
  "Face for the heading of a marked section."
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

(defun sprig--face (string face)
  "Return STRING carrying FACE, as a property the buffer's font-lock keeps."
  (propertize string 'font-lock-face face))

(defun sprig--add-face (beg end face)
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

(defun sprig--adopt-faces (string)
  "Return STRING with each `face' property moved over to `font-lock-face'.
Font-lock fontifies with `face', so a string fontified elsewhere (see
`sprig-session--fontify-markdown') needs this before it is inserted here."
  (let ((pos 0) (end (length string)))
    (while (< pos end)
      (let ((next (next-single-property-change pos 'face string end))
            (val (get-text-property pos 'face string)))
        (when val
          (put-text-property pos next 'font-lock-face val string)
          (remove-list-of-text-properties pos next '(face) string))
        (setq pos next)))
    string))

(defun sprig--suppress-section-highlight ()
  "Turn magit's section highlight off in the current buffer.
Magit highlights the section at point to show what its verbs would act
on.  Here the verbs act on marks and hunks, not on whatever point drifts
over, so the highlight says nothing and only washes out the faces the
conversation is read through.  The selection highlight goes with it, so
the region looks as it does in any other buffer.

Both settings are buffer-local, leaving a real magit buffer alone.  This
is called from `sprig-session-mode', and again by `sprig-reload' for the
buffers whose mode body ran before the edit."
  (setq-local magit-section-highlight-current nil)
  (setq-local magit-section-highlight-selection nil)
  ;; The settings only govern the next update, so a highlight already drawn
  ;; would sit there until something else redrew it.  Force the update that
  ;; deletes it; magit runs one from `post-command-hook'.
  (setq magit-section-highlight-force-update t))

;;;; Change sections

(defun sprig--stat-string (change)
  "Return a \"(+A -B)\" line-count summary for CHANGE, added green, removed red.
The numbers are the whole of what a folded edit tells you about its size,
so they are worth reading at a glance rather than parsing."
  (let ((stat (sprig-change-stat change)))
    (concat "("
            (sprig--face (format "+%d" (car stat))
                                'sprig-diff-stat-added)
            " "
            (sprig--face (format "-%d" (cdr stat))
                                'sprig-diff-stat-removed)
            ")")))

(defun sprig--insert-hunk (hunk)
  "Insert HUNK as removed lines then added lines, each a coloured section line."
  (magit-insert-section (sprig-hunk hunk)
    (dolist (l (plist-get hunk :old))
      (insert (sprig--face (concat "-" l) 'sprig-diff-removed) "\n"))
    (dolist (l (plist-get hunk :new))
      (insert (sprig--face (concat "+" l) 'sprig-diff-added) "\n"))))

(defun sprig--insert-change (change)
  "Insert CHANGE as a foldable file section holding its hunks."
  (magit-insert-section (sprig-change change)
    (magit-insert-heading
      (sprig--face (plist-get change :file) 'sprig-diff-file))
    (dolist (hunk (plist-get change :hunks))
      (sprig--insert-hunk hunk))))

(defun sprig--section-file (section)
  "Return the file path SECTION refers to, or nil."
  (and section
       (pcase (oref section type)
         ('sprig-hunk (plist-get (oref (oref section parent) value) :file))
         ('sprig-change (plist-get (oref section value) :file))
         ('sprig-tool (plist-get (car (plist-get (oref section value) :changes))
                                 :file))
         (_ nil))))

;;;; Marks

(defvar-local sprig--marks nil
  "Idents (per `magit-section-ident') of the marked sections.
Idents rather than section objects, so marks survive a re-render.")

(defun sprig--apply-marks ()
  "Highlight the marked sections; drop marks whose section no longer exists."
  (remove-overlays (point-min) (point-max) 'sprig-mark t)
  (setq sprig--marks (seq-filter #'magit-get-section sprig--marks))
  (dolist (ident sprig--marks)
    (let* ((sec (magit-get-section ident))
           (beg (oref sec start))
           (end (save-excursion (goto-char beg)
                                (min (1+ (line-end-position)) (point-max))))
           (ov (make-overlay beg end)))
      (overlay-put ov 'sprig-mark t)
      (overlay-put ov 'face 'sprig-marked)
      (overlay-put ov 'before-string (propertize "▸" 'face 'sprig-marked)))))

(defun sprig-toggle-mark ()
  "Toggle the mark on the section at point, then move to the next section."
  (interactive)
  (when-let ((sec (magit-current-section)))
    (let ((ident (magit-section-ident sec)))
      (setq sprig--marks
            (if (member ident sprig--marks)
                (delete ident sprig--marks)
              (cons ident sprig--marks))))
    (sprig--apply-marks)
    (ignore-errors (magit-section-forward))))

(defun sprig-unmark-all ()
  "Clear all marks."
  (interactive)
  (setq sprig--marks nil)
  (sprig--apply-marks))

(defun sprig--marked-sections ()
  "Return the marked sections, or the section at point if none are marked."
  (or (let (secs)
        (dolist (ident (reverse sprig--marks))
          (when-let ((s (magit-get-section ident))) (push s secs)))
        (nreverse secs))
      (when-let ((s (magit-current-section))) (list s))))

(defun sprig--sections-of-type (sections type)
  "Return the members of SECTIONS whose section type is TYPE."
  (seq-filter (lambda (s) (eq (oref s type) type)) sections))

(defun sprig--unmark-sections (sections)
  "Drop the marks on SECTIONS and refresh the highlighting."
  (dolist (s sections)
    (setq sprig--marks
          (delete (magit-section-ident s) sprig--marks)))
  (sprig--apply-marks))

(defun sprig--marked-context ()
  "Return the text of the marked sections as a context string, or nil.
Uses only real marks, not the section-at-point fallback."
  (when sprig--marks
    (let ((secs (sprig--marked-sections)))
      (mapconcat (lambda (s)
                   (string-trim (buffer-substring-no-properties
                                 (oref s start) (oref s end))))
                 secs "\n\n"))))

;;;; Renamed faces
;;
;; These render a change wherever it appears, so they left the transcript's
;; namespace in 0.51.0.  A themed face that quietly stops existing is as
;; silent as a `setq' on a renamed option, so the old names stay as aliases.

(define-obsolete-face-alias 'sprig-review-file
  'sprig-diff-file "0.51.0")
(define-obsolete-face-alias 'sprig-review-added
  'sprig-diff-added "0.51.0")
(define-obsolete-face-alias 'sprig-review-removed
  'sprig-diff-removed "0.51.0")
(define-obsolete-face-alias 'sprig-review-stat-added
  'sprig-diff-stat-added "0.51.0")
(define-obsolete-face-alias 'sprig-review-stat-removed
  'sprig-diff-stat-removed "0.51.0")
(define-obsolete-face-alias 'sprig-review-marked
  'sprig-marked "0.51.0")


(provide 'sprig-render)
;;; sprig-render.el ends here
