;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

(define-module (tests examples-test)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-13)
  #:use-module (srfi srfi-64)
  #:use-module (tofuix serializer)
  #:use-module (examples tls))

(define runner (test-runner-create))
(test-runner-current runner)

(define golden
  (string-trim-right
   (call-with-input-file "tests/tls.golden.json" get-string-all)
   #\newline))

(test-begin "examples")

(test-equal "the tls example serializes byte-exactly to the golden JSON"
  golden
  (tofu-configuration->json infrastructure))

(test-end "examples")

(exit (if (zero? (+ (test-runner-fail-count runner)
                    (test-runner-xpass-count runner)))
          0 1))
