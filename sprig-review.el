;;; sprig-review.el --- Review model and diff engine for sprig -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.12.0
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
;; model, a plist (:session ID :cost N :error BOOL :done BOOL :context N
;; :blocks BLOCKS).  Every block carries the `:time' of the most recent `time'
;; event before it, and is one of:
;;
;;   (:type user     :text STR :time ISO)
;;   (:type text     :text STR :time ISO)
;;   (:type thinking :text STR :time ISO)
;;   (:type tool     :id ID :name NAME :input JSON :changes CHANGES
;;                   :result (:error BOOL :text STR) | nil :agent PLIST | nil
;;                   :time ISO)
;;   (:type tasks    :items ITEMS :time ISO)
;;   (:type dialog   :id ID :kind KIND :input INPUT
;;                   :answered BOOL :answers ANSWERS :time ISO)
;;   (:type error    :text STR :time ISO)
;;
;; A tool block's `:agent' is a subagent's live progress, folded onto the
;; `Agent' call it runs under (`:status', `:agent-type', `:description',
;; `:last-tool', `:tokens', `:tool-uses').  It is live-only, and correctly so:
;; the CLI narrates a subagent while it runs but writes none of that to the
;; session log, so a replayed `Agent' call has no `:agent' and needs none, the
;; work being over and its report already sitting in the tool result.
;;
;; A `tasks' block is the CLI's granular task tools folded into one running
;; checklist.  Where a `TodoWrite' resends its whole list each call, this
;; CLI variant emits one `TaskCreate'/`TaskUpdate' per task, so the fold
;; keeps the current task state and snapshots it: ITEMS is a list of todo
;; alists ((content . STR) (status . STR)), the same shape a `TodoWrite'
;; carries, so both render through one checklist.  A run of adjacent task
;; ops coalesces into a single snapshot; a non-task block between ops opens
;; a fresh one, so the checklist reappears wherever the plan next moved.
;;
;; Consecutive `text' (or `thinking') events coalesce into one block; a
;; `text-block' event, a differing block kind, or any structural event
;; closes the open one.  A `tool-result' pairs with the earliest
;; unmatched `tool' block of the same id.  The live wire path never emits
;; `user' events (sprig sent that turn); the stored-session path does, so
;; a replayed transcript shows the user's turns too.
;;
;; A `dialog' event is the CLI asking the user something mid-turn (an
;; `AskUserQuestion', say) and waiting on the answer.  It is conversation,
;; not transport, because it is rendered and answered in the buffer rather
;; than in the minibuffer: the block stands pending until a `dialog-answer'
;; event of the same id resolves it, and the answer lands in the event list
;; so a rebuild still knows the question was settled.  ANSWERS is the alist
;; the tool gets back, or nil for a question waved through.
;;
;; A `time' event carries an ISO 8601 UTC stamp and opens no block of its
;; own; it just says when what follows happened.  The stored log stamps
;; every record, so replayed history keeps its real times; the wire
;; carries none, so the sink stamps events as they arrive (see
;; `sprig-review-consume').  Either way the stamp lands in the event list
;; itself, which is what keeps it stable: the model is rebuilt from that
;; list on every render, so a time read off the clock here would tick
;; forward under a conversation that had long since finished.

(defun sprig-review--merge-plist (base new)
  "Return BASE with NEW's non-nil values laid over it.
A nil in NEW means `this record did not carry the field', never `clear it':
the CLI's task records each carry their own subset, so an overwrite would
lose what an earlier one established."
  (let ((out (copy-sequence base)))
    (while new
      (let ((k (car new)) (v (cadr new)))
        (when v (setq out (plist-put out k v))))
      (setq new (cddr new)))
    out))

(defun sprig-review--find-open-tool (blocks id)
  "Return the tool block in BLOCKS with ID and no result yet, or nil."
  (seq-find (lambda (b)
              (and (eq (plist-get b :type) 'tool)
                   (equal (plist-get b :id) id)
                   (null (plist-get b :result))))
            blocks))

(defun sprig-review--find-dialog (blocks id)
  "Return the dialog block in BLOCKS with ID, or nil."
  (seq-find (lambda (b)
              (and (eq (plist-get b :type) 'dialog)
                   (equal (plist-get b :id) id)))
            blocks))

(defun sprig-review-pending-dialog (model)
  "Return MODEL's dialog block still waiting on an answer, or nil.
The turn is stopped on it: the CLI asked, and will not go on until it
hears back."
  (seq-find (lambda (b)
              (and (eq (plist-get b :type) 'dialog)
                   (not (plist-get b :answered))))
            (plist-get model :blocks)))

(defun sprig-review--task-created-id (text)
  "Return the id string in a TaskCreate result TEXT, or nil.
The task tool answers a create with \"Task #N created ...\", so a new
task's id is only in the result, never in the call's own input."
  (when (and (stringp text) (string-match "Task #\\([0-9]+\\)" text))
    (match-string 1 text)))

(defun sprig-review--task-apply-update (tasks input)
  "Return TASKS folded with one TaskUpdate INPUT alist.
A `deleted' status drops the task; any other status, or a new subject, is
written in place onto the task the INPUT's `taskId' names.  Each task is a
plist (:id ID :content SUBJECT :status STATUS)."
  (let ((tid (alist-get 'taskId input))
        (status (alist-get 'status input))
        (subject (alist-get 'subject input)))
    (if (equal status "deleted")
        (seq-remove (lambda (tk) (equal (plist-get tk :id) tid)) tasks)
      (dolist (tk tasks tasks)
        (when (equal (plist-get tk :id) tid)
          (when status (plist-put tk :status status))
          (when subject (plist-put tk :content subject)))))))

(defun sprig-review-build (events)
  "Fold a list of transport EVENTS into a turn model plist.
See the section commentary for the event vocabulary and block shapes."
  (let* ((session nil) (title nil) (mode nil) (cost nil) (error nil) (done nil)
         (context nil)       ; the freshest turn's context-window token count
         (time nil)          ; the stamp the next block opened takes
         (blocks '())        ; built in reverse
         (open nil)          ; the open text/thinking block being coalesced
         (tasks '())         ; current Task* state, oldest-first (see fold below)
         (pending-creates '()) ; TaskCreate tool-id -> subject, awaiting its id
         (task-ids '())      ; tool-ids of Task* calls, so their results fold too
         (tasks-block nil)   ; the running task snapshot, coalesced across a run
         (snapshot
          (lambda ()
            ;; Push a fresh task checklist, or update the running one, to the
            ;; current `tasks'.  ITEMS mirror a `TodoWrite' alist so both
            ;; render through one checklist; each is copied so a later fold
            ;; does not bleed back into an earlier snapshot.
            (let ((items (mapcar (lambda (tk)
                                   (list (cons 'content (plist-get tk :content))
                                         (cons 'status (plist-get tk :status))))
                                 tasks)))
              (if tasks-block
                  (plist-put tasks-block :items items)
                (setq tasks-block (list :type 'tasks :items items :time time))
                (push tasks-block blocks))))))
    (dolist (ev events)
      (pcase ev
        (`(session ,id) (setq session id))
        (`(title ,tt) (setq title tt))
        (`(mode ,m) (setq mode m))
        (`(time ,ts) (setq time ts))
        (`(text-block) (setq open nil))
        (`(text ,s)
         (if (and open (eq (plist-get open :type) 'text))
             (plist-put open :text (concat (plist-get open :text) s))
           (setq open (list :type 'text :text s :time time))
           (push open blocks)))
        (`(thinking ,s)
         (if (and open (eq (plist-get open :type) 'thinking))
             (plist-put open :text (concat (plist-get open :text) s))
           (setq open (list :type 'thinking :text s :time time))
           (push open blocks)))
        (`(user ,text)
         (setq open nil)
         (push (list :type 'user :text text :time time) blocks))
        (`(tool-call ,id ,name ,input)
         (setq open nil)
         (cond
          ;; The granular task tools fold into the running checklist rather
          ;; than render as their own rows; a create waits on its result for
          ;; the id, an update applies at once, a list changes nothing.
          ((member name '("TaskCreate" "TaskUpdate" "TaskList"))
           (push id task-ids)
           (pcase name
             ("TaskCreate"
              (let ((obj (sprig-review--parse-input input)))
                (push (cons id (or (alist-get 'subject obj) "task"))
                      pending-creates)))
             ("TaskUpdate"
              (setq tasks (sprig-review--task-apply-update
                           tasks (sprig-review--parse-input input)))
              (funcall snapshot))))
          (t
           (push (list :type 'tool :id id :name name :input input
                       :changes (sprig-review-tool-changes name input)
                       :result nil :time time)
                 blocks))))
        (`(tool-result ,id ,is-error ,rtext)
         (setq open nil)
         (cond
          ;; A task op's result. A create's result is the only place the new
          ;; task's id appears, so fold it in here; every other task result
          ;; is bookkeeping and is swallowed rather than shown.
          ((member id task-ids)
           (when-let ((subject (cdr (assoc id pending-creates))))
             (setq pending-creates (assoc-delete-all id pending-creates))
             (let ((tid (or (sprig-review--task-created-id rtext)
                            (number-to-string (1+ (length tasks))))))
               (setq tasks (append tasks (list (list :id tid :content subject
                                                     :status "pending"))))
               (funcall snapshot))))
          (t
           (let ((blk (sprig-review--find-open-tool blocks id)))
             (if blk
                 (plist-put blk :result (list :error is-error :text rtext))
               ;; A result with no matching call: keep it as a loose block
               ;; rather than drop it, so nothing is silently lost.
               (push (list :type 'tool :id id :name nil :input nil
                           :changes nil
                           :result (list :error is-error :text rtext)
                           :time time)
                     blocks))))))
        ;; Subagent progress lands on the `Agent' call it runs under.  It does
        ;; not close the open text block: the subagent's narration is not the
        ;; main agent speaking, so it must not split the main agent's prose in
        ;; two, the way a real block of its own would.
        (`(subagent ,id ,state)
         (when-let ((blk (sprig-review--find-open-tool blocks id)))
           (plist-put blk :agent
                      ;; Merged, not replaced: `task_progress' repeats and
                      ;; carries only what changed, so a plain overwrite would
                      ;; drop the agent type `task_started' named once.
                      (sprig-review--merge-plist (plist-get blk :agent) state))))
        (`(dialog ,id ,kind ,input)
         (setq open nil)
         (push (list :type 'dialog :id id :kind kind :input input
                     :answered nil :answers nil :time time)
               blocks))
        (`(dialog-answer ,id ,answers)
         (setq open nil)
         (when-let ((blk (sprig-review--find-dialog blocks id)))
           (plist-put blk :answered t)
           (plist-put blk :answers answers)))
        (`(done ,c ,e) (setq done t cost c error e))
        (`(context ,n) (setq context n))
        (`(error ,m)
         (setq open nil)
         (push (list :type 'error :text m :time time) blocks)))
      ;; A run of task ops coalesces into one snapshot; the moment any other
      ;; block reaches the head, that run has ended, so the next task op opens
      ;; a fresh checklist rather than reopening the stale one.
      (when (and tasks-block (not (eq (car blocks) tasks-block)))
        (setq tasks-block nil)))
    (list :session session :title title :mode mode
          :cost cost :error error :done done :context context
          :blocks (nreverse blocks))))

(defun sprig-review-events-title (events)
  "Return the freshest title carried by EVENTS, or nil.
EVENTS is a buffer's stored event list, newest first (as pushed by
`sprig-review-consume'), so the first `title' event is the freshest.  The
navigator titles a live session's row with this, recovering the replayed
`ai-title' that the live stream itself never carries."
  (let ((hit (seq-find (lambda (ev) (eq (car-safe ev) 'title)) events)))
    (and hit (cadr hit))))

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
;; The log is really a tree: records link by uuid/parentUuid.
;;
;; A subagent leaves nothing here.  Its transcript is written to a file of its
;; own, `<session-id>/subagents/agent-<task-id>.jsonl', with a `.meta.json'
;; naming the `Agent' call it ran under; the main log carries only that call
;; and its result.  So the `isSidechain' skip below never fires on a main log
;; (the flag is set in those separate files, on records this never reads) and
;; is kept as a guard, not as the thing that hides subagent work.

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

(defun sprig-review--usage-context-event (usage)
  "Return a one-element ((context N)) list for a message's USAGE, or nil.
N is the whole prompt the model was given for the turn: new input plus
cache-read plus cache-creation tokens, which is the context-window size in
use.  Output tokens are the reply, not context, so they are left out."
  (when (listp usage)
    (let ((n (+ (or (alist-get 'input_tokens usage) 0)
                (or (alist-get 'cache_read_input_tokens usage) 0)
                (or (alist-get 'cache_creation_input_tokens usage) 0))))
      (when (> n 0) (list (list 'context n))))))

(defun sprig-review--user-block-event (b)
  "Map one block B of a user message to an event, or nil.
A `tool_result' block carries a tool call's output back; a `text' block is
the turn's own prose, which the CLI spells this way as often as it spells
it a bare string."
  (when (consp b)
    (pcase (alist-get 'type b)
      ("tool_result"
       (list 'tool-result
             (or (alist-get 'tool_use_id b) "t")
             (alist-get 'is_error b)
             (string-trim (sprig-review--flatten-content (alist-get 'content b)))))
      ("text"
       (let ((text (string-trim (or (alist-get 'text b) ""))))
         (unless (string-empty-p text) (list 'user text)))))))

(defun sprig-review--user-events (content)
  "Map a user message CONTENT to events.
CONTENT is either the turn's prose as a bare string, or a list of blocks
holding that prose, a tool call's result, or both.  Both spellings of the
prose have to be read: the CLI picks between them per record, so taking
only the string one drops half a session's user turns from the replay."
  (cond
   ((stringp content)
    (unless (string-empty-p (string-trim content))
      (list (list 'user (string-trim content)))))
   ((listp content)
    (delq nil (mapcar #'sprig-review--user-block-event content)))))

(defun sprig-review--stamp-events (record events)
  "Prefix EVENTS with a `time' event carrying RECORD's timestamp.
Returns EVENTS unchanged when it is empty or the record is unstamped, so
no stray `time' event outlives the blocks it was meant to date."
  (let ((ts (alist-get 'timestamp record)))
    (if (and events (stringp ts))
        (cons (list 'time ts) events)
      events)))

(defun sprig-review-session-record-events (record)
  "Map one parsed session-log RECORD (an alist) to a list of events.
Skips sidechain (subagent) records and bookkeeping records that carry no
conversation content.  A conversation record is stamped with its own
`timestamp', so replayed history dates from the log rather than from now."
  (let ((type (alist-get 'type record)))
    (cond
     ((equal type "ai-title")
      (when-let ((tt (alist-get 'aiTitle record))) (list (list 'title tt))))
     ;; A compaction landed: its boundary carries the post-compact token
     ;; count, so a replayed or refreshed log shows the shrunk context.
     ((and (equal type "system")
           (equal (alist-get 'subtype record) "compact_boundary"))
      (when-let ((pt (alist-get 'postTokens
                                (alist-get 'compactMetadata record))))
        (list (list 'context pt))))
     ;; Only the main thread.  A guard, not a filter: a main log holds no
     ;; sidechain records (see the note above), so this fires only if a
     ;; subagent's own file is ever fed through here.
     ((eq (alist-get 'isSidechain record) t) nil)
     ((equal type "assistant")
      (sprig-review--stamp-events
       record
       (append
        (sprig-review--assistant-events
         (alist-get 'content (alist-get 'message record)))
        (sprig-review--usage-context-event
         (alist-get 'usage (alist-get 'message record))))))
     ((equal type "user")
      (let ((mode (alist-get 'permissionMode record))
            (events (sprig-review--user-events
                     (alist-get 'content (alist-get 'message record)))))
        (sprig-review--stamp-events
         record
         (if mode (cons (list 'mode mode) events) events)))))))

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
