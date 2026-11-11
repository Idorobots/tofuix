;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; A minimal operating system record, exported so that runtime lowering
;;; checks can resolve it by name.

(define-module (tests runtime lib os-fixture)
  #:use-module (gnu system)
  #:export (demo-os))

(define demo-os
  (operating-system
    (host-name "demo-os")
    (bootloader #f)
    (file-systems '())))
