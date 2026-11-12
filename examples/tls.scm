;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; A minimal example: an Ed25519 key and an output exposing its public half.

(define-module (examples tls)
  #:use-module (tofuix)
  #:export (infrastructure))

(define deploy-key
  (resource tls_private_key deploy
    (algorithm "ED25519")))

(define public-key
  (output public-key
    (attribute deploy-key public_key_openssh)))

(define infrastructure
  (configuration
    (provider tls "hashicorp/tls" "~> 4.0")
    deploy-key
    public-key))
