;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; Scheme-source templates: render a text file into the Scheme source that
;;; a provider evaluates, substituting {{name}} placeholders with values
;;; from the infrastructure.  This keeps provider-side Scheme in a real
;;; file instead of gluing strings together.

(define-module (tofuix template)
  #:use-module (ice-9 format)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-13)
  #:use-module (tofuix expressions)
  #:use-module (tofuix records)
  #:export (render-template
            template-file))

(define (render-value value)
  "Return VALUE as template text: a reference or record becomes an
interpolation \"${address}\", strings are inserted verbatim, and numbers,
booleans, and symbols become their printed form."
  (cond
   ((or (tofu-ref? value) (tofu-resource? value) (tofu-data? value)
        (tofu-variable? value) (tofu-local? value))
    (tofu-ref->string (attribute value)))
   ((string? value) value)
   ((number? value) (number->string value))
   ((boolean? value) (if value "#t" "#f"))
   ((symbol? value) (symbol->string value))
   (else
    (error (format #f "tofuix: template: cannot render value: ~s" value)))))

(define (binding-name key)
  (if (symbol? key) (symbol->string key) key))

(define (find-binding bindings name)
  (or (assoc name bindings)
      (assoc (string->symbol name) bindings)))

(define (render-template text bindings)
  "Render TEXT, replacing every {{name}} placeholder with the value bound
to NAME in BINDINGS (an association list with symbol or string keys).

A reference or record renders as its interpolation \"${address}\"; a string
is inserted verbatim; numbers, booleans, and symbols are printed.  Inserted
text is not rescanned, so it may itself contain {{.  An unknown or
unterminated placeholder is an error."
  (let loop ((index 0) (pieces '()))
    (let ((open (string-contains text "{{" index)))
      (if (not open)
          (string-concatenate (reverse (cons (substring text index) pieces)))
          (let ((close (string-contains text "}}" (+ open 2))))
            (unless close
              (error (format #f
                             "tofuix: template: unterminated placeholder at position ~a"
                             open)))
            (let* ((name (string-trim-both (substring text (+ open 2) close)))
                   (binding (find-binding bindings name)))
              (unless binding
                (error (format #f
                               "tofuix: template: no binding named ~s (available: ~a)"
                               name
                               (string-join (map (lambda (entry)
                                                   (binding-name (car entry)))
                                                 bindings)
                                            ", "))))
              (loop (+ close 2)
                    (cons (render-value (cdr binding))
                          (cons (substring text index open) pieces)))))))))

(define (template-file file bindings)
  "Read FILE (relative to the current directory) and render it with
BINDINGS; see `render-template'."
  (unless (file-exists? file)
    (error (format #f "tofuix: template-file: no such file: ~a" file)))
  (render-template (call-with-input-file file get-string-all) bindings))
