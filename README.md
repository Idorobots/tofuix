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

## Running

During development, put the channel's `modules/` directory on Guix's
extension search path:

```sh
GUIX_EXTENSIONS_PATH=$PWD/modules guix tofu generate -f examples/tls.scm
GUIX_EXTENSIONS_PATH=$PWD/modules guix tofu plan -f infrastructure.scm
```

`guix tofu` evaluates the infrastructure file, writes `.tofuix/main.tf.json`
next to it, and runs `tofu` — or `terraform` with `--tool=terraform` — in that
directory; when no `tofu` is on `PATH`, it builds the channel's pinned
`opentofu` package instead.  The provider lock file, state, and provider
cache stay untouched across regenerations.  Commands: `generate`, `build`
(also realizes required Guix artifacts), `validate` (`tofu init
-backend=false` and `tofu validate`), `plan`, `apply`, and `output`; unknown
options and arguments after `--` are forwarded to the tool.  Once tofuix is
installed as a channel, plain `guix tofu` works without the environment
variable.

Guix objects can be used directly as argument values: file-like objects and
packages are lowered to store paths before serialization, prospective paths
for `generate`/`plan`/`validate`, realized ones for `build`/`apply`:

```scheme
(use-modules (tofuix) (guix gexp))

(configuration
  (resource 'terraform_data 'artifact
    (input (plain-file "greeting.txt" "hello from tofuix"))))
```

Builder scripts that use `#$output` belong in modules that do not import
`(tofuix)`, because the `output` constructor macro shadows the gexp builder
variable; see `examples/artifact.scm`.

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
