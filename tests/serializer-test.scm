;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

(define-module (tests serializer-test)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-64)
  #:use-module (tofuix records)
  #:use-module (tofuix expressions)
  #:use-module (tofuix serializer))

(define runner (test-runner-create))
(test-runner-current runner)

(define (serialize configuration)
  (tofu-configuration->scm configuration))

(define (section configuration name)
  (assoc-ref (serialize configuration) name))

(define (resource-arguments configuration type name)
  (let* ((section (assoc-ref (serialize configuration) "resource"))
         (names (assoc-ref section type)))
    (assoc-ref names name)))

(test-begin "serializer")

(test-equal "empty configuration"
  "{}"
  (tofu-configuration->json (configuration)))

(test-equal "empty configuration has no sections"
  '()
  (serialize (configuration)))

(test-equal "locals with scalar values"
  '(("count" . 3) ("flag" . #t) ("name" . "x") ("ratio" . 2.5))
  (section (configuration
            (local 'count 3)
            (local 'flag #t)
            (local 'name "x")
            (local 'ratio 2.5))
           "locals"))

(test-equal "symbol values become strings"
  '(("algorithm" . "ED25519"))
  (resource-arguments
   (configuration (resource 'tls_private_key 'deploy (algorithm 'ED25519)))
   "tls_private_key" "deploy"))

(test-equal "resource section nests type and name"
  '(("tls_private_key"
     ("deploy" ("algorithm" . "ED25519"))))
  (section (configuration
            (resource 'tls_private_key 'deploy (algorithm "ED25519")))
           "resource"))

(test-equal "arrays keep their order"
  '(("ids" . #(1 2)) ("tags" . #("a" "b")))
  (resource-arguments
   (configuration (resource 'x 'y (tags "a" "b") (ids (list 1 2))))
   "x" "y"))

(test-equal "empty lists become empty arrays"
  '(("empty" . #()))
  (resource-arguments
   (configuration (resource 'x 'y (empty (list))))
   "x" "y"))

(test-equal "arrays of objects become vectors of association lists"
  '(("ingress" . #((("from_port" . 80)) (("to_port" . 80)))))
  (resource-arguments
   (configuration
    (resource 'aws_security_group 'web
      (ingress (list (obj 'from_port 80) (obj 'to_port 80)))))
   "aws_security_group" "web"))

(test-equal "objects nest through obj"
  '(("create" ("content" ("url" . "/gnu/store/example"))))
  (resource-arguments
   (configuration
    (resource 'x 'y
      (create (obj 'content (obj 'url "/gnu/store/example")))))
   "x" "y"))

(test-equal "quoted association lists nest as objects"
  '(("create" ("content" ("url" . "/gnu/store/example"))))
  (resource-arguments
   (configuration
    (resource 'x 'y
      (create '((content . ((url . "/gnu/store/example")))))))
   "x" "y"))

(test-equal "data source section"
  '(("aws_ami" ("server" ("most_recent" . #t))))
  (section (configuration
            (data 'aws_ami 'server (most_recent #t)))
           "data"))

(test-equal "variable section"
  '(("region" ("default" . "eu-central-1") ("type" . "string")))
  (section (configuration
            (variable 'region
              (type "string")
              (default "eu-central-1")))
           "variable"))

(test-equal "output value and fields"
  '(("public-key" ("description" . "SSH key")
                  ("sensitive" . #t)
                  ("value" . "${var.region}")))
  (section (configuration
            (variable 'region)
            (output 'public-key
              (attribute (variable 'region))
              (description "SSH key")
              (sensitive #t)))
           "output"))

(test-equal "provider section only includes configured providers"
  '(("aws" ("region" . "eu-central-1")))
  (section (configuration
            (provider 'tls "hashicorp/tls" "~> 4.0")
            (provider 'aws "hashicorp/aws" "~> 6.0"
                      (region "eu-central-1")))
           "provider"))

(test-equal "terraform required providers"
  '(("required_providers"
     ("aws" ("source" . "hashicorp/aws") ("version" . "~> 6.0"))
     ("tls" ("source" . "hashicorp/tls"))))
  (section (configuration
            (provider 'tls "hashicorp/tls")
            (provider 'aws "hashicorp/aws" "~> 6.0"))
           "terraform"))

(test-equal "terraform root block and backend"
  '(("backend" ("local" ("path" . "state.json")))
    ("required_version" . ">= 1.6"))
  (section (configuration
            (terraform (required_version ">= 1.6"))
            (backend (local (obj 'path "state.json"))))
           "terraform"))

(test-equal "whole-resource references"
  '(("guix_blueprint" ("pi3" ("os" . "example")))
    ("guix_host" ("pi3" ("blueprint" . "${guix_blueprint.pi3}"))))
  (let ((blueprint (resource 'guix_blueprint 'pi3 (os "example"))))
    (section (configuration
              blueprint
              (resource 'guix_host 'pi3 (blueprint blueprint)))
             "resource")))

(test-equal "whole-variable and whole-local references"
  '(("local" . "${local.name}") ("variable" . "${var.region}"))
  (resource-arguments
   (configuration
    (variable 'region)
    (local 'name "n")
    (resource 'x 'y
      (variable (variable 'region))
      (local (local 'name "n"))))
   "x" "y"))

(test-equal "referencing a variable by identity"
  '(("region" . "${var.region}"))
  (resource-arguments
   (configuration
    (variable 'region)
    (resource 'x 'y (region (attribute (variable 'region)))))
   "x" "y"))

(test-error "dangling resource reference" #t
  (serialize
   (configuration
    (resource 'guix_host 'pi3
      (blueprint (resource 'guix_blueprint 'pi3))))))

(test-error "dangling data source reference" #t
  (serialize
   (configuration
    (resource 'x 'y (ami (data 'aws_ami 'server))))))

(test-error "dangling variable reference" #t
  (serialize
   (configuration
    (resource 'x 'y (region (variable 'region))))))

(test-error "dangling local reference" #t
  (serialize
   (configuration
    (resource 'x 'y (name (local 'name "x"))))))

(test-error "unserializable values" #t
  (serialize (configuration (local 'x (lambda () #t)))))

(test-equal "array of objects keeps array structure"
  "{
  \"resource\": {
    \"aws_security_group\": {
      \"web\": {
        \"ingress\": [
          {
            \"from_port\": 80
          },
          {
            \"to_port\": 80
          }
        ]
      }
    }
  }
}"
  (tofu-configuration->json
   (configuration
    (resource 'aws_security_group 'web
      (ingress (list (obj 'from_port 80)
                     (obj 'to_port 80)))))))

(test-equal "strings are escaped"
  "{
  \"locals\": {
    \"s\": \"a\\\"b\\nc\\td\"
  }
}"
  (tofu-configuration->json
   (configuration (local 's "a\"b\nc\td"))))

(test-equal "control characters are escaped"
  "{
  \"locals\": {
    \"s\": \"a\\u0001\"
  }
}"
  (tofu-configuration->json
   (configuration (local 's (string #\a (integer->char 1))))))

(test-end "serializer")

(exit (if (zero? (+ (test-runner-fail-count runner)
                    (test-runner-xpass-count runner)))
          0 1))
