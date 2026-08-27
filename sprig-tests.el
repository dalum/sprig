;;; sprig-tests.el --- ERT tests for sprig  -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for the process-free layers of sprig: the claude CLI
;; transport (raw stream-json lines -> events), command construction, the
;; session model and diff engine, the stored-session log parser, and the
;; navigator's session enumeration.  Nothing here starts a real session,
;; so the whole suite runs offline.
;;
;; Run with:
;;
;;   emacs -Q --batch -L . -l sprig.el -l sprig-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'sprig)
(require 'sprig-session)

;; Declared special so a test can dynamically bind the context thresholds,
;; which live in `sprig-session-mode' and are not loaded by this suite.
(defvar sprig-context-large-tokens)
(defvar sprig-context-huge-tokens)

;;;; Helpers

;; Small constructors for the CLI's stream-json line shapes.

(defun sprig-tests--init (id)
  (json-serialize (list :type "system" :subtype "init" :session_id id)))

(defun sprig-tests--text (s)
  (json-serialize
   (list :type "stream_event"
         :event (list :type "content_block_delta" :index 0
                      :delta (list :type "text_delta" :text s)))))

(defun sprig-tests--text-block-start ()
  (json-serialize
   (list :type "stream_event"
         :event (list :type "content_block_start" :index 2
                      :content_block (list :type "text")))))

(defun sprig-tests--tool-start (index id name)
  (json-serialize
   (list :type "stream_event"
         :event (list :type "content_block_start" :index index
                      :content_block (list :type "tool_use" :id id :name name)))))

(defun sprig-tests--tool-delta (index fragment)
  (json-serialize
   (list :type "stream_event"
         :event (list :type "content_block_delta" :index index
                      :delta (list :type "input_json_delta"
                                   :partial_json fragment)))))

(defun sprig-tests--tool-stop (index)
  (json-serialize
   (list :type "stream_event"
         :event (list :type "content_block_stop" :index index))))

(defun sprig-tests--result-msg (id text &optional error)
  (json-serialize
   (list :type "user"
         :message (list :content
                        (vector (list :type "tool_result" :tool_use_id id
                                      :content text
                                      :is_error (if error t :false)))))))

(defun sprig-tests--done (&optional cost error)
  (json-serialize (list :type "result"
                        :total_cost_usd (or cost 0.0)
                        :is_error (if error t :false))))

(defun sprig-tests--message-start (input cache-read cache-create)
  (json-serialize
   (list :type "stream_event"
         :event (list :type "message_start"
                      :message (list :usage
                                     (list :input_tokens input
                                           :cache_read_input_tokens cache-read
                                           :cache_creation_input_tokens cache-create))))))

;;;; Transport: claude stream-json -> events

(ert-deftest sprig-test-parse-session ()
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line (sprig-tests--init "sess-1"))
                   '((session "sess-1"))))))

(ert-deftest sprig-test-parse-text ()
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line (sprig-tests--text "hi"))
                   '((text "hi"))))))

(ert-deftest sprig-test-parse-message-start-context ()
  ;; A turn opens with its prompt's token usage; the sum is the context in use.
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    (sprig-tests--message-start 5 190000 2000))
                   '((context 192005))))))

(ert-deftest sprig-test-parse-init-model ()
  ;; The init line names the model the session actually got, and is the only
  ;; line carrying its context marker.  A line without one still yields just
  ;; the session, which is all the CLI used to give us.
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    (json-serialize
                     (list :type "system" :subtype "init" :session_id "s1"
                           :model "claude-opus-5[1m]")))
                   '((session "s1") (model "claude-opus-5[1m]"))))
    (should (equal (sprig--claude-parse-line (sprig-tests--init "s1"))
                   '((session "s1"))))))

(ert-deftest sprig-test-parse-message-start-model-verbatim ()
  ;; A turn opening, captured verbatim off the wire, kept as the ground truth
  ;; for where the model sits: beside the usage in the same `message', and
  ;; without the init line's context marker.
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    (concat "{\"type\":\"stream_event\",\"event\":{\"type\":"
                            "\"message_start\",\"message\":{\"model\":"
                            "\"claude-opus-5\",\"id\":\"msg_011CeQtpSCJTcdKQ\","
                            "\"type\":\"message\",\"role\":\"assistant\","
                            "\"content\":[],\"stop_reason\":null,"
                            "\"usage\":{\"input_tokens\":2,"
                            "\"cache_creation_input_tokens\":7637,"
                            "\"cache_read_input_tokens\":15820,"
                            "\"output_tokens\":3}}},"
                            "\"session_id\":\"09baaed2-0ea7-424b-b421\","
                            "\"parent_tool_use_id\":null,\"ttft_ms\":993}"))
                   '((model "claude-opus-5") (context 23459))))))

(ert-deftest sprig-test-parse-compact-boundary-context ()
  ;; A compaction reports its post-compact size, so the readout drops at once.
  ;; The stream spells the boundary in snake_case, unlike the session log's
  ;; camelCase: reading the log's spelling here matches no live line at all,
  ;; which left the readout stuck at the pre-compact size until a refresh.
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    (json-serialize
                     (list :type "system" :subtype "compact_boundary"
                           :compact_metadata (list :pre_tokens 398861
                                                   :post_tokens 5457))))
                   '((context 5457))))))

(ert-deftest sprig-test-parse-compact-boundary-verbatim ()
  ;; The line above is hand-written, so it can drift from the CLI and still
  ;; agree with itself.  This one is a boundary captured verbatim off the
  ;; wire, kept as the ground truth for the spelling.
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    (concat "{\"type\":\"system\",\"subtype\":\"compact_boundary\","
                            "\"session_id\":\"83cc1bae-9db9-42d6-a092-07e4a0a117dd\","
                            "\"compact_metadata\":{\"trigger\":\"manual\","
                            "\"pre_tokens\":23237,\"post_tokens\":2223,"
                            "\"cumulative_dropped_tokens\":21014,"
                            "\"duration_ms\":31888}}"))
                   '((context 2223))))))

(ert-deftest sprig-test-sink-tracks-compacting ()
  ;; Live state, not model state: a replayed log must not resurrect it.
  (with-temp-buffer
    (cl-letf (((symbol-function 'sprig-session-consume) #'ignore))
      (sprig--review-sink '(compacting t))
      (should sprig--compacting)
      (sprig--review-sink '(compacting nil))
      (should-not sprig--compacting))))

(ert-deftest sprig-test-sink-excludes-transport-from-consume ()
  ;; A control-request/response is transport, not conversation, and must not be
  ;; consumed: consuming pushes onto `sprig-session--events', so an attach's
  ;; `initialize' ack (a control-response) alone would make a reattached buffer
  ;; non-pristine and suppress its background history seed.  Conversation events
  ;; still pass through.
  (with-temp-buffer
    (let ((consumed nil))
      (cl-letf (((symbol-function 'sprig-session-consume)
                 (lambda (ev) (push ev consumed)))
                ((symbol-function 'sprig--status-refresh-soon) #'ignore)
                ((symbol-function 'sprig--interrupt-receipt) #'ignore)
                ((symbol-function 'sprig--answer-control-request) #'ignore))
        (sprig--review-sink '(control-response "sprig-1" "success"))
        (sprig--review-sink '(control-request "sprig-2" (:subtype "x")))
        (should-not consumed)
        (sprig--review-sink '(text "hello"))
        (should (equal consumed '((text "hello"))))))))

(ert-deftest sprig-test-sink-done-clears-compacting ()
  ;; An interrupted compaction need never report a result, and a flag left
  ;; set would leave the line claiming one that stopped with the turn.
  (with-temp-buffer
    (cl-letf (((symbol-function 'sprig-session-consume) #'ignore)
              ((symbol-function 'sprig--status-render) #'ignore))
      (sprig--review-sink '(compacting t))
      (sprig--review-sink '(done nil nil))
      (should-not sprig--compacting))))

(ert-deftest sprig-test-queue-waits-for-the-turn ()
  "`c q' holds a message mid-turn and sends nothing until `done'."
  (with-temp-buffer
    (let ((sent nil))
      (cl-letf (((symbol-function 'sprig-session-consume) #'ignore)
                ((symbol-function 'sprig--status-render) #'ignore)
                ((symbol-function 'sprig--ensure) #'ignore)
                ((symbol-function 'sprig--send-user)
                 (lambda (text) (push text sent))))
        (setq-local sprig--busy t)
        (sprig--review-queue "then update the README")
        ;; Nothing on the wire: the whole point is that it waits.
        (should-not sent)
        (should (equal sprig--queued '("then update the README")))
        (sprig--review-sink '(done nil nil))
        (should (equal sent '("then update the README")))
        (should-not sprig--queued)))))

(ert-deftest sprig-test-queue-sends-outright-when-idle ()
  ;; No turn to wait for means the promise `after this turn' is already kept;
  ;; holding it would strand the message until some later turn happened to end.
  (with-temp-buffer
    (let ((sent nil))
      (cl-letf (((symbol-function 'sprig-session-consume) #'ignore)
                ((symbol-function 'sprig--status-render) #'ignore)
                ((symbol-function 'sprig--ensure) #'ignore)
                ((symbol-function 'sprig--send-user)
                 (lambda (text) (push text sent))))
        (setq-local sprig--busy nil)
        (sprig--review-queue "do it now")
        (should (equal sent '("do it now")))
        (should-not sprig--queued)))))

(ert-deftest sprig-test-queue-flushes-one-turn-at-a-time ()
  ;; Each queued message gets a turn of its own, so two do not run together
  ;; into one message the agent reads as a single instruction.
  (with-temp-buffer
    (let ((sent nil))
      (cl-letf (((symbol-function 'sprig-session-consume) #'ignore)
                ((symbol-function 'sprig--status-render) #'ignore)
                ((symbol-function 'sprig--ensure) #'ignore)
                ((symbol-function 'sprig--send-user)
                 (lambda (text) (push text sent))))
        (setq-local sprig--busy t)
        (sprig--review-queue "first")
        (sprig--review-queue "second")
        (should (equal sprig--queued '("first" "second")))
        (sprig--review-sink '(done nil nil))
        (should (equal (reverse sent) '("first")))
        (should (equal sprig--queued '("second")))
        ;; That send set the busy flag again; its own `done' takes the next.
        (should sprig--busy)
        (sprig--review-sink '(done nil nil))
        (should (equal (reverse sent) '("first" "second")))
        (should-not sprig--queued)))))

(ert-deftest sprig-test-queue-flushes-after-the-done-is-consumed ()
  ;; Ordering: the queued `user' must be folded in after the `done' it waited
  ;; for, or the transcript shows it sent into the turn it queued behind.
  (with-temp-buffer
    (let ((folded nil))
      (cl-letf (((symbol-function 'sprig-session-consume)
                 (lambda (event) (push (car-safe event) folded)))
                ((symbol-function 'sprig--status-render) #'ignore)
                ((symbol-function 'sprig--ensure) #'ignore)
                ((symbol-function 'sprig--send-user) #'ignore))
        (setq-local sprig--busy t)
        (sprig--review-queue "after")
        (sprig--review-sink '(done nil nil))
        (should (equal (reverse folded) '(done user)))))))

(ert-deftest sprig-test-interrupt-keeps-the-queue ()
  ;; An interrupt ends the turn through `done', which flushes like any other:
  ;; a queued message is the next thing, not the rest of this thing, so
  ;; `c i' with one queued reads as `stop, do this instead'.
  (with-temp-buffer
    (let ((sent nil))
      (cl-letf (((symbol-function 'sprig-session-consume) #'ignore)
                ((symbol-function 'sprig--status-render) #'ignore)
                ((symbol-function 'sprig--ensure) #'ignore)
                ((symbol-function 'sprig--send-interrupt) (lambda () "req-1"))
                ((symbol-function 'sprig--send-user)
                 (lambda (text) (push text sent))))
        (setq-local sprig--busy t)
        (sprig--review-queue "do this instead")
        (sprig--interrupt-turn)
        (should (equal sprig--queued '("do this instead")))
        (sprig--review-sink '(done nil nil))
        (should (equal sent '("do this instead")))))))

(ert-deftest sprig-test-drop-queue-spares-the-turn ()
  ;; `c Q' is the only way to take a queued message back: nothing was sent,
  ;; so there is nothing to steer, and `c i' would now send it.  It drops the
  ;; queue and nothing else, leaving the turn running.
  (with-temp-buffer
    (let ((sent nil))
      (cl-letf (((symbol-function 'sprig-session-consume) #'ignore)
                ((symbol-function 'sprig--status-render) #'ignore)
                ((symbol-function 'sprig--ensure) #'ignore)
                ((symbol-function 'sprig--send-user)
                 (lambda (text) (push text sent))))
        (setq-local sprig--busy t)
        (sprig--review-queue "on second thoughts, no")
        (sprig--review-drop-queue)
        (should-not sprig--queued)
        ;; The turn it was queued behind runs on, untouched.
        (should sprig--busy)
        (sprig--review-sink '(done nil nil))
        (should-not sent)))))

(ert-deftest sprig-test-drop-queue-with-nothing-queued ()
  ;; Says so rather than claiming to have dropped nothing.
  (with-temp-buffer
    (setq-local sprig--queued nil)
    (should (equal (sprig--review-drop-queue) "sprig: nothing queued"))))

(ert-deftest sprig-test-unqueue-drops-just-the-one ()
  ;; `k' on a floated message takes a single queued message back, where `c Q'
  ;; drops the lot; the rest of the queue and the running turn are untouched,
  ;; and the survivor still flushes on the next `done'.
  (with-temp-buffer
    (let ((sent nil))
      (cl-letf (((symbol-function 'sprig-session-consume) #'ignore)
                ((symbol-function 'sprig--status-render) #'ignore)
                ((symbol-function 'sprig--ensure) #'ignore)
                ((symbol-function 'sprig--send-user)
                 (lambda (text) (push text sent))))
        (setq-local sprig--busy t)
        (sprig--review-queue "first")
        (sprig--review-queue "second")
        (sprig--review-unqueue "first")
        (should (equal sprig--queued '("second")))
        (should sprig--busy)
        (sprig--review-sink '(done nil nil))
        (should (equal sent '("second")))))))

(ert-deftest sprig-test-unqueue-drops-one-copy-of-a-duplicate ()
  ;; Two of the same text is two separate queued turns, so a single unqueue
  ;; drops one copy, not both.
  (with-temp-buffer
    (setq-local sprig--queued '("dup" "dup"))
    (sprig--review-unqueue "dup")
    (should (equal sprig--queued '("dup")))))

(ert-deftest sprig-test-unqueue-rejects-a-stale-message ()
  ;; The float the caller read is gone from the queue (flushed or dropped
  ;; under it), so there is nothing to take back.
  (with-temp-buffer
    (setq-local sprig--queued '("real"))
    (should-error (sprig--review-unqueue "ghost") :type 'user-error)
    (should (equal sprig--queued '("real")))))

(ert-deftest sprig-test-teardown-drops-the-queue ()
  ;; The session is gone, so there is no turn left for the message to follow.
  (with-temp-buffer
    (cl-letf (((symbol-function 'sprig-session-consume) #'ignore)
              ((symbol-function 'sprig--status-render) #'ignore))
      (setq-local sprig--busy t)
      (setq-local sprig--queued '("later"))
      (sprig--teardown-process)
      (should-not sprig--queued))))

;;;; Working-directory prompt and completion

(ert-deftest sprig-test-host-dir-candidates-come-from-the-scan ()
  "The candidate roots are the distinct cwds of the host's cached sessions.
Order of first appearance is kept and blanks are dropped, so a new session's
prompt suggests the directories work already lives in without any config."
  (cl-letf (((symbol-function 'sprig--status-scan-cached)
             (lambda (_host)
               '((:dir "/a") (:dir nil) (:dir "/b") (:dir "/a") (:dir "/c")))))
    (should (equal (sprig--host-dir-candidates "host") '("/a" "/b" "/c")))))

(ert-deftest sprig-test-subdirs-lists-local-directories ()
  "A local listing returns the subdirectories with a trailing slash, no files."
  (let* ((root (make-temp-file "sprig-dir-test" t))
         (proj (expand-file-name "project" root)))
    (unwind-protect
        (progn
          (make-directory proj)
          (with-temp-file (expand-file-name "readme" root) (insert "x"))
          (let ((subs (sprig--subdirs nil root)))
            (should (member (file-name-as-directory proj) subs))
            (should-not (member (expand-file-name "readme" root) subs))
            (should (cl-every (lambda (s) (string-suffix-p "/" s)) subs))))
      (delete-directory root t))))

(ert-deftest sprig-test-remote-subdirs-parses-the-ls ()
  "A remote listing keeps the slash-suffixed entries and drops plain files,
prefixing each with the directory so the completion stays a full path."
  (cl-letf (((symbol-function 'sprig--remote-sh)
             (lambda (_cmd) "proj/\nfile.txt\nsub/\n")))
    (should (equal (sprig--remote-subdirs "host" "/home/x")
                   '("/home/x/proj/" "/home/x/sub/")))))

(ert-deftest sprig-test-dir-completion-table-completes-a-local-path ()
  "The table completes a path segment against the local filesystem."
  (let* ((root (make-temp-file "sprig-dir-test" t))
         (proj (expand-file-name "project" root)))
    (unwind-protect
        (progn
          (make-directory proj)
          (with-temp-file (expand-file-name "readme" root) (insert "x"))
          (cl-letf (((symbol-function 'sprig--status-scan-cached)
                     (lambda (_) nil)))
            (let ((table (sprig--dir-completion-table nil))
                  (base (file-name-as-directory root)))
              (should (equal (try-completion (concat base "pro") table)
                             (file-name-as-directory proj)))
              (should (member (file-name-as-directory proj)
                              (all-completions base table)))
              (should-not (member (expand-file-name "readme" root)
                                  (all-completions base table))))))
      (delete-directory root t))))

(ert-deftest sprig-test-dir-completion-table-offers-session-roots ()
  "A host's session directories complete even where the live listing is empty,
so the known roots are reachable without an existing path under point."
  (cl-letf (((symbol-function 'sprig--status-scan-cached)
             (lambda (_) '((:dir "/srv/app"))))
            ((symbol-function 'sprig--remote-sh) (lambda (_) "")))
    (let ((table (sprig--dir-completion-table "host")))
      (should (member "/srv/app" (all-completions "/srv/a" table))))))

(ert-deftest sprig-test-dir-completion-table-metadata-skips-the-network ()
  "Metadata and boundary queries answer without listing, so they never shell
out; were they to, this stub would signal."
  (cl-letf (((symbol-function 'sprig--status-scan-cached) (lambda (_) nil))
            ((symbol-function 'sprig--remote-sh)
             (lambda (_) (error "must not run"))))
    (let ((table (sprig--dir-completion-table "host")))
      (should-not (funcall table "x" nil 'metadata))
      (should-not (funcall table "x" nil '(boundaries . ""))))))

(ert-deftest sprig-test-read-review-dir-local-expands ()
  "A local answer is returned as an expanded absolute path; a blank one keeps
`default-directory'."
  (cl-letf (((symbol-function 'sprig--status-scan-cached) (lambda (_) nil)))
    (let ((default-directory "/tmp/"))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "~/proj")))
        (should (equal (sprig--read-review-dir nil)
                       (expand-file-name "~/proj"))))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
        (should (equal (sprig--read-review-dir nil) "/tmp/"))))))

(ert-deftest sprig-test-read-review-dir-remote-is-raw ()
  "A remote answer is returned verbatim: the path lives on the host, a `~' is
expanded over there, and a blank means the login directory."
  (cl-letf (((symbol-function 'sprig--status-scan-cached) (lambda (_) nil)))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "~/work/proj")))
      (should (equal (sprig--read-review-dir "host") "~/work/proj")))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
      (should (equal (sprig--read-review-dir "host") "")))))

(ert-deftest sprig-test-status-roots-lists-the-host-directories ()
  "The roots view lists the host's session directories, each launchable.
It names the host, and each line carries the directory and host it was built
with so `sprig-roots-visit' can start a session there."
  (cl-letf (((symbol-function 'sprig--status-host-at-point) (lambda () "you@srv"))
            ((symbol-function 'sprig--host-dir-candidates)
             (lambda (host) (should (equal host "you@srv")) '("/srv/a" "/srv/b"))))
    (save-window-excursion (sprig-status-roots))
    (unwind-protect
        (with-current-buffer "*sprig-roots*"
          (should (derived-mode-p 'sprig-roots-mode))
          (should (string-match-p "remote you@srv" (buffer-string)))
          (goto-char (point-min))
          (should (re-search-forward "^/srv/a$" nil t))
          (goto-char (match-beginning 0))
          (should (equal (get-text-property (point) 'sprig-root-dir) "/srv/a"))
          (should (equal (get-text-property (point) 'sprig-root-host) "you@srv")))
      (kill-buffer "*sprig-roots*"))))

(ert-deftest sprig-test-status-roots-notes-an-empty-host ()
  "A host with no known session directories yet says so rather than lying
with an empty, actionless list."
  (cl-letf (((symbol-function 'sprig--status-host-at-point) (lambda () nil))
            ((symbol-function 'sprig--host-dir-candidates) (lambda (_) nil)))
    (save-window-excursion (sprig-status-roots))
    (unwind-protect
        (with-current-buffer "*sprig-roots*"
          (should (string-match-p "on local" (buffer-string)))
          (should (string-match-p "No session directories" (buffer-string))))
      (kill-buffer "*sprig-roots*"))))

(ert-deftest sprig-test-roots-visit-starts-a-session-there ()
  "Visiting a root starts a fresh session in it, pinned to the line's host;
a local line (no host) pins to this machine rather than following a remote."
  (let (captured)
    (cl-letf (((symbol-function 'sprig-session-open)
               (lambda (dir &optional id host &rest _)
                 (setq captured (list dir id host))))
              ((symbol-function 'sprig--status-refresh) #'ignore))
      (with-temp-buffer
        (insert "root\n")
        (add-text-properties (point-min) (1- (point-max))
                             '(sprig-root-dir "/srv/a" sprig-root-host "you@srv"))
        (goto-char (point-min))
        (sprig-roots-visit)
        (should (equal captured '("/srv/a" nil "you@srv"))))
      (with-temp-buffer
        (insert "root\n")
        (add-text-properties (point-min) (1- (point-max))
                             '(sprig-root-dir "/home/me"))
        (goto-char (point-min))
        (sprig-roots-visit)
        (should (equal captured '("/home/me" nil t)))))))

(ert-deftest sprig-test-roots-visit-rejects-an-empty-line ()
  "A line with no root under point is a no-op error, not a blank session."
  (with-temp-buffer
    (insert "not a root\n")
    (goto-char (point-min))
    (should-error (sprig-roots-visit) :type 'user-error)))

;;;; Subagents
;;
;; The lines below are captured off the wire from a real `Agent' run (an
;; Explore subagent reading a file), not hand-built: the last time a parse
;; was pinned to an invented shape, the test and the code agreed with each
;; other and with nothing the CLI emits.

(ert-deftest sprig-test-subagent-events-read-a-stored-transcript ()
  "The replay reader turns a subagent's own log into the same step events.
Its transcript is a file of its own that the session log never mentions, so
without this a refreshed `Agent' call would lose the work you just watched."
  (let ((lines (list
                (concat "{\"type\":\"user\",\"isSidechain\":true,"
                        "\"message\":{\"role\":\"user\",\"content\":\"go and look\"}}")
                (concat "{\"type\":\"assistant\",\"isSidechain\":true,"
                        "\"message\":{\"content\":[{\"type\":\"tool_use\","
                        "\"id\":\"toolu_1\",\"name\":\"Read\","
                        "\"input\":{\"file_path\":\"/tmp/n.txt\"}}]}}")
                (concat "{\"type\":\"user\",\"isSidechain\":true,"
                        "\"message\":{\"role\":\"user\",\"content\":"
                        "[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\","
                        "\"content\":\"hello\"}]}}"))))
    (should (equal (sprig-session-subagent-events "toolu_P" lines)
                   ;; The log stores input as an object; the model reads either
                   ;; spelling, so it is passed on as it lies.
                   '((subagent-call "toolu_P" "toolu_1" "Read"
                                    ((file_path . "/tmp/n.txt")))
                     (subagent-result "toolu_P" "toolu_1" nil "hello"))))
    ;; And they fold onto the row exactly as the live ones do.
    (let* ((model (sprig-session-build
                   (append '((tool-call "toolu_P" "Agent" "{}")
                             (tool-result "toolu_P" nil "done"))
                           (sprig-session-subagent-events "toolu_P" lines))))
           (steps (plist-get (plist-get (car (plist-get model :blocks)) :agent) :steps)))
      (should (equal (mapcar (lambda (s) (plist-get s :name)) steps) '("Read")))
      (should (equal (plist-get (plist-get (car steps) :result) :text) "hello")))))

(ert-deftest sprig-test-merge-plist-keeps-what-a-record-omits ()
  ;; Each task record carries its own subset, so a nil means `not carried',
  ;; never `clear it': a plain overwrite would drop the agent type that only
  ;; `task_started' names.
  (should (equal (sprig-session--merge-plist
                  '(:status "running" :agent-type "Explore" :description "old")
                  '(:status "running" :agent-type nil :description "new"))
                 '(:status "running" :agent-type "Explore" :description "new")))
  (should (equal (sprig-session--merge-plist nil '(:status "running"))
                 '(:status "running"))))

(ert-deftest sprig-test-subagent-folds-onto-its-agent-call ()
  "Progress lands on the `Agent' row it runs under, and accumulates."
  (let* ((model (sprig-session-build
                 '((tool-call "toolu_A" "Agent" "{\"description\":\"find it\"}")
                   (subagent "toolu_A" (:status "running" :agent-type "Explore"
                                        :description "starting"))
                   (subagent "toolu_A" (:status "running" :description "Reading note.txt"
                                        :last-tool "Read" :tool-uses 2))
                   (subagent "toolu_A" (:status "completed")))))
         (blk (car (plist-get model :blocks))))
    (should (equal (plist-get blk :name) "Agent"))
    ;; The type survives from the first record; the description follows the last.
    (should (equal (plist-get (plist-get blk :agent) :agent-type) "Explore"))
    (should (equal (plist-get (plist-get blk :agent) :description) "Reading note.txt"))
    (should (equal (plist-get (plist-get blk :agent) :status) "completed"))))

(ert-deftest sprig-test-agent-running-outlives-the-turn ()
  "A background agent still running is detected, so a done turn need not read
as over while its work is in flight."
  (let ((running (sprig-session-build
                  '((tool-call "toolu_A" "Agent" "{\"description\":\"dig\"}")
                    (subagent "toolu_A" (:status "running" :agent-type "Explore"))
                    (done nil nil))))
        (finished (sprig-session-build
                   '((tool-call "toolu_A" "Agent" "{\"description\":\"dig\"}")
                     (subagent "toolu_A" (:status "running" :agent-type "Explore"))
                     (subagent "toolu_A" (:status "completed"))
                     (done nil nil)))))
    ;; Running while the turn is already done: the case the state line is for.
    (should (plist-get running :done))
    (should (sprig-session-agent-running running))
    ;; Its notification closes it, and the turn reads as over again.
    (should-not (sprig-session-agent-running finished))))

(ert-deftest sprig-test-subagent-steps-nest-under-the-agent-call ()
  "A subagent's steps become tool blocks under the `Agent' row, not beside it."
  (let* ((model (sprig-session-build
                 '((text-block) (text "Off we go.")
                   (tool-call "toolu_P" "Agent" "{\"description\":\"find it\"}")
                   (subagent-call "toolu_P" "toolu_1" "Bash" "{\"command\":\"ls\"}")
                   (subagent-result "toolu_P" "toolu_1" nil "total 4")
                   (subagent-call "toolu_P" "toolu_2" "Read" "{\"file_path\":\"/tmp/n.txt\"}")
                   (subagent-result "toolu_P" "toolu_2" nil "hello")
                   (tool-result "toolu_P" nil "It says hello."))))
         (blocks (plist-get model :blocks))
         (agent (seq-find (lambda (b) (equal (plist-get b :name) "Agent")) blocks))
         (steps (plist-get (plist-get agent :agent) :steps)))
    ;; The steps are not blocks of the transcript: the buffer shows the main
    ;; agent's prose and its one `Agent' row, with the work folded inside.
    (should (equal (mapcar (lambda (b) (plist-get b :type)) blocks) '(text tool)))
    (should (equal (mapcar (lambda (s) (plist-get s :name)) steps) '("Bash" "Read")))
    ;; Each keeps its own result, in the order it happened.
    (should (equal (plist-get (plist-get (car steps) :result) :text) "total 4"))
    (should (equal (plist-get (plist-get (cadr steps) :result) :text) "hello"))
    ;; And the `Agent' call still has its own report.
    (should (equal (plist-get (plist-get agent :result) :text) "It says hello."))))

(ert-deftest sprig-test-subagent-steps-land-after-the-agent-has-finished ()
  ;; The replay path reads the steps from the subagent's own file and folds
  ;; them in after the whole transcript, so the `Agent' call already has its
  ;; result by then: a finder that skipped finished blocks would drop them all.
  (let* ((model (sprig-session-build
                 '((tool-call "toolu_P" "Agent" "{}")
                   (tool-result "toolu_P" nil "done")
                   (subagent-call "toolu_P" "toolu_1" "Read" "{\"file_path\":\"/tmp/n\"}")
                   (subagent-result "toolu_P" "toolu_1" nil "hello"))))
         (agent (car (plist-get model :blocks)))
         (steps (plist-get (plist-get agent :agent) :steps)))
    (should (equal (mapcar (lambda (s) (plist-get s :name)) steps) '("Read")))
    (should (equal (plist-get (plist-get (car steps) :result) :text) "hello"))))

(ert-deftest sprig-test-subagent-edit-gets-a-real-diff ()
  ;; A step is an ordinary tool block, so a subagent editing a file shows the
  ;; change the same way the main agent's edit does.
  (let* ((model (sprig-session-build
                 (list '(tool-call "toolu_P" "Agent" "{}")
                       (list 'subagent-call "toolu_P" "toolu_1" "Edit"
                             (json-serialize
                              '(:file_path "/tmp/f.txt" :old_string "a" :new_string "b"))))))
         (step (car (plist-get (plist-get (car (plist-get model :blocks)) :agent) :steps))))
    (should (plist-get step :changes))
    (should (equal (plist-get (car (plist-get step :changes)) :file) "/tmp/f.txt"))))

(ert-deftest sprig-test-subagent-does-not-split-the-agent-prose ()
  ;; The subagent's narration is not the main agent speaking, so it must not
  ;; close the open text block and cut the main agent's prose in two.
  (let ((model (sprig-session-build
                '((text-block) (text "I'll launch an agent. ")
                  (tool-call "toolu_A" "Agent" "{}")
                  (subagent "toolu_A" (:status "running" :description "working"))
                  (text "Done: it says hello.")))))
    (should (equal (mapcar (lambda (b) (plist-get b :type))
                           (plist-get model :blocks))
                   '(text tool text)))))

(defun sprig-tests--incremental-model (chron)
  "Fold CHRON (chronological events) one at a time through the live memo.
Returns the model `sprig-session--current-model' ends on, having taken the
incremental fold path from the second event on."
  (with-temp-buffer
    (dolist (ev chron)
      (push ev sprig-session--events)
      ;; Build after each push, so all but the first fold continue the
      ;; running builder rather than restart it.
      (sprig-session--current-model))
    (sprig-session--current-model)))

(ert-deftest sprig-test-incremental-model-matches-full ()
  ;; The live buffer folds events into a running builder as they arrive; that
  ;; must land on exactly the model a single full build of the same events
  ;; produces, across every block kind that mutates after it is first made:
  ;; coalesced text, a tool gaining its result, a subagent's nested step and
  ;; result, a task checklist, and an answered dialog.
  (dolist (chron
           (list
            '((session "s1") (text "Hel") (text "lo")
              (tool-call "t1" "Edit"
                         "{\"file_path\":\"x\",\"old_string\":\"a\",\"new_string\":\"b\"}")
              (tool-result "t1" nil "ok")
              (text "after") (context 1234) (done 0.02 nil))
            '((tool-call "toolu_P" "Agent" "{}")
              (subagent "toolu_P" (:status "running" :description "go"))
              (subagent-call "toolu_P" "toolu_1" "Read" "{\"file_path\":\"/tmp/n\"}")
              (subagent-result "toolu_P" "toolu_1" nil "hello")
              (tool-result "toolu_P" nil "done"))
            '((tool-call "c1" "TaskCreate" "{\"subject\":\"first\"}")
              (tool-result "c1" nil "id: 7")
              (tool-call "u1" "TaskUpdate"
                         "{\"id\":\"7\",\"status\":\"completed\"}")
              (tool-result "u1" nil "ok")
              (text "moving on"))
            '((dialog "d1" "ask_user_question" "{\"question\":\"pick\"}")
              (dialog-answer "d1" ["yes"]) (text "ok"))))
    (should (equal (sprig-tests--incremental-model chron)
                   (sprig-session-build chron)))))

(ert-deftest sprig-test-incremental-model-independent-copies ()
  ;; Each build is a value of its own: mutating a returned block must not
  ;; reach through the running builder into the next build.
  (with-temp-buffer
    (push '(text "one") sprig-session--events)
    (let ((first (sprig-session--current-model)))
      (plist-put (car (plist-get first :blocks)) :text "TAMPERED")
      (push '(user "two") sprig-session--events)
      (let ((second (sprig-session--current-model)))
        (should (equal (plist-get (car (plist-get second :blocks)) :text)
                       "one"))))))

(ert-deftest sprig-test-parse-task-started ()
  ;; Names the agent and the job it was given.
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    (concat "{\"type\":\"system\",\"subtype\":\"task_started\","
                            "\"task_id\":\"a095acb48e0523216\","
                            "\"tool_use_id\":\"toolu_01P7GYemHFw4irpCEyJ9N7uk\","
                            "\"description\":\"Find note.txt contents\","
                            "\"subagent_type\":\"Explore\","
                            "\"task_type\":\"local_agent\"}"))
                   '((subagent "toolu_01P7GYemHFw4irpCEyJ9N7uk"
                               (:status "running" :agent-type "Explore"
                                :description "Find note.txt contents")))))))

(ert-deftest sprig-test-parse-task-progress ()
  ;; The only event that repeats, so it is what makes the row move.
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    (concat "{\"type\":\"system\",\"subtype\":\"task_progress\","
                            "\"task_id\":\"a095acb48e0523216\","
                            "\"tool_use_id\":\"toolu_01P7GYemHFw4irpCEyJ9N7uk\","
                            "\"description\":\"Running List probe dir and find note.txt\","
                            "\"subagent_type\":\"Explore\","
                            "\"usage\":{\"total_tokens\":7900,\"tool_uses\":1,"
                            "\"duration_ms\":3335},"
                            "\"last_tool_name\":\"Bash\"}"))
                   '((subagent "toolu_01P7GYemHFw4irpCEyJ9N7uk"
                               (:status "running" :agent-type "Explore"
                                :description "Running List probe dir and find note.txt"
                                :last-tool "Bash" :tokens 7900 :tool-uses 1)))))))

(ert-deftest sprig-test-parse-task-notification ()
  ;; Ends the run.  Its `summary' is deliberately not carried: the same prose
  ;; arrives again as the `Agent' call's tool result.
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    (concat "{\"type\":\"system\",\"subtype\":\"task_notification\","
                            "\"task_id\":\"a095acb48e0523216\","
                            "\"tool_use_id\":\"toolu_01P7GYemHFw4irpCEyJ9N7uk\","
                            "\"status\":\"completed\","
                            "\"summary\":\"Found it on the first try.\"}"))
                   '((subagent "toolu_01P7GYemHFw4irpCEyJ9N7uk"
                               (:status "completed")))))))

(ert-deftest sprig-test-parse-task-without-a-tool-use-id ()
  ;; `task_updated' patches by `task_id' alone, so there is no row to hang it
  ;; on; inventing one would be worse than dropping it.
  (with-temp-buffer
    (should-not (sprig--claude-parse-line
                 (concat "{\"type\":\"system\",\"subtype\":\"task_updated\","
                         "\"task_id\":\"a095acb48e0523216\","
                         "\"patch\":{\"status\":\"completed\"}}")))))

(ert-deftest sprig-test-subagent-work-routes-under-its-agent-row ()
  "A subagent's steps go under its `Agent' row, never into the main thread.
Its `tool_use' arrives as a top-level `assistant' record, which is not read
for text, so folding its results into the transcript would strand each as a
loose row with no name: the subagent's `ls' output would read as the main
agent's own work."
  (with-temp-buffer
    ;; Its call.
    (should (equal (sprig--claude-parse-line
                    (concat "{\"type\":\"assistant\","
                            "\"parent_tool_use_id\":\"toolu_PARENT\","
                            "\"message\":{\"content\":[{\"type\":\"tool_use\","
                            "\"id\":\"toolu_014m9t6n5iTQpLReQBTZYR9k\","
                            "\"name\":\"Read\","
                            "\"input\":{\"file_path\":\"/tmp/note.txt\"}}]}}"))
                   '((subagent-call "toolu_PARENT" "toolu_014m9t6n5iTQpLReQBTZYR9k"
                                    "Read" "{\"file_path\":\"/tmp/note.txt\"}"))))
    ;; Its result.
    (should (equal (sprig--claude-parse-line
                    (concat "{\"type\":\"user\","
                            "\"parent_tool_use_id\":\"toolu_PARENT\","
                            "\"message\":{\"role\":\"user\",\"content\":"
                            "[{\"type\":\"tool_result\","
                            "\"tool_use_id\":\"toolu_014m9t6n5iTQpLReQBTZYR9k\","
                            "\"content\":\"hello\"}]}}"))
                   '((subagent-result "toolu_PARENT" "toolu_014m9t6n5iTQpLReQBTZYR9k"
                                      nil "hello"))))
    ;; The `Agent' call's own result carries no parent, and still lands in the
    ;; transcript as an ordinary tool result.
    (should (equal (sprig--claude-parse-line
                    (concat "{\"type\":\"user\","
                            "\"message\":{\"role\":\"user\",\"content\":"
                            "[{\"type\":\"tool_result\","
                            "\"tool_use_id\":\"toolu_PARENT\","
                            "\"content\":\"Found it.\"}]}}"))
                   '((tool-result "toolu_PARENT" nil "Found it."))))))

(ert-deftest sprig-test-parse-compacting-status ()
  ;; A compaction runs for a minute or more, so it is announced, not implied.
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"compacting\"}")
                   '((compacting t))))))

(ert-deftest sprig-test-parse-compact-result-success ()
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    (concat "{\"type\":\"system\",\"subtype\":\"status\",\"status\":null,"
                            "\"compact_result\":\"success\"}"))
                   '((compacting nil))))))

(ert-deftest sprig-test-parse-compact-result-failed ()
  ;; Captured off the wire: the CLI's own `result' for this turn still says
  ;; success, and the reason reaches the reader nowhere else, so a failed
  ;; compaction is silent unless the status line reports it.
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    (concat "{\"type\":\"system\",\"subtype\":\"status\",\"status\":null,"
                            "\"compact_result\":\"failed\","
                            "\"compact_error\":\"Not enough messages to compact.\"}"))
                   '((compacting nil)
                     (error "Compaction failed: Not enough messages to compact."))))))

(ert-deftest sprig-test-parse-status-still-reports-mode ()
  ;; The compaction bracket shares the status line with the permission mode.
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    (concat "{\"type\":\"system\",\"subtype\":\"status\","
                            "\"permissionMode\":\"plan\"}"))
                   '((mode "plan"))))))

(ert-deftest sprig-test-parse-text-block-start ()
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line (sprig-tests--text-block-start))
                   '((text-block))))))

(ert-deftest sprig-test-parse-done ()
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line (sprig-tests--done 0.5 nil))
                   '((done 0.5 nil))))
    (should (equal (sprig--claude-parse-line (sprig-tests--done 0.5 t))
                   '((done 0.5 t))))))

(ert-deftest sprig-test-parse-control-response ()
  ;; The CLI's receipt for a control request we sent: request_id rides
  ;; inside `response', and the subtype ("success"/"error") tells the sink
  ;; whether the request landed.
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    (json-serialize
                     (list :type "control_response"
                           :response (list :subtype "success"
                                           :request_id "sprig-3"))))
                   '((control-response "sprig-3" "success"))))
    (should (equal (sprig--claude-parse-line
                    (json-serialize
                     (list :type "control_response"
                           :response (list :subtype "error"
                                           :request_id "sprig-4"
                                           :error "nope"))))
                   '((control-response "sprig-4" "error"))))))

(ert-deftest sprig-test-interrupt-error-receipt-falls-back ()
  ;; An error receipt for our interrupt means the CLI refused it: kill the
  ;; turn at once instead of waiting out the timeout.
  (with-temp-buffer
    (let (torn)
      (setq sprig--busy t sprig--interrupt-request-id "sprig-7"
            sprig--interrupt-timer nil)
      (cl-letf (((symbol-function 'sprig--teardown-process)
                 (lambda () (setq torn t sprig--busy nil)))
                ((symbol-function 'sprig--status-render) #'ignore))
        (sprig--interrupt-receipt "sprig-7" "error"))
      (should torn)
      (should-not sprig--interrupt-request-id))))

(ert-deftest sprig-test-interrupt-success-receipt-waits ()
  ;; A success receipt only confirms the interrupt landed; the turn still
  ;; ends through `done', so the process is left alone here.
  (with-temp-buffer
    (let (torn)
      (setq sprig--busy t sprig--interrupt-request-id "sprig-7")
      (cl-letf (((symbol-function 'sprig--teardown-process)
                 (lambda () (setq torn t)))
                ((symbol-function 'sprig--status-render) #'ignore))
        (sprig--interrupt-receipt "sprig-7" "success"))
      (should-not torn)
      (should sprig--busy))))

(ert-deftest sprig-test-interrupt-receipt-ignores-other-ids ()
  ;; A receipt for some other control request (e.g. set_permission_mode)
  ;; must not touch an outstanding interrupt.
  (with-temp-buffer
    (let (torn)
      (setq sprig--busy t sprig--interrupt-request-id "sprig-7")
      (cl-letf (((symbol-function 'sprig--teardown-process)
                 (lambda () (setq torn t)))
                ((symbol-function 'sprig--status-render) #'ignore))
        (sprig--interrupt-receipt "sprig-2" "error"))
      (should-not torn)
      (should (equal sprig--interrupt-request-id "sprig-7")))))

(ert-deftest sprig-test-parse-error ()
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    (json-serialize (list :type "system" :subtype "error"
                                          :message "boom")))
                   '((error "boom"))))))

(ert-deftest sprig-test-parse-junk-and-unknown ()
  (with-temp-buffer
    (should-not (sprig--claude-parse-line "not json at all"))
    (should-not (sprig--claude-parse-line
                 (json-serialize (list :type "system" :subtype "whatever"))))))

(ert-deftest sprig-test-parse-tool-call-reassembly ()
  ;; Fragmented input JSON is reassembled across three parse calls.
  (with-temp-buffer
    (should-not (sprig--claude-parse-line (sprig-tests--tool-start 1 "tu1" "Bash")))
    (should-not (sprig--claude-parse-line (sprig-tests--tool-delta 1 "{\"command\":")))
    (should-not (sprig--claude-parse-line (sprig-tests--tool-delta 1 "\"ls -l\"}")))
    (should (equal (sprig--claude-parse-line (sprig-tests--tool-stop 1))
                   '((tool-call "tu1" "Bash" "{\"command\":\"ls -l\"}"))))))

(ert-deftest sprig-test-parse-tool-results ()
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line (sprig-tests--result-msg "tu1" "output"))
                   '((tool-result "tu1" nil "output"))))
    (should (equal (sprig--claude-parse-line (sprig-tests--result-msg "tu2" "bad" t))
                   '((tool-result "tu2" t "bad"))))))

(ert-deftest sprig-test-parse-string-message-does-not-crash ()
  ;; Regression: `let-alist' used to bind `.message.content' eagerly, so a
  ;; user/system message whose `message' is a bare string crashed.
  (with-temp-buffer
    (should-not (sprig--claude-parse-line
                 (json-serialize (list :type "user" :message "hi"))))))

(ert-deftest sprig-test-parse-control-request ()
  ;; An inbound control_request (a tool wants permission) parses to a
  ;; `control-request' event carrying the request id and the request alist.
  (with-temp-buffer
    (let* ((line (json-serialize
                  (list :type "control_request" :request_id "req-7"
                        :request (list :subtype "can_use_tool"
                                       :tool_name "Bash"
                                       :input (list :command "ls")))))
           (events (sprig--claude-parse-line line)))
      (pcase events
        (`((control-request ,id ,req))
         (should (equal id "req-7"))
         (should (equal (alist-get 'subtype req) "can_use_tool"))
         (should (equal (alist-get 'tool_name req) "Bash")))
        (_ (ert-fail (format "unexpected events: %S" events)))))))

;;;; Command construction

(ert-deftest sprig-test-base-args ()
  (with-temp-buffer
    (let ((sprig-model "claude-x")
          (sprig-system-prompt "be brief")
          (sprig-extra-args '("--foo"))
          (sprig--session-id "sess-1"))
      (let ((args (sprig--base-args)))
        (should (member "--model" args))
        (should (member "claude-x" args))
        (should (member "--append-system-prompt" args))
        (should (member "be brief" args))
        (should (member "--resume" args))
        (should (member "sess-1" args))
        (should (member "--foo" args))
        ;; Routes the CLI's interactive control requests to us over stdio,
        ;; which is what enables permission prompts and AskUserQuestion.
        (should (member "--permission-prompt-tool" args))
        (should (member "stdio" args))))
    (let ((sprig-model nil) (sprig-system-prompt nil)
          (sprig-extra-args nil) (sprig--session-id nil))
      (let ((args (sprig--base-args)))
        (should-not (member "--model" args))
        (should-not (member "--append-system-prompt" args))
        (should-not (member "--resume" args))))))

(ert-deftest sprig-test-fork-session-args ()
  ;; A fork resumes its parent and asks the CLI to carry that history on
  ;; under an id of its own, so the parent's log is not written to.
  (with-temp-buffer
    (let ((sprig-model nil) (sprig-system-prompt nil) (sprig-extra-args nil)
          (sprig--session-id "parent-1") (sprig--fork-session t))
      (let ((args (sprig--base-args)))
        (should (member "--resume" args))
        (should (member "parent-1" args))
        (should (member "--fork-session" args))))
    ;; A plain resume never forks, or every send would branch the session.
    (let ((sprig-model nil) (sprig-system-prompt nil) (sprig-extra-args nil)
          (sprig--session-id "parent-1") (sprig--fork-session nil))
      (should-not (member "--fork-session" (sprig--base-args))))
    ;; No session to fork from: nothing to resume, so nothing to fork.
    (let ((sprig-model nil) (sprig-system-prompt nil) (sprig-extra-args nil)
          (sprig--session-id nil) (sprig--fork-session t))
      (should-not (member "--fork-session" (sprig--base-args))))))

(ert-deftest sprig-test-fork-takes-the-new-session-id ()
  ;; The CLI answers a fork with the new session's own id.  It has to replace
  ;; the parent id the fork resumed from, and the fork flag has to clear, or
  ;; the next send would fork the parent again instead of continuing here.
  (with-temp-buffer
    (let ((sprig--session-id "parent-1") (sprig--fork-session t))
      (cl-letf (((symbol-function 'sprig-session-consume) #'ignore))
        (sprig--review-sink '(session "fork-2")))
      (should (equal sprig--session-id "fork-2"))
      (should-not sprig--fork-session)))
  ;; Without a fork, an id already captured stands: the CLI repeats it on
  ;; every resume, and taking it again would be a no-op at best.
  (with-temp-buffer
    (let ((sprig--session-id "sess-1") (sprig--fork-session nil))
      (cl-letf (((symbol-function 'sprig-session-consume) #'ignore))
        (sprig--review-sink '(session "sess-1")))
      (should (equal sprig--session-id "sess-1")))))

(ert-deftest sprig-test-command-local ()
  (with-temp-buffer
    (let ((sprig-remotes nil) (sprig-program "claude") (sprig-directory nil))
      (let ((cmd (sprig--command)))
        (should (equal (car cmd) "claude"))
        (should (member "--input-format" cmd))))))

(ert-deftest sprig-test-command-remote ()
  (with-temp-buffer
    (let ((sprig-remotes '("me@host")) (sprig-program "claude")
          (sprig-ssh-program "ssh") (sprig-ssh-args '("-T" "-A"))
          (sprig-directory "~/proj"))
      (let ((cmd (sprig--command)))
        (should (equal (car cmd) "ssh"))
        (should (member "-T" cmd))
        (should (member "me@host" cmd))
        ;; The remote payload cds into the (tilde-preserving) dir then execs.
        (let ((payload (car (last cmd))))
          (should (string-prefix-p "cd ~/proj && exec claude" payload)))))))

(ert-deftest sprig-test-command-remote-config-dir ()
  ;; A set `sprig-config-directory' rides an `env CLAUDE_CONFIG_DIR=...'
  ;; prefix, after the `cd' and `exec', with the tilde kept live.
  (with-temp-buffer
    (let ((sprig-remotes '("me@host")) (sprig-program "claude")
          (sprig-ssh-program "ssh") (sprig-ssh-args '("-T" "-A"))
          (sprig-directory "~/proj")
          (sprig-config-directory "~/.config/sprig/claude"))
      (let ((payload (car (last (sprig--command)))))
        (should (string-prefix-p
                 "cd ~/proj && exec env CLAUDE_CONFIG_DIR=~/.config/sprig/claude \
claude"
                 payload))))))

;;; The session broker (`sprig-use-broker')

(ert-deftest sprig-test-command-broker-off-is-unchanged ()
  ;; With the flag off, a remote command is exactly the old `cd && exec'.
  (with-temp-buffer
    (let ((sprig-use-broker nil) (sprig-remotes '("me@host"))
          (sprig-program "claude") (sprig-ssh-program "ssh")
          (sprig-ssh-args '("-T" "-A")) (sprig-directory "~/proj"))
      (should (string-prefix-p "cd ~/proj && exec claude"
                               (car (last (sprig--command))))))))

(ert-deftest sprig-test-command-broker-local-is-unchanged ()
  ;; The broker is remote-only: a local session ignores the flag entirely.
  (with-temp-buffer
    (let ((sprig-use-broker t) (sprig-remotes nil) (sprig-program "claude")
          (sprig-directory nil))
      (should (equal (car (sprig--command)) "claude")))))

(ert-deftest sprig-test-broker-command-shape ()
  ;; A brokered remote session runs `python3 BROKER open ... -- <claude argv>'
  ;; over ssh, with the working dir on `--cwd' and the tilde kept live.
  (with-temp-buffer
    (let ((sprig-use-broker t) (sprig-remotes '("me@host"))
          (sprig-program "claude") (sprig-ssh-program "ssh")
          (sprig-ssh-args '("-T" "-A")) (sprig-directory "~/proj")
          (sprig-config-directory nil)
          (sprig-broker-remote-path "~/.local/share/sprig/sprig-broker"))
      (let ((cmd (sprig--command)))
        (should (equal (car cmd) "ssh"))
        (should (member "me@host" cmd))
        (let ((payload (car (last cmd))))
          (should (string-prefix-p
                   "python3 ~/.local/share/sprig/sprig-broker open" payload))
          (should (string-match-p "--program claude" payload))
          (should (string-match-p "--cwd ~/proj" payload))
          ;; The claude argv follows the `--' separator.
          (should (string-match-p " -- .*--input-format" payload))
          ;; A fresh session names no live session to attach to.
          (should-not (string-match-p "--session" payload)))))))

(ert-deftest sprig-test-broker-command-resumes-by-session ()
  ;; A resumed session hands the broker `--session ID' (attach the live one)
  ;; and still carries `--resume ID' in the claude argv (spawn fallback).
  (with-temp-buffer
    (setq sprig--session-id "sess-1")
    (let ((sprig-use-broker t) (sprig-remotes '("me@host"))
          (sprig-program "claude") (sprig-ssh-program "ssh")
          (sprig-ssh-args '("-T" "-A")) (sprig-directory nil)
          (sprig--fork-session nil))
      (let ((payload (car (last (sprig--command)))))
        (should (string-match-p "--session sess-1" payload))
        (should (string-match-p "--resume sess-1" payload))))))

(ert-deftest sprig-test-broker-command-fork-does-not-attach ()
  ;; A fork must NOT pass `--session', or the broker would attach to the
  ;; live parent instead of spawning a forked child.
  (with-temp-buffer
    (setq sprig--session-id "parent-1")
    (let ((sprig-use-broker t) (sprig-remotes '("me@host"))
          (sprig-program "claude") (sprig-ssh-program "ssh")
          (sprig-ssh-args '("-T" "-A")) (sprig-directory nil)
          (sprig--fork-session t))
      (let ((payload (car (last (sprig--command)))))
        (should-not (string-match-p "--session" payload))
        ;; The fork still resumes the parent to seed the new session.
        (should (string-match-p "--resume parent-1" payload))
        (should (string-match-p "--fork-session" payload))))))

(ert-deftest sprig-test-broker-command-config-dir-rides-env ()
  ;; A config dir is passed as `--env CLAUDE_CONFIG_DIR=...', tilde live, so
  ;; the broker sets it on the spawned child.
  (with-temp-buffer
    (let ((sprig-use-broker t) (sprig-remotes '("me@host"))
          (sprig-program "claude") (sprig-ssh-program "ssh")
          (sprig-ssh-args '("-T" "-A")) (sprig-directory nil)
          (sprig-config-directory "~/.config/sprig/claude"))
      (should (string-match-p "--env CLAUDE_CONFIG_DIR=~/.config/sprig/claude"
                              (car (last (sprig--command))))))))

(ert-deftest sprig-test-broker-predicates ()
  ;; nil is off; `remote' and legacy `t' broker remote only; `all' also local.
  (let ((sprig-use-broker nil))
    (should-not (sprig--broker-remote-p))
    (should-not (sprig--broker-local-p)))
  (dolist (v '(t remote))
    (let ((sprig-use-broker v))
      (should (sprig--broker-remote-p))
      (should-not (sprig--broker-local-p))))
  (let ((sprig-use-broker 'all))
    (should (sprig--broker-remote-p))
    (should (sprig--broker-local-p))))

(ert-deftest sprig-test-command-remote-value-leaves-local-direct ()
  ;; `remote' (and legacy `t') brokers remote only: a local session stays a
  ;; plain `claude' child, not a brokered one.
  (with-temp-buffer
    (dolist (v '(t remote))
      (let ((sprig-use-broker v) (sprig-remotes nil) (sprig-program "claude")
            (sprig-directory nil))
        (should (equal (car (sprig--command)) "claude"))))))

(ert-deftest sprig-test-command-all-brokers-local ()
  ;; With `all', a local session runs `python3 BROKER open ... -- <claude argv>'
  ;; as a direct child: a plain argv list (not an ssh string), the broker path
  ;; expanded here, and the claude args unquoted after `--'.
  (with-temp-buffer
    (let ((sprig-use-broker 'all) (sprig-remotes nil) (sprig-program "claude")
          (sprig-directory "~/proj") (sprig-config-directory nil)
          (sprig-broker-remote-path "~/.local/share/sprig/sprig-broker"))
      (let ((cmd (sprig--command)))
        (should (equal (car cmd) "python3"))
        (should (equal (nth 1 cmd)
                       (expand-file-name "~/.local/share/sprig/sprig-broker")))
        (should (equal (nth 2 cmd) "open"))
        (should (member "--program" cmd))
        (should (member "claude" cmd))
        (should (member "--cwd" cmd))
        (should (member (expand-file-name "~/proj") cmd))
        (should (member "--" cmd))
        ;; The claude argv rides as real list elements, never shell-quoted.
        (should (member "--input-format" cmd))
        ;; A fresh session names none to attach to.
        (should-not (member "--session" cmd))))))

(ert-deftest sprig-test-broker-command-local-resume-and-config ()
  ;; A resumed local session passes `--session ID' and `--resume ID', and a
  ;; config dir rides `--env CLAUDE_CONFIG_DIR=' expanded here.
  (with-temp-buffer
    (setq sprig--session-id "sess-1")
    (let ((sprig-use-broker 'all) (sprig-remotes nil) (sprig-program "claude")
          (sprig-directory nil) (sprig--fork-session nil)
          (sprig-config-directory "~/cfg"))
      (let ((cmd (sprig--command)))
        (should (member "--session" cmd))
        (should (member "sess-1" cmd))
        (should (member "--resume" cmd))
        (should (member (concat "CLAUDE_CONFIG_DIR=" (expand-file-name "~/cfg"))
                        cmd))))))

(ert-deftest sprig-test-broker-command-local-attach-only ()
  ;; `sprig--broker-attach-only' adds `--attach-only --no-start' to the local
  ;; command too, so a stale local marker cannot spawn or start a daemon.
  (with-temp-buffer
    (setq sprig--session-id "sess-1")
    (let ((sprig-use-broker 'all) (sprig-remotes nil) (sprig-program "claude")
          (sprig-directory nil) (sprig--fork-session nil)
          (sprig--broker-attach-only t))
      (let ((cmd (sprig--command)))
        (should (member "--attach-only" cmd))
        (should (member "--no-start" cmd)))))
  ;; A normal local open carries neither.
  (with-temp-buffer
    (setq sprig--session-id "sess-1")
    (let ((sprig-use-broker 'all) (sprig-remotes nil) (sprig-program "claude")
          (sprig-directory nil) (sprig--fork-session nil))
      (should-not (member "--attach-only" (sprig--command))))))

(ert-deftest sprig-test-broker-local-runtime-dir ()
  ;; A set XDG_RUNTIME_DIR wins; unset falls back to /run/user/UID when it
  ;; exists, else a private /tmp dir.  The point is determinism: the same
  ;; value every launch, so a daemon and a later reattach agree.
  (let ((process-environment (cons "XDG_RUNTIME_DIR=/run/user/1000"
                                   process-environment)))
    (should (equal (sprig--broker-local-runtime-dir) "/run/user/1000")))
  ;; Unset: `/run/user/UID' when present (this box has one for the test user),
  ;; else the /tmp fallback.  Assert whichever branch applies, but never the
  ;; env (it is unset here).
  (let* ((process-environment
          (seq-remove (lambda (e) (string-prefix-p "XDG_RUNTIME_DIR=" e))
                      process-environment))
         (std (format "/run/user/%d" (user-uid)))
         (got (sprig--broker-local-runtime-dir)))
    (should-not (getenv "XDG_RUNTIME_DIR"))
    (should (equal got (if (file-directory-p std) std
                         (format "/tmp/sprig-broker-%d" (user-uid)))))))

(ert-deftest sprig-test-broker-local-path-expands ()
  ;; The local broker path is `sprig-broker-remote-path' with `~' expanded.
  (let ((sprig-broker-remote-path "~/.local/share/sprig/sprig-broker"))
    (should (equal (sprig--broker-local-path)
                   (expand-file-name "~/.local/share/sprig/sprig-broker")))))

(ert-deftest sprig-test-broker-install-command-is-atomic ()
  ;; The install writes a temp file, marks it executable, then moves it into
  ;; place, so a half-shipped broker is never run.
  (let ((sprig-broker-remote-path "~/.local/share/sprig/sprig-broker"))
    (let ((cmd (sprig--broker-install-command)))
      (should (string-match-p "mkdir -p ~/.local/share/sprig" cmd))
      (should (string-match-p "cat > ~/.local/share/sprig/sprig-broker.tmp" cmd))
      (should (string-match-p "chmod \\+x" cmd))
      (should (string-match-p "mv ~/.local/share/sprig/sprig-broker.tmp ~/.local/share/sprig/sprig-broker"
                              cmd)))))

(ert-deftest sprig-test-ensure-broker-skips-when-current ()
  ;; When the host already reports the expected version, no install runs.
  (let ((sprig-broker-version "1") (installed nil))
    (cl-letf (((symbol-function 'sprig--remote-sh) (lambda (_) "1\n"))
              ((symbol-function 'sprig--install-broker)
               (lambda (_) (setq installed t))))
      (sprig--ensure-broker "me@host")
      (should-not installed))))

(ert-deftest sprig-test-broker-source-matches-file ()
  ;; The embedded broker bytes must match broker/sprig-broker exactly, or a
  ;; host would be shipped a stale script.  Regenerate with broker/embed.py.
  (let* ((dir (file-name-directory
               (or load-file-name buffer-file-name default-directory)))
         (file (expand-file-name "broker/sprig-broker" dir)))
    (skip-unless (file-readable-p file))
    (let ((on-disk (with-temp-buffer
                     (insert-file-contents-literally file)
                     (buffer-string))))
      (should (equal on-disk sprig--broker-source-text)))))

(ert-deftest sprig-test-broker-source-ships-embedded-by-default ()
  ;; With no override, the shipped bytes are the embedded copy; a set
  ;; `sprig-broker-program' reads that file instead.
  (let ((sprig-broker-program nil))
    (should (equal (sprig--broker-source) sprig--broker-source-text))))

(ert-deftest sprig-test-ensure-broker-installs-when-stale ()
  ;; A missing or older broker (version mismatch, or the check erroring) is
  ;; reshipped.
  (let ((sprig-broker-version "1") (installed nil))
    (cl-letf (((symbol-function 'sprig--remote-sh)
               (lambda (_) (error "no such file")))
              ((symbol-function 'sprig--install-broker)
               (lambda (_) (setq installed t))))
      (sprig--ensure-broker "me@host")
      (should installed))))

;;; Broker auto-reattach (`.sprig-live' markers, `sprig-status-auto-reattach')

(ert-deftest sprig-test-live-file-name ()
  ;; The live marker sits beside the log as `<id>.sprig-live', like the star.
  (should (equal (sprig--live-file "/p/-x/abc.jsonl") "/p/-x/abc.sprig-live")))

(ert-deftest sprig-test-broker-command-attach-only ()
  ;; A reattach binds `sprig--broker-attach-only', which adds `--attach-only
  ;; --no-start' so a stale marker can neither spawn nor start a daemon.
  (with-temp-buffer
    (setq sprig--session-id "sess-1")
    (let ((sprig-use-broker t) (sprig-remotes '("me@host")) (sprig-program "claude")
          (sprig-ssh-program "ssh") (sprig-ssh-args '("-T")) (sprig-directory nil)
          (sprig--fork-session nil) (sprig--broker-attach-only t))
      (let ((payload (car (last (sprig--command)))))
        (should (string-match-p "--attach-only" payload))
        (should (string-match-p "--no-start" payload))
        (should (string-match-p "--session sess-1" payload)))))
  ;; A normal open (flag unbound) carries neither.
  (with-temp-buffer
    (setq sprig--session-id "sess-1")
    (let ((sprig-use-broker t) (sprig-remotes '("me@host")) (sprig-program "claude")
          (sprig-ssh-program "ssh") (sprig-ssh-args '("-T")) (sprig-directory nil)
          (sprig--fork-session nil))
      (should-not (string-match-p "--attach-only" (car (last (sprig--command))))))))

(ert-deftest sprig-test-parse-scan-rows-reads-live-flag ()
  ;; The scan blob now carries a live flag between the star flag and the head;
  ;; a `1' becomes :live t, empty becomes nil, and the star still parses.
  (let* ((blob (concat "\036100\037/p/-x/aaa.jsonl\037\037\037T1\0371"
                       "\036090\037/p/-x/bbb.jsonl\0371\037\037\037"))
         (rows (sprig--parse-scan-rows blob nil)))
    (should (= (length rows) 2))
    (should (equal (plist-get (nth 0 rows) :session) "aaa"))
    (should (eq (plist-get (nth 0 rows) :live) t))
    (should-not (plist-get (nth 0 rows) :starred))
    (should-not (plist-get (nth 1 rows) :live))
    (should (eq (plist-get (nth 1 rows) :starred) t))))

(ert-deftest sprig-test-parse-scan-rows-stars-by-id ()
  ;; A `stars' preamble marks a row starred by session id even when the row's
  ;; own per-log star flag is empty (its marker was stranded in another dir when
  ;; the log was re-homed), and a row whose id is absent stays unstarred.  The
  ;; per-log flag still stars on its own, so the two sources union.
  (let* ((blob (concat "\036stars\037aaa\037ccc\037"
                       "\036100\037/p/-x/aaa.jsonl\037\037\037T1\0371"
                       "\036090\037/p/-y/bbb.jsonl\0371\037\037\037"
                       "\036080\037/p/-z/ddd.jsonl\037\037\037\037"))
         (rows (sprig--parse-scan-rows blob nil)))
    (should (= (length rows) 3))
    ;; aaa: starred by the id preamble though its per-log flag is empty
    (should (equal (plist-get (nth 0 rows) :session) "aaa"))
    (should (eq (plist-get (nth 0 rows) :starred) t))
    ;; bbb: absent from the preamble, but its own per-log flag stars it
    (should (equal (plist-get (nth 1 rows) :session) "bbb"))
    (should (eq (plist-get (nth 1 rows) :starred) t))
    ;; ddd: neither source, so unstarred
    (should (equal (plist-get (nth 2 rows) :session) "ddd"))
    (should-not (plist-get (nth 2 rows) :starred))))

(ert-deftest sprig-test-star-write-unstar-clears-strays ()
  ;; A session's log is re-homed across project dirs, stranding an old star.
  ;; `sprig--star-ids-local' finds the star by id wherever it sits, and
  ;; unstarring removes every copy so no stray keeps the session starred.
  (let* ((root (make-temp-file "sprigstar" t))
         (id "ID1")
         (log (expand-file-name "-p-b/ID1.jsonl" root)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "-p-a" root))
          (make-directory (expand-file-name "-p-b" root))
          (write-region "" nil log)
          ;; a stranded star in the old dir and one beside the current log
          (write-region "" nil (expand-file-name "-p-a/ID1.sprig-star" root))
          (write-region "" nil (expand-file-name "-p-b/ID1.sprig-star" root))
          (should (gethash id (sprig--star-ids-local root)))
          (let ((sprig-config-directory nil)
                (sprig-claude-projects-directory root))
            (sprig--star-write log nil nil))
          (should (= 0 (hash-table-count (sprig--star-ids-local root))))
          (should (file-exists-p log)))       ; the log itself is untouched
      (delete-directory root t))))

(ert-deftest sprig-test-status-revert-rearms-reattach ()
  ;; `g' is the "show me what is there now" gesture, so it re-arms
  ;; auto-reattach like a fresh open: an id in the attempted list (a failed
  ;; probe, an earlier disconnect) gets one new try on the scan it triggers.
  (let ((sprig--status-reattach-attempted (list "a" "b")))
    (cl-letf (((symbol-function 'sprig--status-scan-invalidate) #'ignore)
              ((symbol-function 'sprig--status-render) #'ignore))
      (sprig--status-revert))
    (should-not sprig--status-reattach-attempted)))

(ert-deftest sprig-test-verify-live-cleans-what-the-broker-disowns ()
  ;; The broker's `list' answer is the truth about held sessions: a :live row
  ;; it does not name loses its marker and its cached live flag, one it does
  ;; name is untouched, and an answer that is not an ok listing changes
  ;; nothing (a transport hiccup must not strip a genuinely held session).
  (let* ((root (make-temp-file "sprigverify" t))
         (pdir (expand-file-name "-p-a" root)))
    (unwind-protect
        (progn
          (make-directory pdir)
          (write-region "" nil (expand-file-name "DEAD1.sprig-live" pdir))
          (write-region "" nil (expand-file-name "HELD1.sprig-live" pdir))
          (let ((sprig-config-directory nil)
                (sprig-claude-projects-directory root)
                (rows (list (list :session "DEAD1" :live t)
                            (list :session "HELD1" :live t)
                            (list :session "COLD1" :live nil))))
            ;; Not an ok listing: nothing changes.
            (should-not (sprig--verify-live-apply nil rows "garbage"))
            (should (file-exists-p (expand-file-name "DEAD1.sprig-live" pdir)))
            ;; The broker vouches for HELD1 only: DEAD1 is cleaned, HELD1
            ;; and the never-live COLD1 are untouched.
            (should (sprig--verify-live-apply
                     nil rows
                     (concat "{\"ok\": true, \"sessions\": "
                             "[{\"session\": \"s1-1\","
                             " \"cli_session_id\": \"HELD1\"}]}")))
            (should-not (file-exists-p
                         (expand-file-name "DEAD1.sprig-live" pdir)))
            (should (file-exists-p
                     (expand-file-name "HELD1.sprig-live" pdir)))
            ;; Nothing left to clean: a second pass reports no change.
            (should-not (sprig--verify-live-apply
                         nil (list (list :session "HELD1" :live t))
                         "{\"ok\": true, \"sessions\": [{\"cli_session_id\": \"HELD1\"}]}"))))
      (delete-directory root t))))

(ert-deftest sprig-test-remove-live-marker-clears-a-stale-one ()
  ;; A daemon that died without cleanup (machine restart) leaves `.sprig-live'
  ;; markers behind; removing by id clears every copy under the projects root
  ;; and touches nothing else, so the ghost row goes and the log survives.
  (let* ((root (make-temp-file "sprigghost" t))
         (log (expand-file-name "-p-a/ID1.jsonl" root)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "-p-a" root))
          (make-directory (expand-file-name "-p-b" root))
          (write-region "" nil log)
          (write-region "" nil (expand-file-name "-p-a/ID1.sprig-live" root))
          (write-region "" nil (expand-file-name "-p-b/ID1.sprig-live" root))
          (write-region "" nil (expand-file-name "-p-b/ID2.sprig-live" root))
          (let ((sprig-config-directory nil)
                (sprig-claude-projects-directory root))
            (sprig--remove-live-marker "ID1" nil))
          (should-not (file-exists-p
                       (expand-file-name "-p-a/ID1.sprig-live" root)))
          (should-not (file-exists-p
                       (expand-file-name "-p-b/ID1.sprig-live" root)))
          ;; Another session's marker and the log itself are untouched.
          (should (file-exists-p (expand-file-name "-p-b/ID2.sprig-live" root)))
          (should (file-exists-p log)))
      (delete-directory root t))))

(ert-deftest sprig-test-broker-not-held-re-matches-only-proof ()
  ;; The stale-marker cleanup must fire on the broker's own two not-held
  ;; answers and never on a transport failure, which proves nothing.
  (should (string-match-p sprig--broker-not-held-re
                          "sprig-broker: no broker running (session not held)\n"))
  (should (string-match-p sprig--broker-not-held-re
                          "sprig-broker: session not held by broker\n"))
  (should-not (string-match-p sprig--broker-not-held-re
                              "ssh: connect to host opal.local port 22: No route to host\n"))
  (should-not (string-match-p sprig--broker-not-held-re
                              "Connection closed by remote host\n")))

(ert-deftest sprig-test-disconnect-stops-a-held-session ()
  ;; `d' on a broker-held row stops the session on its host (the broker closes
  ;; the child's stdin) rather than leaving it running detached, works without
  ;; an open buffer, marks the id against auto-reattach so a scan that still
  ;; sees the live marker cannot race the stop, and the following reattach
  ;; pass leaves it alone; `o' (connect) lifts the mark again.
  (let ((sprig-use-broker t) (sprig-status-auto-reattach t)
        (sprig--status-reattach-attempted nil) (stops nil) (calls nil)
        (entry (list :session "a" :dir "/d" :host "me@host" :live t)))
    (cl-letf (((symbol-function 'sprig--status-entry-at-point) (lambda () entry))
              ((symbol-function 'sprig--broker-stop-session)
               (lambda (id host) (push (cons id host) stops) t))
              ((symbol-function 'sprig--status-refresh) #'ignore)
              ((symbol-function 'sprig--reattach-session)
               (lambda (dir id host) (push (list dir id host) calls)))
              ((symbol-function 'sprig--title-live-buffer) (lambda (_) nil)))
      (sprig-status-disconnect)                ; no :buffer: held row, not open
      (should (equal stops '(("a" . "me@host"))))
      (should (member "a" sprig--status-reattach-attempted))
      ;; The scan lands afterwards: the stopped session is not reattached.
      (sprig--status-reattach-live "me@host" (list entry))
      (should-not calls)
      ;; A hand reconnect lifts the mark, so auto-reattach serves it again.
      (cl-letf (((symbol-function 'sprig--status-review-buffer)
                 (lambda (_) (current-buffer)))
                ((symbol-function 'sprig-session-connect) #'ignore))
        (with-temp-buffer
          (setq-local sprig--process nil)
          (sprig-status-connect)))
      (should-not (member "a" sprig--status-reattach-attempted)))))

(ert-deftest sprig-test-disconnect-unbrokered-needs-a-connection ()
  ;; With no broker covering the host, `d' still tears down an open buffer's
  ;; live process and never calls the broker; a row with neither a live buffer
  ;; nor a held session is a user error.
  (let ((sprig-use-broker nil) (stops nil)
        (sprig--status-reattach-attempted nil))
    (cl-letf (((symbol-function 'sprig--broker-stop-session)
               (lambda (id host) (push (cons id host) stops) t))
              ((symbol-function 'sprig--status-refresh) #'ignore))
      (with-temp-buffer
        (let* ((buf (current-buffer))
               (proc (make-process :name "sprig-test-sleep"
                                   :command '("sleep" "30") :noquery t)))
          (setq-local sprig--process proc)
          (unwind-protect
              (cl-letf (((symbol-function 'sprig--status-entry-at-point)
                         (lambda () (list :session "a" :host "me@host"
                                          :buffer buf))))
                (sprig-status-disconnect)
                (should-not (process-live-p proc))
                (should-not stops))
            (when (process-live-p proc) (delete-process proc)))))
      (cl-letf (((symbol-function 'sprig--status-entry-at-point)
                 (lambda () (list :session "b" :host "me@host"))))
        (should-error (sprig-status-disconnect) :type 'user-error)))))

(ert-deftest sprig-test-status-reattach-live-attaches-each-once ()
  ;; Each :live row is reattached once; a second pass over the same rows adds
  ;; nothing (the attempted set), and non-live rows are left alone.
  (let ((sprig-use-broker t) (sprig-status-auto-reattach t)
        (sprig--status-reattach-attempted nil) (calls nil))
    (cl-letf (((symbol-function 'sprig--reattach-session)
               (lambda (dir id host) (push (list dir id host) calls)))
              ((symbol-function 'sprig--title-live-buffer) (lambda (_) nil)))
      (let ((rows (list (list :session "a" :dir "/d" :live t)
                        (list :session "b" :dir "/d" :live nil))))
        (sprig--status-reattach-live "me@host" rows)
        (should (equal calls '(("/d" "a" "me@host"))))
        (sprig--status-reattach-live "me@host" rows)
        (should (equal calls '(("/d" "a" "me@host"))))))))

(ert-deftest sprig-test-status-reattach-live-gated ()
  ;; No reattach when the broker is off, auto-reattach is off, or the host is
  ;; local (only remote sessions are brokered).
  (let ((calls nil)
        (rows (list (list :session "a" :dir "/d" :live t))))
    (cl-letf (((symbol-function 'sprig--reattach-session)
               (lambda (&rest _) (push t calls)))
              ((symbol-function 'sprig--title-live-buffer) (lambda (_) nil)))
      (let ((sprig-use-broker nil) (sprig-status-auto-reattach t)
            (sprig--status-reattach-attempted nil))
        (sprig--status-reattach-live "h" rows))
      (let ((sprig-use-broker t) (sprig-status-auto-reattach nil)
            (sprig--status-reattach-attempted nil))
        (sprig--status-reattach-live "h" rows))
      (let ((sprig-use-broker t) (sprig-status-auto-reattach t)
            (sprig--status-reattach-attempted nil))
        (sprig--status-reattach-live nil rows))
      (should-not calls))))

(ert-deftest sprig-test-status-reattach-live-local ()
  ;; With `all', a local (nil-host) :live row reattaches; with `remote' a local
  ;; row does not (local sessions are brokered only under `all').
  (let ((calls nil)
        (rows (list (list :session "a" :dir "/d" :live t))))
    (cl-letf (((symbol-function 'sprig--reattach-session)
               (lambda (dir id host) (push (list dir id host) calls)))
              ((symbol-function 'sprig--title-live-buffer) (lambda (_) nil)))
      (let ((sprig-use-broker 'all) (sprig-status-auto-reattach t)
            (sprig--status-reattach-attempted nil))
        (sprig--status-reattach-live nil rows))
      (should (equal calls '(("/d" "a" nil))))
      (setq calls nil)
      (let ((sprig-use-broker 'remote) (sprig-status-auto-reattach t)
            (sprig--status-reattach-attempted nil))
        (sprig--status-reattach-live nil rows))
      (should-not calls))))

(ert-deftest sprig-test-spawn-flags-attach-only-probe ()
  ;; An attach-only spawn is the navigator's reattach probe; `sprig--spawn' must
  ;; flag its process `:reattach-probe'/`:deliberate' at creation.  A `--no-start'
  ;; probe whose daemon is gone exits nonzero almost at once, so flagging only
  ;; after the spawn returns can miss the window and let the sentinel log a
  ;; spurious "session exited abnormally".  A plain spawn carries neither flag.
  (let ((put nil) (sprig-use-broker nil))
    (cl-letf (((symbol-function 'sprig--make-stderr) (lambda () nil))
              ((symbol-function 'sprig--command) (lambda () (list "true")))
              ((symbol-function 'sprig--send-initialize) #'ignore)
              ((symbol-function 'sprig--directory) (lambda () nil))
              ((symbol-function 'make-process) (lambda (&rest _) 'proc))
              ((symbol-function 'process-put)
               (lambda (_p k v) (push (cons k v) put))))
      (with-temp-buffer
        (let ((sprig--broker-attach-only t)) (sprig--spawn))
        (should (eq t (cdr (assq :reattach-probe put))))
        (should (eq t (cdr (assq :deliberate put)))))
      (setq put nil)
      (with-temp-buffer
        (let ((sprig--broker-attach-only nil)) (sprig--spawn))
        (should-not (assq :reattach-probe put))
        (should-not (assq :deliberate put))))))

(ert-deftest sprig-test-status-collect-marks-broker-held ()
  ;; A scanned session whose log carries a `.sprig-live' marker (the trailing
  ;; live flag) is collected as `held' (alive on its host), not `disconnected',
  ;; so it survives the live filter and shows the held glyph.
  (let ((sprig-remotes '("me@host"))
        (sprig--status-scan-cache nil)
        (sprig-claude-projects-directory "/x"))
    (cl-letf (((symbol-function 'sprig--remote-sh)
               (lambda (_cmd)
                 (concat "\03620.0\037/r/-p/held-1.jsonl\037\037"
                         "{\"cwd\":\"/home/me/p\","
                         "\"timestamp\":\"2026-08-07T14:10:58.784Z\","
                         "\"aiTitle\":\"Held one\"}\037\0371"))))
      (sprig-tests--warm-remote-scan "me@host")
      (let* ((rows (sprig--status-collect))
             (e (seq-find (lambda (r) (equal (plist-get r :session) "held-1"))
                          rows)))
        (should e)
        (should (plist-get e :live))
        (should (eq (plist-get e :status) 'held))
        (should (equal (alist-get 'held sprig--status-glyphs) "◌"))))))

(ert-deftest sprig-test-btw-args ()
  ;; A side question resumes and forks the session so it sees the whole
  ;; conversation, but turns persistence off, so it writes no log and leaves
  ;; the parent untouched.  It carries the model, but routes no permission
  ;; prompts to us (there is no session buffer to answer them in).
  (let ((sprig-model "claude-x") (sprig-system-prompt "be brief")
        (sprig-extra-args '("--foo")))
    (let ((args (sprig--btw-args "sess-1")))
      (should (member "--resume" args))
      (should (member "sess-1" args))
      (should (member "--fork-session" args))
      (should (member "--no-session-persistence" args))
      (should (member "--model" args))
      (should (member "claude-x" args))
      (should (member "--append-system-prompt" args))
      (should (member "--foo" args))
      ;; No stdio permission routing: the one-shot must never block on a
      ;; control request we are not there to answer.
      (should-not (member "--permission-prompt-tool" args))
      (should (member "stream-json" args))))
  ;; Nothing optional set: still forks with persistence off.
  (let ((sprig-model nil) (sprig-system-prompt nil) (sprig-extra-args nil))
    (let ((args (sprig--btw-args "sess-2")))
      (should (member "--no-session-persistence" args))
      (should-not (member "--model" args)))))

(ert-deftest sprig-test-btw-command-local ()
  (let ((sprig-program "claude") (sprig-model nil) (sprig-system-prompt nil)
        (sprig-extra-args nil))
    (let ((cmd (sprig--btw-command "sess-1" nil nil)))
      (should (equal (car cmd) "claude"))
      (should (member "--no-session-persistence" cmd))
      (should (member "sess-1" cmd)))))

(ert-deftest sprig-test-btw-command-remote ()
  ;; A `--resume' is scoped to the cwd's project, so the one-shot cds into the
  ;; session's own dir on the remote host before it execs, exactly as the
  ;; session command does.
  (let ((sprig-program "claude") (sprig-ssh-program "ssh")
        (sprig-ssh-args '("-T" "-A")) (sprig-model nil)
        (sprig-system-prompt nil) (sprig-extra-args nil)
        (sprig-config-directory nil))
    (let ((cmd (sprig--btw-command "sess-1" "~/proj" "me@host")))
      (should (equal (car cmd) "ssh"))
      (should (member "me@host" cmd))
      (let ((payload (car (last cmd))))
        (should (string-prefix-p "cd ~/proj && exec claude" payload))
        (should (string-match-p "--no-session-persistence" payload))))))

(ert-deftest sprig-test-btw-compose ()
  ;; The message leads with the in-flight-turn note (when a turn is live),
  ;; then the marked context, then the question framed as a question.
  (let ((msg (sprig--btw-compose "why?" "the diff" "agent is mid-turn")))
    (should (string-prefix-p "agent is mid-turn" msg))
    (should (string-match-p "Regarding these marked sections:\n\nthe diff" msg))
    (should (string-match-p "Side question.*why\\?" msg)))
  ;; No context and no live turn: just the framed question.
  (let ((msg (sprig--btw-compose "why?" nil nil)))
    (should (string-match-p "Side question.*why\\?" msg))
    (should-not (string-match-p "Regarding" msg))))

(ert-deftest sprig-test-projects-directory ()
  ;; nil config dir falls back to the CLI default; a set one uses its
  ;; `projects/' subdir, keeping a leading tilde for the session host.
  (let ((sprig-claude-projects-directory "~/.claude/projects"))
    (let ((sprig-config-directory nil))
      (should (equal (sprig--projects-directory) "~/.claude/projects")))
    (let ((sprig-config-directory "~/.config/sprig/claude"))
      (should (equal (sprig--projects-directory)
                     "~/.config/sprig/claude/projects")))
    ;; A trailing slash on the config dir does not double up.
    (let ((sprig-config-directory "~/.config/sprig/claude/"))
      (should (equal (sprig--projects-directory)
                     "~/.config/sprig/claude/projects")))))

(ert-deftest sprig-test-login-command ()
  ;; Local: a plain `claude auth login --claudeai' vector.
  (let ((sprig-remotes nil) (sprig-program "claude") (sprig-config-directory nil))
    (should (equal (sprig--login-command)
                   '("claude" "auth" "login" "--claudeai"))))
  ;; Remote with a config dir: an SSH payload carrying the `env' prefix,
  ;; the tilde kept live for the login shell to expand.
  (let ((sprig-remotes '("me@host")) (sprig-program "claude")
        (sprig-ssh-program "ssh") (sprig-ssh-args '("-T" "-A"))
        (sprig-config-directory "~/.config/sprig/claude"))
    (let ((payload (car (last (sprig--login-command)))))
      (should (equal payload
                     "env CLAUDE_CONFIG_DIR=~/.config/sprig/claude \
claude auth login --claudeai")))))

(ert-deftest sprig-test-login-url ()
  ;; The authorize URL is picked out of the CLI's output and stops at
  ;; whitespace, so the trailing prompt text is not swept in.
  (let ((out "Opening browser to sign in…\n\
If the browser didn't open, visit: https://claude.com/cai/oauth/authorize\
?code=true&state=abc\nPaste code here if prompted > "))
    (should (equal (sprig--login-url out)
                   "https://claude.com/cai/oauth/authorize?code=true&state=abc")))
  (should-not (sprig--login-url "no url here")))

(ert-deftest sprig-test-remote-dir-arg ()
  (should (equal (sprig--remote-dir-arg "~") "~"))
  (should (string-prefix-p "~/" (sprig--remote-dir-arg "~/plain")))
  ;; A tilde path with a space keeps the tilde but quotes the rest.
  (should (string-prefix-p "~" (sprig--remote-dir-arg "~/a b")))
  ;; A non-tilde path is shell-quoted whole.
  (should (equal (sprig--remote-dir-arg "/a b") (shell-quote-argument "/a b"))))

(ert-deftest sprig-test-remote-sh-wraps-in-posix-sh ()
  ;; The scan ships POSIX-sh snippets (a `for'-loop, `find', `tail'); a
  ;; non-POSIX login shell such as fish rejects the loop and would strip
  ;; every session of its cwd, so the command is wrapped in `sh -c' and
  ;; never left to the host's login shell.
  (let ((sprig-remotes '("me@host"))
        (sprig-ssh-program "ssh")
        (sprig-ssh-args '("-T" "-A"))
        (command "for f in a b; do echo $f; done")
        captured)
    (cl-letf (((symbol-function 'call-process)
               (lambda (_program _infile _buffer _display &rest args)
                 (setq captured args)
                 0)))
      (sprig--remote-sh command))
    (should (equal captured
                   (list "-T" "-A" "me@host"
                         (concat "sh -c " (shell-quote-argument command)))))))

;;;; Review model and diff engine (sprig-session.el)

(ert-deftest sprig-session-test-lines ()
  ;; A trailing newline does not add a spurious final empty line.
  (should (equal (sprig--lines "foo\nbar\n") '("foo" "bar")))
  (should (equal (sprig--lines "foo\nbar") '("foo" "bar")))
  ;; A blank line inside the text is preserved.
  (should (equal (sprig--lines "a\n\nb") '("a" "" "b")))
  ;; Empty text is no lines, not one empty line.
  (should (equal (sprig--lines "") nil))
  (should (equal (sprig--lines nil) nil)))

(ert-deftest sprig-session-test-edit-changes ()
  (let* ((input (json-serialize
                 (list :file_path "/tmp/x.el" :old_string "old\nline"
                       :new_string "new\nline\nhere")))
         (changes (sprig-tool-changes "Edit" input))
         (change (car changes)))
    (should (= (length changes) 1))
    (should (equal (plist-get change :file) "/tmp/x.el"))
    (should (eq (plist-get change :kind) 'edit))
    (let ((hunk (car (plist-get change :hunks))))
      (should (equal (plist-get hunk :old) '("old" "line")))
      (should (equal (plist-get hunk :new) '("new" "line" "here"))))
    ;; +3 / -2.
    (should (equal (sprig-change-stat change) '(3 . 2)))))

(ert-deftest sprig-session-test-edit-replace-all ()
  (let* ((input (json-serialize
                 (list :file_path "/tmp/x.el" :old_string "a"
                       :new_string "b" :replace_all t)))
         (hunk (car (plist-get (car (sprig-tool-changes "Edit" input))
                               :hunks))))
    (should (eq (plist-get hunk :replace-all) t))))

(ert-deftest sprig-session-test-multiedit-changes ()
  (let* ((input (json-serialize
                 (list :file_path "/tmp/x.el"
                       :edits (vector (list :old_string "a" :new_string "b")
                                      (list :old_string "c" :new_string "d")))))
         (change (car (sprig-tool-changes "MultiEdit" input))))
    (should (= (length (plist-get change :hunks)) 2))
    (should (equal (plist-get (nth 1 (plist-get change :hunks)) :old) '("c")))))

(ert-deftest sprig-session-test-write-changes ()
  (let* ((input (json-serialize
                 (list :file_path "/tmp/new.el" :content "line1\nline2\n")))
         (change (car (sprig-tool-changes "Write" input))))
    (should (eq (plist-get change :kind) 'write))
    (let ((hunk (car (plist-get change :hunks))))
      ;; A write has no removals, only additions.
      (should (null (plist-get hunk :old)))
      (should (equal (plist-get hunk :new) '("line1" "line2"))))
    (should (equal (sprig-change-stat change) '(2 . 0)))))

(ert-deftest sprig-session-test-non-file-tool ()
  (should (null (sprig-tool-changes
                 "Bash" (json-serialize (list :command "ls")))))
  ;; A file tool missing its path yields no change rather than an error.
  (should (null (sprig-tool-changes "Edit" "{}"))))

(ert-deftest sprig-session-test-format-change ()
  (let* ((input (json-serialize
                 (list :file_path "x" :old_string "a\nb" :new_string "c")))
         (change (car (sprig-tool-changes "Edit" input))))
    (should (equal (sprig-format-change change)
                   "x\n-a\n-b\n+c"))))

;;;; Ground-truth diff parser

(ert-deftest sprig-session-test-parse-diff-modified ()
  "A modified file yields an `edit' change with one hunk per change run."
  (let* ((diff (concat "diff --git a/x.el b/x.el\n"
                       "index abc..def 100644\n"
                       "--- a/x.el\n"
                       "+++ b/x.el\n"
                       "@@ -1,3 +1,3 @@\n"
                       " keep\n"
                       "-old\n"
                       "+new\n"
                       " tail\n"))
         (changes (sprig-parse-diff diff))
         (change (car changes)))
    (should (= (length changes) 1))
    (should (equal (plist-get change :file) "x.el"))
    (should (eq (plist-get change :kind) 'edit))
    (should (= (length (plist-get change :hunks)) 1))
    (let ((hunk (car (plist-get change :hunks))))
      ;; Context lines are dropped, matching the tool-payload model.
      (should (equal (plist-get hunk :old) '("old")))
      (should (equal (plist-get hunk :new) '("new"))))
    (should (equal (sprig-change-stat change) '(1 . 1)))))

(ert-deftest sprig-session-test-parse-diff-splits-runs ()
  "Two change runs separated by context in one hunk become two hunks."
  (let* ((diff (concat "diff --git a/x b/x\n--- a/x\n+++ b/x\n"
                       "@@ -1,6 +1,6 @@\n a\n-b\n+B\n c\n d\n-e\n+E\n f\n"))
         (hunks (plist-get (car (sprig-parse-diff diff)) :hunks)))
    (should (= (length hunks) 2))
    (should (equal (plist-get (nth 0 hunks) :old) '("b")))
    (should (equal (plist-get (nth 0 hunks) :new) '("B")))
    (should (equal (plist-get (nth 1 hunks) :old) '("e")))
    (should (equal (plist-get (nth 1 hunks) :new) '("E")))))

(ert-deftest sprig-session-test-parse-diff-new-file ()
  "A new file is a `write': /dev/null old side, all lines added."
  (let* ((diff (concat "diff --git a/n.el b/n.el\n"
                       "new file mode 100644\n"
                       "index 000..abc\n"
                       "--- /dev/null\n"
                       "+++ b/n.el\n"
                       "@@ -0,0 +1,2 @@\n+line1\n+line2\n"))
         (change (car (sprig-parse-diff diff)))
         (hunk (car (plist-get change :hunks))))
    (should (equal (plist-get change :file) "n.el"))
    (should (eq (plist-get change :kind) 'write))
    (should (null (plist-get hunk :old)))
    (should (equal (plist-get hunk :new) '("line1" "line2")))
    (should (equal (sprig-change-stat change) '(2 . 0)))))

(ert-deftest sprig-session-test-parse-diff-deleted-file ()
  "A deleted file is an `edit' with a nil new side (a pure deletion)."
  (let* ((diff (concat "diff --git a/d.el b/d.el\n"
                       "deleted file mode 100644\n"
                       "--- a/d.el\n"
                       "+++ /dev/null\n"
                       "@@ -1,2 +0,0 @@\n-line1\n-line2\n"))
         (change (car (sprig-parse-diff diff)))
         (hunk (car (plist-get change :hunks))))
    (should (equal (plist-get change :file) "d.el"))
    (should (eq (plist-get change :kind) 'edit))
    (should (equal (plist-get hunk :old) '("line1" "line2")))
    (should (null (plist-get hunk :new)))
    (should (equal (sprig-change-stat change) '(0 . 2)))))

(ert-deftest sprig-session-test-parse-diff-multi-file ()
  "Each `diff --git' header starts a fresh file."
  (let* ((diff (concat "diff --git a/one b/one\n--- a/one\n+++ b/one\n"
                       "@@ -1 +1 @@\n-a\n+A\n"
                       "diff --git a/two b/two\n--- a/two\n+++ b/two\n"
                       "@@ -1 +1 @@\n-b\n+B\n"))
         (changes (sprig-parse-diff diff)))
    (should (equal (mapcar (lambda (c) (plist-get c :file)) changes)
                   '("one" "two")))))

(ert-deftest sprig-session-test-parse-diff-content-looks-like-header ()
  "A removed/added line reading `--- '/`+++ ' is content, not a header.
Position disambiguates: once inside a hunk a `-'/`+' line is a change."
  (let* ((diff (concat "diff --git a/md b/md\n--- a/md\n+++ b/md\n"
                       "@@ -1,2 +1,2 @@\n"
                       "---- old rule\n"          ; a removed line "--- old rule"
                       "++++ new rule\n"))        ; an added line "+++ new rule"
         (change (car (sprig-parse-diff diff)))
         (hunk (car (plist-get change :hunks))))
    (should (= (length (sprig-parse-diff diff)) 1))
    (should (equal (plist-get change :file) "md"))
    (should (equal (plist-get hunk :old) '("--- old rule")))
    (should (equal (plist-get hunk :new) '("+++ new rule")))))

(ert-deftest sprig-session-test-parse-diff-unified-carries-positions ()
  "The `:unified' view keeps context lines and numbers every line.
This is what a tool payload can never supply, and what anchors a review
comment to a line."
  (let* ((diff (concat "diff --git a/x.el b/x.el\n--- a/x.el\n+++ b/x.el\n"
                       "@@ -10,3 +10,4 @@ defun foo ()\n"
                       " keep1\n-old\n+new1\n+new2\n keep2\n"))
         (u (car (plist-get (car (sprig-parse-diff diff)) :unified))))
    (should (equal (plist-get u :old-start) 10))
    (should (equal (plist-get u :new-start) 10))
    (should (equal (plist-get u :heading) "defun foo ()"))
    (should (equal (mapcar (lambda (l) (list (plist-get l :kind)
                                             (plist-get l :old)
                                             (plist-get l :new)
                                             (plist-get l :text)))
                           (plist-get u :lines))
                   ;; A removed line has no new-side number and an added
                   ;; one no old-side number: it exists on one side only.
                   '((context 10 10 "keep1")
                     (del     11 nil "old")
                     (add     nil 11 "new1")
                     (add     nil 12 "new2")
                     (context 12 13 "keep2"))))))

(ert-deftest sprig-session-test-parse-diff-unified-counts-default-to-one ()
  "`@@ -30 +31 @@' omits its counts, which a unified diff reads as 1.
The trailing newline must not become a phantom context line either."
  (let* ((diff "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -30 +31 @@\n-z\n+Z\n")
         (u (car (plist-get (car (sprig-parse-diff diff)) :unified))))
    (should (equal (plist-get u :old-count) 1))
    (should (equal (plist-get u :new-count) 1))
    (should (equal (mapcar (lambda (l) (plist-get l :kind))
                           (plist-get u :lines))
                   '(del add)))))

(ert-deftest sprig-session-test-tool-changes-have-no-positions ()
  "A tool payload knows its bytes but never their line, so `:unified' is nil.
Line-anchored review therefore rides the git diff, not the payload."
  (let ((change (car (sprig-tool-changes
                      "Edit" "{\"file_path\":\"/x.el\",\
\"old_string\":\"a\",\"new_string\":\"b\"}"))))
    (should (equal (plist-get change :file) "/x.el"))
    (should (null (plist-get change :unified)))))

(ert-deftest sprig-session-test-parse-diff-binary-skipped ()
  "Binary files carry no hunks and are dropped."
  (let ((diff (concat "diff --git a/img.png b/img.png\n"
                      "Binary files a/img.png and b/img.png differ\n")))
    (should (null (sprig-parse-diff diff)))))

(ert-deftest sprig-session-test-parse-diff-empty ()
  (should (null (sprig-parse-diff "")))
  (should (null (sprig-parse-diff nil))))

(ert-deftest sprig-session-test-parse-diff-round-trips-format ()
  "Parsing then formatting a single-run edit matches the payload path."
  (let* ((diff (concat "diff --git a/x b/x\n--- a/x\n+++ b/x\n"
                       "@@ -1,2 +1,1 @@\n-a\n-b\n+c\n"))
         (change (car (sprig-parse-diff diff))))
    (should (equal (sprig-format-change change) "x\n-a\n-b\n+c"))))

(ert-deftest sprig-session-test-build-coalesces-text ()
  (let* ((model (sprig-session-build
                 '((session "s1") (text "Hello, ") (text "world")
                   (done 0.01 nil))))
         (blocks (plist-get model :blocks)))
    (should (equal (plist-get model :session) "s1"))
    (should (equal (plist-get model :cost) 0.01))
    (should (eq (plist-get model :done) t))
    ;; The two text events coalesce into one block.
    (should (= (length blocks) 1))
    (should (equal (plist-get (car blocks) :text) "Hello, world"))))

(ert-deftest sprig-session-test-build-context-latest-wins ()
  ;; The model tracks the freshest turn's context size, so the header shows
  ;; what the window holds now, not what it held at the first turn.
  (let ((model (sprig-session-build
                '((context 1000) (text "a") (context 5000) (done 0.01 nil)))))
    (should (equal (plist-get model :context) 5000))))

(ert-deftest sprig-session-test-record-usage-becomes-context ()
  ;; A replayed assistant record carries its token usage; the whole prompt
  ;; (input + cache read + cache creation) is the context in use.
  (let* ((line (json-serialize
                (list :type "assistant"
                      :message
                      (list :content (vector (list :type "text" :text "hi"))
                            :usage (list :input_tokens 3
                                         :cache_read_input_tokens 199000
                                         :cache_creation_input_tokens 1000
                                         :output_tokens 50)))))
         (model (sprig-session-build (sprig-session-parse-session-line line))))
    (should (equal (plist-get model :context) (+ 3 199000 1000)))))

(ert-deftest sprig-session-test-log-carries-the-model ()
  ;; A replayed session reads the model each turn actually ran on, rather
  ;; than whatever `sprig-model' happens to ask for today.
  (let* ((line (json-serialize
                (list :type "assistant"
                      :message
                      (list :model "claude-opus-5"
                            :content (vector (list :type "text" :text "hi"))))))
         (model (sprig-session-build (sprig-session-parse-session-line line))))
    (should (equal (plist-get model :model) "claude-opus-5"))))

(ert-deftest sprig-session-test-compact-boundary-becomes-context ()
  ;; A replayed compaction boundary reports its post-compact size, so a
  ;; refreshed log shows the shrunk context without waiting for a new turn.
  (let* ((line (json-serialize
                (list :type "system" :subtype "compact_boundary"
                      :compactMetadata (list :preTokens 398861
                                             :postTokens 5457))))
         (model (sprig-session-build (sprig-session-parse-session-line line))))
    (should (equal (plist-get model :context) 5457))))

(ert-deftest sprig-session-test-build-text-block-splits ()
  (let ((blocks (plist-get
                 (sprig-session-build
                  '((text "one") (text-block) (text "two")))
                 :blocks)))
    (should (= (length blocks) 2))
    (should (equal (plist-get (nth 0 blocks) :text) "one"))
    (should (equal (plist-get (nth 1 blocks) :text) "two"))))

(ert-deftest sprig-session-test-build-pairs-tool-result ()
  (let* ((input (json-serialize (list :file_path "x" :old_string "a"
                                      :new_string "b")))
         (blocks (plist-get
                  (sprig-session-build
                   `((tool-call "t1" "Edit" ,input)
                     (tool-result "t1" nil "done")))
                  :blocks))
         (tool (car blocks)))
    (should (= (length blocks) 1))
    (should (eq (plist-get tool :type) 'tool))
    (should (equal (plist-get tool :name) "Edit"))
    ;; The change is reconstructed from the call's payload.
    (should (plist-get tool :changes))
    ;; The result pairs onto the same block by id.
    (should (equal (plist-get (plist-get tool :result) :text) "done"))
    (should (null (plist-get (plist-get tool :result) :error)))))

(ert-deftest sprig-session-test-build-orphan-result ()
  ;; A result with no matching call is kept, not dropped.
  (let ((blocks (plist-get
                 (sprig-session-build '((tool-result "t9" t "boom")))
                 :blocks)))
    (should (= (length blocks) 1))
    (should (equal (plist-get (plist-get (car blocks) :result) :text) "boom"))
    (should (eq (plist-get (plist-get (car blocks) :result) :error) t))))

;;;; Stored-session log parser (sprig-session.el)

(ert-deftest sprig-session-test-session-path ()
  (should (equal (sprig-session-log-path "/home/dalum/Projects/sprig" "abc")
                 "~/.claude/projects/-home-dalum-Projects-sprig/abc.jsonl"))
  ;; Dots become dashes too, matching the CLI's project-dir naming.
  (should (equal (sprig-session-log-path "/home/x/.cache/p" "id")
                 "~/.claude/projects/-home-x--cache-p/id.jsonl")))

(ert-deftest sprig-session-test-session-parse-assistant ()
  (let* ((line (json-serialize
                (list :type "assistant"
                      :message
                      (list :role "assistant"
                            :content
                            (vector (list :type "thinking" :thinking "hmm")
                                    (list :type "text" :text "hello")
                                    (list :type "tool_use" :id "t1" :name "Bash"
                                          :input (list :command "ls")))))))
         (events (sprig-session-parse-session-line line)))
    (should (equal (nth 0 events) '(thinking "hmm")))
    (should (equal (nth 1 events) '(text "hello")))
    (let ((tc (nth 2 events)))
      (should (eq (car tc) 'tool-call))
      (should (equal (nth 2 tc) "Bash"))
      ;; The input passes through as the parsed object; the diff engine
      ;; reads it the same as a wire-path JSON string.
      (should (null (sprig-tool-changes "Bash" (nth 3 tc)))))))

(ert-deftest sprig-session-test-session-edit-changes ()
  (let* ((line (json-serialize
                (list :type "assistant"
                      :message
                      (list :content
                            (vector (list :type "tool_use" :id "t1" :name "Edit"
                                          :input (list :file_path "a.el"
                                                       :old_string "x"
                                                       :new_string "y")))))))
         (tc (car (sprig-session-parse-session-line line)))
         (changes (sprig-tool-changes (nth 2 tc) (nth 3 tc))))
    (should (equal (plist-get (car changes) :file) "a.el"))))

(ert-deftest sprig-session-test-session-parse-user ()
  (let ((prose (json-serialize
                (list :type "user" :message (list :role "user" :content "do it"))))
        (result (json-serialize
                 (list :type "user"
                       :message (list :content
                                      (vector (list :type "tool_result"
                                                    :tool_use_id "t1"
                                                    :is_error :false
                                                    :content "ok")))))))
    (should (equal (sprig-session-parse-session-line prose) '((user "do it"))))
    (should (equal (sprig-session-parse-session-line result)
                   '((tool-result "t1" nil "ok"))))))

(ert-deftest sprig-session-test-session-parse-user-text-blocks ()
  ;; The CLI spells a user turn's prose either as a bare string or as a list
  ;; of `text' blocks, and picks per record.  Reading only the string form
  ;; drops the block-form turns, so a replayed session shows no user input.
  (let ((blocks (json-serialize
                 (list :type "user"
                       :message (list :role "user"
                                      :content (vector (list :type "text"
                                                             :text "do it"))))))
        ;; A turn can mix its prose with a tool result in the one message.
        (mixed (json-serialize
                (list :type "user"
                      :message
                      (list :content
                            (vector (list :type "tool_result" :tool_use_id "t1"
                                          :is_error :false :content "ok")
                                    (list :type "text" :text "now this")))))))
    (should (equal (sprig-session-parse-session-line blocks) '((user "do it"))))
    (should (equal (sprig-session-parse-session-line mixed)
                   '((tool-result "t1" nil "ok") (user "now this"))))))

(ert-deftest sprig-session-test-session-stamps-records ()
  ;; Every conversation record in the log carries its own timestamp, so a
  ;; replayed turn is dated from the log rather than from whenever it is read.
  (let ((prose (json-serialize
                '(:type "user" :timestamp "2026-07-15T09:16:56.955Z"
                  :message (:role "user" :content "do it"))))
        (reply (json-serialize
                '(:type "assistant" :timestamp "2026-07-15T09:17:01.000Z"
                  :message (:content [(:type "text" :text "on it")])))))
    (should (equal (sprig-session-parse-session-line prose)
                   '((time "2026-07-15T09:16:56.955Z") (user "do it"))))
    (should (equal (sprig-session-parse-session-line reply)
                   '((time "2026-07-15T09:17:01.000Z") (text "on it")))))
  ;; A record carrying no conversation content leaves no stray `time' event
  ;; behind to misdate the next block.
  (let ((empty (json-serialize
                '(:type "user" :timestamp "2026-07-15T09:16:56.955Z"
                  :message (:content [])))))
    (should (null (sprig-session-parse-session-line empty))))
  ;; An unstamped record still parses.
  (let ((bare (json-serialize
               '(:type "user" :message (:role "user" :content "do it")))))
    (should (equal (sprig-session-parse-session-line bare) '((user "do it"))))))

(ert-deftest sprig-session-test-build-stamps-blocks ()
  (let* ((model (sprig-session-build
                 '((time "2026-07-15T09:00:00.000Z")
                   (user "q")
                   (time "2026-07-15T09:01:00.000Z")
                   (text "a") (text "b")
                   (time "2026-07-15T09:02:00.000Z")
                   (tool-call "t1" "Bash" "{}"))))
         (blocks (plist-get model :blocks)))
    (should (equal (plist-get (nth 0 blocks) :time) "2026-07-15T09:00:00.000Z"))
    ;; Coalesced text keeps the stamp of the delta that opened the block, so
    ;; a reply is dated when it started rather than when it finished.
    (should (equal (plist-get (nth 1 blocks) :text) "ab"))
    (should (equal (plist-get (nth 1 blocks) :time) "2026-07-15T09:01:00.000Z"))
    (should (equal (plist-get (nth 2 blocks) :time) "2026-07-15T09:02:00.000Z")))
  ;; A `time' event opens no block of its own.
  (should (null (plist-get (sprig-session-build '((time "2026-07-15T09:00:00.000Z")))
                           :blocks))))

(ert-deftest sprig-session-test-session-parse-user-skips-empty-text ()
  ;; An empty or whitespace-only text block is not a turn.
  (let ((blank (json-serialize
                (list :type "user"
                      :message (list :content (vector (list :type "text"
                                                            :text "  \n")))))))
    (should (null (sprig-session-parse-session-line blank)))))

(ert-deftest sprig-session-test-session-title-and-sidechain ()
  (let ((title (json-serialize (list :type "ai-title" :aiTitle "My title")))
        (side (json-serialize
               (list :type "assistant" :isSidechain t
                     :message (list :content
                                    (vector (list :type "text" :text "sub")))))))
    (should (equal (sprig-session-parse-session-line title) '((title "My title"))))
    ;; Subagent (sidechain) records are skipped.
    (should (null (sprig-session-parse-session-line side)))))

(ert-deftest sprig-session-test-session-model ()
  (let* ((lines (list
                 (json-serialize (list :type "ai-title" :aiTitle "T"))
                 (json-serialize (list :type "attachment" :foo 1)) ; bookkeeping, ignored
                 (json-serialize (list :type "user" :message (list :content "hi")))
                 (json-serialize
                  (list :type "assistant"
                        :message (list :content
                                       (vector (list :type "text" :text "yo")))))))
         (model (sprig-session-log-model lines))
         (blocks (plist-get model :blocks)))
    (should (equal (plist-get model :title) "T"))
    (should (eq (plist-get (nth 0 blocks) :type) 'user))
    (should (equal (plist-get (nth 0 blocks) :text) "hi"))
    (should (eq (plist-get (nth 1 blocks) :type) 'text))
    (should (equal (plist-get (nth 1 blocks) :text) "yo"))))

(ert-deftest sprig-session-test-build-user-and-thinking ()
  (let* ((model (sprig-session-build
                 '((user "q") (thinking "t1") (thinking "t2")
                   (text "a") (title "X"))))
         (blocks (plist-get model :blocks)))
    (should (equal (plist-get model :title) "X"))
    (should (eq (plist-get (nth 0 blocks) :type) 'user))
    ;; Consecutive thinking coalesces; the following text opens a new block.
    (should (eq (plist-get (nth 1 blocks) :type) 'thinking))
    (should (equal (plist-get (nth 1 blocks) :text) "t1t2"))
    (should (eq (plist-get (nth 2 blocks) :type) 'text))))

;;;; Permission mode

(ert-deftest sprig-session-test-parse-status-mode ()
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    (json-serialize (list :type "system" :subtype "status"
                                          :permissionMode "plan")))
                   '((mode "plan"))))))

(ert-deftest sprig-session-test-session-user-mode ()
  ;; A stored user record's permissionMode replays as a `mode' event.
  (should (equal (sprig-session-parse-session-line
                  (json-serialize (list :type "user" :permissionMode "plan"
                                        :message (list :content "go"))))
                 '((mode "plan") (user "go")))))

(ert-deftest sprig-session-test-build-mode ()
  (should (equal (plist-get (sprig-session-build '((mode "plan") (user "x")))
                            :mode)
                 "plan")))

(ert-deftest sprig-session-test-control-request-wire-format ()
  ;; Pin the exact set_permission_mode control_request shape verified
  ;; against the real CLI (it replies control_response success).
  (with-temp-buffer
    (let (sent)
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (_proc s) (setq sent s))))
        (setq sprig--process 'dummy)
        (sprig--set-permission-mode "plan"))
      (let* ((obj (json-parse-string (string-trim sent) :object-type 'alist))
             (request (alist-get 'request obj)))
        (should (equal (alist-get 'type obj) "control_request"))
        (should (string-prefix-p "sprig-" (alist-get 'request_id obj)))
        (should (equal (alist-get 'subtype request) "set_permission_mode"))
        (should (equal (alist-get 'mode request) "plan")))
      (should (equal sprig--permission-mode "plan")))))

(ert-deftest sprig-test-interrupt-wire-format ()
  ;; `c i' sends a bare `interrupt' control_request; the CLI ends the turn
  ;; with a result rather than the process being killed.
  (with-temp-buffer
    (let (sent)
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (_proc s) (setq sent s))))
        (setq sprig--process 'dummy)
        (sprig--send-interrupt))
      (let* ((obj (json-parse-string (string-trim sent) :object-type 'alist))
             (request (alist-get 'request obj)))
        (should (equal (alist-get 'type obj) "control_request"))
        (should (equal (alist-get 'subtype request) "interrupt"))))))

(ert-deftest sprig-test-interrupt-idle-does-nothing ()
  ;; Nothing in flight: no request goes out and no timer is armed.
  (with-temp-buffer
    (let (sent)
      (setq sprig--busy nil sprig--interrupt-timer nil)
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (_proc s) (setq sent s)))
                ((symbol-function 'sprig--status-render) #'ignore))
        (sprig--review-interrupt-owned))
      (should-not sent)
      (should-not sprig--interrupt-timer))))

(ert-deftest sprig-test-interrupt-graceful-keeps-process ()
  ;; A graceful interrupt sends the request, arms the fallback timer, and
  ;; leaves the process alone; the turn's `done' then clears busy and the
  ;; timer, so the session stays live for the next send.
  (with-temp-buffer
    (let ((sprig-interrupt-timeout 60) sent)
      (setq sprig--process 'dummy sprig--busy t sprig--interrupt-timer nil
            sprig--sink #'sprig--review-sink)
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'process-send-string)
                       (lambda (_proc s) (setq sent s)))
                      ((symbol-function 'sprig--status-render) #'ignore))
              (sprig--review-interrupt-owned))
            (should (string-match-p "interrupt"
                                    (alist-get 'subtype
                                               (alist-get 'request
                                                          (json-parse-string
                                                           (string-trim sent)
                                                           :object-type 'alist)))))
            (should (timerp sprig--interrupt-timer))
            (should sprig--process)       ; process not torn down
            ;; The turn ends normally; done clears busy and the timer.
            (cl-letf (((symbol-function 'sprig--status-render) #'ignore)
                      ((symbol-function 'sprig-session-consume) #'ignore))
              (sprig--review-sink '(done nil nil)))
            (should-not sprig--busy)
            (should-not sprig--interrupt-timer))
        (sprig--clear-interrupt)))))

(ert-deftest sprig-test-interrupt-timeout-falls-back ()
  ;; The CLI never ended the turn: the fallback timer kills the process.
  (with-temp-buffer
    (let (torn)
      (setq sprig--busy t sprig--interrupt-timer 'dummy-timer)
      (cl-letf (((symbol-function 'sprig--teardown-process)
                 (lambda () (setq torn t sprig--busy nil)))
                ((symbol-function 'sprig--status-render) #'ignore))
        (sprig--interrupt-timeout (current-buffer)))
      (should torn)
      (should-not sprig--interrupt-timer))))

(ert-deftest sprig-test-initialize-wire-format ()
  ;; The initialize handshake declares the dialog kinds as a JSON array,
  ;; which is what makes the CLI enable AskUserQuestion / ExitPlanMode.
  (with-temp-buffer
    (let ((sprig-supported-dialog-kinds '("ask_user_question" "exit_plan_mode"))
          sent)
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (_proc s) (setq sent s))))
        (setq sprig--process 'dummy)
        (sprig--send-initialize))
      (let* ((obj (json-parse-string (string-trim sent) :object-type 'alist
                                     :array-type 'list))
             (request (alist-get 'request obj)))
        (should (equal (alist-get 'subtype request) "initialize"))
        (should (equal (alist-get 'supportedDialogKinds request)
                       '("ask_user_question" "exit_plan_mode")))))))

(ert-deftest sprig-test-initialize-skipped-when-no-kinds ()
  (with-temp-buffer
    (let ((sprig-supported-dialog-kinds nil) (sent nil))
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (_proc s) (setq sent s))))
        (setq sprig--process 'dummy)
        (sprig--send-initialize))
      (should-not sent))))

(ert-deftest sprig-test-answer-permission-allow ()
  ;; An allowed can_use_tool replies with the success/allow envelope and,
  ;; deliberately, no updatedInput (absent means "run the call unchanged").
  (with-temp-buffer
    (let ((sprig-permission-function (lambda (&rest _) t)) sent)
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (_proc s) (setq sent s))))
        (setq sprig--process 'dummy)
        (sprig--answer-control-request
         "req-7" '((subtype . "can_use_tool") (tool_name . "Bash")
                   (input (command . "ls")))))
      (let* ((obj (json-parse-string (string-trim sent) :object-type 'alist))
             (resp (alist-get 'response obj))
             (decision (alist-get 'response resp)))
        (should (equal (alist-get 'type obj) "control_response"))
        (should (equal (alist-get 'subtype resp) "success"))
        (should (equal (alist-get 'request_id resp) "req-7"))
        (should (equal (alist-get 'behavior decision) "allow"))
        (should-not (alist-get 'updatedInput decision))))))

(ert-deftest sprig-test-answer-permission-deny ()
  (with-temp-buffer
    (let ((sprig-permission-function #'ignore) sent)
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (_proc s) (setq sent s))))
        (setq sprig--process 'dummy)
        (sprig--answer-control-request
         "req-8" '((subtype . "can_use_tool") (tool_name . "Bash"))))
      (let* ((obj (json-parse-string (string-trim sent) :object-type 'alist))
             (decision (alist-get 'response (alist-get 'response obj))))
        (should (equal (alist-get 'behavior decision) "deny"))
        (should (stringp (alist-get 'message decision)))))))

(ert-deftest sprig-test-answer-dialog-cancelled ()
  ;; A tool-driven dialog sprig cannot yet render is cancelled, so the CLI
  ;; falls back to the dialog's default rather than parking the turn.
  (with-temp-buffer
    (let (sent)
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (_proc s) (setq sent s))))
        (setq sprig--process 'dummy)
        (sprig--answer-control-request
         "req-9" '((subtype . "request_user_dialog")
                   (dialog_kind . "ask_user_question"))))
      (let* ((obj (json-parse-string (string-trim sent) :object-type 'alist))
             (decision (alist-get 'response (alist-get 'response obj))))
        (should (equal (alist-get 'behavior decision) "cancelled"))))))

(defun sprig-tests--ask-question-line ()
  "A control_request line carrying a single AskUserQuestion question."
  (json-serialize
   (list :type "control_request" :request_id "req-q"
         :request
         (list :subtype "can_use_tool" :tool_name "AskUserQuestion"
               :input (list :questions
                            (vector (list :question "Favourite colour?"
                                          :header "Colour"
                                          :multiSelect :false
                                          :options (vector (list :label "Red")
                                                           (list :label "Blue")))))))))

(defun sprig-tests--answer-question (answers)
  "Run the question through the wire and answer it with ANSWERS.
Drives the real path: the request is parsed, handed to the buffer as a
dialog, and answered from there.  Returns the reply string."
  (let ((event (car (sprig--claude-parse-line (sprig-tests--ask-question-line))))
        dialog sent)
    (cl-letf (((symbol-function 'process-send-string)
               (lambda (_proc s) (setq sent s)))
              ((symbol-function 'sprig-session-consume)
               (lambda (event) (when (eq (car event) 'dialog) (setq dialog event)))))
      (setq sprig--process 'dummy)
      (pcase event
        (`(control-request ,id ,req) (sprig--answer-control-request id req)))
      ;; The question is now pending; answer it as the buffer would.
      (pcase dialog
        (`(dialog ,id ,_kind ,input)
         (sprig--review-answer-dialog id input answers))))
    sent))

(ert-deftest sprig-test-answer-user-question ()
  ;; The picked label rides back as updatedInput.answers, keyed by question
  ;; text, alongside the echoed questions (the CLI replaces the whole input
  ;; with updatedInput, so the questions array must survive the round trip).
  (with-temp-buffer
    (let ((sent (sprig-tests--answer-question
                 (list (cons (intern "Favourite colour?") "Red")))))
      (let* ((obj (json-parse-string (string-trim sent) :object-type 'alist))
             (decision (alist-get 'response (alist-get 'response obj)))
             (upd (alist-get 'updatedInput decision))
             (answers (alist-get 'answers upd)))
        (should (equal (alist-get 'behavior decision) "allow"))
        (should (vectorp (alist-get 'questions upd))) ; echoed as an array
        ;; `false' must round-trip as JSON false, not null: the tool's
        ;; boolean schema rejects null (caught only end-to-end otherwise).
        (should (eq (alist-get 'multiSelect (aref (alist-get 'questions upd) 0))
                    :false))
        (should (equal (symbol-name (caar answers)) "Favourite colour?"))
        (should (equal (cdar answers) "Red"))))))

(ert-deftest sprig-test-answer-user-question-skip ()
  ;; No answers means "skipped": plain allow, no updatedInput, which replays
  ;; as the tool's own no-answer outcome.
  (with-temp-buffer
    (let ((sent (sprig-tests--answer-question nil)))
      (let* ((obj (json-parse-string (string-trim sent) :object-type 'alist))
             (decision (alist-get 'response (alist-get 'response obj))))
        (should (equal (alist-get 'behavior decision) "allow"))
        (should-not (alist-get 'updatedInput decision))))))

(defun sprig-tests--offer-plan ()
  "Run an ExitPlanMode request through the wire; return the `dialog' event.
Nothing is answered: the plan is only handed to the buffer, which is the
whole of what the filter should do with it."
  (let ((event (car (sprig--claude-parse-line
                     (json-serialize
                      (list :type "control_request" :request_id "req-p"
                            :request (list :subtype "can_use_tool"
                                           :tool_name "ExitPlanMode"
                                           :input (list :plan "# Do the thing\n\nSteps"
                                                        :planFilePath "/tmp/p.md")))))))
        dialog)
    (cl-letf (((symbol-function 'sprig-session-consume)
               (lambda (e) (when (eq (car e) 'dialog) (setq dialog e))))
              ;; Any prompt from the filter is the bug this replaced.
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (error "prompted in the filter")))
              ((symbol-function 'read-string)
               (lambda (&rest _) (error "prompted in the filter"))))
      (pcase event
        (`(control-request ,id ,req) (sprig--answer-control-request id req))))
    dialog))

(defun sprig-tests--answer-plan (approve feedback)
  "Approve or reject the offered plan; return the reply string."
  (let ((dialog (sprig-tests--offer-plan)) sent)
    (cl-letf (((symbol-function 'process-send-string) (lambda (_proc s) (setq sent s)))
              ((symbol-function 'sprig-session-consume) #'ignore))
      (setq sprig--process 'dummy)
      (if approve
          (sprig--review-approve-plan (nth 1 dialog))
        (sprig--review-reject-plan (nth 1 dialog) feedback)))
    sent))

(defun sprig-tests--decision (sent)
  "Extract the decision payload from a control_response SENT string."
  (alist-get 'response (alist-get 'response
                                  (json-parse-string (string-trim sent)
                                                     :object-type 'alist))))

(ert-deftest sprig-test-plan-is-offered-not-prompted ()
  ;; The plan is handed to the buffer to be read and approved there.  It used
  ;; to be a y-or-n-p naming its first line, from inside the process filter,
  ;; over a buffer that rendered the plan nowhere at all.
  (with-temp-buffer
    (let ((dialog (sprig-tests--offer-plan)))
      (should (equal (nth 0 dialog) 'dialog))
      (should (equal (nth 1 dialog) "req-p"))
      (should (equal (nth 2 dialog) "exit_plan_mode"))
      ;; The whole plan rides along, to be rendered.
      (should (equal (alist-get 'plan (nth 3 dialog)) "# Do the thing\n\nSteps")))))

(ert-deftest sprig-test-answer-plan-approve ()
  ;; Approving replies with a bare allow; the CLI itself exits plan mode.
  (with-temp-buffer
    (let ((decision (sprig-tests--decision (sprig-tests--answer-plan t ""))))
      (should (equal (alist-get 'behavior decision) "allow"))
      (should-not (alist-get 'message decision)))))

(ert-deftest sprig-test-answer-plan-reject ()
  ;; Rejecting replies deny with the typed feedback, which the agent
  ;; revises against and re-presents.
  (with-temp-buffer
    (let ((decision (sprig-tests--decision (sprig-tests--answer-plan nil "add French"))))
      (should (equal (alist-get 'behavior decision) "deny"))
      (should (equal (alist-get 'message decision) "add French"))))
  ;; Rejecting with nothing to say still says something.
  (with-temp-buffer
    (let ((decision (sprig-tests--decision (sprig-tests--answer-plan nil ""))))
      (should (equal (alist-get 'behavior decision) "deny"))
      (should (equal (alist-get 'message decision) "Plan rejected.")))))

(defun sprig-tests--permission-request ()
  "Return the `control-request' event for a Bash call wanting permission."
  (car (sprig--claude-parse-line
        (json-serialize
         (list :type "control_request" :request_id "req-b"
               :request (list :subtype "can_use_tool"
                              :tool_name "Bash"
                              :input (list :command "rm -rf /tmp/scratch")))))))

(ert-deftest sprig-test-permission-does-not-block-the-filter ()
  ;; The third and last thing that prompted from inside the process filter.
  ;; It must hand the call to the buffer and return.
  (with-temp-buffer
    (let ((sprig-permission-function nil)
          consumed responded)
      (cl-letf (((symbol-function 'sprig-session-consume)
                 (lambda (event) (push event consumed)))
                ((symbol-function 'sprig--send-control-response)
                 (lambda (&rest _) (setq responded t)))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (error "prompted in the filter"))))
        (pcase (sprig-tests--permission-request)
          (`(control-request ,id ,req) (sprig--answer-control-request id req))))
      (pcase (car consumed)
        (`(dialog ,id ,kind ,req)
         (should (equal id "req-b"))
         (should (equal kind "can_use_tool"))
         ;; The whole request rides along: the rendering wants the tool's name.
         (should (equal (alist-get 'tool_name req) "Bash"))
         (should (equal (alist-get 'command (alist-get 'input req))
                        "rm -rf /tmp/scratch")))
        (other (ert-fail (format "expected a dialog, got %S" other))))
      ;; Nothing said back: the agent waits on you.
      (should-not responded))))

(ert-deftest sprig-test-permission-function-still-decides ()
  ;; A non-nil `sprig-permission-function' keeps its contract, so `always'
  ;; goes on auto-approving and never renders a dialog.
  (with-temp-buffer
    (let ((sprig-permission-function #'always)
          sent dialog)
      (cl-letf (((symbol-function 'process-send-string) (lambda (_p s) (setq sent s)))
                ((symbol-function 'sprig-session-consume)
                 (lambda (e) (when (eq (car e) 'dialog) (setq dialog e)))))
        (setq sprig--process 'dummy)
        (pcase (sprig-tests--permission-request)
          (`(control-request ,id ,req) (sprig--answer-control-request id req))))
      (should-not dialog)
      (should (equal (alist-get 'behavior (sprig-tests--decision sent)) "allow"))))
  ;; And one that denies still denies.
  (with-temp-buffer
    (let ((sprig-permission-function #'ignore)
          sent)
      (cl-letf (((symbol-function 'process-send-string) (lambda (_p s) (setq sent s)))
                ((symbol-function 'sprig-session-consume) #'ignore))
        (setq sprig--process 'dummy)
        (pcase (sprig-tests--permission-request)
          (`(control-request ,id ,req) (sprig--answer-control-request id req))))
      (should (equal (alist-get 'behavior (sprig-tests--decision sent)) "deny")))))

(ert-deftest sprig-test-allow-and-deny-tool ()
  (with-temp-buffer
    (let (sent consumed)
      (cl-letf (((symbol-function 'process-send-string) (lambda (_p s) (setq sent s)))
                ((symbol-function 'sprig-session-consume)
                 (lambda (e) (setq consumed e))))
        (setq sprig--process 'dummy)
        (sprig--review-allow-tool "req-b")
        (let ((decision (sprig-tests--decision sent)))
          (should (equal (alist-get 'behavior decision) "allow"))
          ;; No `updatedInput': the call runs unchanged.
          (should-not (alist-get 'updatedInput decision)))
        (should (equal consumed '(dialog-answer "req-b" "allowed")))
        (sprig--review-deny-tool "req-b")
        (let ((decision (sprig-tests--decision sent)))
          (should (equal (alist-get 'behavior decision) "deny"))
          (should (equal (alist-get 'message decision) "Denied in sprig")))
        (should (equal consumed '(dialog-answer "req-b" "denied")))))))

(ert-deftest sprig-test-safe-quit-response ()
  ;; A quit never approves: a plan or permission denies, a question skips.
  (should (equal (plist-get (sprig--safe-quit-response
                             '((tool_name . "AskUserQuestion")
                               (subtype . "can_use_tool")))
                            :behavior)
                 "allow"))
  (should (equal (plist-get (sprig--safe-quit-response
                             '((tool_name . "ExitPlanMode")
                               (subtype . "can_use_tool")))
                            :behavior)
                 "deny"))
  (should (equal (plist-get (sprig--safe-quit-response
                             '((subtype . "request_user_dialog")))
                            :behavior)
                 "cancelled")))

(ert-deftest sprig-test-mode-line-permission ()
  (with-temp-buffer
    (let ((sprig--permission-mode nil))
      (should-not (sprig--mode-line-permission)))
    (let ((sprig--permission-mode "plan"))
      (should (string-match-p "plan" (sprig--mode-line-permission))))))

;;;; Navigator: enumerating stored CLI sessions as branches (option A)

(defun sprig-tests--make-session-log (root proj id &rest records)
  "Write RECORDS (alists) as a session log ID.jsonl for project PROJ under ROOT.
Return the log directory."
  (let ((logdir (expand-file-name
                 (replace-regexp-in-string "[/.]" "-" (directory-file-name proj))
                 root)))
    (make-directory logdir t)
    (with-temp-file (expand-file-name (concat id ".jsonl") logdir)
      (dolist (r records) (insert (json-serialize r) "\n")))
    logdir))

(ert-deftest sprig-test-title-clean ()
  ;; The agent's answer is reduced to one tidy title line: first non-blank
  ;; line, quotes and list/heading markup stripped, trailing punctuation
  ;; dropped, length capped, and nothing usable yields nil.
  (should (equal (sprig--title-clean "Refactor the parser") "Refactor the parser"))
  (should (equal (sprig--title-clean "\"Quoted title\"") "Quoted title"))
  (should (equal (sprig--title-clean "- Fix the streaming bug.") "Fix the streaming bug"))
  (should (equal (sprig--title-clean "## Heading title") "Heading title"))
  (should (equal (sprig--title-clean "First line\n\nmore chatter") "First line"))
  (should (equal (sprig--title-clean "  \n  Real title  ") "Real title"))
  (should (null (sprig--title-clean "")))
  (should (null (sprig--title-clean "   \n  ")))
  (should (<= (length (sprig--title-clean (make-string 200 ?a))) 80)))

(ert-deftest sprig-test-log-title-prefers-custom ()
  ;; A user `customTitle' beats the generated `aiTitle', wherever they sit,
  ;; so a later re-emitted `aiTitle' never buries the rename.
  (should (equal (sprig--log-title
                  (concat "\"aiTitle\":\"Generated\"\n"
                          "\"customTitle\":\"By the user\"\n"
                          "\"aiTitle\":\"Generated again\"\n"))
                 "By the user"))
  ;; With no custom title, the last generated one wins.
  (should (equal (sprig--log-title
                  (concat "\"aiTitle\":\"First\"\n\"aiTitle\":\"Second\"\n"))
                 "Second"))
  ;; The last of several custom titles wins.
  (should (equal (sprig--log-title
                  (concat "\"customTitle\":\"Old\"\n\"customTitle\":\"New\"\n"))
                 "New")))

(ert-deftest sprig-test-retitle-persist-writes-custom-title ()
  ;; A retitle writes the CLI's own rename records (`custom-title' plus
  ;; `agent-name'), not an `ai-title', so the CLI never regenerates it away.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/records")
         (sprig-remotes nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj "sess-rec"
           `(:type "user" :cwd ,proj :message (:role "user" :content "hi")))
          (should (sprig--title-persist "sess-rec" nil "A tidy name"))
          (let ((log (with-temp-buffer
                       (insert-file-contents
                        (car (directory-files-recursively
                              root "\\`sess-rec\\.jsonl\\'")))
                       (buffer-string))))
            (should (string-match-p "\"type\":\"custom-title\"" log))
            (should (string-match-p "\"type\":\"agent-name\"" log))
            (should (string-match-p "A tidy name" log))
            (should-not (string-match-p "ai-title" log))))
      (delete-directory root t))))

(ert-deftest sprig-test-retitle-persist-small ()
  ;; A retitle's user title beats the CLI's generated one; for a log inside
  ;; the head window it is read straight from the head.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/small")
         (sprig-remotes nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj "sess-small"
           `(:type "user" :cwd ,proj :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "CLI title"))
          (should (sprig--title-persist "sess-small" nil "Renamed small"))
          (should (equal (plist-get (car (sprig--scan-session-logs)) :title)
                         "Renamed small")))
      (delete-directory root t))))

(ert-deftest sprig-test-retitle-persist-past-head ()
  ;; The user title wins even when the CLI's own title sits in the 64KB head
  ;; and a large turn pushes the appended records well past it: the local
  ;; scan greps the whole file for the title, matching remote.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/big")
         (sprig-remotes nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj "sess-big"
           `(:type "user" :cwd ,proj :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "CLI title")
           `(:type "assistant"
             :message (:role "assistant"
                       :content ,(vector (list :type "text"
                                               :text (make-string 70000 ?x))))))
          (should (sprig--title-persist "sess-big" nil "Renamed big"))
          (should (equal (plist-get (car (sprig--scan-session-logs)) :title)
                         "Renamed big")))
      (delete-directory root t))))

(ert-deftest sprig-test-title-consume ()
  ;; The retitle sink assembles streamed text and hands the cleaned title to
  ;; the callback once the fork settles (deferred to a zero timer).
  (with-temp-buffer
    (let ((got 'unset))
      (setq-local sprig--title-raw "")
      (setq-local sprig--title-callback (lambda (p) (setq got p)))
      (sprig--title-consume '(text "\"My "))
      (sprig--title-consume '(text "title\"\n"))
      (sprig--title-consume '(done nil nil))
      (with-timeout (2 (ert-fail "retitle callback never fired"))
        (while (eq got 'unset) (sit-for 0.02)))
      (should (equal got "My title")))))

(ert-deftest sprig-test-title-commit ()
  ;; A manual commit (behind `T m') trims and persists the title; an empty
  ;; one cancels, leaving the previous title in place.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/commit")
         (sprig-remotes nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj "sess-c"
           `(:type "user" :cwd ,proj :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "CLI title"))
          (sprig--title-commit "sess-c" nil "  By hand  ")
          (should (equal (plist-get (car (sprig--scan-session-logs)) :title)
                         "By hand"))
          (sprig--title-commit "sess-c" nil "   ")
          (should (equal (plist-get (car (sprig--scan-session-logs)) :title)
                         "By hand")))
      (delete-directory root t))))

(ert-deftest sprig-test-retitle-persist-missing-log ()
  ;; Persisting against an id with no log fails cleanly rather than writing.
  (let* ((root (make-temp-file "sprig-proj" t))
         (sprig-remotes nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (should-not (sprig--title-persist "no-such-session" nil "Nope"))
      (delete-directory root t))))

(defun sprig-tests--warm-remote-scan (host)
  "Fill the navigator scan cache for HOST synchronously, for tests.
Production scans a cold remote host in the background (see
`sprig--status-scan-async'); a test that asserts on collected remote rows
stands in for that landed scan here, running the scan through whatever
`sprig--remote-sh' mock is active so the fresh-cache path returns the rows
without a real SSH process."
  (let ((sprig-remotes (list host)))
    (setf (alist-get (cons host (sprig--projects-directory))
                     sprig--status-scan-cache nil nil #'equal)
          (cons (current-time) (sprig--scan-session-logs)))))

(ert-deftest sprig-test-scan-session-logs ()
  ;; The scan is host-wide: every log under the projects root, newest first,
  ;; with each row's project taken from the log's own `cwd' record.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj-a "/tmp/whatever/myproj")
         (proj-b "/tmp/other/second")
         (sprig-remotes nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj-a "sess-old"
           `(:type "user" :cwd ,proj-a :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "First title")
           '(:type "ai-title" :aiTitle "Refined \"quoted\" title"))
          ;; A second project, written later, so it sorts newest first.
          (sprig-tests--make-session-log
           root proj-b "sess-new"
           `(:type "user" :cwd ,proj-b :message (:role "user" :content "yo"))
           '(:type "ai-title" :aiTitle "Second"))
          (let* ((rows (sprig--scan-session-logs))
                 (a (seq-find (lambda (r) (equal (plist-get r :session) "sess-old"))
                              rows)))
            ;; Both projects show, regardless of any configured directory.
            (should (= 2 (length rows)))
            (should (equal (plist-get a :dir) proj-a))
            ;; The freshest ai-title wins, and JSON escapes are decoded.
            (should (equal (plist-get a :title) "Refined \"quoted\" title")))
          ;; The cap keeps only the newest.
          (let ((sprig-status-max-sessions 1))
            (let ((rows (sprig--scan-session-logs)))
              (should (= 1 (length rows))))))
      (delete-directory root t))))

(ert-deftest sprig-test-scan-hides-subagent-transcripts ()
  ;; The CLI writes each subagent it spawns as its own `agent-*' log one level
  ;; deeper, under `<project>/<id>/subagents/'.  Those are not sessions you
  ;; drive, so the local scan drops them by default and lists only the real
  ;; session, then lists them too once `sprig--status-show-subagents' is set.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/myproj")
         (sprig-remotes nil)
         (sprig-claude-projects-directory root)
         (logdir (sprig-tests--make-session-log
                  root proj "sess-main"
                  `(:type "user" :cwd ,proj :message (:role "user" :content "hi"))))
         (subdir (expand-file-name "sess-main/subagents" logdir)))
    (unwind-protect
        (progn
          (make-directory subdir t)
          (with-temp-file (expand-file-name "agent-deadbeef.jsonl" subdir)
            (insert (json-serialize
                     `(:type "user" :cwd ,proj
                       :message (:role "user" :content "sub")))
                    "\n"))
          (should (sprig--log-subagent-p
                   (expand-file-name "agent-deadbeef.jsonl" subdir)))
          (should-not (sprig--log-subagent-p
                       (expand-file-name "sess-main.jsonl" logdir)))
          ;; Default: only the real session shows.
          (let ((rows (sprig--scan-session-logs)))
            (should (= 1 (length rows)))
            (should (equal (plist-get (car rows) :session) "sess-main")))
          ;; Toggled on: the subagent transcript joins the list.
          (let* ((sprig--status-show-subagents t)
                 (rows (sprig--scan-session-logs)))
            (should (= 2 (length rows)))
            (should (seq-find (lambda (r) (equal (plist-get r :session)
                                                 "agent-deadbeef"))
                              rows))))
      (delete-directory root t))))

(ert-deftest sprig-test-remote-scan-command-prunes-subagents ()
  ;; The remote scan prunes subagent transcripts in the `find' itself, so they
  ;; never eat into the newest-N cap; the toggle drops the exclusion.
  (should (string-search "-not -path '*/subagents/*'"
                         (sprig--remote-scan-all-command "~/p" 30)))
  (should-not (string-search "subagents"
                             (sprig--remote-scan-all-command "~/p" 30 t))))

(ert-deftest sprig-test-scan-session-logs-without-cwd ()
  ;; A log whose scanned tail carries no cwd yields a nil :dir, never the
  ;; encoded log-dir name: that name is not a real path, so it survives
  ;; only as the display-only :project and is never handed to a `cd'.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/myproj")
         (sprig-remotes nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj "sess-nocwd"
           '(:type "ai-title" :aiTitle "No cwd here"))
          (let ((row (car (sprig--scan-session-logs))))
            (should (null (plist-get row :dir)))
            (should (equal (plist-get row :project) "-tmp-whatever-myproj"))
            (should (equal (plist-get row :title) "No cwd here"))))
      (delete-directory root t))))

(ert-deftest sprig-test-scan-reads-head-not-tail ()
  ;; The CLI writes the title just after the opening turn, so it sits near
  ;; the top. A later record larger than the read window must not hide it:
  ;; the scan reads the head, not the tail, so a huge trailing record (no
  ;; title of its own) leaves the row's title intact.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/big")
         (filler (make-string (* 128 1024) ?x))
         (sprig-remotes nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj "sess-big"
           `(:type "user" :cwd ,proj :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "Early title")
           `(:type "assistant" :cwd ,proj
             :message (:role "assistant" :content ,filler)))
          (let ((row (car (sprig--scan-session-logs))))
            (should (equal (plist-get row :dir) proj))
            (should (equal (plist-get row :title) "Early title"))))
      (delete-directory root t))))

(ert-deftest sprig-test-scan-session-logs-remote ()
  ;; One round trip: a single combined command lists the newest logs by mtime
  ;; and slurps each one's fields, which come back record-separated so mtime,
  ;; cwd, and title are parsed per session.
  (let ((sprig-remotes '("me@host"))
        (sprig-claude-projects-directory "~/.claude/projects")
        (root "~/.claude/projects")
        (calls nil))
    (cl-letf (((symbol-function 'sprig--remote-sh)
               (lambda (cmd)
                 (push cmd calls)
                 (concat "\03620.0\037" root "/-p/new.jsonl\037\037"
                         "{\"cwd\":\"/home/me/p\",\"aiTitle\":\"Newer\"}\037\n"
                         "\03610.0\037" root "/-p/old.jsonl\037\037"
                         "{\"cwd\":\"/home/me/p\",\"aiTitle\":\"Older\"}\037\n"))))
      (let* ((rows (sprig--scan-session-logs))
             (newer (car rows)))
        ;; Newest first, from the find's descending sort.
        (should (equal (plist-get newer :session) "new"))
        (should (equal (plist-get newer :title) "Newer"))
        (should (equal (plist-get newer :dir) "/home/me/p"))
        (should (= 2 (length rows)))
        ;; One SSH round trip, its command both finding and slurping.
        (should (= 1 (length calls)))
        (should (string-match-p "find" (car calls)))
        (should (string-match-p "while" (car calls)))
        ;; The find left `*.jsonl' for find's own `-name' matching.
        (should (string-match-p "\\*\\.jsonl" (car calls)))))))

(ert-deftest sprig-test-parse-scan-rows ()
  ;; The combined scan blob parses into plists: mtime, session, cwd, title,
  ;; newest first, with ignored logs dropped and the rest capped.
  (let ((blob (concat "\03620.0\037/r/-a/x.jsonl\037\037"
                      "{\"cwd\":\"/home/me/a\"}\037{\"aiTitle\":\"Fallback A\"}\n"
                      "\03610.0\037/r/-b/y.jsonl\037\037"
                      "{\"cwd\":\"/home/me/b\",\"aiTitle\":\"Head B\"}\037\n")))
    (let ((rows (sprig--parse-scan-rows blob nil)))
      (should (= 2 (length rows)))
      ;; Newest first; the cwd is read from the head, and the title falls back
      ;; to the grepped line when the head carried none (row a) or comes from
      ;; the head itself when it is there (row b).
      (should (equal (plist-get (car rows) :session) "x"))
      (should (equal (plist-get (car rows) :dir) "/home/me/a"))
      (should (equal (plist-get (car rows) :mtime) 20.0))
      (should (equal (plist-get (car rows) :title) "Fallback A"))
      (should (equal (plist-get (nth 1 rows) :dir) "/home/me/b"))
      (should (equal (plist-get (nth 1 rows) :title) "Head B")))
    ;; The cap keeps only the newest.
    (should (= 1 (length (sprig--parse-scan-rows blob 1))))
    ;; An ignore list drops matching logs before the cap.
    (let ((sprig-status-ignore-directories '("\\`-a\\'")))
      (let ((rows (sprig--parse-scan-rows blob nil)))
        (should (= 1 (length rows)))
        (should (equal (plist-get (car rows) :session) "y"))))))

(ert-deftest sprig-test-status-scan-cache-remote-never-blocks ()
  ;; A remote host never scans synchronously on the render path: it returns
  ;; whatever is cached and schedules a background scan instead.
  (let* ((sprig-remotes '("host"))
         (sprig-claude-projects-directory "/x")
         (sprig--status-scan-cache
          (list (cons (cons "host" (sprig--projects-directory))
                      (cons (current-time) '(:cached-row)))))
         (scheduled nil))
    (cl-letf (((symbol-function 'sprig--status-scan-async)
               (lambda (h) (setq scheduled h)))
              ((symbol-function 'sprig--remote-sh)
               (lambda (&rest _) (error "must not block on SSH for a render"))))
      ;; Expire the cache so a refresh is due, then read it.
      (sprig--status-scan-invalidate)
      (should (equal (sprig--status-scan-cached "host") '(:cached-row)))
      (should (equal scheduled "host")))))

(ert-deftest sprig-test-entry-matches-filter ()
  (let ((e '(:project "/home/me/Projects/sprig" :title "Fix the navigator")))
    ;; Case-insensitive, matching either the project label or the title.
    (should (sprig--entry-matches-filter e "sprig"))
    (should (sprig--entry-matches-filter e "NAVIGATOR"))
    (should-not (sprig--entry-matches-filter e "unrelated"))))

(ert-deftest sprig-test-session-status-waiting-wins-over-streaming ()
  ;; A live session stopped on an unanswered dialog is `waiting', not
  ;; `streaming', even though its turn is still in flight (busy).
  (with-temp-buffer
    (setq-local sprig--sink #'sprig--review-sink
                sprig--process 'dummy
                sprig--busy t
                sprig-session--events '((dialog "d1" "ask_user_question" nil)))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t)))
      (should (eq (sprig--session-status (current-buffer)) 'waiting)))))

(ert-deftest sprig-test-session-status-answered-dialog-not-waiting ()
  ;; Once the dialog is answered, the session is back to plain `streaming'.
  (with-temp-buffer
    (setq-local sprig--sink #'sprig--review-sink
                sprig--process 'dummy
                sprig--busy t
                sprig-session--events '((dialog-answer "d1" "yes")
                                       (dialog "d1" "ask_user_question" nil)))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t)))
      (should (eq (sprig--session-status (current-buffer)) 'streaming)))))

(ert-deftest sprig-test-session-status-dead-process-not-waiting ()
  ;; A dead session never shows `waiting', even if its last replayed dialog
  ;; was never answered: nothing is blocked on you, the session is gone.
  (with-temp-buffer
    (setq-local sprig--sink #'sprig--review-sink
                sprig--process nil
                sprig--busy nil
                sprig-session--events '((dialog "d1" "ask_user_question" nil)))
    (should (eq (sprig--session-status (current-buffer)) 'disconnected))))

(ert-deftest sprig-test-session-status-agent-outlives-the-turn ()
  ;; The turn is over (not busy) but a background agent is still running, so
  ;; the row is `agent', not the plain `idle' a done live session would show.
  (with-temp-buffer
    (setq-local sprig--sink #'sprig--review-sink
                sprig--process 'dummy
                sprig--busy nil
                ;; Stored newest-first, as `sprig-session-consume' pushes them.
                sprig-session--events
                '((done nil nil)
                  (subagent "toolu_A" (:status "running" :agent-type "Explore"))
                  (tool-call "toolu_A" "Agent" "{\"description\":\"dig\"}")))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t)))
      (should (eq (sprig--session-status (current-buffer)) 'agent)))))

(ert-deftest sprig-test-session-status-idle-once-agent-done ()
  ;; Its notification closes the agent, and a done live session is `idle'.
  (with-temp-buffer
    (setq-local sprig--sink #'sprig--review-sink
                sprig--process 'dummy
                sprig--busy nil
                sprig-session--events
                '((done nil nil)
                  (subagent "toolu_A" (:status "completed"))
                  (subagent "toolu_A" (:status "running" :agent-type "Explore"))
                  (tool-call "toolu_A" "Agent" "{\"description\":\"dig\"}")))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t)))
      (should (eq (sprig--session-status (current-buffer)) 'idle)))))

(ert-deftest sprig-test-status-glyph-has-waiting ()
  (should (equal (alist-get 'waiting sprig--status-glyphs) "?")))

(ert-deftest sprig-test-status-collect-owning-buffer-wins ()
  (let ((root (make-temp-file "sprig-proj" t)))
    (unwind-protect
        (let ((sprig-remotes nil)
              (sprig-claude-projects-directory root)
              (sprig-status-directories '("/tmp/no-such-project")))
          (with-temp-buffer
            (setq-local sprig--sink #'sprig--review-sink
                        sprig--session-id "live-1"
                        sprig--working-dir "/tmp/proj"
                        sprig-session--meta '(:title "Live one"))
            (let* ((rows (sprig--status-collect))
                   (e (seq-find (lambda (r) (equal (plist-get r :session) "live-1"))
                                rows)))
              (should e)
              (should (eq (plist-get e :buffer) (current-buffer)))
              (should (equal (plist-get e :title) "Live one")))))
      (delete-directory root t))))

(ert-deftest sprig-test-scan-title-grepped-past-head ()
  ;; A large opening turn pushes the first `ai-title' past the head window;
  ;; the title is grepped whole-file, so the scan still recovers it (while
  ;; the `cwd', in the first record, still comes from the head).
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/deep")
         (filler (make-string (* 128 1024) ?x))
         (sprig-remotes nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj "sess-deep"
           `(:type "user" :cwd ,proj :message (:role "user" :content ,filler))
           '(:type "ai-title" :aiTitle "Deep title"))
          (let ((row (car (sprig--scan-session-logs))))
            (should (equal (plist-get row :dir) proj))
            (should (equal (plist-get row :title) "Deep title"))))
      (delete-directory root t))))

(ert-deftest sprig-test-status-collect-title-from-events ()
  ;; A live owning buffer with no manual title takes it from its events'
  ;; replayed `ai-title', which the live stream itself never carries.
  (let ((root (make-temp-file "sprig-proj" t)))
    (unwind-protect
        (let ((sprig-remotes nil)
              (sprig-claude-projects-directory root))
          (with-temp-buffer
            (setq-local sprig--sink #'sprig--review-sink
                        sprig--session-id "live-2"
                        sprig--working-dir "/tmp/proj"
                        sprig-session--meta nil
                        sprig-session--events '((title "From events")))
            (let* ((rows (sprig--status-collect))
                   (e (seq-find (lambda (r) (equal (plist-get r :session) "live-2"))
                                rows)))
              (should (equal (plist-get e :title) "From events")))))
      (delete-directory root t))))

(ert-deftest sprig-test-status-collect-title-from-log ()
  ;; A live owning buffer whose events carry no title (a fresh session)
  ;; borrows the title from the session's own stored log.
  (let ((root (make-temp-file "sprig-proj" t)))
    (unwind-protect
        (let ((sprig-remotes nil)
              (sprig-claude-projects-directory root))
          (sprig-tests--make-session-log
           root "/tmp/proj" "live-3"
           `(:type "user" :cwd "/tmp/proj" :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "From log"))
          (with-temp-buffer
            (setq-local sprig--sink #'sprig--review-sink
                        sprig--session-id "live-3"
                        sprig--working-dir "/tmp/proj"
                        sprig-session--meta nil
                        sprig-session--events nil)
            (let* ((rows (sprig--status-collect))
                   (e (seq-find (lambda (r) (equal (plist-get r :session) "live-3"))
                                rows)))
              (should (eq (plist-get e :buffer) (current-buffer)))
              (should (equal (plist-get e :title) "From log")))))
      (delete-directory root t))))

(ert-deftest sprig-test-status-collect-fork-does-not-mask-parent ()
  ;; A fork resumes the parent's id until the CLI answers with its own; keyed
  ;; by that shared id it would mask the parent's stored-log row, and the
  ;; original would look gone until the handover.  Keyed by its buffer while
  ;; the fork flag is set, both the live fork and the original show.
  (let ((root (make-temp-file "sprig-proj" t)))
    (unwind-protect
        (let ((sprig-remotes nil)
              (sprig-claude-projects-directory root)
              (sprig--status-scan-cache nil))
          (sprig-tests--make-session-log
           root "/tmp/proj" "parent-id"
           `(:type "user" :cwd "/tmp/proj" :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "The original"))
          (with-temp-buffer
            (setq-local sprig--sink #'sprig--review-sink
                        sprig--session-id "parent-id"
                        sprig--fork-session t
                        sprig--working-dir "/tmp/proj"
                        sprig-session--meta nil
                        sprig-session--events '((title "The fork")))
            (let* ((rows (sprig--status-collect))
                   ;; The fork owns a buffer; the original comes from its
                   ;; stored log, so it has none.
                   (forkrow (seq-find (lambda (r) (plist-get r :buffer)) rows))
                   (parentrow (seq-find (lambda (r) (null (plist-get r :buffer)))
                                        rows)))
              ;; Two distinct rows, not one collapsed onto the shared id.
              (should (= 2 (length rows)))
              (should forkrow)
              (should parentrow)
              ;; The fork is keyed by its buffer, the original by its stored id.
              (should (equal (plist-get forkrow :key)
                             (cons nil (current-buffer))))
              (should (equal (plist-get parentrow :session) "parent-id"))
              (should (equal (plist-get parentrow :title) "The original")))))
      (delete-directory root t))))

(ert-deftest sprig-test-status-hosts ()
  ;; The local machine is always a group; a configured remote adds a second,
  ;; so the navigator lists both rather than only the configured default.
  (let ((sprig-remotes nil))
    (should (equal (sprig--status-hosts) '(nil))))
  (let ((sprig-remotes '("me@host")))
    (should (equal (sprig--status-hosts) '(nil "me@host")))))

(ert-deftest sprig-test-remote-override-value ()
  ;; A string pins a session to that host; any other non-nil value (the
  ;; interactive prefix included) pins it local; nil follows the primary remote.
  (should (equal (sprig--remote-override-value "me@host") "me@host"))
  (should (null (sprig--remote-override-value t)))
  (should (null (sprig--remote-override-value '(4))))
  (should (eq (sprig--remote-override-value nil) 'inherit)))

(ert-deftest sprig-test-status-collect-lists-both-hosts ()
  ;; The navigator scans every host it lists, so a local session and a
  ;; remote one both show, each tagged with the host it came from and keyed
  ;; by the pair: an id is only unique on the host that issued it.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/localproj")
         (sprig-remotes '("me@host"))
         (sprig--status-scan-cache nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj "sess-local"
           `(:type "user" :cwd ,proj :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "Local one"))
          (cl-letf (((symbol-function 'sprig--remote-sh)
                     (lambda (_cmd)
                       (concat "\03620.0\037/r/-p/sess-remote.jsonl\037\037"
                               "{\"cwd\":\"/home/me/p\","
                               "\"aiTitle\":\"Remote one\"}\037\n"))))
            (sprig-tests--warm-remote-scan "me@host")
            (let* ((rows (sprig--status-collect))
                   (local (seq-find (lambda (r)
                                      (equal (plist-get r :session) "sess-local"))
                                    rows))
                   (remote (seq-find (lambda (r)
                                       (equal (plist-get r :session) "sess-remote"))
                                     rows)))
              (should local)
              (should remote)
              (should (null (plist-get local :host)))
              (should (equal (plist-get remote :host) "me@host"))
              (should (equal (plist-get local :key) '(nil . "sess-local")))
              (should (equal (plist-get remote :key) '("me@host" . "sess-remote")))
              ;; Rows come back grouped, local first, for the render to head.
              (should (equal (mapcar (lambda (r) (plist-get r :host)) rows)
                             '(nil "me@host"))))))
      (delete-directory root t))))

(ert-deftest sprig-test-status-collect-same-id-on-two-hosts ()
  ;; Two hosts can hand out the same session id and they are still two
  ;; different sessions, so neither row may shadow the other.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/dup")
         (sprig-remotes '("me@host"))
         (sprig--status-scan-cache nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj "same-id"
           `(:type "user" :cwd ,proj :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "The local one"))
          (cl-letf (((symbol-function 'sprig--remote-sh)
                     (lambda (_cmd)
                       (concat "\03620.0\037/r/-p/same-id.jsonl\037\037"
                               "{\"cwd\":\"/home/me/p\","
                               "\"aiTitle\":\"The remote one\"}\037\n"))))
            (sprig-tests--warm-remote-scan "me@host")
            (let ((rows (sprig--status-collect)))
              (should (= 2 (length rows)))
              (should (equal (mapcar (lambda (r) (plist-get r :title)) rows)
                             '("The local one" "The remote one"))))))
      (delete-directory root t))))

(ert-deftest sprig-test-status-group-hosts-keeps-a-pinned-stray ()
  ;; A session buffer pinned to a host no longer in `sprig-remotes' is
  ;; still a live session you can steer, so it gets a group of its own
  ;; after the two standing ones rather than being filed under theirs.
  (let ((sprig-remotes '("me@host")))
    (should (equal (sprig--status-group-hosts
                    '((:host nil) (:host "me@host") (:host "old@host")))
                   '(nil "me@host" "old@host")))))

(ert-deftest sprig-test-status-collect-scans-a-pinned-stray-host ()
  ;; A buffer pinned to a host that is not in `sprig-remotes' (e.g. one the
  ;; config since dropped) still gets its log-scan pass, so its creation
  ;; time fills in from the log rather than rendering blank: the scan loop
  ;; covers the hosts its buffers came from, not only the configured ones.
  (let ((sprig-remotes nil)                      ; the stray host is unconfigured
        (sprig--status-scan-cache nil)
        (sprig-claude-projects-directory "/x"))
    (cl-letf (((symbol-function 'sprig--remote-sh)
               (lambda (_cmd)
                 (concat "\03620.0\037/r/-p/stray-1.jsonl\037\037"
                         "{\"cwd\":\"/home/me/p\","
                         "\"timestamp\":\"2026-08-07T14:10:58.784Z\","
                         "\"aiTitle\":\"Stray one\"}\037"))))
      (sprig-tests--warm-remote-scan "old@host")
      (with-temp-buffer
        (setq-local sprig--sink #'sprig--review-sink
                    sprig--session-id "stray-1"
                    sprig--remote-override "old@host"
                    sprig--working-dir "/home/me/p"
                    sprig-session--meta '(:title "Stray one"))
        (let* ((rows (sprig--status-collect))
               (e (seq-find (lambda (r) (equal (plist-get r :session) "stray-1"))
                            rows)))
          (should e)
          (should (eq (plist-get e :buffer) (current-buffer)))
          (should (equal (plist-get e :host) "old@host"))
          ;; The stray host's scan pass ran, so its creation time is filled.
          (should (plist-get e :created)))))))

(ert-deftest sprig-test-status-sort-by-group ()
  ;; Rows are ordered by their host's group; within a group the scan's
  ;; newest-first order survives, since `sort' is stable.
  (let ((rows '((:host "h" :session "r1") (:host nil :session "l1")
                (:host "h" :session "r2") (:host nil :session "l2"))))
    (should (equal (mapcar (lambda (r) (plist-get r :session))
                           (sprig--status-sort-by-group rows '(nil "h")))
                   '("l1" "l2" "r1" "r2")))))

(ert-deftest sprig-test-status-heads-both-groups ()
  ;; Both groups are headed, the empty one included: its heading is what
  ;; you press `s' under to start the first session on that host.  A
  ;; heading falls due when the host changes, not once per row, so a group
  ;; holding several rows keeps all of them; and every line carries its
  ;; group, so `s' knows the host wherever point sits.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/onlylocal")
         (sprig-remotes '("me@host"))
         (sprig--status-scan-cache nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj "sess-one"
           `(:type "user" :cwd ,proj :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "Local one"))
          (sprig-tests--make-session-log
           root proj "sess-two"
           `(:type "user" :cwd ,proj :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "Local two"))
          (cl-letf (((symbol-function 'sprig--remote-sh) (lambda (_) "")))
            (sprig-tests--warm-remote-scan "me@host")
            (with-temp-buffer
              (sprig-status-mode)
              (sprig--status-render)
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                ;; An expanded group heads with the open fold glyph.
                (should (string-match-p "^▾ local (2)$" text))
                ;; The host with nothing on it is headed all the same.
                (should (string-match-p "^▾ remote me@host (none)$" text))
                ;; Both local rows sit above the remote heading, not one.
                (should (string-match-p
                         "\\`▾ local (2)\n.*Local \\(?:one\\|two\\).*\n.*Local \\(?:one\\|two\\).*\n\
▾ remote me@host (none)\n"
                         text)))
              ;; Every line answers with the host of the group it is in.
              (dolist (probe '(("^▾ local (2)$" nil)
                               ("^▾ remote me@host (none)$" "me@host")
                               ("Local one" nil)
                               ("Local two" nil)))
                (goto-char (point-min))
                (should (re-search-forward (car probe) nil t))
                (beginning-of-line)
                (should (equal (sprig--status-host-at-point) (cadr probe)))))))
      (delete-directory root t))))

(ert-deftest sprig-test-status-heads-an-empty-group-in-place ()
  ;; An empty group is headed where it sorts, not swept to the end: `local'
  ;; leads even when every session is on the remote host.
  (let* ((root (make-temp-file "sprig-proj" t))
         (sprig-remotes '("me@host"))
         (sprig--status-scan-cache nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (cl-letf (((symbol-function 'sprig--remote-sh)
                   (lambda (_cmd)
                     (concat "\03620.0\037/r/-p/only-remote.jsonl\037\037"
                             "{\"cwd\":\"/home/me/p\",\"aiTitle\":\"Remote only\"}\037\n"))))
          (sprig-tests--warm-remote-scan "me@host")
          (with-temp-buffer
            (sprig-status-mode)
            (sprig--status-render)
            (should (string-match-p
                     "\\`▾ local (none)\n▾ remote me@host (1)\n.*Remote only"
                     (buffer-substring-no-properties (point-min) (point-max))))))
      (delete-directory root t))))

(ert-deftest sprig-test-status-open-pins-the-row-host ()
  ;; Opening a row pins its buffer to the host the row was scanned on: a
  ;; session id only resumes on the host holding its log, so a local row
  ;; must not come back on the primary remote nor a remote row run locally.
  (let ((sprig-remotes '("me@host"))
        calls)
    (cl-letf (((symbol-function 'sprig-session-open)
               (lambda (&rest args) (push args calls) (current-buffer))))
      (sprig--status-review-buffer '(:host "me@host" :dir "/p" :session "s1"))
      (sprig--status-review-buffer '(:host nil :dir "/p" :session "s2"))
      (should (equal (nth 2 (nth 1 calls)) "me@host"))
      (should (eq (nth 2 (nth 0 calls)) t)))))

(ert-deftest sprig-test-status-steer-verbs-are-commands ()
  ;; The navigator's c / a dispatch runs the session buffer's own verbs on the
  ;; session under point; each wrapper is a real command.
  (dolist (v '(sprig-status-message sprig-status-queue sprig-status-drop-queue
               sprig-status-accept sprig-status-decline sprig-status-message-plan
               sprig-status-retry sprig-status-compact
               sprig-status-answer sprig-status-answer-recommended
               sprig-status-answer-skip
               sprig-status-plan-mode sprig-status-auto-mode
               sprig-status-accept-edits-mode sprig-status-manual-mode
               sprig-status-bypass-mode
               sprig-status-dispatch sprig-status-answer-dispatch
               sprig-status-permission-mode
               sprig-status-start sprig-status-remove sprig-status-view
               sprig-status-new sprig-status-new-message
               sprig-status-new-message-plan sprig-status-fork
               sprig-status-disconnect sprig-status-delete
               sprig-status-toggle-disconnected sprig-status-show-all))
    (should (commandp v)))
  ;; s / c / a / d / l each raise a dispatch transient; interrupt (`k' before)
  ;; is now only `c i', and new/delete/show-all fold under their prefixes.
  (should (eq (lookup-key sprig-status-mode-map (kbd "s")) 'sprig-status-start))
  (should (eq (lookup-key sprig-status-mode-map (kbd "c")) 'sprig-status-dispatch))
  (should (eq (lookup-key sprig-status-mode-map (kbd "a"))
              'sprig-status-answer-dispatch))
  (should (eq (lookup-key sprig-status-mode-map (kbd "d")) 'sprig-status-remove))
  (should (eq (lookup-key sprig-status-mode-map (kbd "l")) 'sprig-status-view))
  (should (eq (lookup-key sprig-status-mode-map (kbd "P"))
              'sprig-status-permission-mode))
  (should-not (lookup-key sprig-status-mode-map (kbd "k")))
  (should-not (lookup-key sprig-status-mode-map (kbd "D"))))

(ert-deftest sprig-test-status-collapse-folds-a-group ()
  ;; TAB on a heading folds its group to the heading alone: the rows stop
  ;; printing, the fold glyph flips, and the count still shows the true
  ;; number (the rows are hidden, not gone).  A second toggle unfolds them.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/onlylocal")
         (sprig-remotes '("me@host"))
         (sprig--status-scan-cache nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj "sess-one"
           `(:type "user" :cwd ,proj :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "Local one"))
          (sprig-tests--make-session-log
           root proj "sess-two"
           `(:type "user" :cwd ,proj :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "Local two"))
          (cl-letf (((symbol-function 'sprig--remote-sh) (lambda (_) "")))
            (sprig-tests--warm-remote-scan "me@host")
            (with-temp-buffer
              (sprig-status-mode)
              (sprig--status-render)
              (should-not (sprig--status-collapsed-p nil))
              ;; Fold the local group.
              (sprig--status-toggle-collapse nil)
              (should (sprig--status-collapsed-p nil))
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                ;; Folded: the glyph flips and the rows are gone, but the
                ;; count still says 2.
                (should (string-match-p "^▸ local (2)$" text))
                (should-not (string-match-p "Local one" text))
                (should-not (string-match-p "Local two" text)))
              ;; Point landed on the folded heading, so a second TAB there
              ;; unfolds it rather than acting on a stranded row.
              (should (get-text-property (line-beginning-position)
                                         'sprig--status-heading))
              (should (null (sprig--status-host-at-point)))
              (sprig--status-toggle-collapse nil)
              (should-not (sprig--status-collapsed-p nil))
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "^▾ local (2)$" text))
                (should (string-match-p "Local one" text))))))
      (delete-directory root t))))

(ert-deftest sprig-test-status-collapse-survives-a-refresh ()
  ;; A background refresh reprints the list, and a collapsed group stays
  ;; collapsed across it: the fold state is the navigator's, not the print's.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/onlylocal")
         (sprig-remotes '("me@host"))
         (sprig--status-scan-cache nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj "sess-one"
           `(:type "user" :cwd ,proj :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "Local one"))
          (cl-letf (((symbol-function 'sprig--remote-sh) (lambda (_) "")))
            (sprig-tests--warm-remote-scan "me@host")
            (with-temp-buffer
              (sprig-status-mode)
              (sprig--status-render)
              (sprig--status-toggle-collapse nil)
              ;; A plain re-render (the lifecycle refresh path).
              (sprig--status-render)
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "^▸ local (1)$" text))
                (should-not (string-match-p "Local one" text))))))
      (delete-directory root t))))

;;; Inline preview: the last exchange

(ert-deftest sprig-test-normalize-prose ()
  ;; Each paragraph's inner line breaks collapse so it re-wraps, but the
  ;; blank-line paragraph break is kept; empty in, nil out.
  (should (equal (sprig--normalize-prose "one\ntwo\n\n  three   four ")
                 "one two\n\nthree four"))
  (should (null (sprig--normalize-prose "   \n\n  ")))
  (should (null (sprig--normalize-prose nil))))

(ert-deftest sprig-test-events-preview-last-exchange ()
  ;; The preview is the last exchange: the last prompt, and the whole reply
  ;; since it (all paragraphs), with the earlier turn left out.
  (let ((p (sprig--events-preview
            '((user "old question") (text "old answer")
              (user "the new question") (text "para one\n\npara two")))))
    (should (equal (plist-get p :prompt) "the new question"))
    (should (equal (plist-get p :reply) "para one\n\npara two"))
    (should-not (string-match-p "old answer" (plist-get p :reply)))))

(ert-deftest sprig-test-events-preview-final-message-only ()
  ;; A turn's running narration between tool calls is dropped: the preview is
  ;; the final message alone, the last text block, not every block joined.
  (let ((p (sprig--events-preview
            '((user "q") (text "before the tool")
              (tool-call "t1" "Bash" nil) (text "the final message")))))
    (should (equal (plist-get p :reply) "the final message"))
    (should-not (string-match-p "before the tool" (plist-get p :reply)))))

(ert-deftest sprig-test-events-preview-falls-back-to-last-text ()
  ;; The newest turn ended on a tool call with no prose of its own, so the
  ;; reply falls back to the last assistant text anywhere: the preview shows
  ;; the freshest prompt over the last thing the agent actually said.
  (let ((p (sprig--events-preview
            '((user "q1") (text "the only prose")
              (user "q2") (tool-call "t1" "Bash" nil)))))
    (should (equal (plist-get p :prompt) "q2"))
    (should (equal (plist-get p :reply) "the only prose"))))

(ert-deftest sprig-test-events-preview-empty ()
  ;; Nothing to preview: no events, or events with no prose at all.
  (should (null (sprig--events-preview nil)))
  (should (null (sprig--events-preview '((tool-call "t" "Bash" nil))))))

(ert-deftest sprig-test-status-preview-lines-leads-with-prompt-then-reply ()
  ;; The preview leads with the prompt in its own face, then the reply as a
  ;; single line in the preview face: the paragraphs collapse to one line,
  ;; trimmed with an ellipsis where it runs past the window.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/prev")
         (sprig-remotes nil)
         (sprig-claude-projects-directory root)
         (reply (mapconcat
                 (lambda (i) (format "Reply line %d with enough words to wrap." i))
                 (number-sequence 1 8) "\n\n")))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj "sess-prev"
           `(:type "user" :cwd ,proj
             :message (:role "user" :content "my prompt here"))
           '(:type "ai-title" :aiTitle "Prev")
           `(:type "assistant" :cwd ,proj
             :message (:role "assistant"
                       :content ,(vector (list :type "text" :text reply)))))
          (let* ((entry (car (sprig--scan-session-logs)))
                 (lines (sprig--status-preview-lines entry))
                 (prompt-line
                  (seq-find (lambda (l) (string-match-p "» my prompt here" l)) lines))
                 (reply-line
                  (seq-find (lambda (l) (string-match-p "Reply line 1" l)) lines)))
            ;; The prompt leads, in the prompt face.
            (should prompt-line)
            (should (eq (get-text-property 0 'face prompt-line)
                        'sprig-status-preview-prompt))
            ;; The reply is one line in the preview face: collapsed to a single
            ;; line of prose and cut with an ellipsis, never more than one row.
            (should reply-line)
            (should (eq (get-text-property 0 'face reply-line)
                        'sprig-status-preview))
            (should (string-suffix-p "…" reply-line))
            (should-not (string-match-p "Reply line 8" reply-line))
            (should (= 1 (seq-count (lambda (l) (string-match-p "Reply line" l))
                                    lines)))))
      (delete-directory root t))))

(ert-deftest sprig-test-log-created-reads-first-timestamp ()
  ;; The creation time is the first record's timestamp, as an epoch float;
  ;; junk or a headless log yields nil.
  (should (= (sprig--log-created "{\"timestamp\":\"2026-08-05T09:16:56.955Z\"}")
             (float-time (encode-time
                          (iso8601-parse "2026-08-05T09:16:56.955Z")))))
  ;; The first match wins, so a later record's stamp does not override it.
  (should (= (sprig--log-created
              (concat "{\"timestamp\":\"2026-08-05T09:16:56.955Z\"}\n"
                      "{\"timestamp\":\"2026-08-05T10:00:00.000Z\"}"))
             (float-time (encode-time
                          (iso8601-parse "2026-08-05T09:16:56.955Z")))))
  (should (null (sprig--log-created "{\"type\":\"user\"}")))
  (should (null (sprig--log-created nil))))

(ert-deftest sprig-test-status-preview-lines-date-each-message ()
  ;; Each preview line leads with its own message's time (HH:MM), the prompt's
  ;; on the prompt line and the reply's on the reply line.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/dated")
         (sprig-remotes nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj "sess-dated"
           `(:type "user" :timestamp "2026-08-05T09:16:00.000Z" :cwd ,proj
             :message (:role "user" :content "my prompt here"))
           '(:type "ai-title" :aiTitle "Dated")
           `(:type "assistant" :timestamp "2026-08-05T09:17:00.000Z" :cwd ,proj
             :message (:role "assistant"
                       :content ,(vector (list :type "text"
                                               :text "the reply here")))))
          (let* ((entry (car (sprig--scan-session-logs)))
                 (lines (sprig--status-preview-lines entry))
                 (prompt-line
                  (seq-find (lambda (l) (string-match-p "» my prompt here" l)) lines))
                 (reply-line
                  (seq-find (lambda (l) (string-match-p "the reply here" l)) lines)))
            ;; A clock leads the prompt, right before its marker.
            (should prompt-line)
            (should (string-match-p "[0-9][0-9]:[0-9][0-9] » my prompt here"
                                    prompt-line))
            ;; And a clock leads the reply, after an optional date prefix that
            ;; `sprig--format-time-value' adds once the log is no longer today.
            (should reply-line)
            (should (string-match-p
                     "^ +\\([0-9][0-9]-[0-9][0-9] \\)?[0-9][0-9]:[0-9][0-9] .*the reply here"
                     reply-line))))
      (delete-directory root t))))

(ert-deftest sprig-test-status-scroll-anchor-round-trips-by-id ()
  ;; The window scroll anchors key off row ids, so a row keeps its place
  ;; across a reprint that shifts the lines above it.  Exercise the id
  ;; helpers on a hand-built buffer (batch has no windows for the wrapper).
  (with-temp-buffer
    (insert (propertize "▾ local (2)\n" 'sprig--status-heading t))
    (insert (propertize "row A\n" 'tabulated-list-id "a"))
    (insert (propertize "     preview of A\n" 'sprig--status-preview-id "a"))
    (insert (propertize "row B\n" 'tabulated-list-id "b"))
    ;; A row and its preview line both report the id; a heading reports none.
    (goto-char (point-min))
    (should-not (sprig--status-id-at (point)))
    (forward-line 1)
    (should (equal (sprig--status-id-at (point)) "a"))
    (forward-line 1)
    (should (equal (sprig--status-id-at (point)) "a"))
    (forward-line 1)
    (should (equal (sprig--status-id-at (point)) "b"))
    ;; The position lookup lands on the printed row, not its preview line.
    (let ((pos-a (sprig--status-id-line-position "a")))
      (should pos-a)
      (should (equal (buffer-substring pos-a (+ pos-a 5)) "row A")))
    (should-not (sprig--status-id-line-position "gone"))
    ;; A window top on the heading anchors to the first row below it, one line
    ;; down; a top already on a row anchors to it with no offset.
    (should (equal (sprig--status-scroll-anchor (point-min)) '("a" . 1)))
    (should (equal (sprig--status-scroll-anchor
                    (sprig--status-id-line-position "b"))
                   '("b" . 0)))))

(ert-deftest sprig-test-status-preview-lines-no-reply ()
  ;; A session with nothing to show falls to the muted placeholder.
  (should (equal (sprig--status-preview-lines '(:buffer nil :file nil))
                 (list (propertize "     (no reply yet)"
                                   'face 'sprig-status-preview)))))

(ert-deftest sprig-test-status-preview-lines-streams-the-last-message ()
  ;; While the turn streams, the preview shows the growing last message live
  ;; under the prompt, rather than holding it back until the turn settles.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/stream")
         (sprig-remotes nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj "sess-stream"
           `(:type "user" :cwd ,proj
             :message (:role "user" :content "my prompt here"))
           '(:type "ai-title" :aiTitle "Stream")
           `(:type "assistant" :cwd ,proj
             :message (:role "assistant"
                       :content ,(vector (list :type "text"
                                               :text "partial reply so far")))))
          (let* ((entry (car (sprig--scan-session-logs)))
                 (streaming (plist-put (copy-sequence entry) :status 'streaming))
                 (lines (sprig--status-preview-lines streaming))
                 (joined (string-join lines "\n")))
            ;; The prompt still leads under the state line.
            (should (string-match-p "» my prompt here" joined))
            ;; The growing reply shows live, as the last message so far.
            (should (string-match-p "partial reply so far" joined))))
      (delete-directory root t))))

(ert-deftest sprig-test-tidy-prose ()
  ;; Trims and squeezes blank runs, but keeps single line breaks so a list
  ;; survives; empty in, nil out.
  (should (equal (sprig--tidy-prose "\n- a\n- b\n\n\npara\n") "- a\n- b\n\npara"))
  (should (null (sprig--tidy-prose "  \n\n ")))
  (should (null (sprig--tidy-prose nil))))

(ert-deftest sprig-test-format-time ()
  ;; A parsable stamp formats to a short local time; junk and nil drop out.
  (should (stringp (sprig--format-time "2026-08-03T10:00:00Z")))
  (should (null (sprig--format-time "not a time")))
  (should (null (sprig--format-time nil))))

(ert-deftest sprig-test-format-tokens ()
  ;; Context size shows compactly in thousands or millions.
  (should (equal (sprig--format-tokens 134000) "134.0k"))
  (should (equal (sprig--format-tokens 2500000) "2.5M")))

(ert-deftest sprig-test-model-label ()
  ;; The vendor prefix and the dated snapshot go, since neither says anything
  ;; on a one-line readout; the context marker stays, because it does.
  (should (equal (sprig--model-label "claude-opus-5") "opus-5"))
  (should (equal (sprig--model-label "claude-opus-5[1m]") "opus-5[1m]"))
  (should (equal (sprig--model-label "claude-sonnet-4-5-20250929") "sonnet-4-5"))
  (should (equal (sprig--model-label "claude-sonnet-4-5-20250929[1m]")
                 "sonnet-4-5[1m]"))
  ;; An alias, or another backend's id, is left as it came.
  (should (equal (sprig--model-label "sonnet") "sonnet"))
  (should-not (sprig--model-label nil))
  (should-not (sprig--model-label "")))

(ert-deftest sprig-test-model-keeps-its-context-marker ()
  ;; Only the init line carries the marker, and every turn afterwards names
  ;; the same model without it, so reporting it again must not cost us the
  ;; marker.  A genuine switch still replaces the lot.
  (should (equal (plist-get (sprig-session-build
                             '((model "claude-opus-5[1m]")
                               (model "claude-opus-5")))
                            :model)
                 "claude-opus-5[1m]"))
  (should (equal (plist-get (sprig-session-build
                             '((model "claude-opus-5[1m]")
                               (model "claude-sonnet-4-5")))
                            :model)
                 "claude-sonnet-4-5")))

(ert-deftest sprig-test-status-state-line ()
  ;; The state line mirrors the session buffer: live states from the row's
  ;; status, the turn's outcome and context from the model fields; nil when
  ;; there is nothing to say.
  (should (null (sprig--status-state-line '(:buffer nil) nil)))
  (let ((l (sprig--status-state-line '(:status idle) '(:done t :context 134000))))
    (should (string-match-p "✓  turn over" l))
    (should (string-match-p "·" l))
    (should (string-match-p "134.0k" l)))
  (should (string-match-p "▶  working…"
                          (sprig--status-state-line '(:status streaming) nil)))
  (should (string-match-p "✗  turn failed"
                          (sprig--status-state-line '(:status idle) '(:error t))))
  (should (string-match-p "waiting on you"
                          (sprig--status-state-line '(:status idle) '(:pending t))))
  ;; A notable permission mode rides the state line; an everyday one does not.
  (let ((l (sprig--status-state-line '(:status idle) '(:done t :mode "plan"))))
    (should (string-match-p "turn over" l))
    (should (string-match-p "plan" l)))
  (should-not (string-match-p
               "auto"
               (sprig--status-state-line '(:status idle) '(:done t :mode "auto"))))
  ;; A background agent still running reads ahead of `turn over', whether the
  ;; row status or the preview flag reports it.
  (should (string-match-p
           "agent working…"
           (sprig--status-state-line '(:status agent) '(:done t))))
  (should (string-match-p
           "agent working…"
           (sprig--status-state-line '(:status idle) '(:done t :agent-running t))))
  ;; A message queued for the running turn is flagged, the way the review
  ;; buffer's state line flags it; no queue, no flag.
  (let ((l (sprig--status-state-line '(:status streaming :queued 2) nil)))
    (should (string-match-p "▶  working…" l))
    (should (string-match-p "2 queued" l)))
  (should-not (string-match-p
               "queued"
               (sprig--status-state-line '(:status streaming :queued 0) nil)))
  ;; The model rides the line too, shortened; without one, nothing shows.
  (let ((l (sprig--status-state-line '(:status idle)
                                     '(:done t :model "claude-opus-5[1m]"))))
    (should (string-match-p "turn over" l))
    (should (string-match-p "opus-5\\[1m\\]" l)))
  (should-not (string-match-p
               "opus"
               (sprig--status-state-line '(:status idle) '(:done t))))
  ;; A queue alone is enough to draw the line even with nothing else to say.
  (should (string-match-p
           "1 queued"
           (sprig--status-state-line '(:queued 1) nil))))

(ert-deftest sprig-test-status-refresh-soon-coalesces ()
  ;; A burst of events schedules a single render; a second call while one is
  ;; pending is folded in, not stacked.  Needs the navigator open, and nil
  ;; interval keeps it off entirely.
  (let ((sprig--status-refresh-timer nil))
    (unwind-protect
        (progn
          ;; No navigator open: nothing scheduled, whatever the interval.
          (let ((sprig-status-live-refresh-interval 1.0))
            (sprig--status-refresh-soon)
            (should-not sprig--status-refresh-timer))
          (unwind-protect
              (with-current-buffer (get-buffer-create sprig-status-buffer-name)
                ;; Disabled by nil interval, even with the navigator open.
                (let ((sprig-status-live-refresh-interval nil))
                  (sprig--status-refresh-soon)
                  (should-not sprig--status-refresh-timer))
                ;; Enabled: one timer, and a second call coalesces onto it.
                (let ((sprig-status-live-refresh-interval 1.0))
                  (sprig--status-refresh-soon)
                  (let ((first sprig--status-refresh-timer))
                    (should first)
                    (sprig--status-refresh-soon)
                    (should (eq first sprig--status-refresh-timer)))))
            (when (get-buffer sprig-status-buffer-name)
              (kill-buffer sprig-status-buffer-name)))
          ;; The cancel path clears the pending render.
          (sprig--status-refresh-cancel)
          (should-not sprig--status-refresh-timer))
      (sprig--status-refresh-cancel))))

(ert-deftest sprig-test-state-parts-shared-vocabulary ()
  ;; The one table the session buffer and the navigator both read, so their
  ;; state lines cannot drift.  An unknown state falls back to idle.
  (should (equal (sprig--state-parts 'streaming)
                 '("▶" "working…" sprig-session-working)))
  (should (equal (sprig--state-parts 'agent)
                 '("▶" "agent working…" sprig-session-working)))
  (should (equal (sprig--state-parts 'done)
                 '("✓" "turn over" sprig-session-done)))
  (should (equal (sprig--state-parts 'waiting)
                 '("?" "waiting on you" sprig-session-waiting)))
  (should (equal (sprig--state-parts 'anything-else)
                 '("●" "idle" sprig-session-idle))))

(ert-deftest sprig-test-notable-mode ()
  ;; Only the modes worth flagging come back; the everyday ones are dropped.
  (should (equal (sprig--notable-mode "plan") "plan"))
  (should (equal (sprig--notable-mode "bypassPermissions") "bypassPermissions"))
  (should-not (sprig--notable-mode "auto"))
  (should-not (sprig--notable-mode "manual"))
  (should-not (sprig--notable-mode "default"))
  (should-not (sprig--notable-mode nil)))

(ert-deftest sprig-test-status-context-face-escalates ()
  ;; The count colours on its own terms: plain when small, amber past the
  ;; large mark, red past the very-large one, mirroring the session buffer.
  (let ((sprig-context-large-tokens 150000)
        (sprig-context-huge-tokens 200000))
    (should (eq (sprig--status-context-face 50000) 'sprig-session-context))
    (should (eq (sprig--status-context-face 158400) 'sprig-session-context-large))
    (should (eq (sprig--status-context-face 250000) 'sprig-session-context-huge)))
  ;; With the thresholds unbound (the review mode not loaded) there is nothing
  ;; to escalate to, so even a big count stays in the plain face.
  (should (eq (sprig--status-context-face 999999) 'sprig-session-context)))

(ert-deftest sprig-test-events-preview-carries-state ()
  ;; The preview surfaces the model's outcome, context, and mode for the line.
  (let ((p (sprig--events-preview
            '((user "q") (text "a") (context 134000) (mode "plan") (done 0.1 nil)))))
    (should (eq (plist-get p :done) t))
    (should (equal (plist-get p :context) 134000))
    (should (equal (plist-get p :mode) "plan"))))

(ert-deftest sprig-test-events-preview-carries-time ()
  ;; The preview surfaces the freshest block's stamp for the render to show.
  (let ((p (sprig--events-preview
            '((time "2026-08-03T10:00:00Z") (user "q") (text "an answer")))))
    (should (equal (plist-get p :time) "2026-08-03T10:00:00Z"))))

(ert-deftest sprig-test-status-reply-oneline-collapses-prose ()
  ;; The reply teaser collapses paragraphs and wrapping to a single line of
  ;; prose, so the row shows one line rather than a block.
  (should (equal (sprig--status-reply-oneline "First para.\n\nSecond  para.")
                 "First para. Second para."))
  (should (equal (sprig--status-reply-oneline nil) "")))

(ert-deftest sprig-test-status-preview-lines-one-line-reply ()
  ;; A multi-paragraph reply renders as a single preview line, never a block.
  (let ((preview '(:prompt "ask" :reply "First para.\n\nSecond para." :time nil)))
    (cl-letf (((symbol-function 'sprig--entry-preview) (lambda (_) preview)))
      (let* ((lines (sprig--status-preview-lines '(:buffer nil :file nil)))
             (reply-line (seq-find (lambda (l) (string-match-p "First para" l))
                                   lines)))
        (should reply-line)
        (should (string-match-p "First para\\. Second para\\." reply-line))
        (should (= 1 (seq-count (lambda (l) (string-match-p "para" l)) lines)))))))

(ert-deftest sprig-test-format-time-value ()
  ;; A time value formats to a short local string; today's clock, else dated.
  (should (stringp (sprig--format-time-value (current-time))))
  (should (null (sprig--format-time-value nil))))

(ert-deftest sprig-test-status-scan-cache-reuses-and-invalidates ()
  ;; The navigator caches its disk scan, so a live re-render reuses it rather
  ;; than re-reading every log; a structural refresh expires the cache, and the
  ;; next read returns the stale rows at once and refreshes in the background
  ;; rather than blocking on a second synchronous scan.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/cache")
         (sprig-remotes nil)
         (sprig-claude-projects-directory root)
         (sprig--status-scan-cache nil)
         (sprig--status-remote-scan-hosts nil)
         (calls 0)
         (scheduled 'unset))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj "sess-cache"
           `(:type "user" :cwd ,proj :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "Cached"))
          (cl-letf* ((orig (symbol-function 'sprig--scan-session-logs))
                     ((symbol-function 'sprig--scan-session-logs)
                      (lambda (&rest a) (setq calls (1+ calls)) (apply orig a)))
                     ((symbol-function 'sprig--status-scan-async)
                      (lambda (h) (setq scheduled h))))
            ;; Cold read scans once; a second within the TTL reuses the cache.
            (should (sprig--status-scan-cached nil))
            (sprig--status-scan-cached nil)
            (should (= calls 1))
            (should (eq scheduled 'unset))
            ;; A structural refresh expires the cache; the next read returns the
            ;; stale rows at once and schedules a background scan for the local
            ;; host (nil), never a second synchronous scan.
            (sprig--status-scan-invalidate)
            (should (sprig--status-scan-cached nil))
            (should (= calls 1))
            (should (null scheduled))))
      (delete-directory root t))))

(ert-deftest sprig-test-status-scan-async-local-uses-sh-not-ssh ()
  ;; The background scan for the local host runs in a bare `sh -c', never
  ;; through ssh (which would defeat the point) and never through TRAMP.
  (let* ((sprig-remotes nil)
         (sprig-claude-projects-directory "/tmp/nope")
         (sprig--status-remote-scan-hosts nil)
         (captured nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args) (setq captured (plist-get args :command)) 'proc))
              ((symbol-function 'set-process-sentinel) #'ignore))
      (sprig--status-scan-async nil)
      (should (equal (car captured) "sh"))
      (should (equal (cadr captured) "-c"))
      (should-not (member sprig-ssh-program captured)))))

(ert-deftest sprig-test-status-scan-async-remote-uses-ssh ()
  ;; A remote host's background scan is the same shell command, wrapped in ssh.
  (let* ((sprig--status-remote-scan-hosts nil)
         (sprig-claude-projects-directory "~/.claude/projects")
         (captured nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args) (setq captured (plist-get args :command)) 'proc))
              ((symbol-function 'set-process-sentinel) #'ignore))
      (sprig--status-scan-async "me@host")
      (should (equal (car captured) sprig-ssh-program))
      (should (member "me@host" captured)))))

(ert-deftest sprig-test-status-scan-cold-remote-never-blocks ()
  ;; Even the first open of a remote host never scans synchronously: with
  ;; nothing cached yet it returns nothing and schedules a background scan,
  ;; rather than blocking Emacs on the SSH round trip.
  (let* ((sprig-claude-projects-directory "/x")
         (sprig--status-scan-cache nil)
         (sprig--status-remote-scan-hosts nil)
         (scheduled 'unset))
    (cl-letf (((symbol-function 'sprig--status-scan-async)
               (lambda (h) (setq scheduled h)))
              ((symbol-function 'sprig--remote-sh)
               (lambda (&rest _)
                 (error "must not block on SSH for a cold open"))))
      (should (null (sprig--status-scan-cached "host")))
      (should (equal scheduled "host")))))

(ert-deftest sprig-test-remote-log-command ()
  ;; The one-round-trip log fetch finds the log by id and cats it.
  (let* ((sprig-claude-projects-directory "~/.claude/projects")
         (cmd (sprig--remote-log-command "abc-123")))
    (should (string-match-p "find " cmd))
    (should (string-match-p "abc-123\\.jsonl" cmd))
    (should (string-match-p "cat " cmd))))

(ert-deftest sprig-test-status-render-signature-tracks-visible-changes ()
  ;; The live-tick skip hinges on this: an unchanged render yields an identical
  ;; signature, and any visible change (a title, or the row's formatted time)
  ;; changes it.  The formatted time string is compared, not the raw value.
  (cl-letf (((symbol-function 'sprig--status-collapsed-p) (lambda (_) nil))
            ((symbol-function 'sprig--format-time-value)
             (lambda (m) (format "%s" m))))
    (let ((a '(:key ("h" . "s1") :host "h" :status disconnected :title "One"
                    :project "p" :session "s1" :created 100 :queued 0))
          (b '(:key ("h" . "s1") :host "h" :status disconnected :title "Two"
                    :project "p" :session "s1" :created 100 :queued 0)))
      (should (equal (sprig--status-render-signature (list a))
                     (sprig--status-render-signature (list a))))
      (should-not (equal (sprig--status-render-signature (list a))
                         (sprig--status-render-signature (list b)))))
    (let ((a '(:key ("h" . "s1") :host "h" :status disconnected :title "One"
                    :project "p" :session "s1" :created 100 :queued 0)))
      (cl-letf (((symbol-function 'sprig--format-time-value) (lambda (_) "2m")))
        (let ((sig (sprig--status-render-signature (list a))))
          (cl-letf (((symbol-function 'sprig--format-time-value)
                     (lambda (_) "3m")))
            (should-not (equal sig (sprig--status-render-signature
                                    (list a))))))))))

(ert-deftest sprig-test-status-row-shows-created-column ()
  ;; The row carries the session's creation time in an outer `Created' column,
  ;; read from the first log record's timestamp, so it is visible even with the
  ;; preview collapsed.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/whenrow")
         (sprig-remotes nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root proj "sess-one"
           `(:type "user" :timestamp "2026-08-05T09:16:56.955Z" :cwd ,proj
             :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "Whenish"))
          (with-temp-buffer
            (sprig-status-mode)
            (sprig--status-render)
            (goto-char (point-min))
            (should (search-forward "Whenish" nil t))
            (beginning-of-line)
            ;; The cell dates the session's creation as a short local time.
            (let ((cell (aref (tabulated-list-get-entry) 4)))
              (should (string-match-p "[0-9][0-9]:[0-9][0-9]" cell)))))
      (delete-directory root t))))

(ert-deftest sprig-test-status-sort-rows-created-desc ()
  ;; The default sort puts the newest-created session first.
  (let* ((sprig--status-sort '("Created" . t))
         (rows (list '(:session "old" :created 100 :host nil)
                     '(:session "new" :created 300 :host nil)
                     '(:session "mid" :created 200 :host nil)))
         (sorted (sprig--status-sort-rows rows)))
    (should (equal (mapcar (lambda (e) (plist-get e :session)) sorted)
                   '("new" "mid" "old")))))

(ert-deftest sprig-test-status-sort-rows-title-asc ()
  ;; Sorting by Title is ascending and case-insensitive.
  (let* ((sprig--status-sort '("Title"))
         (rows (list '(:title "Banana") '(:title "apple") '(:title "Cherry")))
         (sorted (sprig--status-sort-rows rows)))
    (should (equal (mapcar (lambda (e) (plist-get e :title)) sorted)
                   '("apple" "Banana" "Cherry")))))

(ert-deftest sprig-test-status-sort-rows-fresh-session-tops ()
  ;; A live session with no log yet (no creation time) sorts to the top,
  ;; newest first.
  (let* ((sprig--status-sort '("Created" . t))
         (rows (list '(:session "stored" :created 500)
                     '(:session "fresh")))
         (sorted (sprig--status-sort-rows rows)))
    (should (equal (plist-get (car sorted) :session) "fresh"))))

(ert-deftest sprig-test-status-sort-rows-starred-floats ()
  ;; A starred row floats above the rest of its group, keeping the column
  ;; order among the starred and among the unstarred alike.
  (let* ((sprig--status-sort '("Created" . t))
         (rows (list '(:session "old" :created 100 :host nil :starred t)
                     '(:session "new" :created 300 :host nil)
                     '(:session "mid" :created 200 :host nil)))
         (sorted (sprig--status-sort-rows rows)))
    ;; "old" is oldest, yet its star lifts it over the newer unstarred pair.
    (should (equal (mapcar (lambda (e) (plist-get e :session)) sorted)
                   '("old" "new" "mid")))))

(ert-deftest sprig-test-star-file-sits-beside-the-log ()
  ;; The marker replaces the log's `.jsonl' with `.sprig-star', in place.
  (should (equal (sprig--star-file "/p/proj/abc123.jsonl")
                 "/p/proj/abc123.sprig-star")))

(ert-deftest sprig-test-parse-scan-reads-the-star-flag ()
  ;; A `1' in the star field marks the row starred; an empty field does not.
  (let* ((rec (lambda (id star head)
                (concat "\036" "100" "\037" "/p/" id ".jsonl" "\037"
                        star "\037" head "\037" "")))
         (blob (concat (funcall rec "s1" "1" "{\"cwd\":\"/a\"}")
                       (funcall rec "s2" "" "{\"cwd\":\"/b\"}")))
         (rows (sprig--parse-scan-rows blob nil)))
    (should (equal (mapcar (lambda (r) (list (plist-get r :session)
                                             (plist-get r :starred)))
                           rows)
                   '(("s1" t) ("s2" nil))))))

(ert-deftest sprig-test-status-collect-keeps-a-scan-only-star ()
  ;; A disconnected row (a scanned log with no open buffer) carries its star
  ;; through `sprig--status-collect', not only rows an open buffer owns.
  (let ((sprig-remotes nil)
        (sprig--status-scan-cache nil))
    (cl-letf (((symbol-function 'sprig--owning-review-buffers) (lambda () nil))
              ((symbol-function 'sprig--status-scan-cached)
               (lambda (host)
                 (when (null host)
                   (list (list :session "s1" :file "/p/s1.jsonl" :dir "/p"
                               :project "p" :title "One" :mtime 10 :created 10
                               :starred t))))))
      (let* ((rows (sprig--status-collect))
             (e (car rows)))
        (should (equal (plist-get e :session) "s1"))
        (should (plist-get e :starred))))))

(ert-deftest sprig-test-status-scan-cache-set-star-patches-in-place ()
  ;; Patching the cache flips a cached row's star, so a toggle shows at once
  ;; instead of waiting for the background re-scan; other rows are untouched.
  (let* ((sprig-claude-projects-directory "/x")
         (r1 (list :session "s1" :starred nil))
         (r2 (list :session "s2" :starred nil))
         (sprig--status-scan-cache
          (list (cons (cons nil (sprig--projects-directory))
                      (cons '(0 0) (list r1 r2))))))
    (sprig--status-scan-cache-set-star nil "s1" t)
    (should (plist-get r1 :starred))
    (should-not (plist-get r2 :starred))
    ;; A miss (unknown host or session) is a quiet no-op.
    (sprig--status-scan-cache-set-star "other@host" "s1" t)
    (sprig--status-scan-cache-set-star nil "nope" t)
    (should (plist-get r1 :starred))))

(ert-deftest sprig-test-status-star-command-writes-and-removes-a-marker ()
  ;; `*' writes the marker for an unstarred row and removes it for a starred
  ;; one, targeting the row's own log and host; a row with no log errors.
  (let (calls)
    (cl-letf (((symbol-function 'sprig--star-write)
               (lambda (log host starred) (push (list log host starred) calls)))
              ((symbol-function 'sprig--status-render) #'ignore)
              ((symbol-function 'sprig--status-entry-at-point)
               (lambda () '(:host "a@h" :file "/p/s1.jsonl"))))
      (sprig-status-star)
      (should (equal (car calls) '("/p/s1.jsonl" "a@h" t))))
    (cl-letf (((symbol-function 'sprig--star-write)
               (lambda (log host starred) (push (list log host starred) calls)))
              ((symbol-function 'sprig--status-render) #'ignore)
              ((symbol-function 'sprig--status-entry-at-point)
               (lambda () '(:host nil :file "/p/s1.jsonl" :starred t))))
      (sprig-status-star)
      (should (equal (car calls) '("/p/s1.jsonl" nil nil))))
    (cl-letf (((symbol-function 'sprig--status-entry-at-point)
               (lambda () '(:host nil :file nil))))
      (should-error (sprig-status-star) :type 'user-error))))

(ert-deftest sprig-test-star-write-round-trips-a-local-marker ()
  ;; Local starring creates the sibling file and unstarring removes it.
  (let* ((dir (make-temp-file "sprig-star" t))
         (log (expand-file-name "s1.jsonl" dir))
         (marker (sprig--star-file log)))
    (unwind-protect
        (progn
          (sprig--star-write log nil t)
          (should (file-exists-p marker))
          (sprig--star-write log nil nil)
          (should-not (file-exists-p marker))
          ;; Unstarring an already-absent marker is a no-op, not an error.
          (sprig--star-write log nil nil)
          (should-not (file-exists-p marker)))
      (delete-directory dir t))))

(ert-deftest sprig-test-status-sort-command-flips-direction ()
  ;; The command sets the sort, and a second call on the same column flips it;
  ;; a text column defaults ascending, Created descending.
  (with-temp-buffer
    (sprig-status-mode)
    (sprig--status-render)
    (sprig-status-sort "Title")
    (should (equal sprig--status-sort '("Title")))
    (sprig-status-sort "Title")
    (should (equal sprig--status-sort '("Title" . t)))
    (sprig-status-sort "Created")
    (should (equal sprig--status-sort '("Created" . t)))))

(ert-deftest sprig-test-status-preview-line-resolves-the-row-session ()
  ;; A verb keyed on point works from an inline preview line: the line
  ;; carries the row's id, so it resolves to the same session as the row.
  ;; An active row shows its preview on its own; forcing the active check
  ;; stands in for a live owning buffer the test does not spin up.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/prevrow")
         (sprig-remotes nil)
         (sprig-claude-projects-directory root))
    (unwind-protect
        (cl-letf (((symbol-function 'sprig--status-entry-active-p) (lambda (_) t)))
          (sprig-tests--make-session-log
           root proj "sess-one"
           `(:type "user" :cwd ,proj :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "Rowed"))
          (with-temp-buffer
            (sprig-status-mode)
            (sprig--status-render)
            (goto-char (point-min))
            (should (search-forward "Rowed" nil t))
            (beginning-of-line)
            (let ((id (tabulated-list-get-id)))
              (should id)
              ;; The line just below the row is the preview: it has no
              ;; tabulated id of its own, yet resolves to the same session.
              (forward-line 1)
              (should-not (tabulated-list-get-id))
              (should (equal (sprig--status-id-at-point) id))
              (should (equal (plist-get (sprig--status-entry-at-point) :key)
                             id)))))
      (delete-directory root t))))

(ert-deftest sprig-test-log-ignored-p ()
  ;; The ignore list matches a log's encoded project directory name, read
  ;; from the path (no content), and is precise about boundaries.
  (let ((sprig-status-ignore-directories '("\\`-tmp\\(-\\|\\'\\)" "sdk-probe")))
    (should (sprig--log-ignored-p "/x/.claude/projects/-tmp/a.jsonl"))
    (should (sprig--log-ignored-p "/x/.claude/projects/-tmp-sdk-probe/a.jsonl"))
    (should (sprig--log-ignored-p "/x/.claude/projects/-home-me-sdk-probe/a.jsonl"))
    (should-not (sprig--log-ignored-p "/x/.claude/projects/-home-me-real/a.jsonl"))
    ;; `-tmpfoo' is not `/tmp': the boundary guard keeps it.
    (should-not (sprig--log-ignored-p "/x/.claude/projects/-tmpfoo/a.jsonl")))
  (let ((sprig-status-ignore-directories nil))
    (should-not (sprig--log-ignored-p "/x/.claude/projects/-tmp/a.jsonl"))))

(ert-deftest sprig-test-scan-ignores-directories ()
  ;; A session under an ignored directory is dropped from the scan.
  (let* ((root (make-temp-file "sprig-proj" t))
         (sprig-remotes nil)
         (sprig-claude-projects-directory root)
         (sprig-status-ignore-directories '("\\`-tmp\\(-\\|\\'\\)")))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root "/tmp/sdk-probe" "probe-1"
           `(:type "user" :cwd "/tmp/sdk-probe" :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "Probe"))
          (sprig-tests--make-session-log
           root "/home/me/real" "real-1"
           `(:type "user" :cwd "/home/me/real" :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "Real work"))
          (let ((rows (sprig--scan-session-logs)))
            (should (= 1 (length rows)))
            (should (equal (plist-get (car rows) :session) "real-1"))))
      (delete-directory root t))))

(ert-deftest sprig-test-scan-ignore-before-cap ()
  ;; The drop happens before the newest-N cap, so a throwaway session
  ;; written last does not crowd out the kept one under a cap of 1.
  (let* ((root (make-temp-file "sprig-proj" t))
         (sprig-remotes nil)
         (sprig-claude-projects-directory root)
         (sprig-status-max-sessions 1)
         (sprig-status-ignore-directories '("\\`-tmp\\'")))
    (unwind-protect
        (progn
          (sprig-tests--make-session-log
           root "/home/me/keep" "keep-1"
           `(:type "user" :cwd "/home/me/keep" :message (:role "user" :content "hi")))
          (sprig-tests--make-session-log
           root "/tmp" "junk-1"
           `(:type "user" :cwd "/tmp" :message (:role "user" :content "hi")))
          (let ((rows (sprig--scan-session-logs)))
            (should (= 1 (length rows)))
            (should (equal (plist-get (car rows) :session) "keep-1"))))
      (delete-directory root t))))

(ert-deftest sprig-session-test-build-dialog-blocks ()
  ;; A question stands pending until an answer of the same id settles it, so
  ;; a rebuild (which every render does) still knows it was settled.
  (let* ((input '((questions . [((question . "Which?")
                                 (options . [((label . "A")) ((label . "B"))]))])))
         (model (sprig-session-build
                 `((dialog "req-1" "ask_user_question" ,input))))
         (block (car (plist-get model :blocks))))
    (should (eq (plist-get block :type) 'dialog))
    (should (equal (plist-get block :id) "req-1"))
    (should-not (plist-get block :answered))
    (should (eq block (sprig-session-pending-dialog model))))
  ;; Answered: settled, and no longer pending.
  (let* ((input '((questions . [((question . "Which?")
                                 (options . [((label . "A"))]))])))
         (model (sprig-session-build
                 `((dialog "req-1" "ask_user_question" ,input)
                   (dialog-answer "req-1" ((Which? . "A"))))))
         (block (car (plist-get model :blocks))))
    (should (plist-get block :answered))
    (should (equal (plist-get block :answers) '((Which? . "A"))))
    (should-not (sprig-session-pending-dialog model)))
  ;; Waved through: settled with nothing, and still not pending.
  (let* ((input '((questions . [((question . "Which?") (options . []))])))
         (model (sprig-session-build
                 `((dialog "req-1" "ask_user_question" ,input)
                   (dialog-answer "req-1" nil)))))
    (should (plist-get (car (plist-get model :blocks)) :answered))
    (should-not (sprig-session-pending-dialog model))))

(ert-deftest sprig-test-user-question-does-not-block-the-filter ()
  ;; The control request is handled inside the process filter.  Prompting
  ;; there held the filter, and Emacs with it, until the question was
  ;; answered.  It must only hand the question over and return.
  (with-temp-buffer
    (let (consumed responded)
      (cl-letf (((symbol-function 'sprig-session-consume)
                 (lambda (event) (push event consumed)))
                ((symbol-function 'sprig--send-control-response)
                 (lambda (&rest _) (setq responded t)))
                ;; Any prompt reaching the minibuffer is the bug.
                ((symbol-function 'completing-read)
                 (lambda (&rest _) (error "prompted in the filter")))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (error "prompted in the filter"))))
        (sprig--answer-control-request
         "req-1" '((subtype . "can_use_tool")
                   (tool_name . "AskUserQuestion")
                   (input . ((questions . [((question . "Which?"))]))))))
      ;; Handed to the buffer, and nothing said back yet: the agent waits.
      (should (equal (car consumed)
                     '(dialog "req-1" "ask_user_question"
                              ((questions . [((question . "Which?"))])))))
      (should-not responded))))

(ert-deftest sprig-test-answer-dialog-replies-with-updated-input ()
  ;; The answers ride back as `updatedInput', the input plus an `answers'
  ;; map, which is how the CLI feeds them to the tool.
  (with-temp-buffer
    (let ((input '((questions . [((question . "Which?"))])))
          sent consumed)
      (cl-letf (((symbol-function 'sprig--send-control-response)
                 (lambda (id response) (setq sent (list id response))))
                ((symbol-function 'sprig-session-consume)
                 (lambda (event) (setq consumed event))))
        (sprig--review-answer-dialog "req-1" input '((Which? . "A"))))
      (should (equal (car sent) "req-1"))
      (should (equal (plist-get (cadr sent) :behavior) "allow"))
      (should (equal (alist-get 'answers (plist-get (cadr sent) :updatedInput))
                     '((Which? . "A"))))
      ;; And the buffer is told, so the block settles.
      (should (equal consumed '(dialog-answer "req-1" ((Which? . "A")))))))
  ;; Skipped: allowed with no answers, which the tool replays as its own
  ;; skip rather than as an error.
  (with-temp-buffer
    (let (sent)
      (cl-letf (((symbol-function 'sprig--send-control-response)
                 (lambda (_id response) (setq sent response)))
                ((symbol-function 'sprig-session-consume) #'ignore))
        (sprig--review-answer-dialog "req-1" '((questions . [])) nil))
      (should (equal sent '(:behavior "allow"))))))

(ert-deftest sprig-test-review-steer-writes-into-the-live-turn ()
  ;; Steering writes the message to the session's stdin and floats it, without
  ;; opening a turn of its own: the CLI hands it to the agent at its next
  ;; tool-call boundary, and the turn in flight still ends on its own `done'.
  (with-temp-buffer
    (setq-local sprig--busy t)
    (let (wrote staged delivered)
      (cl-letf (((symbol-function 'sprig--send-user)
                 (lambda (text) (setq wrote text)))
                ((symbol-function 'sprig-session-stage-steer)
                 (lambda (text) (setq staged text)))
                ((symbol-function 'sprig--review-deliver)
                 (lambda (&rest _) (setq delivered t))))
        (sprig--review-steer "actually, do X"))
      (should (equal wrote "actually, do X"))
      ;; Floated, not spliced into the stream: it waits above the state line
      ;; until the agent takes it, rather than breaking up the running message.
      (should (equal staged "actually, do X"))
      ;; Not delivered as a turn of its own, and the turn stays in flight.
      (should-not delivered)
      (should sprig--busy))))

(ert-deftest sprig-test-review-steer-falls-back-when-the-turn-ended ()
  ;; A turn can finish while its steering message is still being composed.
  ;; The message is then sent as a turn of its own rather than lost.
  (with-temp-buffer
    (setq-local sprig--busy nil)
    (let (wrote delivered)
      (cl-letf (((symbol-function 'sprig--send-user)
                 (lambda (text) (setq wrote text)))
                ((symbol-function 'sprig--review-deliver)
                 (lambda (text &optional _mode) (setq delivered text))))
        (sprig--review-steer "actually, do X"))
      (should (equal delivered "actually, do X"))
      (should-not wrote))))

(ert-deftest sprig-test-review-deliver-refuses-mid-turn ()
  ;; Deliver still will not open a second turn.  Only `c p' can reach this
  ;; busy now (it needs a turn of its own for its permission mode), so the
  ;; refusal points at the two verbs that do work mid-turn, not at itself.
  (with-temp-buffer
    (setq-local sprig--busy t)
    (cl-letf (((symbol-function 'sprig--ensure) #'ignore)
              ((symbol-function 'sprig--send-user)
               (lambda (_) (error "should not have sent"))))
      (let ((err (should-error (sprig--review-deliver "hi") :type 'user-error)))
        (should (string-match-p "c c" (cadr err)))
        (should (string-match-p "c q" (cadr err)))))))

(ert-deftest sprig-test-undefine-faces-lets-a-reload-restyle ()
  ;; `defface' is a no-op on an already-defined face, so `sprig-reload' has
  ;; to undefine sprig's faces first or an edited spec keeps its stale
  ;; attributes until Emacs restarts.
  (let ((face 'sprig-tests--throwaway-face))
    (unwind-protect
        (progn
          (face-spec-set face '((t :slant italic)) 'face-defface-spec)
          (should (eq (face-attribute face :slant nil t) 'italic))
          ;; A plain re-`defface' does not take: the old slant survives.
          (custom-declare-face face '((t :weight bold)) "")
          (should (eq (face-attribute face :slant nil t) 'italic))
          ;; Undefining first is what lets the new spec land.
          (cl-letf (((symbol-function 'face-list) (lambda () (list face))))
            (sprig--undefine-faces))
          (custom-declare-face face '((t :weight bold)) "")
          (should (eq (face-attribute face :slant nil t) 'unspecified))
          (should (eq (face-attribute face :weight nil t) 'bold)))
      (put face 'face-defface-spec nil))))

(ert-deftest sprig-test-usage-render-paints-the-plan-gauges ()
  ;; The usage view is a render of the endpoint's `limits' array: one gauge
  ;; per rolling limit, labelled by kind (and by model for a scoped one),
  ;; with the spend block following when the account has credits enabled.
  (let ((data (json-parse-string "
{\"limits\": [
   {\"kind\": \"session\", \"percent\": 76, \"severity\": \"warning\",
    \"resets_at\": \"2099-01-01T16:19:59.730664+00:00\", \"scope\": null},
   {\"kind\": \"weekly_all\", \"percent\": 59, \"severity\": \"normal\",
    \"resets_at\": null, \"scope\": null},
   {\"kind\": \"weekly_scoped\", \"percent\": 40, \"severity\": \"normal\",
    \"resets_at\": null,
    \"scope\": {\"model\": {\"id\": null, \"display_name\": \"Fable\"}}}],
 \"spend\": {\"enabled\": true,
             \"used\": {\"amount_minor\": 1250, \"currency\": \"EUR\",
                        \"exponent\": 2},
             \"limit\": {\"amount_minor\": 17000, \"currency\": \"EUR\",
                         \"exponent\": 2}}}"
                                 :object-type 'alist :array-type 'list
                                 :null-object nil)))
    (with-temp-buffer
      (sprig--usage-render data)
      (let ((text (buffer-string)))
        (should (string-match-p "Session (5h)" text))
        (should (string-match-p "76%" text))
        (should (string-match-p "Week (all models)" text))
        (should (string-match-p "Week (Fable)" text))
        ;; The gauge is proportional: 76% paints eight of the ten cells.
        (should (string-match-p (regexp-quote "[████████░░]") text))
        ;; A reset instant renders with a countdown; a null one renders
        ;; nothing rather than "resets nil".
        (should (string-match-p "resets .* (in " text))
        (should-not (string-match-p "resets nil" text))
        ;; Money is minor units scaled by the exponent, not raw.
        (should (string-match-p "12.50 EUR of 170.00 EUR" text))))))

(ert-deftest sprig-test-usage-render-skips-a-disabled-spend-block ()
  ;; An account without usage credits still answers with a spend object;
  ;; `enabled' false means the row would be noise, so it is not drawn.
  (let ((data (json-parse-string
               "{\"limits\": [], \"spend\": {\"enabled\": false}}"
               :object-type 'alist :array-type 'list :null-object nil)))
    (with-temp-buffer
      (sprig--usage-render data)
      (should-not (string-match-p "Extra usage" (buffer-string)))
      (should (string-match-p "No limits reported" (buffer-string))))))

(ert-deftest sprig-test-usage-token-reads-the-cli-login ()
  ;; The token comes from the CLI's own credential store, honouring
  ;; `sprig-config-directory'; a missing or unreadable file is nil, never
  ;; an error, so `sprig-usage' can say "log in" instead of backtracing.
  (let ((dir (make-temp-file "sprig-test-cred" t)))
    (unwind-protect
        (let ((sprig-config-directory dir))
          (should-not (sprig--usage-token))
          (with-temp-file (expand-file-name ".credentials.json" dir)
            (insert "{\"claudeAiOauth\": {\"accessToken\": \"sk-ant-test\"}}"))
          (should (equal (sprig--usage-token) "sk-ant-test"))
          (with-temp-file (expand-file-name ".credentials.json" dir)
            (insert "not json"))
          (should-not (sprig--usage-token)))
      (delete-directory dir t))))

(ert-deftest sprig-test-usage-consumption-script-sums-once-per-request ()
  ;; The consumption count reads the logs raw, so it has to dedupe: a
  ;; reply's assistant record repeats under one (message id, request id)
  ;; pair as it streams, and counting each copy would multiply the bill.
  ;; Synthetic error records carry no real usage and are skipped.
  (skip-unless (executable-find "python3"))
  (let ((root (make-temp-file "sprig-test-usage" t)))
    (unwind-protect
        (let ((proj (expand-file-name "proj" root)))
          (make-directory proj)
          (with-temp-file (expand-file-name "a.jsonl" proj)
            (dolist (line '("{\"type\":\"assistant\",\"timestamp\":\"2026-08-18T10:00:00Z\",\"requestId\":\"r1\",\"message\":{\"id\":\"m1\",\"model\":\"claude-fable-5\",\"usage\":{\"input_tokens\":10,\"cache_creation_input_tokens\":90,\"cache_read_input_tokens\":1000,\"output_tokens\":50}}}"
                            "{\"type\":\"assistant\",\"timestamp\":\"2026-08-18T10:00:01Z\",\"requestId\":\"r1\",\"message\":{\"id\":\"m1\",\"model\":\"claude-fable-5\",\"usage\":{\"input_tokens\":10,\"cache_creation_input_tokens\":90,\"cache_read_input_tokens\":1000,\"output_tokens\":50}}}"
                            "{\"type\":\"assistant\",\"timestamp\":\"2026-08-17T09:00:00Z\",\"requestId\":\"r2\",\"message\":{\"id\":\"m2\",\"model\":\"claude-opus-4-8\",\"usage\":{\"input_tokens\":5,\"cache_read_input_tokens\":0,\"output_tokens\":7}}}"
                            "{\"type\":\"assistant\",\"timestamp\":\"2026-08-18T11:00:00Z\",\"requestId\":\"r3\",\"message\":{\"id\":\"m3\",\"model\":\"<synthetic>\",\"usage\":{\"input_tokens\":999}}}"
                            "{\"type\":\"user\",\"timestamp\":\"2026-08-18T10:00:02Z\",\"message\":{\"usage\":{\"input_tokens\":999}}}"))
              (insert line "\n")))
          (with-temp-buffer
            (should (eq 0 (call-process "python3" nil t nil "-c"
                                        sprig--usage-consumption-script root)))
            (let ((rows (json-parse-string (buffer-string)
                                           :object-type 'alist
                                           :array-type 'list
                                           :null-object nil)))
              (should (equal
                       rows
                       '(((day . "2026-08-17") (model . "claude-opus-4-8")
                          (fresh . 5) (read . 0) (out . 7))
                        ((day . "2026-08-18") (model . "claude-fable-5")
                         (fresh . 100) (read . 1000) (out . 50))))))))
      (delete-directory root t))))

(ert-deftest sprig-test-usage-consumption-insert-replaces-the-placeholder ()
  ;; The gauges render before the log count returns, so the view holds the
  ;; count's place with a marked line; the rows land where it was, and a
  ;; nil result (no python, no logs) resolves it rather than leaving
  ;; "Counting..." forever.
  (with-temp-buffer
    (sprig--usage-render '((limits) (spend)))
    (sprig--usage-consumption-insert
     '(((day . "2026-08-18") (model . "claude-fable-5")
        (fresh . 100) (read . 1000) (out . 50))))
    (let ((text (buffer-string)))
      (should-not (string-match-p "Counting" text))
      (should (string-match-p "Local consumption" text))
      (should (string-match-p "08-18" text))
      (should (string-match-p "fable-5" text))
      (should (string-match-p "0\\.1k in" text))
      (should (string-match-p "1\\.0k cached" text))))
  (with-temp-buffer
    (sprig--usage-render '((limits) (spend)))
    (sprig--usage-consumption-insert nil)
    (should-not (string-match-p "Counting" (buffer-string)))
    (should (string-match-p "No local consumption" (buffer-string)))))

(provide 'sprig-tests)
;;; sprig-tests.el ends here
