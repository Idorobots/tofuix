;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; Evaluating infrastructure files: each file runs in a fresh module, with
;;; its own directory as the working directory, and the result is the
;;; <tofu-configuration> value it produced.  The evaluation session (the
;;; module plus the source of the file's top-level defines) is returned
;;; alongside the configuration so that lowering can resolve where named
;;; Guix values come from.

(define-module (tofuix evaluate)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-9)
  #:use-module (tofuix expressions)
  #:use-module (tofuix records)
  #:export (make-evaluation-session
            evaluation-session?
            evaluation-session-module
            evaluation-session-local-forms
            tofu-evaluate-file))

(define %default-binding 'infrastructure)

(define-record-type <evaluation-session>
  (make-evaluation-session module local-forms)
  evaluation-session?
  (module evaluation-session-module)
  (local-forms evaluation-session-local-forms))

(define (tofu-error format-string . arguments)
  "Raise a user-facing tofuix error described by FORMAT-STRING."
  (throw 'tofuix-error (apply format #f format-string arguments)))

(define (absolute-load-path entries)
  "Return ENTRIES with relative directories resolved against the current
directory, so they stay valid while evaluation runs elsewhere."
  (map (lambda (entry)
         (if (absolute-file-name? entry)
             entry
             (or (false-if-exception (canonicalize-path entry)) entry)))
       entries))

(define (module-configuration module binding)
  "Return the value of BINDING in MODULE, if it is a configuration."
  (and module
       (let ((variable (module-variable module binding)))
         (and variable
              (variable-bound? variable)
              (let ((value (variable-ref variable)))
                (and (tofu-configuration? value) value))))))

(define (capture-definition form)
  "If FORM is a top-level definition, return (NAME . SOURCE) with the
source that defines NAME; return #f otherwise.  Only plain `define' and
`define*' forms are captured; definitions produced by macros or nested in
other forms are not."
  (match form
    (((or 'define 'define*) name . rest)
     (cond
      ;; (define x expression)
      ((and (symbol? name) (pair? rest) (null? (cdr rest)))
       (cons name (car rest)))
      ;; (define (f arguments ...) body ...) — a procedure definition.
      ((and (pair? name) (symbol? (car name)))
       (cons (car name)
             (if (eq? (car form) 'define)
                 `(lambda ,(cdr name) ,@rest)
                 `(lambda* ,(cdr name) ,@rest))))
      (else #f)))
    (_ #f)))

(define (delete-duplicates entries)
  "Return ENTRIES with later duplicates removed, preserving order."
  (let loop ((rest entries) (acc '()))
    (cond
     ((null? rest) (reverse acc))
     ((member (car rest) acc) (loop (cdr rest) acc))
     (else (loop (cdr rest) (cons (car rest) acc))))))

(define* (tofu-evaluate-file file #:key (load-path '()) (binding %default-binding))
  "Evaluate FILE and return two values: the <tofu-configuration> it
produces and the evaluation session.

FILE runs in a fresh module, with LOAD-PATH prepended to the Guile load
path and with the directory containing FILE as the current directory, so
relative file references inside the infrastructure file resolve against
the project root.  The directory containing FILE and the current working
directory are implicitly appended after LOAD-PATH, so project modules
such as (hosts rpi3) are loadable without explicit -L flags; inherited
entries (Guix and its channels) keep their position after those.  The
configuration is the value of FILE's last expression or, when that
expression is a definition, the value of the top-level BINDING (default:
infrastructure).

The session carries the final evaluation module and the captured source of
the file's top-level defines; lowering uses it to resolve where named Guix
values come from."
  (unless (file-exists? file)
    (tofu-error "infrastructure file not found: ~a" file))
  (let* ((path      (canonicalize-path file))
          (directory (dirname path))
          (load-path (map (lambda (entry)
                            (unless (file-exists? entry)
                              (tofu-error "load path directory not found: ~a" entry))
                            (canonicalize-path
                             (if (absolute-file-name? entry)
                                 entry
                                 (in-vicinity (getcwd) entry))))
                           load-path))
          ;; The file's directory and the current working directory are
          ;; searched after explicit -L entries and before the inherited
          ;; load path (Guix and its channels).
          (implicit-path (delete-duplicates (list directory (getcwd))))
          (search-path (append load-path implicit-path))
          (module    (make-fresh-user-module))
          (saved-cwd (getcwd))
          (saved-path (absolute-load-path %load-path))
          (local-forms '())
          (value     #f)
          (evaluated #f))
    (dynamic-wind
      (lambda ()
        (set! %load-path (append search-path saved-path))
        (chdir directory))
      (lambda ()
        (save-module-excursion
         (lambda ()
           (set-current-module module)
           (set! value (primitive-load path))
           (set! evaluated (current-module))
           ;; Capture the source of top-level defines with a read-only
           ;; pass.  It runs after evaluation so that reader extensions the
           ;; file itself loaded (gexps, tf expressions) are registered.
           (call-with-input-file path
             (lambda (port)
               (let loop ((form (read port)))
                 (unless (eof-object? form)
                   (let ((captured (capture-definition form)))
                     (when captured
                       (set! local-forms (cons captured local-forms))))
                   (loop (read port)))))))))
      (lambda ()
        (chdir saved-cwd)
        (set! %load-path saved-path)))
    (let ((configuration
           (or (and (tofu-configuration? value) value)
               (module-configuration evaluated binding)
               (module-configuration module binding)
               (tofu-error "~a does not produce a configuration: the last expression must evaluate to one, or the file must define ~a"
                           file binding))))
      (values configuration
              (make-evaluation-session evaluated (reverse local-forms))))))
