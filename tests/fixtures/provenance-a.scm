;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

(define-module (tests fixtures provenance-a)
  #:use-module (srfi srfi-9)
  #:export (shared-object
            demo-record))

(define shared-object (list 'shared 'a))

(define-record-type <demo-record>
  (make-demo-record)
  demo-record?)

(define demo-record (make-demo-record))
