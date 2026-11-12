;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; A lowered-artifact example: a Guix file-like object becomes an argument
;;; value.  `generate`/`plan` reference the prospective store path without
;;; building anything; `build`/`apply` realize it first.

(define-module (examples artifact)
  #:use-module (tofuix)
  #:use-module (guix gexp)
  #:export (infrastructure))

(define greeting
  (plain-file "greeting.txt" "hello from tofuix\n"))

(define infrastructure
  (configuration
    (resource terraform_data artifact
      (input greeting))))
