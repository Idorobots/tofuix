;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; Store-dependent lowering checks.  Requires a running guix-daemon.
;;; From the channel root:
;;;   guix repl -L modules -L . tests/runtime/lowering.scm

(use-modules (ice-9 textual-ports)
             (srfi srfi-9)
             (srfi srfi-11)
             (srfi srfi-13)
             (guix store)
             (guix gexp)
             (guix packages)
             (guix derivations)
             (gnu packages base)
             (gnu system)
             (tofuix)
             (tofuix evaluate)
             (tofuix lower)
             (tofuix serializer)
             (tests runtime lib artifacts)
             (tests runtime lib os-fixture))

(define store (open-connection))

(define (check what ok?)
  (unless ok?
    (error "lowering check failed" what))
  (format #t "PASS ~a~%" what))

(define (resource-argument name lowered)
  (cdr (assoc name
              (tofu-resource-arguments
               (car (tofu-configuration-resources lowered))))))

(define (resource-input lowered)
  (resource-argument "input" lowered))

;;; File-like objects: plain-file is imported immediately.
(let ((path (lower-value greeting store)))
  (check "file-like values lower to an existing store path"
         (and (string? path)
              (string-prefix? "/gnu/store/" path)
              (file-exists? path)))
  (check "the lowered store path holds the file contents"
         (string=? (call-with-input-file path get-string-all)
                   "hello from tofuix\n")))

;;; Computed files: prospective path in plan mode, built on request.
(define unique-artifact
  (artifact (string-append "tofuix-artifact-"
                           (number->string (getpid))
                           ".txt")))

(define configuration-with-artifact
  (configuration
    (resource terraform_data artifact
      (input unique-artifact))))

(let ((path (resource-input (lower-configuration configuration-with-artifact store))))
  (check "a computed file lowers to a prospective store path"
         (and (string-prefix? "/gnu/store/" path)
              (string-contains path "tofuix-artifact-")
              (string-suffix? ".txt" path)))
  (check "plan-mode lowering does not build the artifact"
         (not (file-exists? path)))
  (let ((realized (resource-input
                   (lower-configuration configuration-with-artifact store
                                        #:realize? #t))))
    (check "realizing lowering builds the artifact and keeps its path"
           (and (string=? path realized)
                (file-exists? realized)))
    (check "the realized artifact has the expected contents"
           (string=? (call-with-input-file
                         (string-append realized "/data")
                       get-string-all)
                     "artifact data"))))

;;; Packages: the output path is computed without building anything.
(let ((path (lower-value hello store)))
  (check "packages lower to their store path"
         (and (string? path)
              (string-prefix? "/gnu/store/" path)
              (string-contains path "-hello-"))))

;;; References and expressions are values, not containers.
(define example
  (resource terraform_data example
    (input "value")))

(define reference-configuration
  (configuration
    example
    (local the-resource example)
    (output identifier (attribute example id))))

(let ((json (tofu-configuration->json
             (lower-configuration reference-configuration store))))
  (check "lowering keeps whole-resource references intact"
         (string-contains json "\"${terraform_data.example}\""))
  (check "lowering keeps attribute references intact"
         (string-contains json "\"${terraform_data.example.id}\"")))

;;; Named Guix records: operating systems cross the boundary by name
;;; instead of a store path.
(define os-session
  (make-evaluation-session (current-module) '()))

(let ((lowered
       (lower-configuration
        (configuration
          (resource guix_blueprint demo (os demo-os)))
        store #:session os-session)))
  (check "imported operating systems lower to their module reference"
         (string=? (resource-argument "os" lowered)
                   "(@ (tests runtime lib os-fixture) demo-os)")))

;;; Locally defined operating systems render the source captured at
;;; evaluation time.
(let* ((directory (mkdtemp "/tmp/tofuix-runtime-XXXXXX"))
       (file (in-vicinity directory "infrastructure.scm")))
  (call-with-output-file file
    (lambda (port)
      (display "\
(use-modules (gnu system) (tofuix))

(define my-os
  (operating-system
    (host-name \"runtime-local\")
    (bootloader #f)
    (file-systems '())))

(define infrastructure
  (configuration
    (resource guix_blueprint local (os my-os))))
" port)))
  (let-values (((configuration session) (tofu-evaluate-file file)))
    (let ((lowered (lower-configuration configuration store
                                        #:session session)))
      (check "local operating systems render their captured source"
             (equal? (read (open-input-string
                            (resource-argument "os" lowered)))
                     '(begin
                        (use-modules (gnu system))
                        (operating-system
                          (host-name "runtime-local")
                          (bootloader #f)
                          (file-systems '())))))))
  (system* "rm" "-rf" directory))

;;; Anything else is an explicit error.
(define-record-type <opaque>
  (make-opaque)
  opaque?)

(check "unlowerable values raise a tofuix error"
       (catch 'tofuix-error
         (lambda () (lower-value (make-opaque) store) #f)
         (lambda (key message) (string? message))))

(display "All runtime lowering checks passed.\n")
