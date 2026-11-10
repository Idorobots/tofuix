;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

(define-module (tests evaluate-test)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-13)
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

(test-equal "the tls example serializes byte-exactly to the golden JSON"
  golden
  (tofu-configuration->json (tofu-evaluate-file "examples/tls.scm")))

(let* ((directory (make-temp-directory))
       (file (in-vicinity directory "infrastructure.scm")))
  (write-file file "\
(use-modules (tofuix))

(define infrastructure
  (configuration (resource 'terraform_data 'example (input \"hello\"))))
")
  (let ((configuration (tofu-evaluate-file file)))
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

(configuration (resource 'terraform_data 'last (input \"expression\")))
")
  (test-equal "the value of the last expression is used"
    "expression"
    (let* ((configuration (tofu-evaluate-file file))
           (resource (car (tofu-configuration-resources configuration))))
      (cdr (assoc "input" (tofu-resource-arguments resource)))))
  (delete-directory directory))

(let* ((directory (make-temp-directory))
       (file (in-vicinity directory "infrastructure.scm")))
  (write-file (in-vicinity directory "data.txt") "relative contents")
  (write-file file "\
(use-modules (tofuix) (ice-9 textual-ports))

(configuration
  (local 'data (call-with-input-file \"data.txt\" get-string-all)))
")
  (test-equal "relative file references resolve against the project root"
    "relative contents"
    (let* ((configuration (tofu-evaluate-file file))
           (local (car (tofu-configuration-locals configuration))))
      (tofu-local-value local)))
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

(configuration (local 'os rpi3-os))
")
  (test-equal "load paths make project modules loadable"
    "blueprint-reference"
    (let* ((configuration (tofu-evaluate-file file #:load-path (list directory)))
           (local (car (tofu-configuration-locals configuration))))
      (tofu-local-value local)))
  (delete-directory directory))

(let* ((directory (make-temp-directory))
       (file (in-vicinity directory "infrastructure.scm")))
  (write-file file "\
(define-module (fixtures defined-infrastructure)
  #:use-module (tofuix)
  #:export (infrastructure))

(define infrastructure
  (configuration (resource 'terraform_data 'defined (input \"defined\"))))
")
  (test-equal "a define-module file is found through its binding"
    "defined"
    (let* ((configuration (tofu-evaluate-file file))
           (resource (car (tofu-configuration-resources configuration))))
      (cdr (assoc "input" (tofu-resource-arguments resource)))))
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

(test-error "a missing load path entry is an error"
  'tofuix-error
  (tofu-evaluate-file "examples/tls.scm" #:load-path (list "/does/not/exist")))

(test-end "evaluate")

(exit (if (zero? (+ (test-runner-fail-count runner)
                    (test-runner-xpass-count runner)))
          0 1))
