;;; sprig-notes.el --- Personal notes stored in an Org file -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.18.1
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, convenience, ai

;;; Commentary:

;; A lightweight personal-reminders store for sprig: things to fix later
;; or just remember, jotted from the `+' transient and listed live in the
;; `sprig-status' navigator.
;;
;; This is the ONE place sprig writes to disk.  Sprig otherwise keeps no
;; store of its own (history is the CLI's session log, see sprig.el's
;; commentary); a personal notes list is not conversation data, though, so
;; it is a user-owned artifact rather than a second store of the log.  It
;; lives in a single Org file (`sprig-notes-file'), one top-level heading
;; per note:
;;
;;     * TODO Fix the flaky test in foo [2026-08-04 Tue 14:03:12]
;;     * DONE Bump the version [2026-08-01 Sat 09:12:00]
;;
;; The trailing inactive-timestamp is the note's creation time and doubles
;; as its immutable identity, so toggling / editing / deleting a note finds
;; it again even after the file was reordered or hand-edited elsewhere.
;;
;; Parsing is deliberately line-based, with no dependency on `org': the
;; grammar is a regular subset, and the file is parsed into a preamble plus
;; a list of heading "blocks" (a heading line and the raw lines beneath it).
;; A mutation rewrites only the target block's heading line and leaves every
;; other block -- and anything the parser does not recognise (a preamble,
;; note bodies, tags, sub-bullets a human added) -- verbatim.  Round-tripping
;; is exact: serialize(parse(S)) is S for any S.

;;; Code:

(require 'seq)
(require 'subr-x)

(defgroup sprig-notes nil
  "Personal notes for sprig."
  :group 'sprig
  :prefix "sprig-notes-")

(defcustom sprig-notes-file (locate-user-emacs-file "sprig-notes.org")
  "Org file holding sprig's personal notes.
A single global list across all sessions, not tied to any one of them.
This is the only file sprig ever writes to; it stays human-editable, so
org-mode opens it and the notes survive outside sprig."
  :type '(file :tag "Org file"))

;;;; Parsing

(defconst sprig-notes--heading-prefix "* "
  "String a top-level Org heading line begins with.")

(defconst sprig-notes--headline-re
  "\\`\\*[ \t]+\\(TODO\\|DONE\\)[ \t]+\\(.*?\\)[ \t]*\\(\\[[^]]*\\]\\)?[ \t]*\\'"
  "Match a note headline: keyword (1), text (2), trailing timestamp id (3).")

(defun sprig-notes--parse-time (id)
  "Return the Emacs time encoded in ID (a bracketed Org timestamp), or nil."
  (when (and id
             (string-match
              (concat "\\`\\[\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)"
                      "[^0-9]+\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\)"
                      "\\(?::\\([0-9]\\{2\\}\\)\\)?\\]\\'")
              id))
    (encode-time
     (list (string-to-number (or (match-string 6 id) "0"))
           (string-to-number (match-string 5 id))
           (string-to-number (match-string 4 id))
           (string-to-number (match-string 3 id))
           (string-to-number (match-string 2 id))
           (string-to-number (match-string 1 id))
           nil -1 nil))))

(defun sprig-notes--heading-line-p (line)
  "Non-nil when LINE opens a top-level Org heading."
  (string-prefix-p sprig-notes--heading-prefix line))

(defun sprig-notes--make-block (lines)
  "Build a block plist from LINES, its first the heading line.
A `TODO'/`DONE' heading yields a note block carrying :text, :state, :id and
:time; anything else yields a plain block that only round-trips."
  (let ((headline (car lines)))
    (if (string-match sprig-notes--headline-re headline)
        (let ((id (match-string 3 headline)))
          (list :lines lines
                :text (string-trim (match-string 2 headline))
                :state (if (equal (match-string 1 headline) "DONE") 'done 'todo)
                :id id
                :time (sprig-notes--parse-time id)))
      (list :lines lines))))

(defun sprig-notes--parse-string (string)
  "Parse STRING into a plist (:preamble LINES :blocks BLOCKS).
Lines before the first heading are the preamble; each heading and the lines
beneath it are one block.  Line-exact, so `sprig-notes--serialize' inverts
this."
  (let ((lines (split-string string "\n"))
        preamble blocks current)
    (while (and lines (not (sprig-notes--heading-line-p (car lines))))
      (push (pop lines) preamble))
    (dolist (line lines)
      (if (sprig-notes--heading-line-p line)
          (progn
            (when current
              (push (sprig-notes--make-block (nreverse current)) blocks))
            (setq current (list line)))
        (push line current)))
    (when current
      (push (sprig-notes--make-block (nreverse current)) blocks))
    (list :preamble (nreverse preamble) :blocks (nreverse blocks))))

(defun sprig-notes--serialize (structure)
  "Render STRUCTURE back to text, exactly inverting `sprig-notes--parse-string'."
  (string-join
   (append (plist-get structure :preamble)
           (apply #'append (mapcar (lambda (b) (plist-get b :lines))
                                   (plist-get structure :blocks))))
   "\n"))

(defun sprig-notes--notes (structure)
  "Return STRUCTURE's note blocks (those with a state), in file order."
  (seq-filter (lambda (b) (plist-get b :state))
              (plist-get structure :blocks)))

(defun sprig-notes--find (notes id)
  "Return the member of NOTES whose :id equals ID, or nil."
  (and id (seq-find (lambda (b) (equal (plist-get b :id) id)) notes)))

;;;; Headline construction and ids

(defun sprig-notes--headline (text state &optional id)
  "Return a note heading line for TEXT in STATE (`todo'/`done'), tagged ID."
  (concat "* " (if (eq state 'done) "DONE" "TODO") " " text
          (and id (concat " " id))))

(defun sprig-notes--format-id (time)
  "Return TIME as an inactive Org timestamp, sprig's note id."
  (format-time-string "[%Y-%m-%d %a %H:%M:%S]" time))

(defun sprig-notes--now-id (existing-ids)
  "Return (ID . TIME) for now, ID unique against EXISTING-IDS.
Two notes jotted in the same second would otherwise collide, so the second
is bumped forward until its id is free."
  (let* ((time (current-time))
         (id (sprig-notes--format-id time)))
    (while (member id existing-ids)
      (setq time (time-add time 1)
            id (sprig-notes--format-id time)))
    (cons id time)))

;;;; Reading and writing (the only disk-write path in sprig)

(defun sprig-notes-read ()
  "Read `sprig-notes-file' into a parsed structure; empty when it is absent."
  (sprig-notes--parse-string
   (if (file-readable-p sprig-notes-file)
       (with-temp-buffer
         (insert-file-contents sprig-notes-file)
         (buffer-string))
     "")))

(defun sprig-notes--write (structure)
  "Write STRUCTURE to `sprig-notes-file', creating its directory if needed.
The single sprig-owned write, and it touches only that file."
  (let ((dir (file-name-directory sprig-notes-file)))
    (when dir (make-directory dir t)))
  (let ((coding-system-for-write 'utf-8))
    (write-region (sprig-notes--serialize structure) nil sprig-notes-file
                  nil 'silent)))

(defun sprig-notes--rebuild-block (block)
  "Return BLOCK with its heading line rebuilt from its :text/:state/:id."
  (plist-put (copy-sequence block) :lines
             (cons (sprig-notes--headline (plist-get block :text)
                                          (plist-get block :state)
                                          (plist-get block :id))
                   (cdr (plist-get block :lines)))))

(defun sprig-notes--map-note (structure id fn)
  "Return STRUCTURE with the note block whose :id is ID replaced by (FN block).
Re-reading is done by the callers, so a note that has vanished from the file
(hand-deleted elsewhere) signals rather than being silently recreated."
  (let* ((found nil)
         (blocks (mapcar (lambda (b)
                           (if (and (plist-get b :id)
                                    (equal (plist-get b :id) id))
                               (progn (setq found t) (funcall fn b))
                             b))
                         (plist-get structure :blocks))))
    (unless found
      (user-error "sprig: that note is no longer in %s (press g to refresh)"
                  (abbreviate-file-name sprig-notes-file)))
    (plist-put (copy-sequence structure) :blocks blocks)))

(defun sprig-notes--note-id (note)
  "Return NOTE's :id, or signal that it has none to track it by."
  (or (plist-get note :id)
      (user-error "sprig: that note has no timestamp id; edit it in the file")))

(defun sprig-notes-add (text)
  "Append a TODO note reading TEXT to `sprig-notes-file'; return the note block."
  (let* ((structure (sprig-notes-read))
         (ids (delq nil (mapcar (lambda (b) (plist-get b :id))
                                (plist-get structure :blocks))))
         (id-time (sprig-notes--now-id ids))
         (block (list :lines (list (sprig-notes--headline text 'todo (car id-time)))
                      :text text :state 'todo :id (car id-time) :time (cdr id-time))))
    (sprig-notes--write
     (plist-put (copy-sequence structure) :blocks
                (append (plist-get structure :blocks) (list block))))
    block))

(defun sprig-notes-toggle (note)
  "Flip NOTE between TODO and DONE in `sprig-notes-file'."
  (let ((id (sprig-notes--note-id note)))
    (sprig-notes--write
     (sprig-notes--map-note
      (sprig-notes-read) id
      (lambda (b)
        (sprig-notes--rebuild-block
         (plist-put (copy-sequence b) :state
                    (if (eq (plist-get b :state) 'done) 'todo 'done))))))))

(defun sprig-notes-edit (note new-text)
  "Replace NOTE's text with NEW-TEXT in `sprig-notes-file'."
  (let ((id (sprig-notes--note-id note)))
    (sprig-notes--write
     (sprig-notes--map-note
      (sprig-notes-read) id
      (lambda (b)
        (sprig-notes--rebuild-block
         (plist-put (copy-sequence b) :text new-text)))))))

(defun sprig-notes-delete (note)
  "Remove NOTE from `sprig-notes-file'."
  (let* ((id (sprig-notes--note-id note))
         (structure (sprig-notes-read))
         (found nil)
         (kept (seq-remove (lambda (b)
                             (and (equal (plist-get b :id) id)
                                  (setq found t)))
                           (plist-get structure :blocks))))
    (unless found
      (user-error "sprig: that note is no longer in %s (press g to refresh)"
                  (abbreviate-file-name sprig-notes-file)))
    (sprig-notes--write (plist-put (copy-sequence structure) :blocks kept))))

;;;; Capture (shared by both surfaces)

(defun sprig-notes-capture ()
  "Read a note from the minibuffer and append it to `sprig-notes-file'.
Returns the new note block.  The navigator and review buffer wrap this to
also refresh the list; capture itself only writes."
  (interactive)
  (let ((text (string-trim (read-string "Note: "))))
    (when (string-empty-p text)
      (user-error "Empty note"))
    (prog1 (sprig-notes-add text)
      (message "sprig: noted"))))

(provide 'sprig-notes)
;;; sprig-notes.el ends here
