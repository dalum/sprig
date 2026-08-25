;;; sprig-change.el --- The change model and diff engines for sprig -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, convenience, ai

;;; Commentary:

;; The one data shape every sprig surface agrees on, and the two engines
;; that produce it.  A *change* is a plist (:file PATH :kind KIND :hunks
;; HUNKS); see the section commentary below for the full shape.
;;
;; Two sources produce changes, and DESIGN.md calls them source 1 and
;; source 2:
;;
;; 1. Tool-call payloads (`sprig-tool-changes').  Every `Edit',
;;    `MultiEdit', and `Write' carries its own before/after in the
;;    stream-json, so a turn's changes reconstruct with no git at all.
;;    Precise and turn-attributed, but positionless: a payload knows the
;;    bytes it replaced, never the line they sat on.
;;
;; 2. A unified git diff (`sprig-parse-diff').  The real working tree,
;;    which also catches what no payload explains (a `Bash' formatter, a
;;    `sed', codegen).  This one does carry positions.
;;
;; Both fold into the same shape, so the stat, the formatter, and every
;; renderer consume them without caring which source they came from.
;; Nothing here renders or touches a live session, so it all runs offline
;; under ERT, and it stays free of `magit-section' so the transport can
;; require it.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

;;;; Tool-payload diff engine
;;
;; A *change* is a plist (:file PATH :kind KIND :hunks HUNKS), where KIND
;; is `edit' or `write' and each HUNK is (:old OLD :new NEW :replace-all
;; FLAG).  OLD and NEW are lists of lines (nil for none), so a `write' of
;; a new file has :old nil and a pure deletion has :new nil.

(defun sprig--parse-input (json)
  "Return tool-call input JSON as an alist, or nil.
JSON may be a string (the wire path, parsed here) or an already-parsed
alist (the stored-session path, passed through).  Blank string is the
empty object."
  (cond
   ((stringp json)
    (let ((s (string-trim json)))
      (ignore-errors
        (json-parse-string (if (string-empty-p s) "{}" s)
                           :object-type 'alist :array-type 'list
                           :null-object nil :false-object nil))))
   ;; nil or an already-parsed alist (nil is the empty object).
   ((listp json) json)
   (t nil)))

(defun sprig--lines (s)
  "Split S into a list of display lines, or nil when S is empty.
A single trailing newline does not yield a spurious empty final line,
but a blank line inside the text is kept."
  (when (and s (not (string-empty-p s)))
    (let ((parts (split-string s "\n")))
      (if (string-empty-p (car (last parts)))
          (butlast parts)
        parts))))

(defun sprig--edit-hunk (edit)
  "Build a hunk plist from an EDIT alist (old_string/new_string/replace_all)."
  (list :old (sprig--lines (alist-get 'old_string edit))
        :new (sprig--lines (alist-get 'new_string edit))
        :replace-all (and (alist-get 'replace_all edit) t)))

(defun sprig-tool-changes (name input)
  "Return the file changes tool NAME made, derived from its INPUT JSON.
Each element is a change plist (see the section commentary).  Returns nil
for tools that touch no files, or when INPUT lacks a file path."
  (let ((obj (sprig--parse-input input)))
    (pcase name
      ("Edit"
       (when-let ((path (alist-get 'file_path obj)))
         (list (list :file path :kind 'edit
                     :hunks (list (sprig--edit-hunk obj))))))
      ("MultiEdit"
       (when-let ((path (alist-get 'file_path obj)))
         (list (list :file path :kind 'edit
                     :hunks (mapcar #'sprig--edit-hunk
                                    (alist-get 'edits obj))))))
      ("Write"
       (when-let ((path (alist-get 'file_path obj)))
         (list (list :file path :kind 'write
                     :hunks (list (list :old nil
                                        :new (sprig--lines
                                              (alist-get 'content obj))
                                        :replace-all nil))))))
      (_ nil))))

(defun sprig-change-stat (change)
  "Return (ADDED . REMOVED) line counts across CHANGE's hunks."
  (let ((add 0) (del 0))
    (dolist (h (plist-get change :hunks))
      (setq add (+ add (length (plist-get h :new)))
            del (+ del (length (plist-get h :old)))))
    (cons add del)))

(defun sprig--format-hunk (hunk)
  "Render HUNK as unified-diff-ish text: removed lines, then added lines."
  (let ((old (plist-get hunk :old))
        (new (plist-get hunk :new)))
    (concat
     (mapconcat (lambda (l) (concat "-" l)) old "\n")
     (when (and old new) "\n")
     (mapconcat (lambda (l) (concat "+" l)) new "\n"))))

(defun sprig-format-change (change)
  "Render CHANGE as a file header line followed by its hunks."
  (concat (plist-get change :file) "\n"
          (mapconcat #'sprig--format-hunk
                     (plist-get change :hunks) "\n")))

;;;; Ground-truth diff parser
;;
;; Source 2 in DESIGN.md ("The crux: diff review"): the real working-tree
;; diff, which the agent produces by running `git diff' and reporting it
;; (Sprig never runs git itself; see the instruction invariant).  It
;; catches changes no tool payload explains (a `Bash' formatter, a `sed'),
;; and it is the subject of navigator mode, where the human's own edits
;; have no `Edit'/`Write' payload to reconstruct from.
;;
;; `sprig-parse-diff' folds a unified git diff into the SAME change
;; shape the tool-payload engine emits (:file/:kind/:hunks), so the stat,
;; formatter, and renderer all consume it unchanged.  The model carries no
;; context lines, matching the payload path, so each contiguous run of
;; -/+ lines inside a hunk becomes one hunk and the surrounding context is
;; dropped.  The input is expected to be `git diff' output (one
;; `diff --git' header per file, which is the file boundary).  Limits, all
;; deferred: binary files are skipped; a rename with no content change is
;; reported at its new path with no hunks; a plain `diff -u' stream with no
;; `diff --git' headers reconstructs only its first file.

(defun sprig--diff-strip-prefix (path)
  "Strip a leading `a/' or `b/' from git diff PATH; leave others alone."
  (cond
   ((null path) nil)
   ((string-prefix-p "a/" path) (substring path 2))
   ((string-prefix-p "b/" path) (substring path 2))
   (t path)))

(defun sprig--diff-header-path (line)
  "Return the path from a `--- ' or `+++ ' diff LINE, nil for /dev/null.
The leading marker and any trailing tab-separated timestamp are dropped."
  (let* ((body (substring line 4))              ; past "--- " / "+++ "
         (field (car (split-string body "\t"))))
    (if (equal field "/dev/null") nil
      (sprig--diff-strip-prefix field))))

(defun sprig-parse-diff (text)
  "Parse unified git-diff TEXT into a list of change plists.
Each element matches the shape `sprig-tool-changes' returns,
\(:file PATH :kind edit|write :hunks HUNKS); see this section's
commentary for the mapping and its limits."
  (let ((changes nil)
        (path nil) (kind 'edit) (hunks nil) (binary nil)
        (a-path nil) (b-path nil)              ; the file's --- / +++ paths
        (old-run nil) (new-run nil) (in-hunk nil))
    (cl-flet* ((flush-run
                 ()
                 (when (or old-run new-run)
                   (push (list :old (nreverse old-run)
                               :new (nreverse new-run)
                               :replace-all nil)
                         hunks)
                   (setq old-run nil new-run nil)))
               (flush-file
                 ()
                 (flush-run)
                 (when (and path (not binary))
                   (push (list :file path :kind kind :hunks (nreverse hunks))
                         changes))
                 (setq path nil kind 'edit hunks nil binary nil
                       a-path nil b-path nil in-hunk nil)))
      (dolist (line (split-string (or text "") "\n"))
        (cond
         ((string-prefix-p "diff --git " line) (flush-file))
         ((string-prefix-p "new file mode" line) (setq kind 'write))
         ((string-prefix-p "Binary files " line) (setq binary t))
         ((string-prefix-p "rename to " line)
          (setq path (sprig--diff-strip-prefix
                      (string-trim (substring line (length "rename to "))))))
         ;; `--- '/`+++ ' are file headers only before the first `@@'; once
         ;; in a hunk a `-'/`+' line is content, even one reading `--- x'.
         ((and (not in-hunk) (string-prefix-p "--- " line))
          (setq a-path (sprig--diff-header-path line)))
         ((and (not in-hunk) (string-prefix-p "+++ " line))
          (setq b-path (sprig--diff-header-path line))
          ;; b is the live path unless it is /dev/null (a deletion); a
          ;; /dev/null old path means a new file even absent `new file mode'.
          (setq path (or b-path a-path))
          (when (null a-path) (setq kind 'write)))
         ((string-prefix-p "@@" line) (flush-run) (setq in-hunk t))
         (in-hunk
          (pcase (and (> (length line) 0) (aref line 0))
            (?- (push (substring line 1) old-run))
            (?+ (push (substring line 1) new-run))
            (?\\ nil)                    ; "\ No newline at end of file"
            (_ (flush-run))))            ; context (incl. blank " ") ends a run
         (t nil)))                       ; index/mode/similarity headers
      (flush-file)
      (nreverse changes))))

(provide 'sprig-change)
;;; sprig-change.el ends here
