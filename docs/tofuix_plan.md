# tofuix implementation plan

**Project:** `tofuix`, developed in the `./tofuix` git module
(<https://github.com/Idorobots/tofuix>, already registered as a submodule).
**Command:** `guix tofu`, delivered as a Guix channel extension.
**Status:** M1 and M2 implemented — Scheme DSL, JSON serializer, 128 SRFI-64
tests, the `examples/tls.scm` golden example, and the `guix tofu` extension
(`eval`/`check`/`plan`/`apply`/`output`, working-directory and lock
management, `--tool` selection). M3 (Guix-value lowering) is next.

This plan consolidates the design discussed in the "Design Guix OpenTofu
Integration" transcript with the decisions taken afterwards.

## 1. Overview

tofuix is a *terranix for Guix*: infrastructure is described in Guile Scheme,
tofuix translates that description into a Terraform-compatible JSON
configuration (`.tf.json`), and runs it with OpenTofu — or Terraform, selected
through configuration.

Core properties:

- **Provider-agnostic.** tofuix has no knowledge of any specific provider,
  including the Guix provider used by `infra/`. All it does is translate a
  Scheme-encoded infrastructure description into Terraform JSON and run it.
  Any provider usable from OpenTofu/Terraform is usable from tofuix.
- **A genuine Guix extension.** The interface is `guix tofu`, registered
  through Guix's extension-command mechanism (`guix/extensions/`); no Guix
  fork or patching. The library layer stays usable from plain Guile code.
- **Guix-native values.** Where a resource argument would take a path or
  string, native Guix objects (file-like objects, packages, system images)
  may be used directly; tofuix lowers them to plain values (store paths)
  before serialization. Guix owns builds; OpenTofu owns infrastructure state.
- **Deploy without surprise builds.** `guix tofu plan` never realizes Guix
  builds (dry-run semantics); `guix tofu apply` realizes them. No atomic
  cross-system transactions are pretended; v2 adds resumable staged applies.

## 2. Scope

| Version | Contents |
|---|---|
| **v1** | Scheme DSL, JSON serializer, `guix tofu` extension, single-stage lifecycle (`eval`/`build`/`check`/`plan`/`apply`/`output`), Guix-value lowering, provider lock management |
| **v2** | Staged bidirectional orchestration: tofu outputs feeding Guix builds feeding later tofu stages; deferred evaluation; resumable checkpoints |
| **Later** | Migration of the homelab `infra/` HCL scaffold to tofuix (work in this repository, not in `tofuix`) |

Explicit non-goals for v1:

- No OpenTofu/Terraform provider of tofuix's own (including no Guix provider
  integration; that provider remains an ordinary third-party resource type).
- No module-system machinery beyond explicit records and composition
  functions with well-defined merge rules.
- No secret management; tofuix only documents state-sensitivity warnings.
  Provider-side secret flows (such as the Guix provider's `guix secrets
  image`/`guix secrets deploy`) stay with the provider.
- No `guix deploy` integration.
- tofuix only generates Terraform JSON and runs `tofu` (or `terraform`);
  it never invokes provider tooling.

## 3. Architecture

Two layers:

1. **Pure Guile library `(tofuix ...)`** — records, expression AST,
   serializer, Guix-value lowering, configuration evaluation. Usable
   programmatically from any Guile/Guix code (e.g. from `guix repl`). No CLI
   concerns.
2. **Guix extension `(guix extensions tofu)`** — the `guix tofu` entry point:
   argument parsing, project/working-directory management, invocation of the
   selected OpenTofu/Terraform binary, and integration with the Guix store
   and daemon.

```text
infrastructure.scm (Scheme)
        |
        v
(tofuix) evaluation: records -> internal tree
        |
        v
lowering: Guix values -> plain values (store paths, derivations)
        |
        v
(tofuix serializer): tree -> .tf.json in the working directory
        |
        v
OpenTofu / Terraform (tofu plan / tofu apply ...)
        |
        v
cloud / local infrastructure
```

### 3.1 Plan/apply semantics (v1)

| Operation | `guix tofu plan` | `guix tofu apply` |
|---|---|---|
| Evaluate Scheme | yes | yes |
| Construct Guix derivations | yes | yes |
| Realize Guix builds | **no** (dry run) | yes |
| Generate `.tf.json` | yes | yes |
| Run `tofu plan` | yes | yes (replan) |
| Run `tofu apply` | no | yes |

Guix can compute a derivation's output path before building it, so plans
reference prospective `/gnu/store/...` paths without realizing them.
Documented caveat: providers that inspect local files during planning may
fail on not-yet-built artifacts; `guix tofu build` exists for that case.

## 4. Repository and channel layout

The channel's Scheme contents live under `./modules`, selected by
`.guix-channel`, mirroring the `spartan-guix` convention in this repository.
Tests stay outside the channel tree so channel distribution and Scheme test
suites do not interfere with each other.

```text
tofuix/
├── .guix-channel            # (channel (version 0) (directory "modules") ...)
├── modules/                 # everything guix pull distributes
│   ├── guix/
│   │   └── extensions/
│   │       └── tofu.scm     # (guix extensions tofu), entry point guix-tofu
│   └── tofuix/
│       ├── records.scm      # configuration/resource/provider/variable/output
│       ├── expressions.scm  # OpenTofu expression AST (ref, ...)
│       ├── serializer.scm   # tree -> .tf.json (guile-json)
│       ├── evaluate.scm     # load/evaluate infrastructure files
│       ├── workdir.scm      # working directory and tofu invocation
│       ├── lower.scm        # Guix-value lowering protocol (M3)
│       └── packages.scm     # opentofu package definition (M3)
├── tests/                   # SRFI-64 suites; not part of the channel
├── examples/                # runnable examples (outside the channel)
├── manifest.scm              # development environment
├── Makefile                  # check / examples targets
└── README.md
```

The extension file must sit at `modules/guix/extensions/tofu.scm`: `guix pull`
copies the channel's `modules/` tree into the profile's Guile site directory,
and Guix looks up extension commands at `<site-dir>/guix/extensions/NAME.scm`
(`guix/ui.scm` in Guix 1.5). During development, the same layout works via:

```sh
GUIX_EXTENSIONS_PATH="$PWD/modules" guix tofu ...
```

which places `modules/` on the extension search path and load path, so both
`(guix extensions tofu)` and `(tofuix ...)` resolve.

### 4.1 OpenTofu/Terraform tool dependency

`guix tofu` is assumed to run on a system with a working `guix-daemon`, so
tofuix depends on OpenTofu as a Guix package:

- `modules/tofuix/packages.scm` defines an `opentofu` package, since
  upstream Guix currently ships none.
- The extension resolves the tool binary in order: explicit config/CLI
  override → `PATH` lookup → build/instantiate the channel's package through
  the store.
- The tool is selectable (`tofu` vs `terraform`) through tofuix
  configuration, because both accept the same JSON configuration format.
- `terraform` is **not** packaged: when selected via `--tool=terraform`, the
  binary must already be available on `PATH`.

## 5. Scheme DSL

Two layers, both in `(tofuix)`:

- **Programmatic layer**: Guile records in `(tofuix records)`, re-exported by
  the facade module. Record types, predicates, and constructors carry a
  `tofu-` prefix (`tofu-configuration`, `tofu-resource`, ...), keeping the
  module namespace honest for programmatic use and third-party imports.
- **Ergonomic layer**: positional constructor macros (`resource`, `data`,
  `provider`, `variable`, `output`, `local`, `configuration`) that expand to
  the `tofu-`-prefixed record constructors — terse and terranix-flavored,
  with **native Scheme references** (next section). The macros are the
  intended user interface; the prefixes live in the data representation.

| Record (v1) | Constructor | Purpose |
|---|---|---|
| `tofu-configuration` | `(configuration ELEM...)` | Root object (the OpenTofu "configuration"); flat sequence of providers, resources, outputs, variables, locals, root blocks |
| `tofu-provider` | `(provider 'tls "hashicorp/tls" "~> 4.0")` | Required provider declaration (name, source, optional version) |
| `tofu-variable` | `(variable 'region (type "string") (default "eu-central-1"))` | Input variable with type/default/validation tuples |
| `tofu-resource` | `(resource 'tls_private_key 'deploy (algorithm "ED25519"))` | Managed resource (type, name, argument tuples) |
| `tofu-data` | `(data 'aws_ami 'server (most_recent #t))` | Data source (v1.1; same shape as `resource`) |
| `tofu-output` | `(output 'public-key VALUE (description "..."))` | Root-module output: positional value, optional field tuples (`description`, `sensitive`, `depends_on`) |
| `tofu-local` | `(local 'bucket-name VALUE)` | Local value aliasing Scheme-computed values |

Example:

```scheme
(use-modules (tofuix) (tofuix expressions))

(define deploy-key
  (resource 'tls_private_key 'deploy
    (algorithm "ED25519")))

(define public-key
  (output 'public-key
    (attribute deploy-key 'public_key_openssh)))

(configuration
  (provider 'tls "hashicorp/tls" "~> 4.0")
  deploy-key
  public-key)
```

serializes to:

```json
{
  "terraform": { "required_providers": { "tls": { "source": "hashicorp/tls", "version": "~> 4.0" } } },
  "resource":  { "tls_private_key": { "deploy": { "algorithm": "ED25519" } } },
  "output":    { "public-key": { "value": "${tls_private_key.deploy.public_key_openssh}" } }
}
```

Rules:

- The constructors are **macros**: argument tuples `(key value ...)` are read
  as field syntax at expansion — `(algorithm "ED25519")` is a tuple, not a
  procedure call. Tuple *values* are ordinary evaluated expressions, so
  `(attribute ...)`, Scheme computation, and lowered Guix objects compose
  freely.
- Resource/data `type` and `name` are inline and positional (symbol or
  string). Meta-arguments (`lifecycle`, `count`, `depends_on`, `provider`)
  are ordinary tuples.
- A tuple with several values serializes to a JSON array:
  `(availability_zones "eu-central-1a" "eu-central-1b")`.
- Nested structures cannot use tuple sugar unambiguously (a list of tuples
  could mean a JSON object or an array of objects), so nesting uses plain
  data, terranix-style: alists and `(obj 'k v ...)` build objects, lists
  build arrays, e.g.
  `(create (obj 'content (obj 'url image-path)))`.
- `configuration` takes a flat sequence: each element is a configuration
  object (or a list of them), classified by record type, plus root-level
  tuple blocks such as `(terraform (required_version ">= 1.6"))` and
  `(backend ...)`. Duplicate type+name pairs are an error; `configuration`
  merges explicitly with collision detection, never silently overriding.
- Scheme evaluation happens at definition time; OpenTofu evaluation happens
  at plan/apply time. The two are never confused (next section).

### 5.1 Expressions: native Scheme references

Resource, data, variable, and local records carry their own identity, so
references stay in Scheme — no stringly-typed paths, no global registry.
OpenTofu calls `TYPE.NAME.attribute` an **attribute reference**, so the
reference constructor is named accordingly:

- `(attribute RESOURCE 'attr...)` → `${TYPE.NAME.attr...}`; e.g. from the
  example, `(attribute deploy-key 'public_key_openssh)` serializes to
  `${tls_private_key.deploy.public_key_openssh}`.
- `attribute` accepts the referencable objects: `resource` →
  `TYPE.NAME.attr...`, `data` → `data.TYPE.NAME.attr...`, `variable` →
  `var.NAME`, `local` → `local.NAME`; and it chains, since a reference is
  itself a value:
  `(attribute (attribute server 'network_interface) 'address)`.
- Traversal: multiple symbols walk attributes; integers index:
  `(attribute iface 'addresses 0)` → `${...addresses}[0]`.
- `attribute` is a plain procedure, so it can be used anywhere an expression
  is expected — inside tuple values, `local`/`output` values, or nested
  `obj` structures.

Escapes and future growth:

- `(ref "module.vpc.vpc_id")` remains the low-level escape hatch for
  dynamic or computed references and module outputs (v1: module blocks
  likely use `ref`; nicer module support can come later).
- Plain Scheme strings that merely *contain* `${...}` are passed through
  verbatim.
- `(guile '(hosts rpi3) 'rpi3-os)` is a plain string expression (not an
  OpenTofu expression): it serializes to `"(@ (hosts rpi3) rpi3-os)"` — the
  canonical Guile module reference — and is the explicit form of the named
  Guix values described in section 7.1.
- Helpers for function calls, conditionals, `for` expressions, and string
  templates are added incrementally as needed, each serializing to its
  HCL-in-JSON equivalent.

### 5.2 Nesting: references and blocks

What looks like embedding in HCL — a `guix_host` consuming a
`guix_blueprint` — is never lexical nesting: resources are always top-level.
It is a **resource-to-resource reference** plus **nested argument blocks**,
and the DSL mirrors exactly those two mechanisms.

**Resource values are whole-object references.** When a `tofu-resource` (or
data) value appears as an argument value, it serializes to `${TYPE.NAME}` —
the JSON equivalent of `blueprint = guix_blueprint.pi3` — and creates the
same implicit dependency edge in OpenTofu:

```scheme
(use-modules (tofuix) (tofuix expressions) (hosts rpi3))

(define pi3-blueprint
  (resource 'guix_blueprint 'pi3
    (os rpi3-os)             ; -> "(@ (hosts rpi3) rpi3-os)" (see 7.1)
    (machine rpi3)           ; -> "(@ (hosts rpi3) rpi3)"
    (channels (call-with-input-file "channels-lock.scm" get-string-all))))

(define pi3-host
  (resource 'guix_host 'pi3
    (hostname "pi3.local")
    (blueprint pi3-blueprint)             ; -> "${guix_blueprint.pi3}"
    (system "aarch64-linux")
    (ssh (obj
          'user "root"
          'private_key (attribute management-key 'private_key_openssh)
          'host_key (attribute pi3-host-key 'public_key_openssh)))
    (timeouts (obj 'create "2h" 'update "2h"))))
```

`ssh` and `timeouts` serialize as nested JSON objects. An explicit
`(depends_on pi3-blueprint)` is available where no value flows but ordering
must still hold.

**Nested blocks are data** (section rules apply at any depth): `obj`/alists
for single blocks, a list of `obj`s for repeated blocks (security-group
`ingress`, etc.) → JSON array of objects. Guix-value lowering (section 7)
also runs inside nested structures, so file-like objects may be used
anywhere in the tree.

**Inline embedding (v1.1 sugar).** A constructor may appear directly in a
value position: `(blueprint (resource 'guix_blueprint 'pi3 ...))`. This is
*not* a syntax error as it would be in HCL, because Scheme resources are
values: the inner constructor is the tuple's value expression, evaluated
eagerly when the outer resource is defined, yielding a `<tofu-resource>`
record in the argument tree. No global registration happens at definition
time; instead the serializer deep-walks the tree, hoists such inline
resources into the configuration, and leaves their reference in place.

Hoisting rules:

- A record identical to one already in the configuration is only
  referenced, never duplicated.
- The same type+name with different content is a collision error; choose a
  new name or reuse the existing resource.
- Until hoisting exists (v1), the serializer's **reference-integrity
  check** rejects the construct with `guix_blueprint.pi3 is not part of the
  configuration` — preferable to emitting a dangling `${...}` that
  `tofu validate` would only report later and less clearly.
- Inline resources are computed eagerly even if the enclosing resource is
  never used, and cannot be referenced elsewhere unless bound with
  `define`; definitions with `define` remain the recommended style, with
  inline embedding as ergonomics for one-off helper resources.

## 6. Serializer

`serializer.scm` walks the record tree and emits `.tf.json`. The mapping is
one-to-one with OpenTofu's documented JSON configuration representation.
The serializer is pure: given the same evaluated tree, the JSON is
deterministic (sorted keys, two-space indentation), which keeps diffs and
plan churn minimal.

Emission uses `guile-json` (`(json)`) with `#:pretty #t` (two-space
indentation) and `#:unicode #t`.  The latter guarantees valid JSON — control
characters below 0x20 are escaped — at the cost of escaping non-ASCII
characters, which also keeps output byte-stable across locales.

guile-json has no key sorting, so the serializer sorts association lists
itself.  The object/array distinction also remains explicit: objects are
association lists, arrays are **vectors**.  A plain list of association
lists would be mistaken for an object (a one-element array of objects is
genuinely ambiguous to generic JSON libraries), so `value->scm` converts
every array to a vector and the empty array to `#()`.  Output bytes are
pinned by the `tests/tls.golden.json` fixture.

`guile-json` is a runtime dependency: it is part of any Guix installation
(Guix itself uses it), and `manifest.scm` lists it for development.

## 7. Guix-value lowering

`lower.scm` defines `lower-value`, dispatched on the argument's type:

| Scheme value | Lowering behavior |
|---|---|
| String, number, boolean, symbol → string | Serialize as JSON scalar |
| List / alist / nested | Recurse |
| Expression AST (`ref`, `attribute` results, ...) | Serialize as OpenTofu expression |
| File-like object (plain-file, computed-file, ...) | Lower to store path string |
| Package | Resolve selected output's store path |
| `<image>` / operating-system-based artifacts (v1.1) | Derive image; use its derivation output path |
| Other named Guix records (`<operating-system>`, service configs, ...) (v1.1) | Resolve the binding's module provenance → canonical module-reference string (section 7.1) |
| Anything else with no store form and no discoverable binding | Error listing the explicit remedies |

For `plan`, derivations are constructed but **not realized**; the prospective
store path is embedded in the JSON. For `apply`/`build`, the derivation is
realized first and the exact artifact path is embedded. Changes in the
underlying Guix definitions therefore propagate into new store paths, and
OpenTofu plans the corresponding infrastructure change — without tofuix
knowing anything about the provider consuming the path.

### 7.1 Named Guix values: module references instead of objects

Store paths are the only provider-neutral currency for build artifacts, but
configuration values such as `<operating-system>` blueprints have no store
path, are not serializable, and some providers (the Guix provider, for one)
evaluate their own Scheme expressions in a pinned-channel, source-bundle
environment rather than accepting objects. Such values cross the tofuix
boundary **by name**, as canonical Guile module references:

- `(os rpi3-os)` — with `(hosts rpi3)` loaded in the tofuix evaluation
  session — works as plain Scheme evaluation followed by provenance
  resolution: tuple values are evaluated normally, so tofuix holds the
  actual `<operating-system>` value; lowering then scans loaded module
  interfaces for a public binding holding the same object (`eq?`) and
  serializes the argument as `"(@ (hosts rpi3) rpi3-os)"`.
- Zero matches → error suggesting the explicit form; multiple matches →
  error listing the candidate modules.
- `(guile '(hosts rpi3) 'rpi3-os)` is the explicit expression for values
  that are not loaded, not exported, or anonymous; the sugar form in the
  section 5.2 example is exactly equivalent to it.
- tofuix transfers the *identity* of the configuration, never the object:
  the provider keeps evaluating the expression in its own environment. The
  rule remains provider-agnostic — tofuix merely produces a canonical name
  for a named Guix value, exactly as it produces a store path for a
  file-like object, without knowing what any provider does with it.
- This requires the defining modules to be loadable in the tofuix session;
  `guix tofu -L/--load-path` (section 8) prepends directories to the load
  path when evaluating the infrastructure file. The extension does **not**
  wrap evaluation in `guix time-machine` itself: users run
  `guix time-machine -C channels-lock.scm -- guix tofu -L ...` when they
  need evaluation at pinned channel revisions.

## 8. Command set

`guix tofu` subcommands (v1, single-stage):

| Command | Purpose |
|---|---|
| `guix tofu eval -f infra.scm` | Evaluate and serialize; print/emit JSON; no builds |
| `guix tofu build -f infra.scm` | As `eval`, plus realize required Guix artifacts (M3) |
| `guix tofu check -f infra.scm` | `tofu init -backend=false` + `tofu validate` |
| `guix tofu plan -f infra.scm` | Dry-run semantics; generate, realize nothing, `tofu plan` |
| `guix tofu apply -f infra.scm` | Realize artifacts, then `tofu apply` |
| `guix tofu output [-f infra.scm] [NAME]` | Read outputs (`tofu output -json` / `-raw`) |
| `guix tofu graph -f infra.scm` | Print the resource/stage dependency graph (later milestone) |

Common options:

- `-f/--file` (default `infrastructure.scm` in the project root);
- `-L/--load-path` (repeatable, Guix convention): directories prepended to
  the load path when evaluating the infrastructure file — this is how
  project and channel modules such as `(hosts rpi3)` become loadable in the
  tofuix session (section 7.1);
- `--tool=tofu|terraform`, `-C`/`--chdir`, `--`;
- pass-through arguments forwarded to the underlying tofu command
  (e.g. `-target`, `-var`). `-L` is consumed by tofuix itself, not
  forwarded.

Example:

```sh
guix tofu plan -L . -L ../spartan-guix/modules -f infrastructure.scm
```

## 9. Working directory and state

Per project (the directory containing the infrastructure file):

```text
<project>/.tofuix/
├── main.tf.json            # generated configuration (recreated each run)
├── terraform.tfstate       # OpenTofu state (tofu-managed)
├── .terraform.lock.hcl     # provider lock file; PRESERVED across runs
└── .terraform/             # provider cache/data dir
```

- The lock file is preserved across regeneration so provider versions stay
  pinned; committing it is recommended.
- State location and backend configuration are tofuix-configuration fields,
  passed through to tofu; tofuix does not manage state beyond pointing tofu at
  the working directory.
- Sensitive values: OpenTofu state may contain credentials regardless of
  `sensitive` flags; tofuix never writes secrets into the Guix store and
  documents that state files require the same protection as today's
  `infra/terraform.tfstate`.

## 10. v2: staged orchestration

The motivating use case (from the transcript): tofu creates SSH keys → the
public key is baked into a Guix system image → the image backs a host created
by a later tofu stage. Some inputs exist only after `apply`, so tofuix v2
introduces **stages**:

- `tofu-stage`: a tofuix configuration with its own working directory and
  OpenTofu state.
- `guix-stage`: a deferred Guix build whose procedure receives resolved
  upstream stage outputs (e.g. the public key) as plain Scheme values.
- `stage-output`/`stage-artifact` references connect stages; downstream stages
  whose inputs are unresolved are reported as **provisional** during planning
  and are not plan-able until upstream stages are applied.

Execution model:

1. Evaluate the full stage graph symbolically (evaluation).
2. `plan`: determine what is known/buildable/plannable; run `tofu plan` where
   inputs are known; mark the rest provisional. Never applies anything to
   resolve outputs.
3. `apply`: execute in dependency order — apply a tofu stage, harvest
   outputs via `tofu output -json`, run deferred Guix builds, regenerate and
   plan/apply downstream stages (realization).
4. **Checkpoints, not atomicity**: each stage's completion is persisted; a
   failure keeps upstream results and marks the deployment incomplete; the
   next `guix tofu apply` resumes after re-verifying state. Approval is
   required at stage boundaries.

## 11. Testing strategy

- Unit tests (SRFI-64, `tests/`): records construction and merge rules;
  expression serialization; serializer output fixtures (golden JSON);
  lowering dispatch with mocked store objects.
- Integration tests: examples run against the `local` Terraform backend and
  providers that need no cloud credentials (e.g. `tls`, `local`).
- Runner: a plain Makefile-based runner is the standard — `make check`
  executes each SRFI-64 suite directly (e.g. `guile -L modules -L tests
  tests/NAME.scm`); `guix test` is not used.
- Manual acceptance per release: `examples/` cover a plain cloud-style
  configuration and a lowered-artifact configuration.

## 12. Distribution and homelab integration

- tofuix is a standalone channel; users add it to their channels (and, once
  published, to `channels-lock.scm`), run `guix pull`, and get `guix tofu`.
- Development uses the submodule checkout plus
  `GUIX_EXTENSIONS_PATH=$PWD/modules`.
- Homelab migration (later, in this repository): re-express `infra/` in
  Scheme, keep using the Guix provider as an ordinary provider, and record
  prerequisites (dev.tfrc provider override, SOPS, signing keys) in
  `infra/README.md` as they apply to tofuix.

## 13. Milestones and acceptance criteria

| Milestone | Deliverable | Acceptance |
|---|---|---|
| **M1** — DSL + serializer | `(tofuix records|expressions|serializer)` with constructor macros, unit tests, example config | Example Scheme serializes to byte-exact expected JSON; constructor macros expand to the same `tofu-`-prefixed records as the programmatic API; `attribute` chains and `ref` escapes serialize correctly; duplicate resources error |
| **M2** — Extension + lifecycle | `guix tofu` entry point, working dir, `eval`/`check`/`plan`/`apply`/`output`, lock preservation | `tls` example plans and applies through `guix tofu`; lock file survives regeneration; `--tool=terraform` works |
| **M3** — Guix-value lowering | `lower.scm`, `build` command, package definitions | File-like/package/image arguments plan without realizing; apply builds and embeds exact paths; tool resolution PATH→package fallback works |
| **M4** — Staged orchestration (v2) | stages, deferred outputs, checkpoints, resumable apply | Transcript use case: tofu-generated SSH key → Guix image → tofu host, resumable across an injected failure |

## 14. Settled design decisions

All questions raised during planning are resolved:

| Decision | Resolution |
|---|---|
| v2 stage naming | `tofu-stage` for tofu configurations with their own working directory/state; `guix-stage` for deferred Guix builds |
| Packaging `terraform` | No; `opentofu` is packaged as the default tool. When `--tool=terraform` is selected, the binary must be on `PATH` |
| Test runner | Plain Makefile-based runner (`make check` runs each SRFI-64 suite directly); no `guix test` dependency |
| Provider-side secret flows | Out of scope. `guix secrets image`/`guix secrets deploy` and similar stay with the provider; tofuix only generates Terraform JSON and runs the selected tool |
| Pinned-channel evaluation | No `guix time-machine` wrapper inside the extension. `-L/--load-path` covers project modules; users wrap the whole invocation (`guix time-machine -C channels-lock.scm -- guix tofu ...`) when they need evaluation at pinned channel revisions |
