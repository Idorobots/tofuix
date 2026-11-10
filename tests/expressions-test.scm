;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

(define-module (tests expressions-test)
  #:use-module (srfi srfi-64)
  #:use-module (tofuix records)
  #:use-module (tofuix expressions))

(define runner (test-runner-create))
(test-runner-current runner)

(test-begin "expressions")

(test-equal "attribute of a resource"
  "tls_private_key.deploy.public_key_openssh"
  (tofu-ref-path
   (attribute (resource 'tls_private_key 'deploy) 'public_key_openssh)))

(test-equal "attribute chains"
  "aws_instance.server.network_interface.address"
  (tofu-ref-path
   (attribute (attribute (resource 'aws_instance 'server)
                         'network_interface)
              'address)))

(test-equal "attribute indexes"
  "aws_instance.server.addresses[0]"
  (tofu-ref-path
   (attribute (resource 'aws_instance 'server) 'addresses 0)))

(test-equal "attribute of a variable"
  "var.region"
  (tofu-ref-path (attribute (variable 'region))))

(test-equal "attribute of a local"
  "local.name"
  (tofu-ref-path (attribute (local 'name "value"))))

(test-equal "attribute of a data source"
  "data.aws_ami.server.id"
  (tofu-ref-path (attribute (data 'aws_ami 'server) 'id)))

(test-equal "attribute extends a reference"
  "module.vpc.vpc_id"
  (tofu-ref-path (attribute (ref "module.vpc") 'vpc_id)))

(test-equal "string steps are attribute names"
  "aws_instance.server.id"
  (tofu-ref-path (attribute (resource 'aws_instance 'server) "id")))

(test-equal "reference interpolation"
  "${module.vpc.vpc_id}"
  (tofu-ref->string (ref "module.vpc.vpc_id")))

(test-equal "guile module reference"
  "(@ (hosts rpi3) rpi3-os)"
  (guile '(hosts rpi3) 'rpi3-os))

(test-error "ref requires a string" #t
  (ref 42))

(test-error "attribute rejects non-referencable objects" #t
  (attribute "not a record" 'field))

(test-error "attribute rejects invalid steps" #t
  (attribute (variable 'region) 1.5))

(test-error "guile requires a module list" #t
  (guile 'hosts 'binding))

(test-error "guile requires a symbol binding" #t
  (guile '(hosts rpi3) "rpi3-os"))

(test-end "expressions")

(exit (if (zero? (+ (test-runner-fail-count runner)
                    (test-runner-xpass-count runner)))
          0 1))
