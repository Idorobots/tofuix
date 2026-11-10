;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; Lowering is exercised with a mocked store: fake file-like objects and
;;; packages carry their would-be store path as an identifier.

(define-module (tests lower-test)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:use-module (srfi srfi-64)
  #:use-module (tofuix)
  #:use-module (tofuix evaluate)
  #:use-module (tofuix lower))

(define runner (test-runner-create))
(test-runner-current runner)

(define-record-type <fake-file>
  (make-fake-file name)
  fake-file?
  (name fake-file-name))

(define-record-type <fake-package>
  (make-fake-package name)
  fake-package?
  (name fake-package-name))

(define-record-type <opaque>
  (make-opaque)
  opaque?)

(define (make-fake-context)
  "Return a lowering context and a thunk reporting how many times
realization was requested."
  (let ((realizations 0))
    (values
     (make-lowering-context
      fake-file?
      fake-package?
      (lambda (file)
        (string-append "/gnu/store/fake-file-" (fake-file-name file)))
      (lambda (package)
        (string-append "/gnu/store/fake-package-" (fake-package-name package)))
      (lambda ()
        (set! realizations (1+ realizations))))
     (lambda () realizations))))

(define empty-context
  (make-lowering-context
   (lambda (value) #f)
   (lambda (value) #f)
   (lambda (value) (error "no file-like values expected"))
   (lambda (value) (error "no packages expected"))
   (lambda () #f)))

(test-begin "lower")

(test-equal "scalars pass through unchanged"
  (list "text" 42 #t 'symbol)
  (map (lambda (value) (lower-value empty-context value))
       (list "text" 42 #t 'symbol)))

(test-equal "association list values are lowered"
  '(("a" . "text") ("b" . 42))
  (lower-value empty-context '(("a" . "text") ("b" . 42))))

(test-equal "list elements are lowered"
  '("x" "y")
  (lower-value empty-context '("x" "y")))

(test-equal "vector elements are lowered"
  #("x" "y")
  (lower-value empty-context #("x" "y")))

(let-values (((context realizations) (make-fake-context)))
  (test-equal "file-like objects lower to their store path"
    "/gnu/store/fake-file-greeting"
    (lower-value context (make-fake-file "greeting")))
  (test-equal "packages lower to their store path"
    "/gnu/store/fake-package-hello"
    (lower-value context (make-fake-package "hello")))
  (test-equal "nested structures are lowered recursively"
    '(("block" ("path" . "/gnu/store/fake-file-data")
               ("items" "/gnu/store/fake-package-tool")))
    (lower-value context
                 `(("block" ("path" . ,(make-fake-file "data"))
                            ("items" ,(make-fake-package "tool"))))))
  (test-equal "lowering does not realize anything"
    0
    (realizations)))

(let* ((resource (resource 'terraform_data 'example (input "value")))
       (variable (variable 'region (default "eu-central-1")))
       (local (local 'name "example")))
  (test-assert "resource references pass through unchanged"
    (eq? resource (lower-value empty-context resource)))
  (test-assert "variable references pass through unchanged"
    (eq? variable (lower-value empty-context variable)))
  (test-assert "local references pass through unchanged"
    (eq? local (lower-value empty-context local)))
  (test-equal "OpenTofu expressions pass through unchanged"
    "${terraform_data.example.id}"
    (tofu-ref->string (lower-value empty-context
                                   (attribute resource 'id)))))

(test-error "unlowerable values are an error"
  'tofuix-error
  (lower-value empty-context (make-opaque)))

(let-values (((context realizations) (make-fake-context)))
  (let* ((configuration
          (configuration
           (provider 'tls "hashicorp/tls" "~> 4.0")
           (resource 'terraform_data 'example
             (input (make-fake-file "hello"))
             (nested (obj 'package (make-fake-package "tool")
                          'files (list (make-fake-file "a")))))
           (output 'path (make-fake-file "result"))))
         (lowered (lower-configuration configuration context))
         (json (tofu-configuration->json lowered)))
    (test-assert "file-like arguments are lowered in resources"
      (string-contains json "/gnu/store/fake-file-hello"))
    (test-assert "packages are lowered in nested objects"
      (string-contains json "/gnu/store/fake-package-tool"))
    (test-assert "nested arrays are lowered"
      (string-contains json "/gnu/store/fake-file-a"))
    (test-assert "output values are lowered"
      (string-contains json "/gnu/store/fake-file-result"))
    (test-equal "lower-configuration alone realizes nothing"
      0
      (realizations))
    (lowering-context-realize! context)
    (test-equal "realization is requested once explicitly"
      1
      (realizations))))

(test-equal "lowering a plain configuration changes nothing"
  (tofu-configuration->json (tofu-evaluate-file "examples/tls.scm"))
  (tofu-configuration->json
   (lower-configuration (tofu-evaluate-file "examples/tls.scm")
                        empty-context)))

(test-end "lower")

(exit (if (zero? (+ (test-runner-fail-count runner)
                    (test-runner-xpass-count runner)))
          0 1))
