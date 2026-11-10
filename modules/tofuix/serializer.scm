;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

(define-module (tofuix serializer)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (tofuix records)
  #:use-module (tofuix expressions)
  #:export (tofu-configuration->scm
            tofu-configuration->json))

;;;
;;; JSON-compatible representation.
;;;

(define (tofu-configuration->scm configuration)
  "Return CONFIGURATION as a JSON-shaped Scheme value: association lists
for objects (with sorted, string keys), lists for arrays, and scalars for
primitive values.  Empty configurations return the empty list."
  (let* ((providers (tofu-configuration-providers configuration))
         (variables (tofu-configuration-variables configuration))
         (datas     (tofu-configuration-datas configuration))
         (resources (tofu-configuration-resources configuration))
         (outputs   (tofu-configuration-outputs configuration))
         (locals    (tofu-configuration-locals configuration))
         (roots     (tofu-configuration-root-blocks configuration))
         (terraform (make-terraform-block configuration providers roots))
         (provider* (make-provider-block configuration providers))
         (sections
          (append
           (if (null? terraform) '()
               (list (cons "terraform" terraform)))
           (if (null? provider*) '()
               (list (cons "provider" provider*)))
           (if (null? variables) '()
               (list (cons "variable"
                           (make-named-block configuration variables
                                             tofu-variable-name
                                             tofu-variable-fields))))
           (if (null? locals) '()
               (list (cons "locals"
                           (make-named-block configuration locals
                                             tofu-local-name
                                             tofu-local-value))))
           (if (null? datas) '()
               (list (cons "data"
                           (make-typed-block configuration datas
                                             tofu-data-type
                                             tofu-data-name
                                             tofu-data-arguments))))
           (if (null? resources) '()
               (list (cons "resource"
                           (make-typed-block configuration resources
                                             tofu-resource-type
                                             tofu-resource-name
                                             tofu-resource-arguments))))
           (if (null? outputs) '()
               (list (cons "output"
                           (make-named-block configuration outputs
                                             tofu-output-name
                                             output-shape)))))))
    (sort-alist sections)))

(define (output-shape output)
  "Return OUTPUT as a JSON-shaped association list: its value and fields."
  (cons (cons "value" (tofu-output-value output))
        (tofu-output-fields output)))

(define (make-named-block configuration records name-field value-field)
  "Return an association list mapping each record's name to its converted
value."
  (sort-alist
   (map (lambda (record)
          (cons (name-field record)
                (value->scm configuration (value-field record))))
        records)))

(define (make-typed-block configuration records type-field name-field
                          value-field)
  "Return an association list mapping each type to an association list of
names to converted values, as used by `resource' and `data' blocks."
  (sort-alist
   (map (lambda (type)
          (cons type
                (sort-alist
                 (map (lambda (record)
                        (cons (name-field record)
                              (value->scm configuration
                                          (value-field record))))
                      (filter (lambda (record)
                                (string=? (type-field record) type))
                              records)))))
        (delete-duplicates (map type-field records)))))

(define (make-provider-block configuration providers)
  "Return the `provider' block: providers that carry configuration
arguments, keyed by name."
  (sort-alist
   (filter-map
    (lambda (provider)
      (let ((arguments (tofu-provider-arguments provider)))
        (and (pair? arguments)
             (cons (tofu-provider-name provider)
                   (value->scm configuration arguments)))))
    providers)))

(define (make-terraform-block configuration providers roots)
  "Return the `terraform' block: required provider versions, optional
root-level terraform fields, and the backend configuration."
  (let* ((required
          (map (lambda (provider)
                 (cons (tofu-provider-name provider)
                       (sort-alist
                        (append
                         (list (cons "source"
                                     (tofu-provider-source provider)))
                         (let ((version (tofu-provider-version provider)))
                           (if version
                               (list (cons "version" version))
                               '()))))))
               providers))
         (backend (assoc-ref roots "backend"))
         (entries
          (append
           (if (null? required) '()
               (list (cons "required_providers" (sort-alist required))))
           (or (assoc-ref roots "terraform") '())
           (if backend
               (list (cons "backend" backend))
               '()))))
    (if (null? entries) '() (sort-alist entries))))

(define (sort-alist alist)
  (sort alist (lambda (a b) (string<? (car a) (car b)))))

;;;
;;; Value conversion: Scheme values and expressions to JSON-shaped values.
;;;

(define (value->scm configuration value)
  "Convert VALUE to its JSON-shaped representation.  CONFIGURATION is used
to verify that records used as references belong to it."
  (cond
   ((string? value) value)
   ((symbol? value) (symbol->string value))
   ((boolean? value) value)
   ((number? value) value)
   ((tofu-ref? value) (tofu-ref->string value))
   ((tofu-resource? value)
    (let ((identity (string-append (tofu-resource-type value) "."
                                   (tofu-resource-name value))))
      (require-member 'resource identity
                      (tofu-configuration-resources configuration)
                      (lambda (resource)
                        (string=? (string-append
                                   (tofu-resource-type resource) "."
                                   (tofu-resource-name resource))
                                  identity)))
      (string-append "${" identity "}")))
   ((tofu-data? value)
    (let ((identity (string-append (tofu-data-type value) "."
                                   (tofu-data-name value))))
      (require-member 'data identity
                      (tofu-configuration-datas configuration)
                      (lambda (data)
                        (string=? (string-append
                                   (tofu-data-type data) "."
                                   (tofu-data-name data))
                                  identity)))
      (string-append "${data." identity "}")))
   ((tofu-variable? value)
    (require-member 'variable (tofu-variable-name value)
                    (tofu-configuration-variables configuration)
                    (lambda (variable)
                      (string=? (tofu-variable-name variable)
                                (tofu-variable-name value))))
    (string-append "${var." (tofu-variable-name value) "}"))
   ((tofu-local? value)
    (require-member 'local (tofu-local-name value)
                    (tofu-configuration-locals configuration)
                    (lambda (local)
                      (string=? (tofu-local-name local)
                                (tofu-local-name value))))
    (string-append "${local." (tofu-local-name value) "}"))
   ((null? value) '())
   ((json-object? value)
    (sort-alist
     (map (lambda (entry)
            (cons (tofu-key->string (car entry))
                  (value->scm configuration (cdr entry))))
          value)))
   ((list? value)
    (map (lambda (element) (value->scm configuration element)) value))
   (else
    (error (format #f "tofuix: cannot serialize value: ~s" value)))))

(define (json-object? value)
  "Return true when VALUE is an association list whose entries all have a
symbol or string key.  This distinguishes objects from arrays of objects
(whose elements are themselves lists)."
  (and (pair? value)
       (every (lambda (entry)
                (and (pair? entry)
                     (or (symbol? (car entry)) (string? (car entry)))))
              value)))

(define (require-member what identity members member?)
  (unless (any member? members)
    (error (format #f
                   "tofuix: ~a ~a is referenced as a value but is not part of the configuration"
                   what identity))))

;;;
;;; JSON emitter.
;;;

(define (tofu-configuration->json configuration)
  "Serialize CONFIGURATION to a deterministic, pretty-printed JSON string."
  (let ((scm (tofu-configuration->scm configuration)))
    (if (null? scm)
        "{}"
        (with-output-to-string
          (lambda ()
            (emit scm (current-output-port) 0))))))

(define (emit value port depth)
  (cond
   ((string? value) (emit-string value port))
   ((boolean? value) (display (if value "true" "false") port))
   ((integer? value) (display value port))
   ((and (real? value) (inexact? value))
    (display value port))
   ((number? value)
    (error (format #f "tofuix: cannot serialize number: ~s" value)))
   ((null? value) (display "[]" port))
   ((json-object? value)
    (emit-object value port depth))
   ((list? value) (emit-array value port depth))
   (else
    (error (format #f "tofuix: cannot serialize value: ~s" value)))))

(define (emit-object alist port depth)
  (display "{\n" port)
  (let loop ((entries alist))
    (match entries
      (((key . value))
       (pad port (1+ depth))
       (emit-string key port)
       (display ": " port)
       (emit value port (1+ depth))
       (display "\n" port))
      (((key . value) rest ...)
       (pad port (1+ depth))
       (emit-string key port)
       (display ": " port)
       (emit value port (1+ depth))
       (display ",\n" port)
       (loop rest))))
  (pad port depth)
  (display "}" port))

(define (emit-array values port depth)
  (display "[\n" port)
  (let loop ((values values))
    (match values
      ((value)
       (pad port (1+ depth))
       (emit value port (1+ depth))
       (display "\n" port))
      ((value rest ...)
       (pad port (1+ depth))
       (emit value port (1+ depth))
       (display ",\n" port)
       (loop rest))))
  (pad port depth)
  (display "]" port))

(define (pad port depth)
  (display (make-string (* 2 depth) #\space) port))

(define (emit-string string port)
  (display #\" port)
  (string-for-each
   (lambda (character)
     (case character
       ((#\newline) (display "\\n" port))
       ((#\return) (display "\\r" port))
       ((#\tab) (display "\\t" port))
       ((#\backspace) (display "\\b" port))
       ((#\page) (display "\\f" port))
       ((#\") (display "\\\"" port))
       ((#\\) (display "\\\\" port))
       (else
        (if (char<? character #\space)
            (format port "\\u~4,'0x" (char->integer character))
            (display character port)))))
   string)
  (display #\" port))
