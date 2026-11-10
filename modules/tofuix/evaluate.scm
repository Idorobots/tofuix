;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; Evaluating infrastructure files: each file runs in a fresh module, with
;;; its own directory as the working directory, and the result is the
;;; <tofu-configuration> value it produced.

(define-module (tofuix evaluate)
  #:use-module (ice-9 format)
  #:use-module (tofuix records)
  #:export (tofu-evaluate-file))

(define %default-binding 'infrastructure)

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

(define* (tofu-evaluate-file file #:key (load-path '()) (binding %default-binding))
  "Evaluate FILE and return the <tofu-configuration> it produces.

FILE runs in a fresh module, with LOAD-PATH prepended to the Guile load
path and with the directory containing FILE as the current directory, so
relative file references inside the infrastructure file resolve against
the project root.  The configuration is the value of FILE's last
expression or, when that expression is a definition, the value of the
top-level BINDING (default: infrastructure)."
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
         (module    (make-fresh-user-module))
         (saved-cwd (getcwd))
         (saved-path (absolute-load-path %load-path))
         (value     #f)
         (evaluated #f))
    (dynamic-wind
      (lambda ()
        (set! %load-path (append load-path saved-path))
        (chdir directory))
      (lambda ()
        (save-module-excursion
         (lambda ()
           (set-current-module module)
           (set! value (primitive-load path))
           (set! evaluated (current-module)))))
      (lambda ()
        (chdir saved-cwd)
        (set! %load-path saved-path)))
    (or (and (tofu-configuration? value) value)
        (module-configuration evaluated binding)
        (module-configuration module binding)
        (tofu-error "~a does not produce a configuration: the last expression must evaluate to one, or the file must define ~a"
                    file binding))))
