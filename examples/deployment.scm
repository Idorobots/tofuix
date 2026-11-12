;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; A small deployment: an Ed25519 key, a Guix-built artifact, and a
;;; package — Guix values are ordinary argument values, lowered to store
;;; paths (prospective for `generate'/`plan', realized for `build'/`apply').

(define-module (examples deployment)
  #:use-module (gnu packages)
  #:use-module (guix gexp)
  #:use-module (tofuix)
  #:export (infrastructure))

(define deploy-key
  (resource tls_private_key deploy
    (algorithm "ED25519")))

(define region
  (variable region
    (type "string")
    (default "eu-central-1")))

(define greeting
  (plain-file "greeting.txt" "hello from tofuix\n"))

(define infrastructure
  (configuration
    (provider tls "hashicorp/tls" "~> 4.0")
    region
    deploy-key
    (resource terraform_data deployment
      (input (obj greeting greeting
                  region (attribute region)))
      (triggers_replace greeting))
    (resource terraform_data tools
      (input (specification->package "hello")))
    (output public-key
      (attribute deploy-key public_key_openssh))))
