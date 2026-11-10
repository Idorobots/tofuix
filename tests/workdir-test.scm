;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

(define-module (tests workdir-test)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:use-module (srfi srfi-64)
  #:use-module (tofuix)
  #:use-module (tofuix workdir))

(define runner (test-runner-create))
(test-runner-current runner)

(define (make-temp-directory)
  (mkdtemp "/tmp/tofuix-workdir-XXXXXX"))

(define (delete-directory directory)
  (system* "rm" "-rf" directory))

(define (write-file file text)
  (call-with-output-file file
    (lambda (port)
      (display text port))))

(define (read-file file)
  (call-with-input-file file get-string-all))

(define example
  (configuration
   (resource 'terraform_data 'example
     (input "hello"))))

(test-begin "workdir")

(let* ((directory (make-temp-directory))
       (file (in-vicinity directory "infrastructure.scm")))
  (write-file file "(use-modules (tofuix))\n")
  (test-equal "the project root is the directory of the infrastructure file"
    (canonicalize-path directory)
    (tofu-project-root file))
  (test-equal "the working directory lives under the project root"
    (in-vicinity (canonicalize-path directory) ".tofuix")
    (tofu-workdir (tofu-project-root file)))
  (delete-directory directory))

(let* ((directory (make-temp-directory))
       (nested (in-vicinity directory "a/b/c")))
  (test-equal "nested directories are created"
    nested
    (tofu-ensure-directory nested))
  (test-assert "nested directories exist afterwards"
    (file-exists? nested))
  (delete-directory directory))

(let* ((directory (make-temp-directory))
       (workdir (tofu-workdir directory))
       (config (tofu-config-file workdir))
       (lock (tofu-lock-file workdir)))
  (tofu-ensure-directory workdir)
  (write-file lock "# provider lock\n")
  (write-file config "stale\n")
  (tofu-write-configuration example workdir)
  (let ((json (read-file config)))
    (test-assert "the configuration is written inside the working directory"
      (file-exists? config))
    (test-assert "the configuration ends with a newline"
      (string-suffix? "\n" json))
    (test-assert "the configuration names the resource type"
      (string-contains json "\"terraform_data\""))
    (test-assert "no temporary file is left behind"
      (not (file-exists? (string-append config ".tmp")))))
  (tofu-write-configuration example workdir)
  (test-equal "the provider lock file survives regeneration"
    "# provider lock\n"
    (read-file lock))
  (delete-directory directory))

(let* ((directory (make-temp-directory))
       (bin (in-vicinity directory "bin"))
       (tool (in-vicinity bin "fake-tofu")))
  (mkdir bin)
  (write-file tool "#!/bin/sh\nexit 0\n")
  (chmod tool #o755)
  (test-equal "an executable on PATH is found"
    (canonicalize-path tool)
    (tofu-find-tool "fake-tofu" #:path bin))
  (test-equal "a missing executable yields #f"
    #f
    (tofu-find-tool "not-a-tool" #:path bin))
  (test-equal "a file name with a slash is used as-is"
    (canonicalize-path tool)
    (tofu-find-tool tool))
  (delete-directory directory))

(define script "\
#!/bin/sh
printf '%s\\n' \"$PWD\" > \"$TOFUIX_TEST_LOG\"
printf '%s\\n' \"$@\" >> \"$TOFUIX_TEST_LOG\"
exit \"${TOFUIX_TEST_EXIT:-0}\"
")

(let* ((directory (make-temp-directory))
       (workdir (in-vicinity directory "work"))
       (tool (in-vicinity directory "fake-tool"))
       (log (in-vicinity directory "log")))
  (mkdir workdir)
  (write-file tool script)
  (chmod tool #o755)
  (setenv "TOFUIX_TEST_LOG" log)
  (test-equal "a successful command yields exit code 0"
    0
    (tofu-run tool '("plan" "-target=example") #:directory workdir))
  (test-equal "the command runs in the requested directory and sees its arguments"
    (list (canonicalize-path workdir) "plan" "-target=example")
    (string-split (string-trim-right (read-file log) #\newline) #\newline))
  (setenv "TOFUIX_TEST_EXIT" "7")
  (test-equal "a failing command yields its exit code"
    7
    (tofu-run tool '() #:directory workdir))
  (delete-directory directory))

(let* ((directory (make-temp-directory))
       (tool (in-vicinity directory "echo-args")))
  (write-file tool "\
#!/bin/sh
for argument in \"$@\"; do printf '%s\\n' \"$argument\"; done
")
  (chmod tool #o755)
  (let-values (((output status) (tofu-run/capture tool '("a b" "c'd"))))
    (test-equal "captured output preserves arguments with spaces and quotes"
      "a b\nc'd\n"
      output)
    (test-equal "a successful capture yields exit code 0"
      0
      status))
  (let-values (((output status) (tofu-run/capture tool '() #:directory directory)))
    (test-equal "capture runs in the requested directory"
      ""
      output))
  (delete-directory directory))

(test-equal "shell quoting escapes single quotes"
  "'c'\\''d'"
  (tofu-shell-quote "c'd"))

(test-end "workdir")

(exit (if (zero? (+ (test-runner-fail-count runner)
                    (test-runner-xpass-count runner)))
          0 1))
