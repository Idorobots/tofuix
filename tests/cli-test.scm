;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

(define-module (tests cli-test)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:use-module (srfi srfi-64)
  #:use-module (guix extensions tofu))

(define runner (test-runner-create))
(test-runner-current runner)

(define (option options name)
  (cdr (assq name options)))

(define golden
  (string-trim-right
   (call-with-input-file "tests/tls.golden.json" get-string-all)
   #\newline))

(test-begin "cli")

(let-values (((command options positionals forwarded)
              (tofu-parse-arguments '("plan"))))
  (test-equal "the command is parsed" "plan" command)
  (test-equal "the file has no default in the parser" #f (option options 'file))
  (test-equal "the load path is empty by default" '() (option options 'load-path))
  (test-equal "the default tool is tofu" "tofu" (option options 'tool))
  (test-equal "there are no positional arguments" '() positionals)
  (test-equal "there are no forwarded arguments" '() forwarded))

(let-values (((command options positionals forwarded)
              (tofu-parse-arguments
               '("plan" "-f" "x.scm" "-L" "a" "-L" "b" "--tool=terraform"
                 "-C" "dir" "-target=x" "--" "-var" "a=b"))))
  (test-equal "options around the command are parsed" "plan" command)
  (test-equal "-f sets the file" "x.scm" (option options 'file))
  (test-equal "-L accumulates in order" '("a" "b") (option options 'load-path))
  (test-equal "--tool selects the tool" "terraform" (option options 'tool))
  (test-equal "-C selects the directory" "dir" (option options 'chdir))
  (test-equal "unrecognized options and arguments after -- are forwarded"
    '("-target=x" "-var" "a=b")
    forwarded)
  (test-equal "nothing is positional" '() positionals))

(let-values (((command options positionals forwarded)
              (tofu-parse-arguments '("output" "public-key"))))
  (test-equal "output names are positional" '("public-key") positionals)
  (test-equal "the command is parsed" "output" command))

(let-values (((command options positionals forwarded)
              (tofu-parse-arguments '("plan" "--file=main.scm" "--load-path=lib"))))
  (test-equal "--file=VALUE sets the file" "main.scm" (option options 'file))
  (test-equal "--load-path=VALUE appends to the load path" '("lib")
              (option options 'load-path)))

(let-values (((command options positionals forwarded)
              (tofu-parse-arguments '("apply" "--chdir" "sub"))))
  (test-equal "--chdir VALUE sets the directory" "sub" (option options 'chdir)))

(let-values (((command options positionals forwarded)
              (tofu-parse-arguments '("plan" "--chdir=dir"))))
  (test-equal "--chdir=VALUE sets the directory" "dir" (option options 'chdir)))

(let-values (((command options positionals forwarded)
              (tofu-parse-arguments '("plan" "--help"))))
  (test-equal "--help is recognized" #t (option options 'help)))

(test-error "-f without a value is an error" 'tofuix-error
  (tofu-parse-arguments '("plan" "-f")))
(test-error "--tool without a value is an error" 'tofuix-error
  (tofu-parse-arguments '("plan" "--tool")))
(test-error "an unknown tool is an error" 'tofuix-error
  (tofu-parse-arguments '("plan" "--tool=pulumi")))
(test-error "-C without a value is an error" 'tofuix-error
  (tofu-parse-arguments '("plan" "-C")))
(test-error "--chdir without a value is an error" 'tofuix-error
  (tofu-parse-arguments '("plan" "--chdir")))

(let ((status #f)
      (output #f))
  (set! output
        (with-output-to-string
          (lambda ()
            (set! status (tofu-main '("generate" "-f" "examples/tls.scm"))))))
  (test-equal "generate succeeds" 0 status)
  (test-equal "generate prints the configuration followed by a newline"
    (string-append golden "\n")
    output))

(test-end "cli")

(exit (if (zero? (+ (test-runner-fail-count runner)
                    (test-runner-xpass-count runner)))
          0 1))
