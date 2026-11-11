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
  #:autoload (gnu system) (operating-system?)
  #:autoload (gnu image) (image?)
  #:autoload (gnu machine) (machine?)
  #:use-module (tofuix expressions)
  #:use-module (tofuix provenance)
  #:use-module (tofuix records)
  #:export (lower-value
            lower-configuration))

(define (tofu-error format-string . arguments)
  (throw 'tofuix-error (apply format #f format-string arguments)))

(define %named-record-type-names
  ;; Guix records that cross the tofuix boundary by name instead of a
  ;; store path.  The vtable-name check is a cheap gate; the real
  ;; predicates are autoloaded because (gnu system) and friends are heavy
  ;; and must not load for every file-like value.
  '(<operating-system> <image> <machine>))

(define (record-type-name* value)
  "Return the record type name of the struct VALUE, or #f."
  (and (struct? value)
       (or (false-if-exception (record-type-name (struct-vtable value)))
           #f)))

(define (named-record? value)
  "Return true when VALUE is one of the Guix records that providers
re-evaluate by name (operating systems, images, machines)."
  (and (struct? value)
       (member (record-type-name* value) %named-record-type-names)
       (or (operating-system? value)
           (image? value)
           (machine? value))))

(define (lower-named-value value session)
  (or (resolve-named-value value session)
      (tofu-error "cannot lower value: ~s; this Guix record has no store form, so it crosses the tofuix boundary by name: export it from (or define it in) a module the provider can load, or reference it explicitly with (guile MODULE BINDING)"
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

(define (lower-value-with value store remember session)
  "Lower VALUE against STORE, calling REMEMBER on every derivation that
would have to be built for the value to be real.  SESSION is the
evaluation session used to resolve named Guix values, or #f."
  (cond
   ;; Reference expressions and records are values, not containers: a
   ;; resource used as an argument is a whole-object reference.
   ((tofu-ref? value) value)
   ((or (tofu-resource? value) (tofu-data? value)
         (tofu-variable? value) (tofu-local? value))
    value)
   ((or (string? value) (symbol? value) (boolean? value) (number? value))
    value)
   ;; (package . "output") selects a non-default output.
   ((and (pair? value) (package? (car value)) (string? (cdr value)))
    (lower-package (car value) (cdr value) store remember))
   ((vector? value)
    (list->vector (map (lambda (element)
                          (lower-value-with element store remember session))
                        (vector->list value))))
   ((list? value)
    ;; Lists are objects; vectors are arrays.  An empty list is the empty
    ;; object.
    (map (lambda (entry)
            (unless (and (pair? entry)
                         (or (symbol? (car entry)) (string? (car entry))))
              (tofu-error "lists are objects: expected (key . value) entries in ~s; use vectors for arrays"
                          value))
            (cons (car entry)
                  (lower-value-with (cdr entry) store remember session)))
          value))
   ;; Named Guix records cross the boundary by name (plan 7.1): they have
   ;; no store form, and some (operating systems, images) are file-like?,
   ;; so they must not reach the store branches below.
   ((and session (named-record? value))
    (lower-named-value value session))
   ((file-like? value) (lower-file-like value store remember))
   ((package? value) (lower-package value "out" store remember))
   ;; Any other struct: anonymous unless provenance names it.
   ((and session (struct? value))
    (or (resolve-named-value value session)
        (tofu-error "cannot lower value: ~s; expected a string, number, boolean, symbol, association list (object) or vector (array), an OpenTofu expression, a file-like object, a package, or a named Guix value exported from a module the provider can load"
                    value)))
   (else
    (tofu-error "cannot lower value: ~s; expected a string, number, boolean, symbol, association list (object) or vector (array), an OpenTofu expression, a file-like object, or a package"
                value))))

(define* (lower-value value store #:key (session #f))
  "Return VALUE with Guix objects replaced by their store paths.

Derivations are computed but not built; use `lower-configuration' with
`#:realize? #t' to build the artifacts a configuration needs.  SESSION,
the evaluation session of the configuration's file, enables named-value
resolution for Guix records."
  (lower-value-with value store (lambda (derivation) #f) session))

(define* (lower-configuration configuration store
                                #:key (realize? #f) (session #f))
  "Return CONFIGURATION with every argument value lowered against STORE.

The configuration's records are rebuilt, so the result serializes exactly
as the original with the lowered values in place.  When REALIZE? is true,
the derivations the lowering computed are built before returning.  SESSION
is the evaluation session of the configuration's file; it enables
named-value resolution for Guix records."
  (let ((pending '()))
    (define (remember derivation)
      (set! pending (cons derivation pending)))
    (define (lower value)
      (lower-value-with value store remember session))
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
