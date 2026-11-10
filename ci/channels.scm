;; Run with `guix repl ci/channels.scm` to emit a pure-data channel file for
;; Guix's isolated loader.  The committed checkout supplies the channel under
;; test, including PR merge commits; no remote publication is needed.
(use-modules (guix channels) (ice-9 pretty-print))

(let* ((root (dirname (dirname (canonicalize-path (current-filename)))))
       (commit (or (getenv "TOFUIX_COMMIT") (getenv "GITHUB_SHA"))))
  (unless commit
    (error "Set TOFUIX_COMMIT to the checkout's git commit"))
  (pretty-print
   `(list ,@(map channel->code
                 (list (channel
                        (name 'tofuix)
                        (url (string-append "file://" root))
                        (branch "main")
                        (commit commit))
                       ;; Select CI's Guix version here.
                       (channel
                        (name 'guix)
                        (url "https://git.guix.gnu.org/guix.git")
                        (commit "2bc642182e5e7914c1ea4deb696b8e3566b12b3f")
                        (introduction
                         (make-channel-introduction
                          "9edb3f66fd807b096b48283debdcddccfea34bad"
                          (openpgp-fingerprint
                           "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))))))))
