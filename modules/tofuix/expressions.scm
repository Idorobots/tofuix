;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

(define-module (tofuix expressions)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (srfi srfi-13)
  #:use-module (tofuix records)
  #:export (tofu-ref
            tofu-ref?
            tofu-ref-path
            tofu-ref->string
            attribute
            tofu-attribute
            ref
            guile
            tf
            untf
            untf-splicing))

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

(define (tofu-attribute object . steps)
  "Return an attribute reference to OBJECT, optionally walking STEPS.
OBJECT is a resource, data source, variable, local, or another reference.
Each step is a symbol or string (an attribute name) or an integer (an
index):

  (attribute deploy-key public_key_openssh)
  => ${tls_private_key.deploy.public_key_openssh}

  (attribute (attribute server network_interface) address)
  (attribute server addresses 0)  => ${...addresses}[0]"
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

(define-syntax attribute
  (lambda (form)
    (define (literalize step)
      (if (symbol? (syntax->datum step))
          #`(quote #,step)
          step))
    (syntax-case form ()
      ((_ object step ...)
       #`(tofu-attribute object
           #,@(map literalize (syntax-list #'(step ...))))))))

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

;;;
;;; Tofu expressions: a gexp-like language for OpenTofu expressions.
;;;
;;; (tf ...) compiles tofu-side code into an HCL expression; (untf value)
;;; splices a Scheme value, lowered to HCL; (untf-splicing values) splices
;;; a Scheme list into an argument list.  Lists are applications; string
;;; atoms are HCL templates; arrays are Scheme vectors inside untf.
;;;
;;; Reader shortcuts: #%(...) for tf, #^x for untf, #^@x for
;;; untf-splicing.  Guix gexps own #~/#$/#+ process-wide, so tofuix uses
;;; different characters and both can coexist.
;;;

(define-record-type <tf-untf>
  (make-tf-untf value)
  tf-untf?
  (value tf-untf-value))

(define-record-type <tf-untf-splicing>
  (make-tf-untf-splicing value)
  tf-untf-splicing?
  (value tf-untf-splicing-value))

(define* (escape-template-text string #:key (escape-dollar? #f))
  "Escape STRING for a quoted HCL template: backslash, double quote,
newline, and tab.  With ESCAPE-DOLLAR? also escape template interpolation
openers (${ and $${) so the text stays literal."
  (with-output-to-string
    (lambda ()
      (let loop ((index 0))
        (when (< index (string-length string))
          (let ((char (string-ref string index)))
            (cond
             ((char=? char #\\) (display "\\\\") (loop (+ index 1)))
             ((char=? char #\") (display "\\\"") (loop (+ index 1)))
             ((char=? char #\newline) (display "\\n") (loop (+ index 1)))
             ((char=? char #\tab) (display "\\t") (loop (+ index 1)))
             ((and escape-dollar?
                   (char=? char #\$)
                   (< (+ index 2) (string-length string))
                   (char=? (string-ref string (+ index 1)) #\$)
                   (char=? (string-ref string (+ index 2)) #\{))
              (display "$$$${") (loop (+ index 3)))
             ((and escape-dollar?
                   (char=? char #\$)
                   (< (+ index 1) (string-length string))
                   (char=? (string-ref string (+ index 1)) #\{))
              (display "$${") (loop (+ index 2)))
             (else (display char) (loop (+ index 1))))))))))

(define (hcl-template-text string)
  (escape-template-text string))

(define (hcl-literal-text string)
  (escape-template-text string #:escape-dollar? #t))

(define (hcl-string string)
  "Return STRING as a quoted HCL template string; ${...} interpolates."
  (string-append "\"" (hcl-template-text string) "\""))

(define (hcl-literal string)
  "Return STRING as a quoted HCL string where ${...} stays literal."
  (string-append "\"" (hcl-literal-text string) "\""))

(define (hcl-array elements)
  (if (null? elements)
      "[]"
      (string-append "[ " (string-join elements ", ") " ]")))

(define (hcl-object-map entries)
  (if (null? entries)
      "{}"
      (string-append
       "{ "
       (string-join
        (map (lambda (entry)
               (format #f "~s = ~a"
                       (tofu-key->string (car entry))
                       (host->hcl (cdr entry))))
             (sort entries
                   (lambda (a b)
                     (string<? (tofu-key->string (car a))
                               (tofu-key->string (car b))))))
        ", ")
       " }")))

(define (host->hcl value)
  "Lower a Scheme value (the argument of untf) to HCL expression text."
  (cond
   ((tofu-ref? value) (tofu-ref-path value))
   ((or (tofu-resource? value) (tofu-data? value)
        (tofu-variable? value) (tofu-local? value))
    (reference-base value))
   ((string? value) (hcl-literal value))
   ((boolean? value) (if value "true" "false"))
   ((number? value) (number->string value))
   ((symbol? value) (symbol->string value))
   ((vector? value) (hcl-array (map host->hcl (vector->list value))))
   ((list? value)
    (for-each (lambda (entry)
                (unless (and (pair? entry)
                             (or (symbol? (car entry)) (string? (car entry))))
                  (error (format #f
                                 "tofuix: tf: lists are objects: expected (key . value) entries in ~s; use vectors for arrays"
                                 value))))
              value)
    (hcl-object-map value))
   (else
    (error (format #f "tofuix: tf: cannot lower value: ~s" value)))))

(define (tf-argument-parts node)
  "Return the argument fragments for NODE: one, or several when spliced."
  (if (tf-untf-splicing? node)
      (let ((values (tf-untf-splicing-value node)))
        (unless (list? values)
          (error (format #f "tofuix: tf: untf-splicing expects a list: ~s"
                         values)))
        (map host->hcl values))
      (list (tf-hcl node))))

(define (tf-application node)
  (unless (and (pair? node) (symbol? (car node)))
    (error (format #f
                   "tofuix: tf: an application needs a function name, got: ~s"
                   node)))
  (format #f "~a(~a)"
          (symbol->string (car node))
          (string-join (append-map tf-argument-parts (cdr node)) ", ")))

(define (tf-hcl node)
  "Compile a tf tree NODE to HCL expression text."
  (cond
   ((tf-untf? node) (host->hcl (tf-untf-value node)))
   ((tf-untf-splicing? node)
    (error "tofuix: tf: untf-splicing is only valid in an argument list"))
   ((symbol? node) (symbol->string node))
   ((string? node) (hcl-string node))
   ((boolean? node) (if node "true" "false"))
   ((number? node) (number->string node))
   ((vector? node) (hcl-array (map host->hcl (vector->list node))))
   ((list? node) (tf-application node))
   (else (error (format #f "tofuix: tf: cannot compile: ~s" node)))))

(define (syntax-list stx)
  "Return the elements of the proper list syntax STX as syntax objects."
  (syntax-case stx ()
    (() '())
    ((first rest ...) (cons #'first (syntax-list #'(rest ...))))))

(define-syntax untf
  (syntax-rules ()
    ((_ value) (error "tofuix: untf is only valid inside tf"))))

(define-syntax untf-splicing
  (syntax-rules ()
    ((_ value) (error "tofuix: untf-splicing is only valid inside tf"))))

(define (tf-rewrite expression)
  "Rewrite a tf body into a runtime expression building the tf tree."
  (syntax-case expression (untf untf-splicing tf)
    ((untf value) #`(make-tf-untf #,#'value))
    ((untf-splicing value) #`(make-tf-untf-splicing #,#'value))
    ((tf inner) #`(make-tf-untf (tf #,#'inner)))
    ((head argument ...)
     #`(list 'head #,@(map tf-rewrite (syntax-list #'(argument ...)))))
    (_ #`'#,expression)))

(define-syntax tf
  (lambda (form)
    (syntax-case form ()
      ((_ expression)
       #`(tofu-ref (tf-hcl #,(tf-rewrite #'expression)))))))

;;; Reader shortcuts.  #~/#$/#+ belong to (guix gexp), so use #%/#^/#^@.

(read-hash-extend #\%
  (lambda (character port)
    (list 'tf (read port))))

(read-hash-extend #\^
  (lambda (character port)
    (if (eqv? (peek-char port) #\@)
        (begin
          (read-char port)
          (list 'untf-splicing (read port)))
        (list 'untf (read port)))))
