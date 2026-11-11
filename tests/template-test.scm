;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

(define-module (tests template-test)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-64)
  #:use-module (tofuix records)
  #:use-module (tofuix expressions)
  #:use-module (tofuix template))

(define runner (test-runner-create))
(test-runner-current runner)

(define age-key (resource 'age_secret_key 'pi3))
(define host-key (resource 'tls_private_key 'pi3_host))

(define (make-temp-directory)
  (mkdtemp "/tmp/tofuix-template-XXXXXX"))

(define (write-file file text)
  (call-with-output-file file
    (lambda (port) (display text port))))

(test-begin "template")

(test-equal "strings are inserted verbatim"
  "hello tofuix"
  (render-template "hello {{who}}" '(("who" . "tofuix"))))

(test-equal "symbols are accepted as binding names"
  "hello tofuix"
  (render-template "hello {{who}}" '((who . "tofuix"))))

(test-equal "placeholders may carry surrounding whitespace"
  "hello tofuix"
  (render-template "hello {{  who  }}" '(("who" . "tofuix"))))

(test-equal "references render as interpolations"
  "(content (base64-decode \"${age_secret_key.pi3.secret_key}\"))"
  (render-template "(content (base64-decode \"{{key}}\"))"
                   `(("key" . ,(attribute age-key 'secret_key)))))

(test-equal "records render as whole-object interpolations"
  "${tls_private_key.pi3_host}"
  (render-template "{{key}}" `(("key" . ,host-key))))

(test-equal "numbers and booleans are printed"
  "(f 3 #t #f)"
  (render-template "(f {{n}} {{yes}} {{no}})"
                   '((n . 3) (yes . #t) (no . #f))))

(test-equal "a placeholder may appear more than once"
  "a-a-a"
  (render-template "{{x}}-{{x}}-{{x}}" '(("x" . "a"))))

(test-equal "adjacent placeholders"
  "ab"
  (render-template "{{a}}{{b}}" '(("a" . "a") ("b" . "b"))))

(test-equal "inserted text is not rescanned"
  "{{nested}}"
  (render-template "{{x}}" '(("x" . "{{nested}}"))))

(test-error "an unknown placeholder is an error" #t
  (render-template "{{missing}}" '(("present" . "x"))))

(test-error "an unterminated placeholder is an error" #t
  (render-template "{{open" '()))

(test-error "unrenderable values are an error" #t
  (render-template "{{x}}" `(("x" . ,(list 1 2)))))

(let* ((directory (make-temp-directory))
       (file (in-vicinity directory "secrets.tmpl.scm")))
  (write-file file "\
(use-modules (guix secrets) (guix base64))

(secrets
  (files
    (list
      (secret-file
        (destination \"/etc/sops/age/keys.txt\")
        (content (base64-decode \"{{age-secret}}\")))
      (secret-file
        (destination \"/etc/ssh/ssh_host_ed25519_key\")
        (content (base64-decode \"{{host-secret}}\"))))))
")
  (test-equal "template-file renders a file"
    "\
(use-modules (guix secrets) (guix base64))

(secrets
  (files
    (list
      (secret-file
        (destination \"/etc/sops/age/keys.txt\")
        (content (base64-decode \"${age_secret_key.pi3.secret_key}\")))
      (secret-file
        (destination \"/etc/ssh/ssh_host_ed25519_key\")
        (content (base64-decode \"${tls_private_key.pi3_host.private_key_openssh}\"))))))
"
    (template-file file
                   `(("age-secret" . ,(attribute age-key 'secret_key))
                     ("host-secret" . ,(attribute host-key 'private_key_openssh)))))
  (test-error "a missing template file is an error" #t
    (template-file (in-vicinity directory "absent.tmpl.scm") '()))
  (system* "rm" "-rf" directory))

(test-end "template")

(exit (if (zero? (+ (test-runner-fail-count runner)
                    (test-runner-xpass-count runner)))
          0 1))
