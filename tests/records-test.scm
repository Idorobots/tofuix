;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

(define-module (tests records-test)
  #:use-module (srfi srfi-64)
  #:use-module (tofuix records))

(define runner (test-runner-create))
(test-runner-current runner)

(test-begin "records")

(test-equal "resource macro matches the programmatic API"
  '("tls_private_key" "deploy" (("algorithm" . "ED25519")))
  (let ((r (resource 'tls_private_key 'deploy (algorithm "ED25519"))))
    (list (tofu-resource-type r)
          (tofu-resource-name r)
          (tofu-resource-arguments r))))

(test-equal "programmatic resource constructor"
  '("tls_private_key" "deploy" (("algorithm" . "ED25519")))
  (let ((r (tofu-resource "tls_private_key" "deploy"
                          #:arguments '(("algorithm" . "ED25519")))))
    (list (tofu-resource-type r)
          (tofu-resource-name r)
          (tofu-resource-arguments r))))

(test-equal "data macro matches the programmatic API"
  '("aws_ami" "server" (("most_recent" . #t)))
  (let ((d (data 'aws_ami 'server (most_recent #t))))
    (list (tofu-data-type d)
          (tofu-data-name d)
          (tofu-data-arguments d))))

(test-equal "provider without version or arguments"
  '("tls" "hashicorp/tls" #f ())
  (let ((p (provider 'tls "hashicorp/tls")))
    (list (tofu-provider-name p)
          (tofu-provider-source p)
          (tofu-provider-version p)
          (tofu-provider-arguments p))))

(test-equal "provider with version"
  '("tls" "hashicorp/tls" "~> 4.0" ())
  (let ((p (provider 'tls "hashicorp/tls" "~> 4.0")))
    (list (tofu-provider-name p)
          (tofu-provider-source p)
          (tofu-provider-version p)
          (tofu-provider-arguments p))))

(test-equal "provider with arguments"
  '("aws" "hashicorp/aws" #f (("region" . "eu-central-1")))
  (let ((p (provider 'aws "hashicorp/aws" (region "eu-central-1"))))
    (list (tofu-provider-name p)
          (tofu-provider-source p)
          (tofu-provider-version p)
          (tofu-provider-arguments p))))

(test-equal "provider with version and arguments"
  '("aws" "hashicorp/aws" "~> 6.0" (("region" . "eu-central-1")))
  (let ((p (provider 'aws "hashicorp/aws" "~> 6.0"
                     (region "eu-central-1"))))
    (list (tofu-provider-name p)
          (tofu-provider-source p)
          (tofu-provider-version p)
          (tofu-provider-arguments p))))

(test-equal "variable macro matches the programmatic API"
  '("region" (("type" . "string") ("default" . "eu-central-1")))
  (let ((v (variable 'region
                     (type "string")
                     (default "eu-central-1"))))
    (list (tofu-variable-name v)
          (tofu-variable-fields v))))

(test-equal "output macro matches the programmatic API"
  '("public-key" "value" (("description" . "SSH public key")))
  (let ((o (output 'public-key "value"
                   (description "SSH public key"))))
    (list (tofu-output-name o)
          (tofu-output-value o)
          (tofu-output-fields o))))

(test-equal "output value is positional"
  '("public-key" "value" ())
  (let ((o (output 'public-key "value")))
    (list (tofu-output-name o)
          (tofu-output-value o)
          (tofu-output-fields o))))

(test-equal "local macro matches the programmatic API"
  '("name" "value")
  (let ((l (local 'name "value")))
    (list (tofu-local-name l)
          (tofu-local-value l))))

(test-equal "obj builds a nested association list"
  '(("a" . 1) ("b" . (("c" . 2))))
  (obj 'a 1 'b (obj 'c 2)))

(test-error "obj rejects an odd number of arguments" #t
  (obj 'a))

(test-error "obj rejects invalid keys" #t
  (obj 1 2))

(test-equal "multi-value tuple becomes a vector"
  '(("tags" . #("a" "b")))
  (tofu-resource-arguments (resource 'x 'y (tags "a" "b"))))

(test-equal "single vector value is evaluated"
  '(("tags" . #("a" "b")))
  (tofu-resource-arguments (resource 'x 'y (tags (vector "a" "b")))))

(test-equal "configuration classifies and orders elements"
  '(("tls" "hashicorp/tls")
    ("tls_private_key" "deploy")
    ("public-key"))
  (let ((config (configuration
                 (provider 'tls "hashicorp/tls")
                 (resource 'tls_private_key 'deploy)
                 (output 'public-key "value"))))
    (append
     (map (lambda (p)
            (list (tofu-provider-name p) (tofu-provider-source p)))
          (tofu-configuration-providers config))
     (map (lambda (r)
            (list (tofu-resource-type r) (tofu-resource-name r)))
          (tofu-configuration-resources config))
     (map (lambda (o) (list (tofu-output-name o)))
          (tofu-configuration-outputs config)))))

(test-equal "configuration splices lists of elements"
  '("a" "b" "c")
  (let ((config (configuration
                 (list (resource 'a 'one)
                       (resource 'b 'two))
                 (resource 'c 'three))))
    (map (lambda (r) (tofu-resource-type r))
         (tofu-configuration-resources config))))

(test-error "duplicate provider" #t
  (configuration (provider 'tls "hashicorp/tls")
                 (provider 'tls "hashicorp/tls")))

(test-error "duplicate resource" #t
  (configuration (resource 'tls_private_key 'deploy (a "1"))
                 (resource 'tls_private_key 'deploy (a "2"))))

(test-error "duplicate data source" #t
  (configuration (data 'aws_ami 'server)
                 (data 'aws_ami 'server)))

(test-error "duplicate variable" #t
  (configuration (variable 'region)
                 (variable 'region)))

(test-error "duplicate output" #t
  (configuration (output 'x "1")
                 (output 'x "2")))

(test-error "duplicate local" #t
  (configuration (local 'x "1")
                 (local 'x "2")))

(test-equal "terraform and backend root blocks"
  '(("terraform" ("required_version" . ">= 1.6"))
    ("backend" ("local" ("path" . "state.json"))))
  (tofu-configuration-root-blocks
   (configuration
    (terraform (required_version ">= 1.6"))
    (backend (local (obj 'path "state.json"))))))

(test-error "duplicate root block" #t
  (configuration (terraform (required_version ">= 1.6"))
                 (terraform (required_version ">= 1.7"))))

(test-error "unrecognized configuration element" #t
  (configuration 42))

(test-error "resource arguments must be an association list" #t
  (tofu-resource "a" "b" #:arguments '(("x" . 1) 2)))

(test-error "duplicate resource argument" #t
  (resource 'x 'y (a "1") (a "2")))

(test-error "duplicate obj key" #t
  (obj 'a 1 'a 2))

(test-error "provider source must be a string" #t
  (tofu-provider 'tls 'hashicorp/tls))

(test-end "records")

(exit (if (zero? (+ (test-runner-fail-count runner)
                    (test-runner-xpass-count runner)))
          0 1))
