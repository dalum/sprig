;;; sprig-tests.el --- ERT tests for sprig  -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for the process-free layers of sprig: the claude CLI
;; transport (raw stream-json lines -> events), command construction, the
;; review model and diff engine, the stored-session log parser, and the
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
(require 'sprig-review)

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

(ert-deftest sprig-test-parse-compact-boundary-context ()
  ;; A compaction reports its post-compact size, so the readout drops at once.
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    (json-serialize
                     (list :type "system" :subtype "compact_boundary"
                           :compactMetadata (list :preTokens 398861
                                                  :postTokens 5457))))
                   '((context 5457))))))

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
                ((symbol-function 'sprig--status-refresh) #'ignore))
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
                ((symbol-function 'sprig--status-refresh) #'ignore))
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
                ((symbol-function 'sprig--status-refresh) #'ignore))
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
      (cl-letf (((symbol-function 'sprig-review-consume) #'ignore))
        (sprig--review-sink '(session "fork-2")))
      (should (equal sprig--session-id "fork-2"))
      (should-not sprig--fork-session)))
  ;; Without a fork, an id already captured stands: the CLI repeats it on
  ;; every resume, and taking it again would be a no-op at best.
  (with-temp-buffer
    (let ((sprig--session-id "sess-1") (sprig--fork-session nil))
      (cl-letf (((symbol-function 'sprig-review-consume) #'ignore))
        (sprig--review-sink '(session "sess-1")))
      (should (equal sprig--session-id "sess-1")))))

(ert-deftest sprig-test-command-local ()
  (with-temp-buffer
    (let ((sprig-remote nil) (sprig-program "claude") (sprig-directory nil))
      (let ((cmd (sprig--command)))
        (should (equal (car cmd) "claude"))
        (should (member "--input-format" cmd))))))

(ert-deftest sprig-test-command-remote ()
  (with-temp-buffer
    (let ((sprig-remote "me@host") (sprig-program "claude")
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
    (let ((sprig-remote "me@host") (sprig-program "claude")
          (sprig-ssh-program "ssh") (sprig-ssh-args '("-T" "-A"))
          (sprig-directory "~/proj")
          (sprig-config-directory "~/.config/sprig/claude"))
      (let ((payload (car (last (sprig--command)))))
        (should (string-prefix-p
                 "cd ~/proj && exec env CLAUDE_CONFIG_DIR=~/.config/sprig/claude \
claude"
                 payload))))))

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
  (let ((sprig-remote nil) (sprig-program "claude") (sprig-config-directory nil))
    (should (equal (sprig--login-command)
                   '("claude" "auth" "login" "--claudeai"))))
  ;; Remote with a config dir: an SSH payload carrying the `env' prefix,
  ;; the tilde kept live for the login shell to expand.
  (let ((sprig-remote "me@host") (sprig-program "claude")
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
  (let ((sprig-remote "me@host")
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

;;;; Review model and diff engine (sprig-review.el)

(ert-deftest sprig-review-test-lines ()
  ;; A trailing newline does not add a spurious final empty line.
  (should (equal (sprig-review--lines "foo\nbar\n") '("foo" "bar")))
  (should (equal (sprig-review--lines "foo\nbar") '("foo" "bar")))
  ;; A blank line inside the text is preserved.
  (should (equal (sprig-review--lines "a\n\nb") '("a" "" "b")))
  ;; Empty text is no lines, not one empty line.
  (should (equal (sprig-review--lines "") nil))
  (should (equal (sprig-review--lines nil) nil)))

(ert-deftest sprig-review-test-edit-changes ()
  (let* ((input (json-serialize
                 (list :file_path "/tmp/x.el" :old_string "old\nline"
                       :new_string "new\nline\nhere")))
         (changes (sprig-review-tool-changes "Edit" input))
         (change (car changes)))
    (should (= (length changes) 1))
    (should (equal (plist-get change :file) "/tmp/x.el"))
    (should (eq (plist-get change :kind) 'edit))
    (let ((hunk (car (plist-get change :hunks))))
      (should (equal (plist-get hunk :old) '("old" "line")))
      (should (equal (plist-get hunk :new) '("new" "line" "here"))))
    ;; +3 / -2.
    (should (equal (sprig-review-change-stat change) '(3 . 2)))))

(ert-deftest sprig-review-test-edit-replace-all ()
  (let* ((input (json-serialize
                 (list :file_path "/tmp/x.el" :old_string "a"
                       :new_string "b" :replace_all t)))
         (hunk (car (plist-get (car (sprig-review-tool-changes "Edit" input))
                               :hunks))))
    (should (eq (plist-get hunk :replace-all) t))))

(ert-deftest sprig-review-test-multiedit-changes ()
  (let* ((input (json-serialize
                 (list :file_path "/tmp/x.el"
                       :edits (vector (list :old_string "a" :new_string "b")
                                      (list :old_string "c" :new_string "d")))))
         (change (car (sprig-review-tool-changes "MultiEdit" input))))
    (should (= (length (plist-get change :hunks)) 2))
    (should (equal (plist-get (nth 1 (plist-get change :hunks)) :old) '("c")))))

(ert-deftest sprig-review-test-write-changes ()
  (let* ((input (json-serialize
                 (list :file_path "/tmp/new.el" :content "line1\nline2\n")))
         (change (car (sprig-review-tool-changes "Write" input))))
    (should (eq (plist-get change :kind) 'write))
    (let ((hunk (car (plist-get change :hunks))))
      ;; A write has no removals, only additions.
      (should (null (plist-get hunk :old)))
      (should (equal (plist-get hunk :new) '("line1" "line2"))))
    (should (equal (sprig-review-change-stat change) '(2 . 0)))))

(ert-deftest sprig-review-test-non-file-tool ()
  (should (null (sprig-review-tool-changes
                 "Bash" (json-serialize (list :command "ls")))))
  ;; A file tool missing its path yields no change rather than an error.
  (should (null (sprig-review-tool-changes "Edit" "{}"))))

(ert-deftest sprig-review-test-format-change ()
  (let* ((input (json-serialize
                 (list :file_path "x" :old_string "a\nb" :new_string "c")))
         (change (car (sprig-review-tool-changes "Edit" input))))
    (should (equal (sprig-review-format-change change)
                   "x\n-a\n-b\n+c"))))

(ert-deftest sprig-review-test-build-coalesces-text ()
  (let* ((model (sprig-review-build
                 '((session "s1") (text "Hello, ") (text "world")
                   (done 0.01 nil))))
         (blocks (plist-get model :blocks)))
    (should (equal (plist-get model :session) "s1"))
    (should (equal (plist-get model :cost) 0.01))
    (should (eq (plist-get model :done) t))
    ;; The two text events coalesce into one block.
    (should (= (length blocks) 1))
    (should (equal (plist-get (car blocks) :text) "Hello, world"))))

(ert-deftest sprig-review-test-build-context-latest-wins ()
  ;; The model tracks the freshest turn's context size, so the header shows
  ;; what the window holds now, not what it held at the first turn.
  (let ((model (sprig-review-build
                '((context 1000) (text "a") (context 5000) (done 0.01 nil)))))
    (should (equal (plist-get model :context) 5000))))

(ert-deftest sprig-review-test-record-usage-becomes-context ()
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
         (model (sprig-review-build (sprig-review-parse-session-line line))))
    (should (equal (plist-get model :context) (+ 3 199000 1000)))))

(ert-deftest sprig-review-test-compact-boundary-becomes-context ()
  ;; A replayed compaction boundary reports its post-compact size, so a
  ;; refreshed log shows the shrunk context without waiting for a new turn.
  (let* ((line (json-serialize
                (list :type "system" :subtype "compact_boundary"
                      :compactMetadata (list :preTokens 398861
                                             :postTokens 5457))))
         (model (sprig-review-build (sprig-review-parse-session-line line))))
    (should (equal (plist-get model :context) 5457))))

(ert-deftest sprig-review-test-build-text-block-splits ()
  (let ((blocks (plist-get
                 (sprig-review-build
                  '((text "one") (text-block) (text "two")))
                 :blocks)))
    (should (= (length blocks) 2))
    (should (equal (plist-get (nth 0 blocks) :text) "one"))
    (should (equal (plist-get (nth 1 blocks) :text) "two"))))

(ert-deftest sprig-review-test-build-pairs-tool-result ()
  (let* ((input (json-serialize (list :file_path "x" :old_string "a"
                                      :new_string "b")))
         (blocks (plist-get
                  (sprig-review-build
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

(ert-deftest sprig-review-test-build-orphan-result ()
  ;; A result with no matching call is kept, not dropped.
  (let ((blocks (plist-get
                 (sprig-review-build '((tool-result "t9" t "boom")))
                 :blocks)))
    (should (= (length blocks) 1))
    (should (equal (plist-get (plist-get (car blocks) :result) :text) "boom"))
    (should (eq (plist-get (plist-get (car blocks) :result) :error) t))))

;;;; Stored-session log parser (sprig-review.el)

(ert-deftest sprig-review-test-session-path ()
  (should (equal (sprig-review-session-file "/home/dalum/Projects/sprig" "abc")
                 "~/.claude/projects/-home-dalum-Projects-sprig/abc.jsonl"))
  ;; Dots become dashes too, matching the CLI's project-dir naming.
  (should (equal (sprig-review-session-file "/home/x/.cache/p" "id")
                 "~/.claude/projects/-home-x--cache-p/id.jsonl")))

(ert-deftest sprig-review-test-session-parse-assistant ()
  (let* ((line (json-serialize
                (list :type "assistant"
                      :message
                      (list :role "assistant"
                            :content
                            (vector (list :type "thinking" :thinking "hmm")
                                    (list :type "text" :text "hello")
                                    (list :type "tool_use" :id "t1" :name "Bash"
                                          :input (list :command "ls")))))))
         (events (sprig-review-parse-session-line line)))
    (should (equal (nth 0 events) '(thinking "hmm")))
    (should (equal (nth 1 events) '(text "hello")))
    (let ((tc (nth 2 events)))
      (should (eq (car tc) 'tool-call))
      (should (equal (nth 2 tc) "Bash"))
      ;; The input passes through as the parsed object; the diff engine
      ;; reads it the same as a wire-path JSON string.
      (should (null (sprig-review-tool-changes "Bash" (nth 3 tc)))))))

(ert-deftest sprig-review-test-session-edit-changes ()
  (let* ((line (json-serialize
                (list :type "assistant"
                      :message
                      (list :content
                            (vector (list :type "tool_use" :id "t1" :name "Edit"
                                          :input (list :file_path "a.el"
                                                       :old_string "x"
                                                       :new_string "y")))))))
         (tc (car (sprig-review-parse-session-line line)))
         (changes (sprig-review-tool-changes (nth 2 tc) (nth 3 tc))))
    (should (equal (plist-get (car changes) :file) "a.el"))))

(ert-deftest sprig-review-test-session-parse-user ()
  (let ((prose (json-serialize
                (list :type "user" :message (list :role "user" :content "do it"))))
        (result (json-serialize
                 (list :type "user"
                       :message (list :content
                                      (vector (list :type "tool_result"
                                                    :tool_use_id "t1"
                                                    :is_error :false
                                                    :content "ok")))))))
    (should (equal (sprig-review-parse-session-line prose) '((user "do it"))))
    (should (equal (sprig-review-parse-session-line result)
                   '((tool-result "t1" nil "ok"))))))

(ert-deftest sprig-review-test-session-parse-user-text-blocks ()
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
    (should (equal (sprig-review-parse-session-line blocks) '((user "do it"))))
    (should (equal (sprig-review-parse-session-line mixed)
                   '((tool-result "t1" nil "ok") (user "now this"))))))

(ert-deftest sprig-review-test-session-stamps-records ()
  ;; Every conversation record in the log carries its own timestamp, so a
  ;; replayed turn is dated from the log rather than from whenever it is read.
  (let ((prose (json-serialize
                '(:type "user" :timestamp "2026-07-15T09:16:56.955Z"
                  :message (:role "user" :content "do it"))))
        (reply (json-serialize
                '(:type "assistant" :timestamp "2026-07-15T09:17:01.000Z"
                  :message (:content [(:type "text" :text "on it")])))))
    (should (equal (sprig-review-parse-session-line prose)
                   '((time "2026-07-15T09:16:56.955Z") (user "do it"))))
    (should (equal (sprig-review-parse-session-line reply)
                   '((time "2026-07-15T09:17:01.000Z") (text "on it")))))
  ;; A record carrying no conversation content leaves no stray `time' event
  ;; behind to misdate the next block.
  (let ((empty (json-serialize
                '(:type "user" :timestamp "2026-07-15T09:16:56.955Z"
                  :message (:content [])))))
    (should (null (sprig-review-parse-session-line empty))))
  ;; An unstamped record still parses.
  (let ((bare (json-serialize
               '(:type "user" :message (:role "user" :content "do it")))))
    (should (equal (sprig-review-parse-session-line bare) '((user "do it"))))))

(ert-deftest sprig-review-test-build-stamps-blocks ()
  (let* ((model (sprig-review-build
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
  (should (null (plist-get (sprig-review-build '((time "2026-07-15T09:00:00.000Z")))
                           :blocks))))

(ert-deftest sprig-review-test-session-parse-user-skips-empty-text ()
  ;; An empty or whitespace-only text block is not a turn.
  (let ((blank (json-serialize
                (list :type "user"
                      :message (list :content (vector (list :type "text"
                                                            :text "  \n")))))))
    (should (null (sprig-review-parse-session-line blank)))))

(ert-deftest sprig-review-test-session-title-and-sidechain ()
  (let ((title (json-serialize (list :type "ai-title" :aiTitle "My title")))
        (side (json-serialize
               (list :type "assistant" :isSidechain t
                     :message (list :content
                                    (vector (list :type "text" :text "sub")))))))
    (should (equal (sprig-review-parse-session-line title) '((title "My title"))))
    ;; Subagent (sidechain) records are skipped.
    (should (null (sprig-review-parse-session-line side)))))

(ert-deftest sprig-review-test-session-model ()
  (let* ((lines (list
                 (json-serialize (list :type "ai-title" :aiTitle "T"))
                 (json-serialize (list :type "attachment" :foo 1)) ; bookkeeping, ignored
                 (json-serialize (list :type "user" :message (list :content "hi")))
                 (json-serialize
                  (list :type "assistant"
                        :message (list :content
                                       (vector (list :type "text" :text "yo")))))))
         (model (sprig-review-session-model lines))
         (blocks (plist-get model :blocks)))
    (should (equal (plist-get model :title) "T"))
    (should (eq (plist-get (nth 0 blocks) :type) 'user))
    (should (equal (plist-get (nth 0 blocks) :text) "hi"))
    (should (eq (plist-get (nth 1 blocks) :type) 'text))
    (should (equal (plist-get (nth 1 blocks) :text) "yo"))))

(ert-deftest sprig-review-test-build-user-and-thinking ()
  (let* ((model (sprig-review-build
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

(ert-deftest sprig-review-test-parse-status-mode ()
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    (json-serialize (list :type "system" :subtype "status"
                                          :permissionMode "plan")))
                   '((mode "plan"))))))

(ert-deftest sprig-review-test-session-user-mode ()
  ;; A stored user record's permissionMode replays as a `mode' event.
  (should (equal (sprig-review-parse-session-line
                  (json-serialize (list :type "user" :permissionMode "plan"
                                        :message (list :content "go"))))
                 '((mode "plan") (user "go")))))

(ert-deftest sprig-review-test-build-mode ()
  (should (equal (plist-get (sprig-review-build '((mode "plan") (user "x")))
                            :mode)
                 "plan")))

(ert-deftest sprig-review-test-control-request-wire-format ()
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
                ((symbol-function 'sprig--status-refresh) #'ignore))
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
                      ((symbol-function 'sprig--status-refresh) #'ignore))
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
            (cl-letf (((symbol-function 'sprig--status-refresh) #'ignore)
                      ((symbol-function 'sprig-review-consume) #'ignore))
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
                ((symbol-function 'sprig--status-refresh) #'ignore))
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
              ((symbol-function 'sprig-review-consume)
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
    (cl-letf (((symbol-function 'sprig-review-consume)
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
              ((symbol-function 'sprig-review-consume) #'ignore))
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
      (cl-letf (((symbol-function 'sprig-review-consume)
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
                ((symbol-function 'sprig-review-consume)
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
                ((symbol-function 'sprig-review-consume) #'ignore))
        (setq sprig--process 'dummy)
        (pcase (sprig-tests--permission-request)
          (`(control-request ,id ,req) (sprig--answer-control-request id req))))
      (should (equal (alist-get 'behavior (sprig-tests--decision sent)) "deny")))))

(ert-deftest sprig-test-allow-and-deny-tool ()
  (with-temp-buffer
    (let (sent consumed)
      (cl-letf (((symbol-function 'process-send-string) (lambda (_p s) (setq sent s)))
                ((symbol-function 'sprig-review-consume)
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

(ert-deftest sprig-test-scan-session-logs ()
  ;; The scan is host-wide: every log under the projects root, newest first,
  ;; with each row's project taken from the log's own `cwd' record.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj-a "/tmp/whatever/myproj")
         (proj-b "/tmp/other/second")
         (sprig-remote nil)
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

(ert-deftest sprig-test-scan-session-logs-without-cwd ()
  ;; A log whose scanned tail carries no cwd yields a nil :dir, never the
  ;; encoded log-dir name: that name is not a real path, so it survives
  ;; only as the display-only :project and is never handed to a `cd'.
  (let* ((root (make-temp-file "sprig-proj" t))
         (proj "/tmp/whatever/myproj")
         (sprig-remote nil)
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
         (sprig-remote nil)
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
  ;; Two round trips: a mtime-sorted find, then one batched slurp of tails.
  ;; The find output pairs each mtime with a path; the tails come back
  ;; record-separated so cwd and title are parsed per session.
  (let ((sprig-remote "me@host")
        (sprig-claude-projects-directory "~/.claude/projects")
        (root "~/.claude/projects")
        (calls nil))
    (cl-letf (((symbol-function 'sprig--remote-sh)
               (lambda (cmd)
                 (push cmd calls)
                 (cond
                  ((string-match-p "find" cmd)
                   (format "20.0\t%s/-p/new.jsonl\n10.0\t%s/-p/old.jsonl\n"
                           root root))
                  ((string-match-p "^for f in" cmd)
                   (concat "\036" root "/-p/new.jsonl\037"
                           "{\"cwd\":\"/home/me/p\",\"aiTitle\":\"Newer\"}\n"
                           "\036" root "/-p/old.jsonl\037"
                           "{\"cwd\":\"/home/me/p\",\"aiTitle\":\"Older\"}\n"))
                  (t "")))))
      (let* ((rows (sprig--scan-session-logs))
             (newer (car rows)))
        ;; Newest first, from the find's descending sort.
        (should (equal (plist-get newer :session) "new"))
        (should (equal (plist-get newer :title) "Newer"))
        (should (equal (plist-get newer :dir) "/home/me/p"))
        (should (= 2 (length rows)))
        ;; The find left `*.jsonl' unquoted so the remote shell expands it.
        (should (seq-find (lambda (c) (string-match-p "\\*\\.jsonl" c)) calls))))))

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
                sprig-review--events '((dialog "d1" "ask_user_question" nil)))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t)))
      (should (eq (sprig--session-status (current-buffer)) 'waiting)))))

(ert-deftest sprig-test-session-status-answered-dialog-not-waiting ()
  ;; Once the dialog is answered, the session is back to plain `streaming'.
  (with-temp-buffer
    (setq-local sprig--sink #'sprig--review-sink
                sprig--process 'dummy
                sprig--busy t
                sprig-review--events '((dialog-answer "d1" "yes")
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
                sprig-review--events '((dialog "d1" "ask_user_question" nil)))
    (should (eq (sprig--session-status (current-buffer)) 'disconnected))))

(ert-deftest sprig-test-status-glyph-has-waiting ()
  (should (equal (alist-get 'waiting sprig--status-glyphs) "?")))

(ert-deftest sprig-test-status-collect-owning-buffer-wins ()
  (let ((root (make-temp-file "sprig-proj" t)))
    (unwind-protect
        (let ((sprig-remote nil)
              (sprig-claude-projects-directory root)
              (sprig-status-directories '("/tmp/no-such-project")))
          (with-temp-buffer
            (setq-local sprig--sink #'sprig--review-sink
                        sprig--session-id "live-1"
                        sprig--working-dir "/tmp/proj"
                        sprig-review--meta '(:title "Live one"))
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
         (sprig-remote nil)
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
        (let ((sprig-remote nil)
              (sprig-claude-projects-directory root))
          (with-temp-buffer
            (setq-local sprig--sink #'sprig--review-sink
                        sprig--session-id "live-2"
                        sprig--working-dir "/tmp/proj"
                        sprig-review--meta nil
                        sprig-review--events '((title "From events")))
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
        (let ((sprig-remote nil)
              (sprig-claude-projects-directory root))
          (sprig-tests--make-session-log
           root "/tmp/proj" "live-3"
           `(:type "user" :cwd "/tmp/proj" :message (:role "user" :content "hi"))
           '(:type "ai-title" :aiTitle "From log"))
          (with-temp-buffer
            (setq-local sprig--sink #'sprig--review-sink
                        sprig--session-id "live-3"
                        sprig--working-dir "/tmp/proj"
                        sprig-review--meta nil
                        sprig-review--events nil)
            (let* ((rows (sprig--status-collect))
                   (e (seq-find (lambda (r) (equal (plist-get r :session) "live-3"))
                                rows)))
              (should (eq (plist-get e :buffer) (current-buffer)))
              (should (equal (plist-get e :title) "From log")))))
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
         (sprig-remote nil)
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
         (sprig-remote nil)
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

(ert-deftest sprig-review-test-build-dialog-blocks ()
  ;; A question stands pending until an answer of the same id settles it, so
  ;; a rebuild (which every render does) still knows it was settled.
  (let* ((input '((questions . [((question . "Which?")
                                 (options . [((label . "A")) ((label . "B"))]))])))
         (model (sprig-review-build
                 `((dialog "req-1" "ask_user_question" ,input))))
         (block (car (plist-get model :blocks))))
    (should (eq (plist-get block :type) 'dialog))
    (should (equal (plist-get block :id) "req-1"))
    (should-not (plist-get block :answered))
    (should (eq block (sprig-review-pending-dialog model))))
  ;; Answered: settled, and no longer pending.
  (let* ((input '((questions . [((question . "Which?")
                                 (options . [((label . "A"))]))])))
         (model (sprig-review-build
                 `((dialog "req-1" "ask_user_question" ,input)
                   (dialog-answer "req-1" ((Which? . "A"))))))
         (block (car (plist-get model :blocks))))
    (should (plist-get block :answered))
    (should (equal (plist-get block :answers) '((Which? . "A"))))
    (should-not (sprig-review-pending-dialog model)))
  ;; Waved through: settled with nothing, and still not pending.
  (let* ((input '((questions . [((question . "Which?") (options . []))])))
         (model (sprig-review-build
                 `((dialog "req-1" "ask_user_question" ,input)
                   (dialog-answer "req-1" nil)))))
    (should (plist-get (car (plist-get model :blocks)) :answered))
    (should-not (sprig-review-pending-dialog model))))

(ert-deftest sprig-test-user-question-does-not-block-the-filter ()
  ;; The control request is handled inside the process filter.  Prompting
  ;; there held the filter, and Emacs with it, until the question was
  ;; answered.  It must only hand the question over and return.
  (with-temp-buffer
    (let (consumed responded)
      (cl-letf (((symbol-function 'sprig-review-consume)
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
                ((symbol-function 'sprig-review-consume)
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
                ((symbol-function 'sprig-review-consume) #'ignore))
        (sprig--review-answer-dialog "req-1" '((questions . [])) nil))
      (should (equal sent '(:behavior "allow"))))))

(ert-deftest sprig-test-review-steer-writes-into-the-live-turn ()
  ;; Steering writes the message to the session's stdin and echoes it, without
  ;; opening a turn of its own: the CLI hands it to the agent at its next
  ;; tool-call boundary, and the turn in flight still ends on its own `done'.
  (with-temp-buffer
    (setq-local sprig--busy t)
    (let (wrote consumed delivered)
      (cl-letf (((symbol-function 'sprig--send-user)
                 (lambda (text) (setq wrote text)))
                ((symbol-function 'sprig-review-consume)
                 (lambda (event) (setq consumed event)))
                ((symbol-function 'sprig--review-deliver)
                 (lambda (&rest _) (setq delivered t))))
        (sprig--review-steer "actually, do X"))
      (should (equal wrote "actually, do X"))
      ;; Echoed locally, so the steer shows in the transcript where it landed.
      (should (equal consumed '(user "actually, do X")))
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
  ;; An ordinary send still will not open a second turn; it points at `c s'.
  (with-temp-buffer
    (setq-local sprig--busy t)
    (cl-letf (((symbol-function 'sprig--ensure) #'ignore)
              ((symbol-function 'sprig--send-user)
               (lambda (_) (error "should not have sent"))))
      (let ((err (should-error (sprig--review-deliver "hi") :type 'user-error)))
        (should (string-match-p "c s" (cadr err)))))))

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

(provide 'sprig-tests)
;;; sprig-tests.el ends here
