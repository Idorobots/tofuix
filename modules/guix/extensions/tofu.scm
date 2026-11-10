;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; The `guix tofu` extension: argument parsing, the single-stage command
;;; lifecycle, and invocation of the selected OpenTofu/Terraform binary.
;;; Guix finds this file at <extensions-dir>/guix/extensions/tofu.scm and
;;; calls guix-tofu with the arguments that follow `guix tofu'.

(define-module (guix extensions tofu)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:use-module (tofuix evaluate)
  #:use-module (tofuix serializer)
  #:use-module (tofuix workdir)
  #:export (guix-tofu
            tofu-main
            tofu-parse-arguments))

(define %default-file "infrastructure.scm")
(define %tool-names '("tofu" "terraform"))
(define %default-tool "tofu")

(define (tofu-usage port)
  (format port "\
Usage: guix tofu COMMAND [OPTIONS] [-- ARGS...]

Commands:
  eval      Evaluate the infrastructure file and print its JSON configuration
  check     Generate the configuration, then run `tofu init -backend=false'
            and `tofu validate'
  plan      Generate the configuration, initialize providers, then run
            `tofu plan'
  apply     As plan, then run `tofu apply'
  output    Print OpenTofu outputs (from the existing state unless -f is
            given); prints `tofu output -json' unless an output name is given
  help      Show this help

Options:
  -f, --file=FILE       Infrastructure file (default: infrastructure.scm)
  -L, --load-path=DIR   Prepend DIR to the Guile load path (repeatable)
      --tool=NAME       Tool to run: tofu (default) or terraform
  -C, --chdir=DIR       Run as if started in DIR
  -h, --help            Show this help

Arguments after -- are forwarded to the underlying tool, as are unknown
options such as -target=... and -var=...  --tool=terraform requires
terraform on PATH; tofuix does not package it.
"))

(define (tofu-parse-arguments arguments)
  "Parse the arguments that follow `guix tofu'.

Return four values: the COMMAND name (string or #f), an association list
of OPTIONS (help, file, load-path, tool, chdir), the POSITIONAL
arguments, and the arguments FORWARDED to the underlying tool."
  (define (missing option)
    (throw 'tofuix-error (format #f "option ~a requires an argument" option)))
  (define (finish command file load-path tool chdir help positionals forwarded)
    (unless (member tool %tool-names)
      (throw 'tofuix-error
             (format #f "unknown tool: ~a (expected one of: ~a)"
                     tool (string-join %tool-names ", "))))
    (values command
            `((help . ,help)
              (file . ,file)
              (load-path . ,(reverse load-path))
              (tool . ,tool)
              (chdir . ,chdir))
            positionals
            forwarded))
  (let loop ((rest arguments)
             (command #f)
             (file #f)
             (load-path '())
             (tool %default-tool)
             (chdir #f)
             (help #f)
             (positionals '())
             (forwarded '()))
    (cond
     ((null? rest)
      (finish command file load-path tool chdir help positionals forwarded))

     ;; Everything after -- is forwarded verbatim.
     ((string=? (car rest) "--")
      (finish command file load-path tool chdir help positionals
              (append forwarded (cdr rest))))

     ((or (string=? (car rest) "-h") (string=? (car rest) "--help"))
      (loop (cdr rest) command file load-path tool chdir #t positionals forwarded))

     ((string=? (car rest) "-f")
      (if (null? (cdr rest))
          (missing "-f")
          (loop (cddr rest) command (cadr rest) load-path tool chdir help positionals forwarded)))

     ((string-prefix? "--file=" (car rest))
      (loop (cdr rest) command (substring (car rest) 7) load-path tool chdir help positionals forwarded))

     ((string=? (car rest) "-L")
      (if (null? (cdr rest))
          (missing "-L")
          (loop (cddr rest) command file (cons (cadr rest) load-path) tool chdir help positionals forwarded)))

     ((string-prefix? "--load-path=" (car rest))
      (loop (cdr rest) command file (cons (substring (car rest) 12) load-path) tool chdir help positionals forwarded))

     ((string=? (car rest) "--tool")
      (if (null? (cdr rest))
          (missing "--tool")
          (loop (cddr rest) command file load-path (cadr rest) chdir help positionals forwarded)))

     ((string-prefix? "--tool=" (car rest))
      (loop (cdr rest) command file load-path (substring (car rest) 7) chdir help positionals forwarded))

     ((string=? (car rest) "-C")
      (if (null? (cdr rest))
          (missing "-C")
          (loop (cddr rest) command file load-path tool (cadr rest) help positionals forwarded)))

     ((string=? (car rest) "--chdir")
      (if (null? (cdr rest))
          (missing "--chdir")
          (loop (cddr rest) command file load-path tool (cadr rest) help positionals forwarded)))

     ((string-prefix? "--chdir=" (car rest))
      (loop (cdr rest) command file load-path tool (substring (car rest) 8) help positionals forwarded))

     ((string-prefix? "-" (car rest))
      (loop (cdr rest) command file load-path tool chdir help positionals
            (append forwarded (list (car rest)))))

     (command
      (loop (cdr rest) command file load-path tool chdir help
            (append positionals (list (car rest))) forwarded))

     (else
      (loop (cdr rest) (car rest) file load-path tool chdir help positionals forwarded)))))

(define (assq-ref alist key)
  (cdr (assq key alist)))

(define (resolve-file file chdir)
  (let ((file (or file %default-file))
        (base (or chdir ".")))
    (if (absolute-file-name? file)
        file
        (in-vicinity base file))))

(define (load-configuration file chdir load-path)
  "Evaluate the infrastructure file; return two values: the configuration
and the project root."
  (let ((path (resolve-file file chdir)))
    (values (tofu-evaluate-file path #:load-path load-path)
            (tofu-project-root path))))

(define (resolve-tool tool)
  (or (tofu-find-tool tool)
      (throw 'tofuix-error
             (if (string=? tool "tofu")
                 "the tofu executable is not on PATH; install OpenTofu (the channel's packaged fallback arrives with milestone M3) or pass --tool=terraform"
                 "the terraform executable is not on PATH; tofuix does not package Terraform"))))

(define (run-after-init program init-arguments arguments workdir)
  (let ((status (tofu-run program init-arguments #:directory workdir)))
    (if (zero? status)
        (tofu-run program arguments #:directory workdir)
        status)))

(define (no-positionals command positionals)
  (unless (null? positionals)
    (throw 'tofuix-error
           (format #f "~a takes no positional arguments: ~s" command positionals))))

(define (command-eval file chdir load-path positionals forwarded)
  (no-positionals "eval" positionals)
  (unless (null? forwarded)
    (throw 'tofuix-error
           (format #f "eval does not run a tool; unexpected arguments: ~s" forwarded)))
  (let-values (((configuration root) (load-configuration file chdir load-path)))
    (display (tofu-configuration->json configuration))
    (newline)
    0))

(define (command-build file chdir load-path positionals forwarded)
  (throw 'tofuix-error
         "the build command arrives with Guile-value lowering (milestone M3)"))

(define (command-graph file chdir load-path positionals forwarded)
  (throw 'tofuix-error
         "the graph command is not implemented yet"))

(define (command-check file chdir load-path positionals forwarded tool)
  (no-positionals "check" positionals)
  (let-values (((configuration root) (load-configuration file chdir load-path)))
    (let ((workdir (tofu-workdir root))
          (program (resolve-tool tool)))
      (tofu-write-configuration configuration workdir)
      (run-after-init program
                      (list "init" "-backend=false" "-input=false")
                      (append (list "validate") forwarded)
                      workdir))))

(define (command-plan file chdir load-path positionals forwarded tool)
  (no-positionals "plan" positionals)
  (let-values (((configuration root) (load-configuration file chdir load-path)))
    (let ((workdir (tofu-workdir root))
          (program (resolve-tool tool)))
      (tofu-write-configuration configuration workdir)
      (run-after-init program
                      (list "init" "-input=false")
                      (append (list "plan") forwarded)
                      workdir))))

(define (command-apply file chdir load-path positionals forwarded tool)
  (no-positionals "apply" positionals)
  (let-values (((configuration root) (load-configuration file chdir load-path)))
    (let ((workdir (tofu-workdir root))
          (program (resolve-tool tool)))
      (tofu-write-configuration configuration workdir)
      (run-after-init program
                      (list "init" "-input=false")
                      (append (list "apply") forwarded)
                      workdir))))

(define (command-output file chdir load-path positionals forwarded tool)
  (when (> (length positionals) 1)
    (throw 'tofuix-error "output takes at most one output name"))
  (let* ((program (resolve-tool tool))
         (root (cond
                (file
                 (let-values (((configuration root)
                               (load-configuration file chdir load-path)))
                   root))
                (chdir (canonicalize-path chdir))
                (else (getcwd))))
         (workdir (tofu-workdir root))
         (arguments (append (list "output")
                            (if (null? positionals) '("-json") positionals)
                            forwarded)))
    (tofu-run program arguments #:directory workdir)))

(define (tofu-main arguments)
  "Run the tofuix command line and return an exit code."
  (let-values (((command options positionals forwarded)
                (tofu-parse-arguments arguments)))
    (let ((file      (assq-ref options 'file))
          (load-path (assq-ref options 'load-path))
          (tool      (assq-ref options 'tool))
          (chdir     (assq-ref options 'chdir))
          (help      (assq-ref options 'help)))
      (cond
       ((or help (not command) (string=? command "help"))
        (tofu-usage (current-output-port))
        0)
       ((string=? command "eval")
        (command-eval file chdir load-path positionals forwarded))
       ((string=? command "build")
        (command-build file chdir load-path positionals forwarded))
       ((string=? command "check")
        (command-check file chdir load-path positionals forwarded tool))
       ((string=? command "plan")
        (command-plan file chdir load-path positionals forwarded tool))
       ((string=? command "apply")
        (command-apply file chdir load-path positionals forwarded tool))
       ((string=? command "output")
        (command-output file chdir load-path positionals forwarded tool))
       ((string=? command "graph")
        (command-graph file chdir load-path positionals forwarded))
       (else
        (format (current-error-port) "guix: tofu: unknown command: ~a~%" command)
        (tofu-usage (current-error-port))
        1)))))

(define (guix-tofu . arguments)
  "Entry point for `guix tofu'."
  (exit
   (catch #t
     (lambda ()
       (tofu-main arguments))
     (lambda (key . arguments)
       (cond
        ((eq? key 'tofuix-error)
         (format (current-error-port) "guix: tofu: ~a~%" (car arguments)))
        (else
         (print-exception (current-error-port) #f key arguments)))
       1))))
