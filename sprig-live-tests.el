;;; sprig-live-tests.el --- Tests for sprig-live  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -l sprig-live.el -l sprig-live-tests.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; The streaming itself wants a server, so what is tested here is the pure
;; half: how the stream is split, how the prompt is built, and the request
;; fields the prompt cache depends on.

;;; Code:

(require 'ert)
(require 'sprig-live)

(ert-deftest sprig-live-test-sse-content-joins-records ()
  (pcase-let ((`(,content . ,rest)
               (sprig-live--sse-content
                "" "data: {\"content\":\"a\"}\ndata: {\"content\":\"b\"}\n")))
    (should (equal content "ab"))
    (should (equal rest ""))))

(ert-deftest sprig-live-test-sse-content-carries-a-partial-line ()
  ;; A chunk can split a record anywhere; the tail must wait for the rest
  ;; rather than be parsed as truncated JSON and dropped.
  (pcase-let* ((`(,first . ,rest)
                (sprig-live--sse-content "" "data: {\"content\":\"a\"}\ndata: {\"con"))
               (`(,second . ,tail)
                (sprig-live--sse-content rest "tent\":\"b\"}\n")))
    (should (equal first "a"))
    (should (equal second "b"))
    (should (equal tail ""))))

(ert-deftest sprig-live-test-sse-content-ignores-done-and-noise ()
  (pcase-let ((`(,content . ,_)
               (sprig-live--sse-content
                "" "data: [DONE]\n: keep-alive\ndata: {\"content\":\"x\"}\n")))
    (should (equal content "x"))))

(ert-deftest sprig-live-test-sse-content-survives-bad-json ()
  ;; A malformed record must not kill the turn: the rest of the stream is
  ;; still worth having.
  (pcase-let ((`(,content . ,_)
               (sprig-live--sse-content
                "" "data: {not json}\ndata: {\"content\":\"y\"}\n")))
    (should (equal content "y"))))

(ert-deftest sprig-live-test-context-is-bounded-by-lines ()
  ;; The bound exists to cap the one cost the cache cannot remove, the
  ;; first prefill.
  (with-temp-buffer
    (dotimes (i 50) (insert (format "line %d\n" i)))
    (let ((all (sprig-live--context nil))
          (some (sprig-live--context 3)))
      (should (string-match-p "line 0" all))
      (should-not (string-match-p "line 0" some))
      (should (string-match-p "line 49" some)))))

(ert-deftest sprig-live-test-context-stops-at-point ()
  ;; What follows point is the model's to write, so it must not be fed back
  ;; as though already written.
  (with-temp-buffer
    (insert "before\n")
    (save-excursion (insert "after\n"))
    (let ((context (sprig-live--context nil)))
      (should (string-match-p "before" context))
      (should-not (string-match-p "after" context)))))

(ert-deftest sprig-live-test-comment-uses-the-buffer-language ()
  (with-temp-buffer
    (setq-local comment-start ";;")
    (should (equal (sprig-live--comment "one\ntwo") ";; one\n;; two"))))

(ert-deftest sprig-live-test-prompt-is-commented-and-names-the-marker ()
  ;; A completion model continues code; prose where code belongs is out of
  ;; distribution, and it answers in kind.
  (with-temp-buffer
    (setq-local comment-start "#")
    (let* ((sprig-live-steer-marker ">>>")
           (prompt (sprig-live--prompt "def f():\n")))
      (should (string-match-p "^# " prompt))
      (should (string-match-p ">>>" prompt))
      (should (string-suffix-p "def f():\n" prompt)))))

(ert-deftest sprig-live-test-request-keeps-the-cache-fields ()
  ;; `cache_prompt' and a pinned `id_slot' are what make a steer cost the
  ;; new tokens and not a fresh prefill.  Losing either is the difference
  ;; between 0.09s and 21.8s, and nothing would fail loudly.
  (let* ((sprig-live-slot 3)
         (body (json-parse-string (sprig-live--request-body "p")
                                  :object-type 'alist)))
    (should (eq (alist-get 'cache_prompt body) t))
    (should (equal (alist-get 'id_slot body) 3))
    (should (eq (alist-get 'stream body) t))
    (should (equal (alist-get 'prompt body) "p"))))

(ert-deftest sprig-live-test-command-is-unbuffered ()
  ;; Without `--no-buffer' curl holds the stream and the text arrives in
  ;; bursts, which is the one thing live mode must not do.
  (let ((cmd (sprig-live--command)))
    (should (member "--no-buffer" cmd))
    (should (string-suffix-p "/completion" (car (last cmd))))))

(ert-deftest sprig-live-test-steer-opens-a-marked-comment ()
  (with-temp-buffer
    (setq-local comment-start "#")
    (insert "code\n")
    (setq sprig-live--marker (copy-marker (point) t))
    (let ((sprig-live-steer-marker ">>>"))
      (sprig-live-steer))
    (should (string-match-p "# >>> " (buffer-string)))))

(ert-deftest sprig-live-test-mode-off-releases-the-marker ()
  ;; A live marker in a buffer nobody is writing to would keep a stale
  ;; position alive and resume into it later.
  (with-temp-buffer
    (sprig-live-mode 1)
    (setq sprig-live--marker (copy-marker (point) t))
    (sprig-live-mode -1)
    (should-not sprig-live--marker)))

(ert-deftest sprig-live-test-request-stops-on-the-steer-marker ()
  ;; Without this the model answers your line, then writes itself a
  ;; plausible next instruction and keeps going: it puts words in your
  ;; mouth, which is the one thing live mode must not do.
  (let* ((sprig-live-steer-marker "###")
         (body (json-parse-string (sprig-live--request-body "p")
                                  :object-type 'alist :array-type 'list)))
    (should (member "###" (alist-get 'stop body)))))

(ert-deftest sprig-live-test-trim-removes-only-a-bare-opener ()
  (with-temp-buffer
    (setq-local comment-start ";;")
    (insert "(defun f ())\n;; ")
    (setq sprig-live--marker (copy-marker (point) t))
    (sprig-live--trim-dangling-comment)
    (should (equal (buffer-string) "(defun f ())")))
  ;; A comment with words in it is the model's prose, and stays.
  (with-temp-buffer
    (setq-local comment-start ";;")
    (insert "(defun f ())\n;; a real remark")
    (setq sprig-live--marker (copy-marker (point) t))
    (sprig-live--trim-dangling-comment)
    (should (equal (buffer-string) "(defun f ())\n;; a real remark"))))

(provide 'sprig-live-tests)
;;; sprig-live-tests.el ends here
