;;; sprig-review.el --- Review model and diff engine for sprig -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.4.1
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, convenience, ai

;;; Commentary:

;; The data foundation for the read-only, Magit-like review buffer (see
;; DESIGN.md, "Current direction: the review buffer").  Two pure layers,
;; both independent of any rendering and of a live session, so both run
;; offline under ERT:
;;
;; 1. The diff engine.  The crux of the review buffer is reviewing the
;;    agent's actual file changes.  In v1 those changes are attributed
;;    per turn straight from the tool-call payloads: every `Edit',
;;    `MultiEdit', and `Write' already carries its before/after in the
;;    stream-json, so `sprig-review-tool-changes' reconstructs the hunks
;;    with no git.  (Git ground truth, which also catches `Bash'-driven
;;    edits, is a later slice.)
;;
;; 2. The review model.  `sprig-review-build' folds the backend-neutral
;;    event vocabulary (see sprig.el's transport/sink seam) into an
;;    ordered list of blocks: assistant text, tool calls with their
;;    reconstructed changes and paired results, and errors.  The renderer
;;    projects this model into `magit-section' rows; the model itself
;;    knows nothing about the display.

;;; Code:

(require 'json)
(require 'seq)
(require 'subr-x)

;;;; Tool-payload diff engine
;;
;; A *change* is a plist (:file PATH :kind KIND :hunks HUNKS), where KIND
;; is `edit' or `write' and each HUNK is (:old OLD :new NEW :replace-all
;; FLAG).  OLD and NEW are lists of lines (nil for none), so a `write' of
;; a new file has :old nil and a pure deletion has :new nil.

(defun sprig-review--parse-input (json)
  "Parse a tool-call input JSON string into an alist, or nil on failure.
Treats blank input as the empty object."
  (let ((s (string-trim (or json ""))))
    (ignore-errors
      (json-parse-string (if (string-empty-p s) "{}" s)
                         :object-type 'alist :array-type 'list
                         :null-object nil :false-object nil))))

(defun sprig-review--lines (s)
  "Split S into a list of display lines, or nil when S is empty.
A single trailing newline does not yield a spurious empty final line,
but a blank line inside the text is kept."
  (when (and s (not (string-empty-p s)))
    (let ((parts (split-string s "\n")))
      (if (string-empty-p (car (last parts)))
          (butlast parts)
        parts))))

(defun sprig-review--edit-hunk (edit)
  "Build a hunk plist from an EDIT alist (old_string/new_string/replace_all)."
  (list :old (sprig-review--lines (alist-get 'old_string edit))
        :new (sprig-review--lines (alist-get 'new_string edit))
        :replace-all (and (alist-get 'replace_all edit) t)))

(defun sprig-review-tool-changes (name input)
  "Return the file changes tool NAME made, derived from its INPUT JSON.
Each element is a change plist (see the section commentary).  Returns nil
for tools that touch no files, or when INPUT lacks a file path."
  (let ((obj (sprig-review--parse-input input)))
    (pcase name
      ("Edit"
       (when-let ((path (alist-get 'file_path obj)))
         (list (list :file path :kind 'edit
                     :hunks (list (sprig-review--edit-hunk obj))))))
      ("MultiEdit"
       (when-let ((path (alist-get 'file_path obj)))
         (list (list :file path :kind 'edit
                     :hunks (mapcar #'sprig-review--edit-hunk
                                    (alist-get 'edits obj))))))
      ("Write"
       (when-let ((path (alist-get 'file_path obj)))
         (list (list :file path :kind 'write
                     :hunks (list (list :old nil
                                        :new (sprig-review--lines
                                              (alist-get 'content obj))
                                        :replace-all nil))))))
      (_ nil))))

(defun sprig-review-change-stat (change)
  "Return (ADDED . REMOVED) line counts across CHANGE's hunks."
  (let ((add 0) (del 0))
    (dolist (h (plist-get change :hunks))
      (setq add (+ add (length (plist-get h :new)))
            del (+ del (length (plist-get h :old)))))
    (cons add del)))

(defun sprig-review--format-hunk (hunk)
  "Render HUNK as unified-diff-ish text: removed lines, then added lines."
  (let ((old (plist-get hunk :old))
        (new (plist-get hunk :new)))
    (concat
     (mapconcat (lambda (l) (concat "-" l)) old "\n")
     (when (and old new) "\n")
     (mapconcat (lambda (l) (concat "+" l)) new "\n"))))

(defun sprig-review-format-change (change)
  "Render CHANGE as a file header line followed by its hunks."
  (concat (plist-get change :file) "\n"
          (mapconcat #'sprig-review--format-hunk
                     (plist-get change :hunks) "\n")))

;;;; Review model
;;
;; `sprig-review-build' folds a list of transport events into a turn
;; model, a plist (:session ID :cost N :error BOOL :done BOOL :blocks
;; BLOCKS).  Each block is one of:
;;
;;   (:type text  :text STR)
;;   (:type tool  :id ID :name NAME :input JSON :changes CHANGES
;;                :result (:error BOOL :text STR) | nil)
;;   (:type error :text STR)
;;
;; Consecutive `text' events coalesce into one block; a `text-block'
;; event forces the next `text' to open a fresh one.  A `tool-result'
;; pairs with the earliest unmatched `tool' block of the same id.

(defun sprig-review--find-open-tool (blocks id)
  "Return the tool block in BLOCKS with ID and no result yet, or nil."
  (seq-find (lambda (b)
              (and (eq (plist-get b :type) 'tool)
                   (equal (plist-get b :id) id)
                   (null (plist-get b :result))))
            blocks))

(defun sprig-review-build (events)
  "Fold a list of transport EVENTS into a turn model plist.
See the section commentary for the event vocabulary and block shapes."
  (let ((session nil) (cost nil) (error nil) (done nil)
        (blocks '())        ; built in reverse
        (text nil))         ; the currently open text block, or nil
    (dolist (ev events)
      (pcase ev
        (`(session ,id) (setq session id))
        (`(text-block) (setq text nil))
        (`(text ,s)
         (if text
             (plist-put text :text (concat (plist-get text :text) s))
           (setq text (list :type 'text :text s))
           (push text blocks)))
        (`(tool-call ,id ,name ,input)
         (setq text nil)
         (push (list :type 'tool :id id :name name :input input
                     :changes (sprig-review-tool-changes name input)
                     :result nil)
               blocks))
        (`(tool-result ,id ,is-error ,rtext)
         (setq text nil)
         (let ((blk (sprig-review--find-open-tool blocks id)))
           (if blk
               (plist-put blk :result (list :error is-error :text rtext))
             ;; A result with no matching call: keep it as a loose block
             ;; rather than drop it, so nothing is silently lost.
             (push (list :type 'tool :id id :name nil :input nil
                         :changes nil
                         :result (list :error is-error :text rtext))
                   blocks))))
        (`(done ,c ,e) (setq done t cost c error e))
        (`(error ,m)
         (setq text nil)
         (push (list :type 'error :text m) blocks))))
    (list :session session :cost cost :error error :done done
          :blocks (nreverse blocks))))

(provide 'sprig-review)
;;; sprig-review.el ends here
