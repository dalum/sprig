;;; sprig-session.el --- Session model and stored-log reader for sprig -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.35.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, convenience, ai

;;; Commentary:

;; The session model: the pure data layer behind the transcript buffer
;; (`sprig-session-mode').  `sprig-session-build' folds the
;; backend-neutral event vocabulary (see sprig.el's transport/sink seam)
;; into an ordered list of blocks: assistant text, tool calls with their
;; reconstructed changes and paired results, plans, dialogs, and errors.
;; The renderer projects that model into `magit-section' rows; the model
;; itself knows nothing about the display, so it runs offline under ERT.
;;
;; Reading the CLI's own stored session log lives here too, since a
;; replayed conversation and a live one must fold to the same blocks.
;;
;; The change shape those blocks carry is not defined here: it comes from
;; sprig-change.el, which every surface shares.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'sprig-change)

;;;; Review model
;;
;; `sprig-session-build' folds a list of transport events into a turn
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
;;                   :answered BOOL :answers ANSWERS :stale BOOL :time ISO)
;;   (:type error    :text STR :time ISO)
;;
;; A tool block's `:agent' is the subagent folded onto the `Agent' call it runs
;; under: its progress (`:status', `:agent-type', `:description', `:last-tool',
;; `:tokens', `:tool-uses') and `:steps', the tool calls it made.  A step is
;; itself a tool block, so it renders through the same code and gets a real
;; diff when the subagent edits a file.
;;
;; The progress is live-only, and correctly so: the CLI narrates a running
;; subagent but writes none of that narration to any log, so a replayed
;; `Agent' call has no progress and needs none, the work being over.  The
;; steps outlive the turn by the other route: live they stream in tagged with
;; their parent, and on replay they are read back from the subagent's own
;; file (see `sprig-session-subagent-events').
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
;; `sprig-session-consume').  Either way the stamp lands in the event list
;; itself, which is what keeps it stable: the model is rebuilt from that
;; list on every render, so a time read off the clock here would tick
;; forward under a conversation that had long since finished.

(defun sprig-session--merge-plist (base new)
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

(defun sprig-session--agent-put (block key value)
  "Set KEY to VALUE in BLOCK's `:agent' plist, creating the plist if need be.
`plist-put' cannot grow a nil plist in place, so the result has to be put
back on the block; this keeps that from being spelled out at each call."
  (plist-put block :agent
             (sprig-session--merge-plist (plist-get block :agent)
                                        (list key value))))

(defun sprig-session--find-tool (blocks id)
  "Return the tool block in BLOCKS with ID, finished or not, or nil.
Unlike `sprig-session--find-open-tool', a result does not put the block out
of reach.  Subagent events need that: live they arrive while the `Agent'
call is still open, but a replayed log's are read from the subagent's own
file and folded in after the whole transcript, result and all."
  (seq-find (lambda (b)
              (and (eq (plist-get b :type) 'tool)
                   (equal (plist-get b :id) id)))
            blocks))

(defun sprig-session--find-open-tool (blocks id)
  "Return the tool block in BLOCKS with ID and no result yet, or nil."
  (seq-find (lambda (b)
              (and (eq (plist-get b :type) 'tool)
                   (equal (plist-get b :id) id)
                   (null (plist-get b :result))))
            blocks))

(defun sprig-session--find-dialog (blocks id)
  "Return the dialog block in BLOCKS with ID, or nil."
  (seq-find (lambda (b)
              (and (eq (plist-get b :type) 'dialog)
                   (equal (plist-get b :id) id)))
            blocks))

(defun sprig-session--abandon-dialogs (blocks)
  "Mark every unanswered dialog in BLOCKS as one nothing waits on any more.
A question stops the CLI dead: it is a control request, and the turn cannot
reach its result until the client answers.  So a turn that ends over an open
question ended some other way, an interrupt or a failure or an answer given
somewhere this buffer could not see, and the question died with it.  Left
standing, it went on reading as `waiting on you' in the state line and in
the navigator for the rest of the session, with nothing on screen to answer."
  (dolist (block blocks)
    (when (and (eq (plist-get block :type) 'dialog)
               (not (plist-get block :answered)))
      (plist-put block :stale t))))

(defun sprig-session-pending-dialog (model)
  "Return MODEL's dialog block still waiting on an answer, or nil.
The turn is stopped on it: the CLI asked, and will not go on until it
hears back.  A question the turn outlived is not one of these; see
`sprig-session--abandon-dialogs'."
  (seq-find (lambda (b)
              (and (eq (plist-get b :type) 'dialog)
                   (not (plist-get b :answered))
                   (not (plist-get b :stale))))
            (plist-get model :blocks)))

(defun sprig-session-agent-running (model)
  "Return MODEL's `Agent' block whose subagent is still working, or nil.
A subagent (Task, Explore, ...) runs in the background, so the turn that
launched it can end while its work is still in flight, leaving the turn to
read as over when it is not.  The `Agent' row carries the last status the
CLI narrated for its subagent: \"running\" until a `task_notification'
closes it.  A replayed log records no subagent status, so this is nil there
and only ever fires for a live subagent actually in flight."
  (seq-find (lambda (b)
              (equal (plist-get (plist-get b :agent) :status) "running"))
            (plist-get model :blocks)))

(defun sprig-session--task-created-id (text)
  "Return the id string in a TaskCreate result TEXT, or nil.
The task tool answers a create with \"Task #N created ...\", so a new
task's id is only in the result, never in the call's own input."
  (when (and (stringp text) (string-match "Task #\\([0-9]+\\)" text))
    (match-string 1 text)))

(defun sprig-session--task-apply-update (tasks input)
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

;;;; Event list and its memoised model
;;
;; The event list and the model memo live in the data layer, not the UI
;; layer, so a headless caller (the navigator's status and preview, in
;; sprig.el) shares the one build a session buffer already paid for without
;; pulling in sprig-session-mode (and magit-section) to reach it.

(defvar-local sprig-session--events nil
  "Transport events consumed by this session buffer, most recent first.")
(defvar-local sprig-session--model nil
  "The last-built session model for this buffer, memoised (see below).")
(defvar-local sprig-session--model-head nil
  "The `sprig-session--events' list head `sprig-session--model' was built at.
Every consumed event conses a new head onto the list, so this is `eq' to the
current head exactly when the cached model is still current.")
(defvar-local sprig-session--builder nil
  "Persisted `sprig-session--fold-events' state, for incremental model builds.
Carrying it lets `sprig-session--current-model' fold only the newly-arrived
events into the running fold, instead of re-folding the whole history.")
(defvar-local sprig-session--builder-head nil
  "The `sprig-session--events' head `sprig-session--builder' has folded up to.")
(defvar-local sprig-session--last-fold nil
  "What the last `sprig-session--current-model' did, for the debug log:
`cached', `(incremental . N)', or a `full-...' symbol naming why it had to
rebuild the whole history.")

(defun sprig-session--initial-state ()
  "Return a fresh, empty `sprig-session--fold-events' state.
The state is an opaque list of the fold's accumulators, in the order the
folder and finaliser unpack them: session, title, mode, model, cost, error,
done, context, the pending block timestamp, the reversed block list, the
open text/thinking block, the task list, pending TaskCreate subjects, Task*
tool ids, and the running task snapshot."
  (list nil nil nil nil nil nil nil nil nil '() nil '() '() '() nil))

(defun sprig-session--events-since (events old-head)
  "Return the events in EVENTS newer than OLD-HEAD, and whether OLD-HEAD held.
The car is those events oldest-first, ready to fold; the cdr is t when
OLD-HEAD is still a tail of EVENTS (only events were appended since), so the
running fold can be continued rather than restarted."
  (let ((new '()) (cell events))
    (while (and (consp cell) (not (eq cell old-head)))
      (push (car cell) new)
      (setq cell (cdr cell)))
    (cons new (eq cell old-head))))

(defun sprig-session--state-model (state)
  "Finalise fold STATE into a model plist.
The blocks are deep-copied out, so the running fold may keep mutating its
own blocks in place (a result landing on a call, a delta extending the open
text) without those edits reaching a model already handed out: each build
is an independent value, which is what lets the renderer diff one against
the next by `equal'."
  (pcase-let ((`(,session ,title ,mode ,model ,cost ,error ,done ,context
                 ,_time ,blocks . ,_rest)
               state))
    (list :session session :title title :mode mode :model model
          :cost cost :error error :done done :context context
          :blocks (mapcar #'copy-tree (reverse blocks)))))

(defun sprig-session--current-model ()
  "Return this buffer's session model, folding only what is new since last time.
The same model is wanted by the buffer's own refresh, its state line, and
the navigator's inline preview and status, often several times a second
while a turn streams.  This memoises the last build on the event-list head
\(see `sprig-session--model-head'), so those callers share one build per
event.  And the build itself is incremental: a full fold is O(all events)
and, run per structural event on a long session, is a main source of live
lag, so the running fold state is kept (`sprig-session--builder') and only
the newly-arrived events are folded into it.  It restarts from scratch only
when the event list was replaced rather than appended to (a reseed)."
  (if (eq sprig-session--events sprig-session--model-head)
      (setq sprig-session--last-fold 'cached)
    (let ((delta (and sprig-session--builder sprig-session--builder-head
                      (sprig-session--events-since sprig-session--events
                                                  sprig-session--builder-head))))
      (setq sprig-session--last-fold
            (cond ((not sprig-session--builder) 'full-no-builder)
                  ((not (and delta (cdr delta)))
                   (if delta 'full-not-reached 'full-no-head))
                  (t (cons 'incremental (length (car delta))))))
      (setq sprig-session--builder
            (if (and delta (cdr delta))
                (sprig-session--fold-events sprig-session--builder (car delta))
              (sprig-session--fold-events (sprig-session--initial-state)
                                         (reverse sprig-session--events))))
      (setq sprig-session--builder-head sprig-session--events
            sprig-session--model (sprig-session--state-model sprig-session--builder)
            sprig-session--model-head sprig-session--events)))
  sprig-session--model)

(defun sprig-session-build (events)
  "Fold a list of transport EVENTS into a turn model plist.
See the section commentary for the event vocabulary and block shapes.  This
is the one-shot entry point (a stored log, a preview); the live buffer folds
incrementally through `sprig-session--current-model'."
  (sprig-session--state-model
   (sprig-session--fold-events (sprig-session--initial-state) events)))

(defun sprig-session--fold-events (state events)
  "Fold transport EVENTS into fold STATE, returning the advanced state.
STATE is the opaque accumulator list built by `sprig-session--initial-state';
EVENTS are in order (oldest first).  Blocks accumulate in place, so a state
may be carried across calls to continue a fold (see
`sprig-session--current-model')."
  (pcase-let ((`(,session ,title ,mode ,model ,cost ,error ,done ,context
                 ,time ,blocks ,open ,tasks ,pending-creates ,task-ids
                 ,tasks-block)
               state))
    (let ((snapshot
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
        ;; A turn names the model bare (`claude-opus-5') where the session's
        ;; own init line names it with a context marker (`claude-opus-5[1m]').
        ;; Reporting the same model must not cost us the marker, so only a
        ;; genuinely different model replaces what we have.
        (`(model ,m)
         (when (and (stringp m)
                    (not (and model (string-prefix-p m model))))
           (setq model m)))
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
              (let ((obj (sprig--parse-input input)))
                (push (cons id (or (alist-get 'subject obj) "task"))
                      pending-creates)))
             ("TaskUpdate"
              (setq tasks (sprig-session--task-apply-update
                           tasks (sprig--parse-input input)))
              (funcall snapshot))))
          (t
           (push (list :type 'tool :id id :name name :input input
                       :changes (sprig-tool-changes name input)
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
             (let ((tid (or (sprig-session--task-created-id rtext)
                            (number-to-string (1+ (length tasks))))))
               (setq tasks (append tasks (list (list :id tid :content subject
                                                     :status "pending"))))
               (funcall snapshot))))
          (t
           (let ((blk (sprig-session--find-open-tool blocks id)))
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
         (when-let ((blk (sprig-session--find-tool blocks id)))
           (plist-put blk :agent
                      ;; Merged, not replaced: `task_progress' repeats and
                      ;; carries only what changed, so a plain overwrite would
                      ;; drop the agent type `task_started' named once.
                      (sprig-session--merge-plist (plist-get blk :agent) state))))
        ;; A subagent's step becomes an ordinary tool block, nested under the
        ;; `Agent' row rather than pushed on the transcript.  Being the same
        ;; shape, it renders through the same code and gets a real diff when
        ;; the subagent edits a file.
        (`(subagent-call ,parent ,id ,name ,input)
         (when-let ((blk (sprig-session--find-tool blocks parent)))
           (sprig-session--agent-put
            blk :steps
            (append (plist-get (plist-get blk :agent) :steps)
                    (list (list :type 'tool :id id :name name :input input
                                :changes (sprig-tool-changes name input)
                                :result nil :time time))))))
        (`(subagent-result ,parent ,id ,is-error ,rtext)
         (when-let* ((blk (sprig-session--find-tool blocks parent))
                     (step (sprig-session--find-tool
                            (plist-get (plist-get blk :agent) :steps) id)))
           (plist-put step :result (list :error is-error :text rtext))))
        (`(dialog ,id ,kind ,input)
         (setq open nil)
         ;; A prompt can arrive twice under one id: reattaching to a session
         ;; the CLI is still blocked on re-delivers it (see the broker's
         ;; `reattach_offset'), and the buffer's events outlive the
         ;; disconnect.  Fold the repeat into the block already standing
         ;; rather than pushing a twin: an answer settles the one block it
         ;; finds, so a twin would stay unanswered for good and keep the
         ;; session reading `waiting on you' with no question on screen.
         (if-let ((blk (sprig-session--find-dialog blocks id)))
             (progn (plist-put blk :kind kind)
                    (plist-put blk :input input))
           (push (list :type 'dialog :id id :kind kind :input input
                       :answered nil :answers nil :time time)
                 blocks)))
        (`(dialog-answer ,id ,answers)
         (setq open nil)
         (when-let ((blk (sprig-session--find-dialog blocks id)))
           (plist-put blk :answered t)
           (plist-put blk :answers answers)))
        (`(done ,c ,e)
         (setq done t cost c error e)
         (sprig-session--abandon-dialogs blocks))
        (`(context ,n) (setq context n))
        (`(error ,m)
         (setq open nil)
         (push (list :type 'error :text m :time time) blocks)))
      ;; A run of task ops coalesces into one snapshot; the moment any other
      ;; block reaches the head, that run has ended, so the next task op opens
      ;; a fresh checklist rather than reopening the stale one.
      (when (and tasks-block (not (eq (car blocks) tasks-block)))
        (setq tasks-block nil))))
    ;; Repack the advanced accumulators, in the order `sprig-session--initial-state'
    ;; lays them out, so a later fold can pick this state up.
    (list session title mode model cost error done context time
          blocks open tasks pending-creates task-ids tasks-block)))

(defun sprig-session-events-title (events)
  "Return the freshest title carried by EVENTS, or nil.
EVENTS is a buffer's stored event list, newest first (as pushed by
`sprig-session-consume'), so the first `title' event is the freshest.  The
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
;; That file is a durable event log, so a session buffer can replay full
;; history without sprig keeping any store of its own.  This is the store
;; counterpart of the wire parser in sprig.el: both map their own schema
;; onto the shared event vocabulary that `sprig-session-build' consumes.
;;
;; The log is really a tree: records link by uuid/parentUuid.
;;
;; A subagent leaves nothing here.  Its transcript is written to a file of its
;; own, `<session-id>/subagents/agent-<task-id>.jsonl', with a `.meta.json'
;; naming the `Agent' call it ran under; the main log carries only that call
;; and its result.  So the `isSidechain' skip below never fires on a main log
;; (the flag is set in those separate files, on records this never reads) and
;; is kept as a guard, not as the thing that hides subagent work.

(defun sprig-session-log-path (cwd session-id)
  "Return the session-log path (with a leading ~) for CWD and SESSION-ID.
The path is relative to the session host, so a caller reads it locally or
over SSH.  CWD is encoded the way the CLI names its project directory."
  (format "~/.claude/projects/%s/%s.jsonl"
          (replace-regexp-in-string "[/.]" "-" cwd)
          session-id))

(defun sprig-session--flatten-content (content)
  "Flatten a tool_result CONTENT (string or block list) into text."
  (cond
   ((stringp content) content)
   ((listp content)
    (mapconcat (lambda (b) (if (stringp b) b (or (alist-get 'text b) "")))
               content ""))
   (t (format "%S" content))))

(defun sprig-session--assistant-events (content)
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

(defun sprig-session--usage-context-event (usage)
  "Return a one-element ((context N)) list for a message's USAGE, or nil.
N is the whole prompt the model was given for the turn: new input plus
cache-read plus cache-creation tokens, which is the context-window size in
use.  Output tokens are the reply, not context, so they are left out."
  (when (listp usage)
    (let ((n (+ (or (alist-get 'input_tokens usage) 0)
                (or (alist-get 'cache_read_input_tokens usage) 0)
                (or (alist-get 'cache_creation_input_tokens usage) 0))))
      (when (> n 0) (list (list 'context n))))))

(defun sprig-session--user-block-event (b)
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
             (string-trim (sprig-session--flatten-content (alist-get 'content b)))))
      ("text"
       (let ((text (string-trim (or (alist-get 'text b) ""))))
         (unless (string-empty-p text) (list 'user text)))))))

(defun sprig-session--user-events (content)
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
    (delq nil (mapcar #'sprig-session--user-block-event content)))))

(defun sprig-session--stamp-events (record events)
  "Prefix EVENTS with a `time' event carrying RECORD's timestamp.
Returns EVENTS unchanged when it is empty or the record is unstamped, so
no stray `time' event outlives the blocks it was meant to date."
  (let ((ts (alist-get 'timestamp record)))
    (if (and events (stringp ts))
        (cons (list 'time ts) events)
      events)))

(defun sprig-session-record-events (record)
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
      (sprig-session--stamp-events
       record
       (append
        ;; The log keeps each turn's model, so a replayed session reads the
        ;; model it actually ran on rather than whatever `sprig-model' asks
        ;; for today.
        (when-let ((m (alist-get 'model (alist-get 'message record))))
          (list (list 'model m)))
        (sprig-session--assistant-events
         (alist-get 'content (alist-get 'message record)))
        (sprig-session--usage-context-event
         (alist-get 'usage (alist-get 'message record))))))
     ((equal type "user")
      (let ((mode (alist-get 'permissionMode record))
            (events (sprig-session--user-events
                     (alist-get 'content (alist-get 'message record)))))
        (sprig-session--stamp-events
         record
         (if mode (cons (list 'mode mode) events) events)))))))

(defun sprig-session--parse-session-json (line)
  "Parse one JSONL LINE into a record alist, or nil if it is not one."
  (let ((record (ignore-errors
                  (json-parse-string line :object-type 'alist :array-type 'list
                                     :null-object nil :false-object nil))))
    (and (consp record) record)))

(defun sprig-session-parse-session-line (line)
  "Parse one JSONL session-log LINE into a list of events, or nil."
  (when-let ((record (sprig-session--parse-session-json line)))
    (sprig-session-record-events record)))

(defun sprig-session-log-events (lines)
  "Return the ordered event list parsed from LINES of the session log."
  (apply #'append (mapcar #'sprig-session-parse-session-line lines)))

(defun sprig-session--subagent-block-event (parent block)
  "Map one subagent message BLOCK under PARENT to a step event, or nil."
  (when (consp block)
    (let ((type (alist-get 'type block)))
      (cond
       ((equal type "tool_use")
        (list 'subagent-call parent (or (alist-get 'id block) "t")
              (alist-get 'name block)
              ;; The log stores input as an object; the model takes either
              ;; spelling through `sprig--parse-input', so it is
              ;; passed on as it lies rather than round-tripped through JSON.
              (alist-get 'input block)))
       ((equal type "tool_result")
        (list 'subagent-result parent (or (alist-get 'tool_use_id block) "t")
              (alist-get 'is_error block)
              (string-trim (sprig-session--flatten-content
                            (alist-get 'content block)))))))))

(defun sprig-session-subagent-events (parent lines)
  "Return the step events for the subagent under PARENT, from LINES.
PARENT is the `Agent' tool call the subagent ran under, taken from the
`toolUseId' of the transcript's `.meta.json' sidecar.

The CLI writes a subagent's transcript to a file of its own and mentions
none of it in the session log, so a replayed `Agent' call would otherwise
show only its report, losing the work behind it that a live one shows.
Reading it back here is what keeps a refresh from erasing what you just
watched.

Pure, like the rest of the reader: the caller reads the file (over TRAMP,
for a remote session), so nothing here needs to know where it lives."
  (apply #'append
         (mapcar
          (lambda (line)
            (when-let* ((record (sprig-session--parse-session-json line))
                        (content (alist-get 'content (alist-get 'message record))))
              (delq nil (mapcar (lambda (b)
                                  (sprig-session--subagent-block-event parent b))
                                (and (listp content) content)))))
          lines)))

(defun sprig-session-log-model (lines)
  "Build a session model from LINES of the stored session log."
  (sprig-session-build (sprig-session-log-events lines)))

(provide 'sprig-session)
;;; sprig-session.el ends here
