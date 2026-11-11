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
lists (objects); vectors are arrays, so `()` is `{}` and `#()` is `[]`.
Guix values (file-like objects, packages) are lowered to store paths.

When a value needs Terraform functions or mixes Scheme data with
Terraform-computed values, use the gexp-like expression layer and its
reader shortcuts (`#%`, `#^`, `#^@` — `#~`/`#$` stay Guix's):

```scheme
(resource 'terraform_data 'example
  (input #%(jsonencode #^(obj 'name "x" 'tags (vector "a" "b"))))
  (triggers_replace (computed-file "artifact" #~(begin (mkdir #$output)))))
```

Provider-side Scheme source (for example `guix_blueprint`'s `secrets`) goes
in a `.tmpl.scm` template file whose `{{name}}` placeholders are filled in
at evaluation time:

```scheme
(secrets
 (template-file "secrets.tmpl.scm"
                `(("age-secret" . ,#%(base64encode (format "%s\n" #^(attribute age-key 'secret_key)))))))
```

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

Named Guix records that have no store form — operating systems, images,
machines, and other exported records — cross the boundary **by name**, so a
provider can re-evaluate them in its own environment:

```scheme
(use-modules (tofuix) (hosts rpi3))

(configuration
  (resource 'guix_blueprint 'pi3
    (os rpi3-os)))                  ; -> "(@ (hosts rpi3) rpi3-os)"
```

An imported binding resolves to its canonical module reference; a value
defined in the infrastructure file itself is rendered from its captured
source (with a `(use-modules ...)` preamble for the modules it refers to).
`(guile '(hosts rpi3) 'rpi3-os)` is the explicit form for values that are
not loaded or not exported.

## Development

The test suites run under Guix, as in `spartan-guix`:

```sh
make check          # SRFI-64 unit suites (guix repl)
make check-runtime  # store-dependent lowering checks (needs a daemon)
```

CI installs Guix, emits an exact-commit channel list from `ci/channels.scm`,
bootstraps it with `guix time-machine`, and runs both targets against the
pinned channel.

Load path for interactive use and examples:

```sh
guile -L modules -L . -c '(use-modules (tofuix) (examples tls)) \
  (display (tofu-configuration->json infrastructure))'
```

## License

MIT. See [LICENSE](LICENSE).
