;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; Working directories, tool discovery, and process invocation for the
;;; `guix tofu` extension.  Nothing here depends on Guix modules, so the
;;; logic is testable from plain Guile.

(define-module (tofuix workdir)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-13)
  #:use-module (tofuix serializer)
  #:export (tofu-project-root
            tofu-workdir
            tofu-config-file
            tofu-lock-file
            tofu-ensure-directory
            tofu-write-configuration
            tofu-find-tool
            tofu-shell-quote
            tofu-run
            tofu-run/capture))

(define %workdir-name ".tofuix")
(define %config-name "main.tf.json")
(define %lock-name ".terraform.lock.hcl")

(define (tofu-project-root file)
  "Return the project root for FILE: the directory containing it."
  (dirname (canonicalize-path file)))

(define (tofu-workdir root)
  "Return the tofuix working directory for project ROOT."
  (in-vicinity root %workdir-name))

(define (tofu-config-file workdir)
  "Return the generated configuration path inside WORKDIR."
  (in-vicinity workdir %config-name))

(define (tofu-lock-file workdir)
  "Return the provider lock file path inside WORKDIR."
  (in-vicinity workdir %lock-name))

(define (tofu-ensure-directory directory)
  "Create DIRECTORY and any missing parents; return DIRECTORY."
  (unless (file-exists? directory)
    (tofu-ensure-directory (dirname directory))
    (mkdir directory))
  directory)

(define (tofu-write-configuration configuration workdir)
  "Serialize CONFIGURATION to main.tf.json in WORKDIR, atomically.

Existing files in WORKDIR, in particular the provider lock file and the
provider cache, are left untouched."
  (tofu-ensure-directory workdir)
  (let* ((file (tofu-config-file workdir))
         (temp (string-append file ".tmp"))
         (json (string-append (tofu-configuration->json configuration) "\n")))
    (call-with-output-file temp
      (lambda (port)
        (display json port)))
    (rename-file temp file)
    file))

(define* (tofu-find-tool name #:key (path (getenv "PATH")))
  "Return the absolute file name of NAME on PATH, or #f when not found."
  (define (executable-file? file)
    (and (file-exists? file)
         (not (eq? 'directory (stat:type (stat file))))
         (access? file X_OK)))
  (if (string-index name #\/)
      (and (executable-file? name) (canonicalize-path name))
      (let loop ((directories (if path (string-split path #\:) '())))
        (cond
         ((null? directories) #f)
         (else
          (let* ((directory (car directories))
                 (candidate (if (string-null? directory)
                                (in-vicinity "." name)
                                (in-vicinity directory name))))
            (if (executable-file? candidate)
                (canonicalize-path candidate)
                (loop (cdr directories)))))))))

(define (tofu-shell-quote string)
  "Quote STRING for /bin/sh, escaping single quotes."
  (string-append "'"
                 (string-join (string-split string #\') "'\\''")
                 "'"))

(define (status->code status)
  (or (status:exit-val status) 128))

(define* (tofu-run program arguments #:key (directory #f))
  "Run PROGRAM with ARGUMENTS, optionally in DIRECTORY; return its exit code."
  (let ((run (lambda () (apply system* program arguments))))
    (status->code
     (if directory
         (let ((saved (getcwd)))
           (dynamic-wind
             (lambda () (chdir directory))
             run
             (lambda () (chdir saved))))
         (run)))))

(define* (tofu-run/capture program arguments #:key (directory #f))
  "Run PROGRAM with ARGUMENTS, capturing its standard output.

Return two values: the captured output and the exit code."
  (let* ((command (string-join (cons program
                                     (map tofu-shell-quote arguments))
                               " "))
         (run (lambda ()
                (let* ((port (open-input-pipe command))
                       (output (get-string-all port))
                       (status (close-pipe port)))
                  (values output (status->code status))))))
    (if directory
        (let ((saved (getcwd)))
          (dynamic-wind
            (lambda () (chdir directory))
            run
            (lambda () (chdir saved))))
        (run))))
