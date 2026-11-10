;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; Guix-value lowering: turn native Guix objects used as argument values
;;; into plain values OpenTofu understands (store paths).

(define-module (tofuix lower)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (guix store)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix derivations)
  #:use-module (tofuix expressions)
  #:use-module (tofuix records)
  #:export (lower-value
            lower-configuration))

(define (tofu-error format-string . arguments)
  (throw 'tofuix-error (apply format #f format-string arguments)))

(define (alist-like? value)
  "Return true when VALUE is an association list whose entries all have a
symbol or string key; this distinguishes objects from arrays, exactly as
the serializer does."
  (and (pair? value)
       (every (lambda (entry)
                (and (pair? entry)
                     (or (symbol? (car entry)) (string? (car entry)))))
              value)))

(define (lower-file-like object store remember)
  "Return the store path for the file-like OBJECT, remembering its
derivation for realization when it is not available yet."
  (let ((lowered (run-with-store store (lower-object object))))
    (if (derivation? lowered)
        (begin (remember lowered) (derivation->output-path lowered))
        lowered)))

(define (lower-package package output store remember)
  "Return the store path of PACKAGE's OUTPUT, remembering the derivation
for realization."
  (let ((derivation (package-derivation store package)))
    (remember derivation)
    (derivation->output-path derivation output)))

(define (lower-value-with value store remember)
  "Lower VALUE against STORE, calling REMEMBER on every derivation that
would have to be built for the value to be real."
  (cond
   ;; Reference expressions and records are values, not containers: a
   ;; resource used as an argument is a whole-object reference.
   ((tofu-ref? value) value)
   ((or (tofu-resource? value) (tofu-data? value)
        (tofu-variable? value) (tofu-local? value))
    value)
   ((or (string? value) (symbol? value) (boolean? value) (number? value))
    value)
   ;; (package . \"output\") selects a non-default output.
   ((and (pair? value) (package? (car value)) (string? (cdr value)))
    (lower-package (car value) (cdr value) store remember))
   ((alist-like? value)
    (map (lambda (entry)
           (cons (car entry) (lower-value-with (cdr entry) store remember)))
         value))
   ((list? value)
    (map (lambda (element) (lower-value-with element store remember)) value))
   ((vector? value)
    (list->vector (map (lambda (element)
                         (lower-value-with element store remember))
                       (vector->list value))))
   ((file-like? value) (lower-file-like value store remember))
   ((package? value) (lower-package value "out" store remember))
   (else
    (tofu-error "cannot lower value: ~s; expected a string, number, boolean, symbol, list or association list, an OpenTofu expression, a file-like object, or a package"
                value))))

(define (lower-value value store)
  "Return VALUE with Guix objects replaced by their store paths.

Derivations are computed but not built; use `lower-configuration' with
`#:realize? #t' to build the artifacts a configuration needs."
  (lower-value-with value store (lambda (derivation) #f)))

(define* (lower-configuration configuration store #:key (realize? #f))
  "Return CONFIGURATION with every argument value lowered against STORE.

The configuration's records are rebuilt, so the result serializes exactly
as the original with the lowered values in place.  When REALIZE? is true,
the derivations the lowering computed are built before returning."
  (let ((pending '()))
    (define (remember derivation)
      (set! pending (cons derivation pending)))
    (define (lower value) (lower-value-with value store remember))
    (define (lower-fields fields)
      (map (lambda (entry) (cons (car entry) (lower (cdr entry)))) fields))
    (let ((lowered
           (tofu-configuration
            #:providers
            (map (lambda (provider)
                   (tofu-provider (tofu-provider-name provider)
                                  (tofu-provider-source provider)
                                  #:version (tofu-provider-version provider)
                                  #:arguments
                                  (lower-fields (tofu-provider-arguments provider))))
                 (tofu-configuration-providers configuration))
            #:variables
            (map (lambda (variable)
                   (tofu-variable (tofu-variable-name variable)
                                  (lower-fields (tofu-variable-fields variable))))
                 (tofu-configuration-variables configuration))
            #:datas
            (map (lambda (data)
                   (tofu-data (tofu-data-type data)
                              (tofu-data-name data)
                              #:arguments (lower-fields (tofu-data-arguments data))))
                 (tofu-configuration-datas configuration))
            #:resources
            (map (lambda (resource)
                   (tofu-resource (tofu-resource-type resource)
                                  (tofu-resource-name resource)
                                  #:arguments
                                  (lower-fields (tofu-resource-arguments resource))))
                 (tofu-configuration-resources configuration))
            #:outputs
            (map (lambda (output)
                   (tofu-output (tofu-output-name output)
                                (lower (tofu-output-value output))
                                (lower-fields (tofu-output-fields output))))
                 (tofu-configuration-outputs configuration))
            #:locals
            (map (lambda (local)
                   (tofu-local (tofu-local-name local)
                               (lower (tofu-local-value local))))
                 (tofu-configuration-locals configuration))
            #:root-blocks
            (map (lambda (block)
                   (cons (car block) (lower-fields (cdr block))))
                 (tofu-configuration-root-blocks configuration)))))
      (when (and realize? (pair? pending))
        (build-derivations store pending))
      lowered)))
