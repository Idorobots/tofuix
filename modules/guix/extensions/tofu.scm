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
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:use-module (tofuix evaluate)
  #:use-module (tofuix lower)
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
  generate  Evaluate the infrastructure file and print its JSON configuration
  build     As generate, realize required Guix artifacts, and write the
            configuration to the working directory
  validate  Generate the configuration, then run `tofu init -backend=false'
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

;;;
;;; Guix integration: store access, lowering, and the packaged tool
;;; fallback.  Guix modules are resolved lazily so the extension itself
;;; stays loadable from plain Guile (the test suite).
;;;

(define %guix-modules (make-hash-table))

(define (find-guix-module name)
  "Return the Guix module NAME, or #f when it is unavailable."
  (or (hash-ref %guix-modules name)
      (let ((module (false-if-exception (resolve-interface name))))
        (when module
          (hash-set! %guix-modules name module))
        module)))

(define (guix-module name)
  "Return the Guix module NAME or raise a user-facing error."
  (or (find-guix-module name)
      (throw 'tofuix-error
             (format #f "Guix modules are unavailable (cannot resolve ~s); run this command through guix"
                     name))))

(define (module-ref-or-false module name)
  "Return the value of NAME in MODULE, or #f when MODULE does not provide
it."
  (and module (false-if-exception (module-ref module name))))

(define (guix-binding modules name)
  "Return the first binding of NAME found in one of MODULES.

Guix moves procedures between modules across versions (for instance
`run-with-store' lives in (guix store) in 1.5), so bindings are looked up
across a list of candidate modules instead of assuming one layout."
  (any (lambda (module-name)
         (module-ref-or-false (find-guix-module module-name) name))
       modules))

(define %store #f)

(define (guix-store)
  "Return the daemon connection, opening it on first use."
  (or %store
      (let* ((module (guix-module '(guix store)))
             (store ((module-ref module 'open-connection))))
        (set! %store store)
        store)))

(define* (guix-lowering-context #:key (realize? #f))
  "Return a lowering context backed by the Guix store.

File-like objects and packages are resolved to store paths.  With
REALIZE? true, `lowering-context-realize!' builds the derivations the
lowering computed; otherwise they remain unbuilt (plan semantics)."
  (let* ((pending '())
         (file-like? (guix-binding '((guix gexp)) 'file-like?))
         (package? (guix-binding '((guix packages)) 'package?))
         (lower-object (guix-binding '((guix gexp)) 'lower-object))
         (package-derivation (guix-binding '((guix packages)) 'package-derivation))
         (output-path (guix-binding '((guix derivations)) 'derivation->output-path))
         (run-with-store (guix-binding '((guix store) (guix monads)) 'run-with-store))
         (build-derivations (guix-binding '((guix derivations) (guix store)) 'build-derivations)))
    (define (remember derivation)
      (set! pending (cons derivation pending)))
    (make-lowering-context
     (lambda (value) (and file-like? (file-like? value)))
     (lambda (value) (and package? (package? value)))
     (lambda (object)
       ;; `lower-object' yields either an already-available store path (a
       ;; string, as for plain-file) or a derivation to build later.
       (let ((lowered (run-with-store (guix-store) (lower-object object))))
         (if (string? lowered)
             lowered
             (begin (remember lowered) (output-path lowered)))))
     (lambda (package)
       (let ((derivation (package-derivation (guix-store) package)))
         (remember derivation)
         (output-path derivation)))
     (lambda ()
       (when (and realize? (pair? pending))
         (build-derivations (guix-store) pending)
         (set! pending '()))))))

(define* (lower-infrastructure configuration #:key (realize? #f))
  "Lower the Guix values in CONFIGURATION, realizing artifacts when
REALIZE? is true."
  (let ((context (guix-lowering-context #:realize? realize?)))
    (let ((lowered (lower-configuration configuration context)))
      (lowering-context-realize! context)
      lowered)))

(define (opentofu-from-store)
  "Return the tofu executable provided by the channel's opentofu package,
building the package when needed."
  (let* ((packages-module (guix-module '(tofuix packages)))
         (package (module-ref-or-false packages-module 'opentofu))
         (store (guix-store))
         (package-derivation (guix-binding '((guix packages)) 'package-derivation))
         (build-derivations (guix-binding '((guix derivations) (guix store)) 'build-derivations))
         (output-path (guix-binding '((guix derivations)) 'derivation->output-path))
         (derivation (package-derivation store package))
         (built? (build-derivations store (list derivation)))
         (output (output-path derivation)))
    (unless built?
      (throw 'tofuix-error "failed to build the channel's opentofu package"))
    (string-append output "/bin/tofu")))

(define (resolve-tool tool)
  (or (tofu-find-tool tool)
      (if (string=? tool "tofu")
          (catch #t
            (lambda () (opentofu-from-store))
            (lambda (key . arguments)
              (throw 'tofuix-error
                     (format #f "the tofu executable is not on PATH and could not be provided by the channel's opentofu package: ~a"
                             (if (eq? key 'tofuix-error)
                                 (car arguments)
                                 key)))))
          (throw 'tofuix-error
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

(define (command-generate file chdir load-path positionals forwarded)
  (no-positionals "generate" positionals)
  (unless (null? forwarded)
    (throw 'tofuix-error
           (format #f "generate does not run a tool; unexpected arguments: ~s" forwarded)))
  (let-values (((configuration root) (load-configuration file chdir load-path)))
    (display (tofu-configuration->json (lower-infrastructure configuration)))
    (newline)
    0))

(define (command-build file chdir load-path positionals forwarded)
  (no-positionals "build" positionals)
  (unless (null? forwarded)
    (throw 'tofuix-error
           (format #f "build does not run a tool; unexpected arguments: ~s" forwarded)))
  (let-values (((configuration root) (load-configuration file chdir load-path)))
    (let* ((lowered (lower-infrastructure configuration #:realize? #t))
           (workdir (tofu-workdir root)))
      (tofu-write-configuration lowered workdir)
      (display (tofu-configuration->json lowered))
      (newline)
      0)))

(define (command-graph file chdir load-path positionals forwarded)
  (throw 'tofuix-error
         "the graph command is not implemented yet"))

(define (command-validate file chdir load-path positionals forwarded tool)
  (no-positionals "validate" positionals)
  (let-values (((configuration root) (load-configuration file chdir load-path)))
    (let* ((lowered (lower-infrastructure configuration))
           (workdir (tofu-workdir root))
           (program (resolve-tool tool)))
      (tofu-write-configuration lowered workdir)
      (run-after-init program
                      (list "init" "-backend=false" "-input=false")
                      (append (list "validate") forwarded)
                      workdir))))

(define (command-plan file chdir load-path positionals forwarded tool)
  (no-positionals "plan" positionals)
  (let-values (((configuration root) (load-configuration file chdir load-path)))
    (let* ((lowered (lower-infrastructure configuration))
           (workdir (tofu-workdir root))
           (program (resolve-tool tool)))
      (tofu-write-configuration lowered workdir)
      (run-after-init program
                      (list "init" "-input=false")
                      (append (list "plan") forwarded)
                      workdir))))

(define (command-apply file chdir load-path positionals forwarded tool)
  (no-positionals "apply" positionals)
  (let-values (((configuration root) (load-configuration file chdir load-path)))
    (let* ((lowered (lower-infrastructure configuration #:realize? #t))
           (workdir (tofu-workdir root))
           (program (resolve-tool tool)))
      (tofu-write-configuration lowered workdir)
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
       ((string=? command "generate")
        (command-generate file chdir load-path positionals forwarded))
       ((string=? command "build")
        (command-build file chdir load-path positionals forwarded))
       ((string=? command "validate")
        (command-validate file chdir load-path positionals forwarded tool))
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
