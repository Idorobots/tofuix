;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; Provenance resolution for named Guix values: imported bindings become
;;; canonical module references, local bindings render their captured
;;; source.

(define-module (tests provenance-test)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-64)
  #:use-module (tests fixtures provenance-a)
  #:use-module (tofuix evaluate)
  #:use-module (tofuix lower)
  #:use-module (tofuix provenance))

(define runner (test-runner-create))
(test-runner-current runner)

(define (make-temp-directory)
  (mkdtemp "/tmp/tofuix-provenance-XXXXXX"))

(define (delete-directory directory)
  (system* "rm" "-rf" directory))

(define (write-file file text)
  (call-with-output-file file
    (lambda (port)
      (display text port))))

(define (evaluate-infrastructure text)
  "Evaluate TEXT as an infrastructure file; return its session."
  (let* ((directory (make-temp-directory))
         (file (in-vicinity directory "infrastructure.scm")))
    (write-file file text)
    (let-values (((configuration session)
                  (tofu-evaluate-file file)))
      (delete-directory directory)
      session)))

(define (session-module-value session name)
  (module-ref (evaluation-session-module session) name))

(define (read-source string)
  (with-input-from-string string read))

;;; Sessions built from an explicit module, like the ones evaluation
;;; produces for ordinary infrastructure files.

(define (make-test-session module)
  (make-evaluation-session module '()))

(test-begin "provenance")

(let ((session (make-test-session (current-module))))
  (test-equal "imported bindings resolve to their module reference"
    "(@ (tests fixtures provenance-a) shared-object)"
    (resolve-named-value shared-object session))

  (test-equal "lower-value resolves imported structs by name"
    "(@ (tests fixtures provenance-a) demo-record)"
    (lower-value demo-record #f #:session session))

  (test-eqv "anonymous values do not resolve"
    #f
    (resolve-named-value (list 'fresh 'object) session)))

(let ((module (make-fresh-user-module)))
  (module-use! module (resolve-interface '(tests fixtures provenance-a)))
  (module-use! module (resolve-interface '(tests fixtures provenance-b)))
  (let ((session (make-test-session module)))
    (test-error "values exported by several modules are an error"
      'tofuix-error
      (resolve-named-value shared-object session))))

(let* ((session (evaluate-infrastructure "\
(use-modules (tests fixtures provenance-a) (tofuix))

(define my-alias shared-object)

(configuration (resource 'terraform_data 'demo (input \"x\")))
")))
  (test-equal "local aliases resolve to the imported binding"
    "(@ (tests fixtures provenance-a) shared-object)"
    (resolve-named-value (session-module-value session 'my-alias) session)))

(let* ((session (evaluate-infrastructure "\
(use-modules (tofuix))

(define local-thing (list 'x 1 \"two\"))

(configuration (resource 'terraform_data 'demo (input \"x\")))
")))
  (test-equal "local bindings render their captured source"
    '(list 'x 1 "two")
    (read-source
     (resolve-named-value (session-module-value session 'local-thing)
                          session))))

(let* ((session (evaluate-infrastructure "\
(use-modules (tofuix))

(define base (list 'b))
(define combo (list 'inner base))

(configuration (resource 'terraform_data 'demo (input \"x\")))
")))
  (test-equal "local references inside a local form are substituted"
    '(list 'inner (list 'b))
    (read-source
     (resolve-named-value (session-module-value session 'combo) session))))

(let* ((session (evaluate-infrastructure "\
(use-modules (tests fixtures provenance-a) (tofuix))

(define wrapper (list 'wrap shared-object))

(configuration (resource 'terraform_data 'demo (input \"x\")))
")))
  (let ((rendered
         (resolve-named-value (session-module-value session 'wrapper)
                              session)))
    (test-assert "local forms load the modules of imported references"
      (string-contains rendered "use-modules"))
    (test-equal "local forms keep imported references by name"
      '(list 'wrap shared-object)
      (caddr (read-source rendered)))))

(let* ((session (evaluate-infrastructure "\
(use-modules (tofuix))

(define (f) (g))
(define (g) (f))

(configuration (resource 'terraform_data 'demo (input \"x\")))
")))
  (test-error "circular local references are an error"
    'tofuix-error
    (resolve-named-value (session-module-value session 'f) session)))

(let* ((session (evaluate-infrastructure "\
(use-modules (tofuix))

(define-values (a b) (values 1 2))

(configuration (resource 'terraform_data 'demo (input \"x\")))
")))
  (test-error "uncaptured local bindings are an error"
    'tofuix-error
    (resolve-named-value (session-module-value session 'a) session)))

(let ((session (make-test-session (current-module))))
  (test-error "unresolvable structs remain a lowering error"
    'tofuix-error
    (lower-value (current-output-port) #f #:session session)))

(test-end "provenance")

(exit (if (zero? (+ (test-runner-fail-count runner)
                    (test-runner-xpass-count runner)))
          0 1))
