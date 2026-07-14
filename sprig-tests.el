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

;;;; Transport: claude stream-json -> events

(ert-deftest sprig-test-parse-session ()
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line (sprig-tests--init "sess-1"))
                   '((session "sess-1"))))))

(ert-deftest sprig-test-parse-text ()
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line (sprig-tests--text "hi"))
                   '((text "hi"))))))

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
        (should (member "--foo" args))))
    (let ((sprig-model nil) (sprig-system-prompt nil)
          (sprig-extra-args nil) (sprig--session-id nil))
      (let ((args (sprig--base-args)))
        (should-not (member "--model" args))
        (should-not (member "--append-system-prompt" args))
        (should-not (member "--resume" args))))))

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

(provide 'sprig-tests)
;;; sprig-tests.el ends here
