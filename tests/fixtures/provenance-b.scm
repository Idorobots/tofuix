;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; Exports the same object as (tests fixtures provenance-a), so tests can
;;; exercise the multiple-export error path.

(define-module (tests fixtures provenance-b)
  #:use-module (tests fixtures provenance-a)
  #:export (same-object))

(define same-object (@ (tests fixtures provenance-a) shared-object))
