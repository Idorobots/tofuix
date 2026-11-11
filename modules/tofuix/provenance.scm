;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; Provenance resolution for named Guix values.  Some providers evaluate
;;; their own Scheme in a pinned-channel, source-bundle environment; such
;;; values cross the tofuix boundary by name.  Imported bindings become
;;; canonical module references; local bindings are re-rendered from the
;;; source captured at evaluation time.

(define-module (tofuix provenance)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (tofuix evaluate)
  #:use-module (tofuix expressions)
  #:export (resolve-named-value))

(define (tofu-error format-string . arguments)
  (throw 'tofuix-error (apply format #f format-string arguments)))

;;;
;;; Finding bindings by value.
;;;

(define (binding-value variable)
  "Return the value of VARIABLE, or #f when it cannot be read.  Reading a
binding may trigger an autoload; that is acceptable, because the module is
part of the pinned channels the evaluation runs against."
  (and (variable-bound? variable)
       (false-if-exception (variable-ref variable))))

(define (interface-matches session value)
  "Return ((MODULE-NAME . BINDING) ...) for every public binding among the
modules the evaluation session imported directly that holds the object
VALUE.

Only direct imports are searched: a Guix value used in a tofuix
configuration must be imported into its scope, or be re-exported by a
direct import.  Indirect imports are not followed."
  (delete-duplicates
   (append-map
    (lambda (interface)
      (let ((name (module-name interface))
            (matches '()))
        (module-for-each
         (lambda (binding variable)
           (when (eq? (binding-value variable) value)
             (set! matches (cons (cons name binding) matches))))
         interface)
        matches))
    (module-uses (evaluation-session-module session)))))

(define (local-matches session value)
  "Return the local bindings of the evaluation module that hold VALUE."
  (let ((matches '()))
    (module-for-each
     (lambda (binding variable)
       (when (eq? (binding-value variable) value)
         (set! matches (cons binding matches))))
     (evaluation-session-module session))
    matches))

;;;
;;; Rendering local bindings: the captured source, with local references
;;; substituted, prefixed by every module the infrastructure file imported.
;;;

(define %ignored-imports
  ;; Core is always available, and tofuix's own modules are never Guix
  ;; value providers; making the provider load them would be surprising.
  '(guile tofuix))

(define (imported-modules session)
  "Return the module names the infrastructure file imported directly,
excluding core and tofuix's own modules."
  (delete-duplicates
   (filter (lambda (name)
             (and (pair? name)
                  (not (memq (car name) %ignored-imports))))
           (map module-name
                (module-uses (evaluation-session-module session))))
   equal?))

(define (captured-form name session)
  (or (assq-ref (evaluation-session-local-forms session) name)
      (tofu-error "cannot reconstruct the source of the local binding `~a': only plain top-level defines are captured; move the definition into a module the provider can load, or name it explicitly with (guile MODULE BINDING)"
                  name)))

(define (module-name->string name)
  (format #f "~s" name))

(define (render-local-form name session)
  "Return source text that re-evaluates the local binding NAME in the
provider's environment: its captured source, with local references
substituted, prefixed by every module the infrastructure file imported
(just in case the source needs them)."
  (let ((eval-module (evaluation-session-module session)))
    (define (walk form in-progress)
      (cond
       ((symbol? form)
        (cond
         ((memq form in-progress)
          (tofu-error "circular reference between local bindings: ~a"
                      form))
         ;; A local binding: substitute its captured source.
         ((module-locally-bound? eval-module form)
          (walk (captured-form form session) (cons form in-progress)))
         ;; Anything else stays as written: imported bindings resolve
         ;; through the preamble, record field names and other syntax are
         ;; left alone.
         (else form)))
       ;; Quoted data is data, not code.
       ((and (pair? form) (eq? (car form) 'quote))
        form)
       ((pair? form)
        (if (list? form)
            (map (lambda (sub) (walk sub in-progress)) form)
            (cons (walk (car form) in-progress)
                  (walk (cdr form) in-progress))))
       (else form)))
    (let* ((form     (captured-form name session))
           (walked   (walk form (list name)))
           (imports  (imported-modules session))
           (preamble (and (pair? imports)
                          `(use-modules
                            ,@(sort imports
                                    (lambda (a b)
                                      (string<? (module-name->string a)
                                                (module-name->string b)))))))
           (source   (if preamble
                         `(begin ,preamble ,walked)
                         walked)))
      (format #f "~s" source))))

;;;
;;; Resolution.
;;;

(define (resolve-named-value value session)
  "Return the source string naming VALUE, or #f when it is anonymous.

Imported bindings resolve to their canonical module reference
\"(@ (hosts rpi3) rpi3-os)\"; local bindings render the source captured at
evaluation time.  Imported bindings win over local ones because the
provider can load the module directly.

Only the infrastructure file's direct imports and its own local bindings
are considered: a value used in a configuration must be imported into its
scope, or be re-exported by a direct import."
  (let ((imports (interface-matches session value)))
    (cond
     ((pair? imports)
      (if (null? (cdr imports))
          (guile (caar imports) (cdar imports))
          (tofu-error "the value ~s is exported by several modules: ~a; reference one explicitly with (guile MODULE BINDING)"
                      value
                      (string-join
                       (map (lambda (match)
                              (format #f "(@ ~s ~s)"
                                      (car match) (cdr match)))
                            imports)
                       ", "))))
     (else
      (let ((locals (local-matches session value)))
        (cond
         ((pair? locals)
          (if (null? (cdr locals))
              (render-local-form (car locals) session)
              (tofu-error "the value ~s is bound to several local names: ~a; move the definition into a module the provider can load, or name it explicitly with (guile MODULE BINDING)"
                          value
                          (string-join (map symbol->string locals) ", "))))
         (else #f)))))))
