;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

(define-module (tests evaluate-test)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-13)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-64)
  #:use-module (tofuix evaluate)
  #:use-module (tofuix records)
  #:use-module (tofuix serializer))

(define runner (test-runner-create))
(test-runner-current runner)

(define (make-temp-directory)
  (mkdtemp "/tmp/tofuix-evaluate-XXXXXX"))

(define (delete-directory directory)
  (system* "rm" "-rf" directory))

(define (write-file file text)
  (call-with-output-file file
    (lambda (port)
      (display text port))))

(define golden
  (string-trim-right
   (call-with-input-file "tests/tls.golden.json" get-string-all)
   #\newline))

(test-begin "evaluate")

(let-values (((configuration session)
              (tofu-evaluate-file "examples/tls.scm")))
  (test-equal "the tls example serializes byte-exactly to the golden JSON"
    golden
    (tofu-configuration->json configuration)))

(let* ((directory (make-temp-directory))
       (file (in-vicinity directory "infrastructure.scm")))
  (write-file file "\
(use-modules (tofuix))

(define infrastructure
  (configuration (resource terraform_data example (input \"hello\"))))
")
  (let-values (((configuration session) (tofu-evaluate-file file)))
    (test-assert "a file defining infrastructure yields it"
      (tofu-configuration? configuration))
    (test-equal "the defined configuration carries its resources"
      '("terraform_data" "example")
      (let ((resource (car (tofu-configuration-resources configuration))))
        (list (tofu-resource-type resource)
              (tofu-resource-name resource)))))
  (delete-directory directory))

(let* ((directory (make-temp-directory))
       (file (in-vicinity directory "infrastructure.scm")))
  (write-file file "\
(use-modules (tofuix))

(configuration (resource terraform_data last (input \"expression\")))
")
  (test-equal "the value of the last expression is used"
    "expression"
    (let-values (((configuration session) (tofu-evaluate-file file)))
      (let ((resource (car (tofu-configuration-resources configuration))))
        (cdr (assoc "input" (tofu-resource-arguments resource))))))
  (delete-directory directory))

(let* ((directory (make-temp-directory))
       (file (in-vicinity directory "infrastructure.scm")))
  (write-file (in-vicinity directory "data.txt") "relative contents")
  (write-file file "\
(use-modules (tofuix) (ice-9 textual-ports))

(configuration
  (local data (call-with-input-file \"data.txt\" get-string-all)))
")
  (test-equal "relative file references resolve against the project root"
    "relative contents"
    (let-values (((configuration session) (tofu-evaluate-file file)))
      (let ((local (car (tofu-configuration-locals configuration))))
        (tofu-local-value local))))
  (test-equal "the current directory is restored after evaluation"
    (getcwd)
    (begin (tofu-evaluate-file file) (getcwd)))
  (delete-directory directory))

(let* ((directory (make-temp-directory))
       (hosts (in-vicinity directory "hosts"))
       (file (in-vicinity directory "infrastructure.scm")))
  (mkdir hosts)
  (write-file (in-vicinity hosts "rpi3.scm") "\
(define-module (hosts rpi3)
  #:export (rpi3-os))

(define rpi3-os \"blueprint-reference\")
")
  (write-file file "\
(use-modules (tofuix) (hosts rpi3))

(configuration (local os rpi3-os))
")
  (test-equal "load paths make project modules loadable"
    "blueprint-reference"
    (let-values (((configuration session)
                  (tofu-evaluate-file file #:load-path (list directory))))
      (let ((local (car (tofu-configuration-locals configuration))))
        (tofu-local-value local))))
  (delete-directory directory))

(let* ((directory (make-temp-directory))
        (hosts (in-vicinity directory "hosts"))
        (file (in-vicinity directory "infrastructure.scm")))
  (mkdir hosts)
  (write-file (in-vicinity hosts "alpha.scm") "\
(define-module (hosts alpha)
  #:export (alpha-os))

(define alpha-os \"file-directory-reference\")
")
  (write-file file "\
(use-modules (tofuix) (hosts alpha))

(configuration (local os alpha-os))
")
  (test-equal "the infrastructure file's directory is on the load path"
    "file-directory-reference"
    (let-values (((configuration session)
                  (tofu-evaluate-file file)))
      (let ((local (car (tofu-configuration-locals configuration))))
        (tofu-local-value local))))
  (delete-directory directory))

(let* ((directory (make-temp-directory))
        (file (in-vicinity (in-vicinity directory "nested")
                           "infrastructure.scm")))
  (mkdir (in-vicinity directory "nested"))
  (mkdir (in-vicinity directory "hosts"))
  (write-file (in-vicinity (in-vicinity directory "hosts") "beta.scm") "\
(define-module (hosts beta)
  #:export (beta-os))

(define beta-os \"cwd-reference\")
")
  (write-file file "\
(use-modules (tofuix) (hosts beta))

(configuration (local os beta-os))
")
  (let ((saved-cwd (getcwd)))
    (dynamic-wind
      (const #t)
      (lambda ()
        (chdir directory)
        (test-equal "the current working directory is on the load path"
          "cwd-reference"
          (let-values (((configuration session)
                        (tofu-evaluate-file file)))
            (let ((local (car (tofu-configuration-locals configuration))))
              (tofu-local-value local)))))
      (lambda () (chdir saved-cwd))))
  (delete-directory directory))

(let* ((directory (make-temp-directory))
        (override (make-temp-directory))
        (hosts (in-vicinity directory "hosts"))
        (file (in-vicinity directory "infrastructure.scm")))
  (mkdir hosts)
  (mkdir (in-vicinity override "hosts"))
  (write-file (in-vicinity hosts "gamma.scm") "\
(define-module (hosts gamma)
  #:export (gamma-os))

(define gamma-os \"file-directory\")
")
  (write-file (in-vicinity (in-vicinity override "hosts") "gamma.scm") "\
(define-module (hosts gamma)
  #:export (gamma-os))

(define gamma-os \"explicit-load-path\")
")
  (write-file file "\
(use-modules (tofuix) (hosts gamma))

(configuration (local os gamma-os))
")
  ;; Evaluation happens with DIRECTORY as the working directory, so the
  ;; file's directory would otherwise win.
  (let ((saved-cwd (getcwd)))
    (dynamic-wind
      (const #t)
      (lambda ()
        (chdir directory)
        (test-equal "explicit load path entries shadow the file directory"
          "explicit-load-path"
          (let-values (((configuration session)
                        (tofu-evaluate-file file #:load-path (list override))))
            (let ((local (car (tofu-configuration-locals configuration))))
              (tofu-local-value local)))))
      (lambda () (chdir saved-cwd))))
  (delete-directory directory)
  (delete-directory override))

(let* ((directory (make-temp-directory))
        (file (in-vicinity directory "infrastructure.scm")))
  (write-file file "\
(define-module (fixtures defined-infrastructure)
  #:use-module (tofuix)
  #:export (infrastructure))

(define infrastructure
  (configuration (resource terraform_data defined (input \"defined\"))))
")
  (test-equal "a define-module file is found through its binding"
    "defined"
    (let-values (((configuration session) (tofu-evaluate-file file)))
      (let ((resource (car (tofu-configuration-resources configuration))))
        (cdr (assoc "input" (tofu-resource-arguments resource))))))
  (delete-directory directory))

(test-error "a missing infrastructure file is an error"
  'tofuix-error
  (tofu-evaluate-file "/does/not/exist/infrastructure.scm"))

(let* ((directory (make-temp-directory))
       (file (in-vicinity directory "infrastructure.scm")))
  (write-file file "(use-modules (tofuix)) (define unrelated 1)\n")
  (test-error "a file without a configuration is an error"
    'tofuix-error
    (tofu-evaluate-file file))
  (delete-directory directory))

(let* ((directory (make-temp-directory))
       (file (in-vicinity directory "infrastructure.scm")))
  (write-file file "\
(use-modules (tofuix))

(define a-value (list 'captured))
(define (a-function x) x)

(configuration (resource terraform_data session (input \"x\")))
")
  (let-values (((configuration session) (tofu-evaluate-file file)))
    (test-equal "the session captures the source of plain defines"
      '(list 'captured)
      (assq-ref (evaluation-session-local-forms session) 'a-value))
    (test-equal "function defines are captured as lambdas"
      '(lambda (x) x)
      (assq-ref (evaluation-session-local-forms session) 'a-function))
    (test-assert "the session keeps the evaluation module"
      (equal? (module-ref (evaluation-session-module session) 'a-value)
              (list 'captured))))
  (delete-directory directory))

(test-error "a missing load path entry is an error"
  'tofuix-error
  (tofu-evaluate-file "examples/tls.scm" #:load-path (list "/does/not/exist")))

(test-end "evaluate")

(exit (if (zero? (+ (test-runner-fail-count runner)
                    (test-runner-xpass-count runner)))
          0 1))
