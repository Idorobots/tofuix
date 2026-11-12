;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

(define-module (tofuix records)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (ice-9 optargs)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:export (tofu-configuration
            tofu-configuration?
            tofu-configuration-providers
            tofu-configuration-variables
            tofu-configuration-datas
            tofu-configuration-resources
            tofu-configuration-outputs
            tofu-configuration-locals
            tofu-configuration-root-blocks

            tofu-provider
            tofu-provider?
            tofu-provider-name
            tofu-provider-source
            tofu-provider-version
            tofu-provider-arguments

            tofu-resource
            tofu-resource?
            tofu-resource-type
            tofu-resource-name
            tofu-resource-arguments

            tofu-data
            tofu-data?
            tofu-data-type
            tofu-data-name
            tofu-data-arguments

            tofu-variable
            tofu-variable?
            tofu-variable-name
            tofu-variable-fields

            tofu-output
            tofu-output?
            tofu-output-name
            tofu-output-value
            tofu-output-fields

            tofu-local
            tofu-local?
            tofu-local-name
            tofu-local-value

            tofu-key->string
            tofu-merge-configuration-elements

            obj
            configuration resource data provider variable output local))

;;;
;;; Records: the programmatic layer.  Every record carries a `tofu-' prefix;
;;; the constructor macros at the end of this module are the ergonomic,
;;; unprefixed interface that expands to these records.
;;;

(define-record-type <tofu-configuration>
  (make-tofu-configuration providers variables datas resources
                           outputs locals root-blocks)
  tofu-configuration?
  (providers    tofu-configuration-providers)
  (variables    tofu-configuration-variables)
  (datas        tofu-configuration-datas)
  (resources    tofu-configuration-resources)
  (outputs      tofu-configuration-outputs)
  (locals       tofu-configuration-locals)
  (root-blocks  tofu-configuration-root-blocks))

(define* (tofu-configuration #:key
                             (providers '())
                             (variables '())
                             (datas '())
                             (resources '())
                             (outputs '())
                             (locals '())
                             (root-blocks '()))
  "Return a Tofu configuration made of the given records.
PROVIDERS, VARIABLES, DATAS, RESOURCES, OUTPUTS and LOCALS are lists of
records; ROOT-BLOCKS is an association list of block name (the symbol
`terraform' or `backend') to its association list of fields."
  (make-tofu-configuration providers variables datas resources
                           outputs locals root-blocks))

(define-record-type <tofu-provider>
  (make-tofu-provider name source version arguments)
  tofu-provider?
  (name       tofu-provider-name)
  (source     tofu-provider-source)
  (version    tofu-provider-version)
  (arguments  tofu-provider-arguments))

(define* (tofu-provider name source #:key (version #f) (arguments '()))
  "Return a provider declaration called NAME, obtained from SOURCE, an
optional VERSION constraint, and an association list of provider
ARGUMENTS."
  (unless (string? source)
    (error (format #f "tofuix: provider source must be a string: ~s" source)))
  (make-tofu-provider (tofu-key->string name)
                      source
                      (and version (tofu-key->string version))
                      (arguments->alist arguments 'provider)))

(define-record-type <tofu-resource>
  (make-tofu-resource type name arguments)
  tofu-resource?
  (type       tofu-resource-type)
  (name       tofu-resource-name)
  (arguments  tofu-resource-arguments))

(define* (tofu-resource type name #:key (arguments '()))
  "Return a managed resource of TYPE called NAME with the given ARGUMENTS."
  (make-tofu-resource (tofu-key->string type)
                      (tofu-key->string name)
                      (arguments->alist arguments 'resource)))

(define-record-type <tofu-data>
  (make-tofu-data type name arguments)
  tofu-data?
  (type       tofu-data-type)
  (name       tofu-data-name)
  (arguments  tofu-data-arguments))

(define* (tofu-data type name #:key (arguments '()))
  "Return a data source of TYPE called NAME with the given ARGUMENTS."
  (make-tofu-data (tofu-key->string type)
                  (tofu-key->string name)
                  (arguments->alist arguments 'data)))

(define-record-type <tofu-variable>
  (make-tofu-variable name fields)
  tofu-variable?
  (name    tofu-variable-name)
  (fields  tofu-variable-fields))

(define (tofu-variable name fields)
  "Return an input variable called NAME whose FIELDS are an association
list such as `(type default description validation)'."
  (make-tofu-variable (tofu-key->string name)
                      (arguments->alist fields 'variable)))

(define-record-type <tofu-output>
  (make-tofu-output name value fields)
  tofu-output?
  (name    tofu-output-name)
  (value   tofu-output-value)
  (fields  tofu-output-fields))

(define (tofu-output name value fields)
  "Return a root-module output called NAME with the given VALUE and FIELDS,
an association list such as `(description sensitive depends_on)'."
  (make-tofu-output (tofu-key->string name)
                    value
                    (arguments->alist fields 'output)))

(define-record-type <tofu-local>
  (make-tofu-local name value)
  tofu-local?
  (name   tofu-local-name)
  (value  tofu-local-value))

(define (tofu-local name value)
  "Return a local value called NAME with the given VALUE."
  (make-tofu-local (tofu-key->string name) value))

;;;
;;; Helpers.
;;;

(define (tofu-key->string key)
  "Return KEY (a symbol or a string) as a string."
  (cond ((string? key) key)
        ((symbol? key) (symbol->string key))
        ((and (pair? key) (eq? (car key) 'quote))
         (error (format #f
                        "tofuix: invalid name or key: ~s; identifiers in constructor macros are written raw, without a quote"
                        key)))
        (else (error (format #f "tofuix: invalid name or key: ~s" key)))))

(define (arguments->alist arguments who)
  "Validate ARGUMENTS as an association list and normalize its keys to
strings.  WHO names the record type in error messages.  Duplicate keys are
an error."
  (unless (list? arguments)
    (error (format #f "tofuix: ~a arguments must be an association list: ~s"
                   who arguments)))
  (let ((alist (map (lambda (entry)
                      (unless (and (pair? entry)
                                   (or (symbol? (car entry))
                                       (string? (car entry))))
                        (error (format #f "tofuix: invalid ~a argument: ~s"
                                       who entry)))
                      (cons (tofu-key->string (car entry)) (cdr entry)))
                    arguments)))
    (let loop ((rest alist) (seen '()))
      (match rest
        (() alist)
        (((key . value) more ...)
         (when (assoc key seen)
           (error (format #f "tofuix: duplicate ~a argument: ~a" who key)))
         (loop more (cons (cons key value) seen)))))))

(define (%obj . key-values)
  "Build an association list from alternating keys and values, for nested
blocks: (obj content (obj url \"/gnu/store/...\"))."
  (let loop ((rest key-values) (result '()))
    (match rest
      (() (reverse result))
      ((key value rest* ...)
       (let ((key (tofu-key->string key)))
         (when (assoc key result)
           (error (format #f "tofuix: duplicate obj key: ~a" key)))
         (loop rest* (cons (cons key value) result))))
      (_ (error "tofuix: obj expects an even number of arguments")))))

(define (qualified-name type name)
  (string-append type "." name))

(define (check-duplicate what identity existing identity-of)
  (when (any (lambda (element) (string=? (identity-of element) identity))
             existing)
    (error (format #f "tofuix: duplicate ~a: ~a" what identity))))

(define (merge-root-blocks blocks)
  (let loop ((blocks blocks) (result '()))
    (match blocks
      (() (reverse result))
      (((key . value) rest ...)
       (let ((name (tofu-key->string key)))
         (when (assoc name result)
           (error (format #f "tofuix: duplicate root block: ~a" name)))
         (loop rest
               (cons (cons name (arguments->alist value 'root-block))
                     result))))
      (_ (error (format #f "tofuix: invalid root block list: ~s" blocks))))))

(define (tofu-merge-configuration-elements elements root-blocks)
  "Merge ELEMENTS---configuration objects or lists thereof---and ROOT-BLOCKS
into a single configuration, rejecting duplicate identities."
  (let loop ((elements elements)
             (providers '()) (variables '()) (datas '())
             (resources '()) (outputs '()) (locals '()))
    (match elements
      (()
       (make-tofu-configuration (reverse providers) (reverse variables)
                                (reverse datas) (reverse resources)
                                (reverse outputs) (reverse locals)
                                (merge-root-blocks root-blocks)))
      ((element . rest)
       (cond
        ((tofu-provider? element)
         (check-duplicate 'provider (tofu-provider-name element)
                          providers tofu-provider-name)
         (loop rest (cons element providers)
               variables datas resources outputs locals))
        ((tofu-variable? element)
         (check-duplicate 'variable (tofu-variable-name element)
                          variables tofu-variable-name)
         (loop rest providers (cons element variables)
               datas resources outputs locals))
        ((tofu-data? element)
         (check-duplicate 'data
                          (qualified-name (tofu-data-type element)
                                          (tofu-data-name element))
                          datas
                          (lambda (data)
                            (qualified-name (tofu-data-type data)
                                            (tofu-data-name data))))
         (loop rest providers variables (cons element datas)
               resources outputs locals))
        ((tofu-resource? element)
         (check-duplicate 'resource
                          (qualified-name (tofu-resource-type element)
                                          (tofu-resource-name element))
                          resources
                          (lambda (resource)
                            (qualified-name (tofu-resource-type resource)
                                            (tofu-resource-name resource))))
         (loop rest providers variables datas (cons element resources)
               outputs locals))
        ((tofu-output? element)
         (check-duplicate 'output (tofu-output-name element)
                          outputs tofu-output-name)
         (loop rest providers variables datas resources
               (cons element outputs) locals))
        ((tofu-local? element)
         (check-duplicate 'local (tofu-local-name element)
                          locals tofu-local-name)
         (loop rest providers variables datas resources outputs
               (cons element locals)))
        ((list? element)
         (loop (append element rest) providers variables datas
               resources outputs locals))
        (else
         (error (format #f "tofuix: unrecognized configuration element: ~s"
                        element))))))))

;;;
;;; Constructor macros: the ergonomic layer.
;;;
;;; Identifier positions---resource and data types and names, variable,
;;; output, local and provider names, and obj keys---are raw identifiers,
;;; read verbatim at macro expansion and never evaluated:
;;;
;;;   (resource tls_private_key deploy (algorithm "ED25519"))
;;;   (obj content (obj url "/gnu/store/..."))
;;;

(define-syntax %tofu-arg-value
  (syntax-rules ()
    ((_ value) value)
    ((_ value rest ...) (vector value rest ...))))

(define-syntax resource
  (syntax-rules ()
    ((_ type name (key value ...) ...)
     (tofu-resource 'type 'name
       #:arguments (list (cons 'key (%tofu-arg-value value ...)) ...)))))

(define-syntax data
  (syntax-rules ()
    ((_ type name (key value ...) ...)
     (tofu-data 'type 'name
       #:arguments (list (cons 'key (%tofu-arg-value value ...)) ...)))))

(define-syntax variable
  (syntax-rules ()
    ((_ name (key value ...) ...)
     (tofu-variable 'name
       (list (cons 'key (%tofu-arg-value value ...)) ...)))))

(define-syntax output
  (syntax-rules ()
    ((_ name value (key v ...) ...)
     (tofu-output 'name value
       (list (cons 'key (%tofu-arg-value v ...)) ...)))))

(define-syntax local
  (syntax-rules ()
    ((_ name value)
     (tofu-local 'name value))))

(define-syntax provider
  (lambda (form)
    (define (tuples->alist tuples)
      (syntax-case tuples ()
        (() #''())
        (((key value ...) ...)
         #'(list (cons 'key (%tofu-arg-value value ...)) ...))))
    (syntax-case form ()
      ((_ name source)
       #'(tofu-provider 'name source))
      ((_ name source extra rest ...)
       (string? (syntax->datum #'extra))
       #`(tofu-provider 'name source
           #:version extra
           #:arguments #,(tuples->alist #'(rest ...))))
      ((_ name source rest ...)
       #`(tofu-provider 'name source
           #:arguments #,(tuples->alist #'(rest ...)))))))

(define-syntax obj
  (lambda (form)
    (define (expand stx)
      (syntax-case stx ()
        (() #'())
        ((key value rest ...)
         #`('key value . #,(expand #'(rest ...))))
        ((key)
         #'((error "tofuix: obj expects an even number of arguments")))))
    (syntax-case form ()
      ((_ rest ...)
       #`(%obj . #,(expand #'(rest ...)))))))

(define-syntax configuration
  (syntax-rules ()
    ((_ element ...)
     (%tofu-configuration-collect () () element ...))))

(define-syntax %tofu-configuration-collect
  (syntax-rules (terraform backend)
    ((_ elements roots)
     (tofu-merge-configuration-elements (reverse (list . elements))
                                        (reverse (list . roots))))
    ((_ elements roots (backend (key value ...) ...) rest ...)
     (%tofu-configuration-collect
      elements
      ((cons 'backend (list (cons 'key (%tofu-arg-value value ...)) ...))
       . roots)
      rest ...))
    ((_ elements roots (terraform (key value ...) ...) rest ...)
     (%tofu-configuration-collect
      elements
      ((cons 'terraform (list (cons 'key (%tofu-arg-value value ...)) ...))
       . roots)
      rest ...))
    ((_ elements roots element rest ...)
     (%tofu-configuration-collect (element . elements) roots rest ...))))

;;;
;;; Record printers.
;;;

(set-record-type-printer! <tofu-provider>
  (lambda (provider port)
    (format port "#<tofu-provider ~a>" (tofu-provider-name provider))))

(set-record-type-printer! <tofu-resource>
  (lambda (resource port)
    (format port "#<tofu-resource ~a>"
            (qualified-name (tofu-resource-type resource)
                            (tofu-resource-name resource)))))

(set-record-type-printer! <tofu-data>
  (lambda (data port)
    (format port "#<tofu-data ~a>"
            (qualified-name (tofu-data-type data)
                            (tofu-data-name data)))))

(set-record-type-printer! <tofu-variable>
  (lambda (variable port)
    (format port "#<tofu-variable ~a>" (tofu-variable-name variable))))

(set-record-type-printer! <tofu-output>
  (lambda (output port)
    (format port "#<tofu-output ~a>" (tofu-output-name output))))

(set-record-type-printer! <tofu-local>
  (lambda (local port)
    (format port "#<tofu-local ~a>" (tofu-local-name local))))

(set-record-type-printer! <tofu-configuration>
  (lambda (configuration port)
    (format port "#<tofu-configuration ~a resource(s)>"
            (length (tofu-configuration-resources configuration)))))
