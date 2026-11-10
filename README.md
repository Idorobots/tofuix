# tofuix

Infrastructure as code for Guix: describe OpenTofu infrastructure in Guile
Scheme, generate the JSON configuration, and run the selected tool.

## Example

```scheme
(use-modules (tofuix))

(define deploy-key
  (resource 'tls_private_key 'deploy
    (algorithm "ED25519")))

(define public-key
  (output 'public-key
    (attribute deploy-key 'public_key_openssh)))

(define infrastructure
  (configuration
    (provider 'tls "hashicorp/tls" "~> 4.0")
    deploy-key
    public-key))
```

`(tofu-configuration->json infrastructure)` returns:

```json
{
  "output": {
    "public-key": {
      "value": "${tls_private_key.deploy.public_key_openssh}"
    }
  },
  "resource": {
    "tls_private_key": {
      "deploy": {
        "algorithm": "ED25519"
      }
    }
  },
  "terraform": {
    "required_providers": {
      "tls": {
        "source": "hashicorp/tls",
        "version": "~> 4.0"
      }
    }
  }
}
```

Resources are first-class Scheme values, so references stay in Scheme:
`(attribute resource 'name)` yields an unevaluated OpenTofu expression, and a
resource used directly as an argument value becomes a whole-object
reference. Nested blocks use `(obj 'key value ...)` or plain association
lists; lists become JSON arrays. Guix values (file-like objects, packages,
images) are lowered to store paths.

## Development

```sh
make check                       # run the SRFI-64 test suites
guix shell -m manifest.scm -- make check
```

Load path for interactive use and examples:

```sh
guile -L modules -L . -c '(use-modules (tofuix) (examples tls)) \
  (display (tofu-configuration->json infrastructure))'
```

## License

MIT. See [LICENSE](LICENSE).
