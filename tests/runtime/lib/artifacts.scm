;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; Builder helpers for the store-dependent lowering checks.  This module
;;; does not import (tofuix), so gexp builders can use #$output.

(define-module (tests runtime lib artifacts)
  #:use-module (guix gexp)
  #:export (greeting
            artifact))

(define greeting
  (plain-file "tofuix-greeting.txt" "hello from tofuix\n"))

(define (artifact name)
  "Return a computed file called NAME whose contents are built on demand."
  (computed-file name
    #~(begin
        (mkdir #$output)
        (call-with-output-file (string-append #$output "/data")
          (lambda (port)
            (display "artifact data" port))))))
