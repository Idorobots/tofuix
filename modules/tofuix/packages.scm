;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; The opentofu package: `guix tofu` builds it when no tofu executable is
;;; found on PATH.  OpenTofu is written in Go; a source build needs the full
;;; module graph, so this package installs the upstream release binary for
;;; the host architecture, pinned by its SHA256.

(define-module (tofuix packages)
  #:use-module (guix base32)
  #:use-module (guix download)
  #:use-module (guix packages)
  #:use-module (guix build-system copy)
  #:use-module (guix utils)
  #:use-module (ice-9 match)
  #:use-module (gnu packages compression)
  #:use-module ((guix licenses) #:prefix license:)
  #:export (opentofu))

(define %opentofu-version "1.13.9")

(define (opentofu-uri architecture)
  "Return the release archive URI for ARCHITECTURE (a Go architecture
name such as \"amd64\")."
  (string-append "https://github.com/opentofu/opentofu/releases/download/v"
                 %opentofu-version "/tofu_" %opentofu-version "_linux_"
                 architecture ".zip"))

(define %opentofu-hashes
  ;; SHA256 of the release archives, keyed by system.
  '(("x86_64-linux" . "1kirqm87q57ilwvjfwfadkv91xc7364i8887shxshss40rmyni5w")
    ("aarch64-linux" . "18vzich4v2nqz1dvjzsxgcahkgzy7y90zlwy4qhd8ndq50wckxq4")))

(define (opentofu-architecture system)
  "Return the release architecture for SYSTEM."
  (match system
    ("x86_64-linux" "amd64")
    ("aarch64-linux" "arm64")
    (_ (error "tofuix: opentofu has no release for this system" system))))

(define opentofu
  (let* ((system (or (%current-target-system) (%current-system)))
         (hash (assoc-ref %opentofu-hashes system)))
    (unless hash
      (error "tofuix: opentofu has no release for this system" system))
    (package
      (name "opentofu")
      (version %opentofu-version)
      (source (origin
                (method url-fetch)
                (uri (opentofu-uri (opentofu-architecture system)))
                (sha256 (base32 hash))))
      (build-system copy-build-system)
      (native-inputs (list unzip))
      (arguments
       '(#:install-plan
         '(("tofu" "bin/")
           ("LICENSE" "share/doc/opentofu/")
           ("README.md" "share/doc/opentofu/")
           ("CHANGELOG.md" "share/doc/opentofu/"))
         #:strip-binaries? #f))
      (supported-systems '("x86_64-linux" "aarch64-linux"))
      (synopsis "Tool for building, changing, and versioning infrastructure")
      (description
       "OpenTofu is an open source tool for building, changing, and
versioning infrastructure safely and efficiently.  It is compatible with
the Terraform configuration language and JSON configuration
representation.")
      (home-page "https://opentofu.org/")
      (license license:mpl2.0))))
