;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

(define-module (tofuix expressions)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (tofuix records)
  #:export (tofu-ref
            tofu-ref?
            tofu-ref-path
            tofu-ref->string
            attribute
            ref
            guile))

;;;
;;; Values that must remain unevaluated in Scheme and are evaluated by
;;; OpenTofu during plan/apply.
;;;

(define-record-type <tofu-ref>
  (make-tofu-ref path)
  tofu-ref?
  (path tofu-ref-path))

(define (tofu-ref path)
  "Return a reference expression for PATH, a raw OpenTofu reference such as
\"module.vpc.vpc_id\".  Prefer `attribute' on a resource record; use this for
dynamic or computed references."
  (unless (string? path)
    (error (format #f "tofuix: ref path must be a string: ~s" path)))
  (make-tofu-ref path))

(define (tofu-ref->string reference)
  "Return REFERENCE as an OpenTofu interpolation string, \"${...}\"."
  (string-append "${" (tofu-ref-path reference) "}"))

(define ref tofu-ref)

(define (attribute object . steps)
  "Return an attribute reference to OBJECT, optionally walking STEPS.
OBJECT is a resource, data source, variable, local, or another reference.
Each step is a symbol or string (an attribute name) or an integer (an
index):

  (attribute deploy-key 'public_key_openssh)
  => ${tls_private_key.deploy.public_key_openssh}

  (attribute (attribute server 'network_interface) 'address)
  (attribute server 'addresses 0)  => ${...addresses}[0]"
  (make-tofu-ref
   (let loop ((path (reference-base object)) (steps steps))
     (match steps
       (() path)
       ((step rest ...)
        (loop (string-append path
                             (cond
                              ((integer? step)
                               (format #f "[~a]" step))
                              ((symbol? step)
                               (string-append "." (symbol->string step)))
                              ((string? step)
                               (string-append "." step))
                              (else
                               (error (format #f
                                              "tofuix: invalid attribute step: ~s"
                                              step)))))
              rest))))))

(define (reference-base object)
  (cond
   ((tofu-resource? object)
    (string-append (tofu-resource-type object) "."
                   (tofu-resource-name object)))
   ((tofu-data? object)
    (string-append "data." (tofu-data-type object) "."
                   (tofu-data-name object)))
   ((tofu-variable? object)
    (string-append "var." (tofu-variable-name object)))
   ((tofu-local? object)
    (string-append "local." (tofu-local-name object)))
   ((tofu-ref? object)
    (tofu-ref-path object))
   (else
    (error (format #f "tofuix: attribute: not a referencable object: ~s"
                   object)))))

(define (guile module binding)
  "Return the canonical Guile module reference for BINDING exported by
MODULE, e.g. (guile '(hosts rpi3) 'rpi3-os) => \"(@ (hosts rpi3) rpi3-os)\".
This is a plain string expression, not an OpenTofu expression; it names a
Guix value that a provider may evaluate in its own environment."
  (unless (list? module)
    (error (format #f "tofuix: guile: module name must be a list: ~s"
                   module)))
  (unless (symbol? binding)
    (error (format #f "tofuix: guile: binding must be a symbol: ~s"
                   binding)))
  (format #f "(@ ~s ~s)" module binding))

(set-record-type-printer! <tofu-ref>
  (lambda (reference port)
    (format port "#<tofu-ref ~a>" (tofu-ref-path reference))))
