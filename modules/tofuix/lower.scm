;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; Guix-value lowering: turn native Guix objects used as argument values
;;; into plain values OpenTofu understands (store paths).  This module is
;;; deliberately free of Guix imports: the protocol is a
;;; <lowering-context> record carrying type predicates and resolvers, so the
;;; traversal is testable with mocked store objects.  The extension module
;;; provides the Guix-backed context.

(define-module (tofuix lower)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (tofuix expressions)
  #:use-module (tofuix records)
  #:export (make-lowering-context
            lowering-context?
            lowering-context-file-like?
            lowering-context-package?
            lowering-context-lower-file-like
            lowering-context-lower-package
            lowering-context-realize!
            lower-value
            lower-configuration))

(define-record-type <lowering-context>
  (make-lowering-context file-like? package? lower-file-like lower-package realize)
  lowering-context?
  (file-like?     lowering-context-file-like?)
  (package?       lowering-context-package?)
  (lower-file-like lowering-context-lower-file-like)
  (lower-package  lowering-context-lower-package)
  (realize        lowering-context-realize))

(define (lowering-context-realize! context)
  "Build the artifacts the lowering through CONTEXT planned.
Realizing contexts build their derived artifacts; planning contexts do
nothing."
  ((lowering-context-realize context)))

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

(define (lower-value context value)
  "Return VALUE with Guix objects replaced by their lowered representations.

Scalars pass through unchanged; OpenTofu expressions and records used as
references are left alone; lists, vectors, and association lists are
lowered recursively; file-like objects and packages are resolved through
CONTEXT."
  (cond
   ;; Reference expressions and records are values, not containers: a
   ;; resource used as an argument is a whole-object reference.
   ((tofu-ref? value) value)
   ((or (tofu-resource? value) (tofu-data? value)
        (tofu-variable? value) (tofu-local? value))
    value)
   ((or (string? value) (symbol? value) (boolean? value) (number? value))
    value)
   ((alist-like? value)
    (map (lambda (entry)
           (cons (car entry) (lower-value context (cdr entry))))
         value))
   ((list? value)
    (map (lambda (element) (lower-value context element)) value))
   ((vector? value)
    (list->vector (map (lambda (element) (lower-value context element))
                       (vector->list value))))
   (((lowering-context-file-like? context) value)
    ((lowering-context-lower-file-like context) value))
   (((lowering-context-package? context) value)
    ((lowering-context-lower-package context) value))
   (else
    (tofu-error "cannot lower value: ~s; expected a string, number, boolean, symbol, list or association list, an OpenTofu expression, a file-like object, or a package"
                value))))

(define (lower-fields context fields)
  (map (lambda (entry)
         (cons (car entry) (lower-value context (cdr entry))))
       fields))

(define (lower-configuration configuration context)
  "Return CONFIGURATION with every argument value lowered through CONTEXT.

The configuration's records are rebuilt, so the result serializes exactly
as the original with the lowered values in place.  Call
`lowering-context-realize!' on CONTEXT afterwards to build any artifacts
that were only planned."
  (tofu-configuration
   #:providers
   (map (lambda (provider)
          (tofu-provider (tofu-provider-name provider)
                         (tofu-provider-source provider)
                         #:version (tofu-provider-version provider)
                         #:arguments (lower-fields context
                                                   (tofu-provider-arguments provider))))
        (tofu-configuration-providers configuration))
   #:variables
   (map (lambda (variable)
          (tofu-variable (tofu-variable-name variable)
                         (lower-fields context
                                       (tofu-variable-fields variable))))
        (tofu-configuration-variables configuration))
   #:datas
   (map (lambda (data)
          (tofu-data (tofu-data-type data)
                     (tofu-data-name data)
                     #:arguments (lower-fields context
                                               (tofu-data-arguments data))))
        (tofu-configuration-datas configuration))
   #:resources
   (map (lambda (resource)
          (tofu-resource (tofu-resource-type resource)
                         (tofu-resource-name resource)
                         #:arguments (lower-fields context
                                                   (tofu-resource-arguments resource))))
        (tofu-configuration-resources configuration))
   #:outputs
   (map (lambda (output)
          (tofu-output (tofu-output-name output)
                       (lower-value context (tofu-output-value output))
                       (lower-fields context (tofu-output-fields output))))
        (tofu-configuration-outputs configuration))
   #:locals
   (map (lambda (local)
          (tofu-local (tofu-local-name local)
                      (lower-value context (tofu-local-value local))))
        (tofu-configuration-locals configuration))
   #:root-blocks
   (map (lambda (block)
          (cons (car block) (lower-fields context (cdr block))))
        (tofu-configuration-root-blocks configuration))))
