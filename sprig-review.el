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
;;   (:type user     :text STR)
;;   (:type text     :text STR)
;;   (:type thinking :text STR)
;;   (:type tool     :id ID :name NAME :input JSON :changes CHANGES
;;                   :result (:error BOOL :text STR) | nil)
;;   (:type error    :text STR)
;;
;; Consecutive `text' (or `thinking') events coalesce into one block; a
;; `text-block' event, a differing block kind, or any structural event
;; closes the open one.  A `tool-result' pairs with the earliest
;; unmatched `tool' block of the same id.  The live wire path never emits
;; `user' events (sprig sent that turn); the stored-session path does, so
;; a replayed transcript shows the user's turns too.

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
  (let ((session nil) (title nil) (cost nil) (error nil) (done nil)
        (blocks '())        ; built in reverse
        (open nil))         ; the open text/thinking block being coalesced
    (dolist (ev events)
      (pcase ev
        (`(session ,id) (setq session id))
        (`(title ,tt) (setq title tt))
        (`(text-block) (setq open nil))
        (`(text ,s)
         (if (and open (eq (plist-get open :type) 'text))
             (plist-put open :text (concat (plist-get open :text) s))
           (setq open (list :type 'text :text s))
           (push open blocks)))
        (`(thinking ,s)
         (if (and open (eq (plist-get open :type) 'thinking))
             (plist-put open :text (concat (plist-get open :text) s))
           (setq open (list :type 'thinking :text s))
           (push open blocks)))
        (`(user ,text)
         (setq open nil)
         (push (list :type 'user :text text) blocks))
        (`(tool-call ,id ,name ,input)
         (setq open nil)
         (push (list :type 'tool :id id :name name :input input
                     :changes (sprig-review-tool-changes name input)
                     :result nil)
               blocks))
        (`(tool-result ,id ,is-error ,rtext)
         (setq open nil)
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
         (setq open nil)
         (push (list :type 'error :text m) blocks))))
    (list :session session :title title :cost cost :error error :done done
          :blocks (nreverse blocks))))

;;;; Reading the CLI's stored session log
;;
;; The `claude' CLI persists each session as JSONL under
;;   ~/.claude/projects/<CWD>/<SESSION-ID>.jsonl
;; on the host where it runs (the SSH host for a remote session), where
;; <CWD> is the working directory with every `/' and `.' turned into `-'.
;; That file is a durable event log, so a review buffer can replay full
;; history without sprig keeping any store of its own.  This is the store
;; counterpart of the wire parser in sprig.el: both map their own schema
;; onto the shared event vocabulary that `sprig-review-build' consumes.
;;
;; The log is really a tree (records link by uuid/parentUuid) and subagent
;; transcripts are flagged `isSidechain'; v1 reads the main thread and
;; skips sidechains.

(defun sprig-review-session-file (cwd session-id)
  "Return the session-log path (with a leading ~) for CWD and SESSION-ID.
The path is relative to the session host, so a caller reads it locally or
over SSH.  CWD is encoded the way the CLI names its project directory."
  (format "~/.claude/projects/%s/%s.jsonl"
          (replace-regexp-in-string "[/.]" "-" cwd)
          session-id))

(defun sprig-review--flatten-content (content)
  "Flatten a tool_result CONTENT (string or block list) into text."
  (cond
   ((stringp content) content)
   ((listp content)
    (mapconcat (lambda (b) (if (stringp b) b (or (alist-get 'text b) "")))
               content ""))
   (t (format "%S" content))))

(defun sprig-review--assistant-events (content)
  "Map an assistant message CONTENT block list to events."
  (when (listp content)
    (delq nil
          (mapcar
           (lambda (b)
             (pcase (and (consp b) (alist-get 'type b))
               ("text" (list 'text (or (alist-get 'text b) "")))
               ("thinking" (list 'thinking (or (alist-get 'thinking b) "")))
               ("tool_use"
                (list 'tool-call
                      (or (alist-get 'id b) "t")
                      (alist-get 'name b)
                      (alist-get 'input b)))
               (_ nil)))
           content))))

(defun sprig-review--user-result-event (b)
  "Map a user-message tool_result block B to a `tool-result' event, or nil."
  (when (and (consp b) (equal (alist-get 'type b) "tool_result"))
    (list 'tool-result
          (or (alist-get 'tool_use_id b) "t")
          (alist-get 'is_error b)
          (string-trim (sprig-review--flatten-content (alist-get 'content b))))))

(defun sprig-review--user-events (content)
  "Map a user message CONTENT (string prose or tool_result blocks) to events."
  (cond
   ((stringp content)
    (unless (string-empty-p (string-trim content))
      (list (list 'user (string-trim content)))))
   ((listp content)
    (delq nil (mapcar #'sprig-review--user-result-event content)))))

(defun sprig-review-session-record-events (record)
  "Map one parsed session-log RECORD (an alist) to a list of events.
Skips sidechain (subagent) records and bookkeeping records that carry no
conversation content."
  (let ((type (alist-get 'type record)))
    (cond
     ((equal type "ai-title")
      (when-let ((tt (alist-get 'aiTitle record))) (list (list 'title tt))))
     ;; Only the main thread; sidechains are subagent transcripts.
     ((eq (alist-get 'isSidechain record) t) nil)
     ((equal type "assistant")
      (sprig-review--assistant-events
       (alist-get 'content (alist-get 'message record))))
     ((equal type "user")
      (sprig-review--user-events
       (alist-get 'content (alist-get 'message record)))))))

(defun sprig-review-parse-session-line (line)
  "Parse one JSONL session-log LINE into a list of events, or nil."
  (let ((record (ignore-errors
                  (json-parse-string line :object-type 'alist :array-type 'list
                                     :null-object nil :false-object nil))))
    (and (consp record) (sprig-review-session-record-events record))))

(defun sprig-review-session-events (lines)
  "Return the ordered event list parsed from LINES of the session log."
  (apply #'append (mapcar #'sprig-review-parse-session-line lines)))

(defun sprig-review-session-model (lines)
  "Build a review model from LINES of the stored session log."
  (sprig-review-build (sprig-review-session-events lines)))

(provide 'sprig-review)
;;; sprig-review.el ends here
