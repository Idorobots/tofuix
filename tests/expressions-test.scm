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

(define test-resource (resource 'test_thing 'example (id "value")))
(define test-ref (attribute test-resource 'id))

(test-equal "tf compiles an application"
  "merge({ \"a\" = \"b\" })"
  (tofu-ref-path (tf (merge (untf '((a . "b")))))))

(test-equal "tf nests applications"
  "jsonencode(sort(tolist([ test_thing.example.id ])))"
  (tofu-ref-path
   (tf (jsonencode (sort (tolist (untf (vector test-ref))))))))

(test-equal "tf keeps bare symbols as identifiers"
  "path.root"
  (tofu-ref-path (tf path.root)))

(test-equal "tf code strings interpolate"
  "f(\"a${b}c\")"
  (tofu-ref-path (tf (f "a${b}c"))))

(test-equal "tf data strings stay literal"
  "f(\"a$${b}c\")"
  (tofu-ref-path (tf (f (untf "a${b}c")))))

(test-equal "tf escapes quotes and newlines in data strings"
  "f(\"a\\nb\")"
  (tofu-ref-path (tf (f (untf "a\nb")))))

(test-equal "tf splices Scheme lists into argument lists"
  "f(1, 2)"
  (tofu-ref-path (tf (f (untf-splicing (list 1 2))))))

(test-equal "tf arrays are vectors"
  "toset([ 1, 2 ])"
  (tofu-ref-path (tf (toset (untf (vector 1 2))))))

(test-equal "tf array elements may be references"
  "toset([ test_thing.example.id ])"
  (tofu-ref-path (tf (toset (untf (vector test-ref))))))

(test-equal "tf array elements may be nested expressions"
  "toset([ merge({ \"a\" = \"b\" }) ])"
  (tofu-ref-path (tf (toset (untf (vector (tf (merge (untf '((a . "b")))))))))))

(test-equal "tf array elements may be template strings"
  "toset([ \"a${b}c\" ])"
  (tofu-ref-path (tf (toset (untf (vector (tf "a${b}c")))))))

(test-equal "tf mixes literal text and values with HCL format"
  "base64encode(format(\"%s\\n\", test_thing.example.id))"
  (tofu-ref-path (tf (base64encode (format "%s\n" (untf test-ref))))))

(test-equal "tf lowers empty lists to objects and empty vectors to arrays"
  "f({}, [])"
  (tofu-ref-path (tf (f (untf (list)) (untf (vector))))))

(test-equal "tf supports nested tf forms"
  "f(g(\"x\"))"
  (tofu-ref-path (tf (f (tf (g (untf "x")))))))

(test-equal "the #%/#^ reader shortcuts work"
  "merge({ \"a\" = \"b\" }, x)"
  (tofu-ref-path #%(merge #^'((a . "b")) #^(ref "x"))))

(test-equal "the #^@ reader shortcut splices"
  "f(1, 2)"
  (tofu-ref-path #%(f #^@(list 1 2))))

(test-error "untf outside tf is an error" #t
  (untf 1))

(test-error "tf rejects non-association lists" #t
  (tf (f (untf (list "a" "b")))))

(test-error "guile requires a module list" #t
  (guile 'hosts 'binding))

(test-error "guile requires a symbol binding" #t
  (guile '(hosts rpi3) "rpi3-os"))

(test-end "expressions")

(exit (if (zero? (+ (test-runner-fail-count runner)
                    (test-runner-xpass-count runner)))
          0 1))
