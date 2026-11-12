# tofuix

Infrastructure as code for Guix: describe OpenTofu infrastructure in Guile
Scheme, use Guix values — files, packages, operating systems — directly as
argument values, and let `guix tofu` serialize the configuration and run
the tool.

## Example

From `examples/deployment.scm`:

```scheme
(use-modules (gnu packages) (guix gexp) (tofuix))

(define deploy-key
  (resource tls_private_key deploy
    (algorithm "ED25519")))

(define region
  (variable region
    (type "string")
    (default "eu-central-1")))

(define greeting
  (plain-file "greeting.txt" "hello from tofuix\n"))

(define infrastructure
  (configuration
    (provider tls "hashicorp/tls" "~> 4.0")
    region
    deploy-key
    (resource terraform_data deployment
      (input (obj greeting greeting
                  region (attribute region)))
      (triggers_replace greeting))
    (resource terraform_data tools
      (input (specification->package "hello")))
    (output public-key
      (attribute deploy-key public_key_openssh))))
```

`guix tofu generate -f examples/deployment.scm` prints (store paths are
prospective; `build` and `apply` realize them first):

```json
{
  "output": {
    "public-key": {
      "value": "${tls_private_key.deploy.public_key_openssh}"
    }
  },
  "resource": {
    "terraform_data": {
      "deployment": {
        "input": {
          "greeting": "/gnu/store/rlfrk45slmm21bngrbh2s77lp2ds98nk-greeting.txt",
          "region": "${var.region}"
        },
        "triggers_replace": "/gnu/store/rlfrk45slmm21bngrbh2s77lp2ds98nk-greeting.txt"
      },
      "tools": {
        "input": "/gnu/store/z41alj60i5a0jvbl56s0nj4h6gnrwn5v-hello-2.12.3"
      }
    },
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
  },
  "variable": {
    "region": {
      "default": "eu-central-1",
      "type": "string"
    }
  }
}
```

## The language

- Identifier positions — resource and data types and names, provider,
  variable, output and local names, `obj` keys, `attribute` steps — are
  raw, unquoted identifiers; everything else is an ordinary Scheme
  expression.
- Objects are association lists or `(obj key value ...)`; vectors are
  arrays, so `()` is `{}` and `#()` is `[]`.
- References stay in Scheme: `(attribute deploy-key public_key_openssh)`
  yields `${tls_private_key.deploy.public_key_openssh}`, variables and
  locals are referenced the same way, and a resource used directly as an
  argument value becomes a whole-object reference. `(ref "module.vpc")`
  is the escape hatch for addresses tofuix did not build.
- Values that need Terraform functions or mix Scheme data with
  Terraform-computed values use the gexp-like expression layer and its
  reader shortcuts (`#%`, `#^`, `#^@` — `#~`/`#$` stay Guix's):

```scheme
(input #%(jsonencode #^(obj name "x" tags (vector "a" "b"))))
```

## Guix interop

Guix values are ordinary argument values; `guix tofu` lowers them before
serialization:

- file-like objects and packages lower to store paths — prospective for
  `generate`/`plan`/`validate`, realized for `build`/`apply`;
- named Guix records — operating systems, images, machines, and other
  exported records — cross the boundary **by name**, so a provider can
  re-evaluate them in its own environment:

```scheme
(use-modules (tofuix) (hosts rpi3))

(resource guix_blueprint pi3
  (os rpi3-os))                  ; -> "(@ (hosts rpi3) rpi3-os)"
```

  An imported binding resolves to its canonical module reference; a value
  defined in the infrastructure file itself renders from its captured
  source. `(guile '(hosts rpi3) 'rpi3-os)` is the explicit form for
  values that are not loaded or not exported.
- provider-side Scheme source (for example `guix_blueprint`'s `secrets`)
  goes in a `.tmpl.scm` template file whose `{{name}}` placeholders are
  filled in at evaluation time:

```scheme
(secrets
 (template-file "secrets.tmpl.scm"
                `(("age-secret" . ,#%(base64encode (format "%s\n" #^(attribute age-key secret_key)))))))
```

One gotcha: builder scripts that use `#$output` belong in modules that do
not import `(tofuix)`, because the `output` constructor macro shadows the
gexp builder variable; see `examples/artifact.scm`.

## Running

During development, put the channel's `modules/` directory on Guix's
extension search path; once tofuix is installed as a channel, plain
`guix tofu` works without it:

```sh
GUIX_EXTENSIONS_PATH=$PWD/modules guix tofu plan -f examples/deployment.scm
```

| Command | Purpose |
|---|---|
| `generate` | Evaluate the infrastructure file and print its JSON configuration |
| `build` | As `generate`, realize required Guix artifacts, and write the configuration |
| `validate` | Generate, then `tofu init -backend=false` and `tofu validate` |
| `plan` | Generate, initialize providers, then `tofu plan` |
| `apply` | As `plan` with realization, then `tofu apply` |
| `destroy` | Generate, initialize providers, then `tofu destroy` (realizes nothing) |
| `output` | Print outputs from existing state (`-json` unless a name is given) |

Common options: `-f, --file=FILE` (default `infrastructure.scm`),
`-L, --load-path=DIR`, `--tool=tofu|terraform`, `-C, --chdir=DIR`.
Arguments after `--` and unknown options are forwarded to the tool.

`guix tofu` evaluates the infrastructure file, writes `.tofuix/main.tf.json`
next to it, and runs `tofu` — or `terraform` with `--tool=terraform` — in
that directory; when no `tofu` is on `PATH`, it builds the channel's pinned
`opentofu` package instead. The provider lock file, state, and provider
cache stay untouched across regenerations.

Modules resolve without `-L` flags: the channels of the invoking `guix`
are already on the load path, and the infrastructure file's directory and
the current directory are searched automatically (`-L` adds entries ahead
of those).

## Programmatic use

Configurations are ordinary Scheme values: `tofu-configuration->json`
from `(tofuix serializer)` serializes one, after lowering any Guix values
with `lower-configuration` from `(tofuix lower)`.

```sh
guile -L modules -L . -c '(use-modules (tofuix serializer) (examples tls)) \
  (display (tofu-configuration->json infrastructure))'
```

## Development

The test suites run under Guix, as in `spartan-guix`:

```sh
make check          # SRFI-64 unit suites (guix repl)
make check-runtime  # store-dependent lowering checks (needs a daemon)
```

CI installs Guix, emits an exact-commit channel list from `ci/channels.scm`,
bootstraps it with `guix time-machine`, and runs both targets against the
pinned channel.

## License

MIT. See [LICENSE](LICENSE).
