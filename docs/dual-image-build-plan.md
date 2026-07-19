# Dual Image Build (ubi9 + ubi10) in Konflux

## Context

The [`rust-builder`](https://github.com/konflux-ci/rust-builder) repo builds multi-arch container images providing Rust toolchains. The requirement is to build **two images** from the same repo using different base images (UBI9 and UBI10), and release them to separate repositories.

---

## Design Decisions & Implementation Journey

This section documents the approaches explored, what failed, what we learned, and why the current architecture was chosen. It serves as a decision log for future maintainers.

### Approach 1: Single Containerfile with `ARG BASE_IMAGE` (abandoned)

**Idea:** One `Containerfile` parameterized with `ARG BASE_IMAGE`, both pipelines pass different `build-args`:

```dockerfile
ARG BASE_IMAGE=registry.access.redhat.com/ubi9/ubi:latest
FROM ${BASE_IMAGE} AS builder
```

**Why it failed:** Konflux hermetic builds use `rpms.lock.yaml` to prefetch RPMs. The lockfile is generated against a specific base image — UBI9 lockfile contains `el9` packages, UBI10 needs `el10` packages. With a shared Containerfile, both pipelines point to the same `prefetch-input` path, so the UBI10 build tried to install `el9` RPMs onto a `el10` base. The actual error was:

```
vim-data-2:9.1.083-9.el10_2.7 (installed) conflicts with vim-filesystem (el9)
crypto-policies-20260216-1.el10 (installed) conflicts with openssh (el9)
nothing provides libgomp = 11.5.0-14.el9 needed by gcc (el9)
```

**Lesson:** When base images differ at the OS version level, hermetic build infrastructure (RPM repos, lockfiles, prefetch paths) must be separated per variant. A single Containerfile with `build-args` works for simple parameterization but breaks when the prefetch pipeline can't distinguish which lockfile to use.

### Approach 2: Containerfile symlinks (abandoned)

**Idea:** `Containerfile.ubi9` and `Containerfile.ubi10` as symlinks to `Containerfile`, avoiding duplication:

```
Containerfile.ubi9  -> Containerfile  (git mode 120000)
Containerfile.ubi10 -> Containerfile  (git mode 120000)
```

**Why it failed:** Symlinks point to the same file, so there's no way to differentiate the build content. The `Containerfile.ubi10` name suggested UBI10 but its content (via symlink) defaulted to UBI9. Additionally, symlinks can fail in strict build environments or Windows checkouts.

**Lesson:** If two variants need any content differentiation (even comments), use real files.

### Approach 3: Drop hermetic mode for UBI10 (temporary workaround, superseded)

**Idea:** Remove `hermetic: 'true'` and `prefetch-input` entirely from UBI10 pipelines, letting `dnf` use the network.

**Why it was superseded:** This unblocked the build initially but had two problems:
1. `build.sh` reads Rust source tarballs from `/cachi2/output/deps/generic/` — this path is only populated by cachi2 prefetch. Without `prefetch-input`, the tarballs weren't there, and `build.sh` crashed at `tar xaf /cachi2/output/deps/generic/rustc-$TO-src.tar.xz`.
2. Enterprise Contract (EC) release policies enforce `hermetic: "true"` and SLSA provenance. Non-hermetic images cannot be promoted to production registries.

**Lesson:** Even when dropping RPM hermeticity, the `generic` prefetch (for source tarballs) is still needed because `build.sh` has a hard dependency on the cachi2 output path. The fix was generic-only prefetch (without rpm) as a transitional step.

### Approach 4 (current): Separate Containerfiles + symmetric RPM directories

**Final design:** Two real Containerfiles with hardcoded base images, two RPM config directories (`ubi9/`, `ubi10/`), both pipelines fully hermetic.

This approach emerged from the constraints discovered above:
- Separate Containerfiles: needed because RPM lockfile paths differ
- Symmetric `ubi9/` and `ubi10/` directories: clean layout, MintMaker auto-detects both
- Both hermetic: EC-compliant for production release

---

### Key Discoveries During Implementation

#### UBI10 `:latest` ships `rust-1.92.0` (same as UBI9)

Initial web research indicated RHEL 10 shipped `rust-1.88.0`, which would require 4 intermediate bootstrap steps (1.89→1.90→1.91→1.92) before reaching the 1.93.1 entry point. We implemented these steps but then discovered — via the actual `rpms.lock.yaml` generation — that UBI10 `:latest` (version 10.2) ships `cargo-1.92.0-1.el10`. The build chains are identical between UBI9 and UBI10.

**Lesson:** Don't trust web search for package versions — verify against the actual image. The `rpms.lock.yaml` generation resolved the authoritative version.

#### UBI10 `:10.0` tag is outdated (`:latest` = 10.2)

The initial implementation used `ubi10/ubi:10.0`. Registry inspection via `skopeo` revealed:
- `:10.0` — RHEL 10.0 GA, ships `rust-1.84.0`, no longer receives latest security patches
- `:10.1` — available but also superseded
- `:latest` — resolves to **10.2** (confirmed via `skopeo inspect`), ships `rust-1.92.0`

Using `:latest` is consistent with the UBI9 pattern and avoids maintaining version-specific bootstrap chains.

#### The "stale" tarballs in `artifacts.lock.yaml` (1.89–1.92) are not stale

Earlier reviews flagged `rustc-1.89.0-src.tar.xz` through `rustc-1.92.0-src.tar.xz` in `artifacts.lock.yaml` as unused (UBI9's build chain starts at 1.93.1). However, these would be needed if UBI10 ever ships a lower Rust version than UBI9, requiring intermediate bootstrap steps. They remain as safety margin and should not be removed.

#### `python` package may not resolve on UBI10

UBI10 uses `dnf5` and the `python` virtual package may not resolve. All references were changed to `python3` (in `build.sh`, both Containerfiles, and both `rpms.in.yaml` files). `python3` is available on both UBI9 and UBI10.

#### `rpm-lockfile-prototype` requires Linux

The lockfile generation tool depends on `python3-dnf` (Linux-only). On macOS, run it inside a UBI container via podman (documented below in the RPM Lockfile section).

#### MintMaker `DependencyUpdateCheck` requires cluster permissions

Manually triggering MintMaker requires creating a `DependencyUpdateCheck` CR, which needs `appstudio.redhat.com` API group access that standard users may not have. Alternative: generate the lockfile locally via podman and commit directly.

---

### Multi-Agent Review Process

The codebase was reviewed across 3 rounds using two independent reviewers:
- **Claude Code** — focused on bugs, security, correctness, edge cases, build chain analysis
- **Antigravity CLI** — focused on architecture, design patterns, maintainability, EC compliance

Key findings by reviewer:

| Finding | Discovered by | Round |
|---------|--------------|-------|
| RPM lockfile mismatch (el9 on el10) | Both | 1 |
| Triple-trigger (3 pipeline sets) | Both | 1 |
| Enterprise Contract blocks non-hermetic | Antigravity | 3 |
| Missing cachi2 tarballs (build.sh crash) | Both | 3 |
| Bootstrap Rust version gap | Claude | 2–3 |
| `python` → `python3` | Claude | 1–3 |
| Pipeline YAML duplication (~2,200 lines) | Both | 1–3 |

Full review report: [`docs/multi-agent-review-report.md`](multi-agent-review-report.md)

---

## Architecture

### Build Configuration (Source Repo Side)

#### Separate Containerfiles per UBI Version

Each UBI version has its own Containerfile with a hardcoded base image. Both share the same build chain (UBI9 and UBI10 `:latest` both ship `rust-1.92.0`):

- `Containerfile.ubi9` — `FROM registry.access.redhat.com/ubi9/ubi:latest`
- `Containerfile.ubi10` — `FROM registry.access.redhat.com/ubi10/ubi:latest`

Separate files are required because each version needs its own RPM lockfile directory for hermetic builds (`ubi9/` vs `ubi10/`). The build logic is otherwise identical.

#### RPM Lockfile Directories (Symmetric Layout)

Each UBI version has its own RPM configuration in a versioned subdirectory:

```
ubi9/
  rpms.in.yaml      # package list, references ./ubi.repo
  rpms.lock.yaml     # resolved lockfile (el9 packages)
  ubi.repo           # ubi-9-for-* repos

ubi10/
  rpms.in.yaml      # package list, references ./ubi.repo
  rpms.lock.yaml     # resolved lockfile (el10 packages)
  ubi.repo           # ubi-10-for-* repos
```

MintMaker auto-detects `rpms.in.yaml` files in both directories and refreshes the lockfiles via PRs.

To manually refresh (requires [rpm-lockfile-prototype](https://github.com/konflux-ci/rpm-lockfile-prototype) on a Linux system with `python3-dnf`):

```bash
# UBI9
rpm-lockfile-prototype --image registry.access.redhat.com/ubi9/ubi:latest ubi9/rpms.in.yaml

# UBI10
rpm-lockfile-prototype --image registry.access.redhat.com/ubi10/ubi:latest ubi10/rpms.in.yaml
```

**How `rpm-lockfile-prototype` works:**

1. Pulls the base image manifest for all architectures (amd64, arm64, ppc64le, s390x)
2. Reads the RPM database from each architecture's image layer to find **pre-installed** packages
3. Reads `rpms.in.yaml` for desired packages and repo config (`ubi.repo`)
4. Runs `dnf` dependency resolution: desired packages minus already-installed = what needs downloading
5. Writes `rpms.lock.yaml` with exact URLs, checksums, and versions for every resolved RPM

The lockfile tells cachi2/Hermeto exactly which RPMs to prefetch so the hermetic build can run `dnf install` without network access.

**On macOS** (no `python3-dnf`), run inside a UBI container:

```bash
podman run --rm -v $(pwd)/ubi10:/work:Z registry.access.redhat.com/ubi10/ubi:latest bash -c "
  dnf install -y python3 python3-pip python3-dnf skopeo &&
  pip3 install --break-system-packages \
    https://github.com/konflux-ci/rpm-lockfile-prototype/archive/refs/heads/main.zip &&
  cd /work &&
  rpm-lockfile-prototype --image registry.access.redhat.com/ubi10/ubi:latest rpms.in.yaml
"
```

#### Tekton Pipeline & PipelineRun Definitions

Five files in `.tekton/`:

- `rust-builder-pipeline.yaml` — shared Pipeline definition (~537 lines, all tasks defined once)
- `rust-builder-ubi9-pull-request.yaml` / `rust-builder-ubi9-push.yaml` — lightweight PipelineRuns (~62 lines each)
- `rust-builder-ubi10-pull-request.yaml` / `rust-builder-ubi10-push.yaml` — lightweight PipelineRuns (~62 lines each)

Each PipelineRun references the shared Pipeline via `pipelineRef: name: rust-builder-pipeline` and only specifies variant-specific params. Pipelines-as-Code pre-parses Pipeline resources in `.tekton/` and resolves `pipelineRef` locally.

Key fields per PipelineRun variant:

| Field | ubi9 | ubi10 |
|-------|------|-------|
| `component` label | `rust-builder-ubi9` | `rust-builder-ubi10` |
| `application` label | `rust-builder` (shared) | `rust-builder` (shared) |
| `pipelineRef` | `rust-builder-pipeline` | `rust-builder-pipeline` |
| `dockerfile` | `Containerfile.ubi9` | `Containerfile.ubi10` |
| `hermetic` | `'true'` | `'true'` |
| `prefetch-input` (generic) | `"path": "."` | `"path": "."` |
| `prefetch-input` (rpm) | `"path": "ubi9"` | `"path": "ubi10"` |
| `output-image` | `.../rust-builder-ubi9:...` | `.../rust-builder-ubi10:...` |
| `serviceAccountName` | `build-pipeline-rust-builder-ubi9` | `build-pipeline-rust-builder-ubi10` |

#### Rebuild Scope: Always Rebuild Both — Do NOT Use CEL Filtering

Both components share the same source code and Containerfile structure, so any commit affects both images. Both components always rebuild on every commit. No CEL filtering.

---

### Integration Testing Configuration

When a Component build completes, the Integration Service creates a **Snapshot** containing all Components of the Application. The IntegrationTestScenario (ITS) runs against this Snapshot.

#### Enterprise Contract ITS (application context)

One enterprise-contract ITS with `application` context covers both components:

```yaml
apiVersion: appstudio.redhat.com/v1beta2
kind: IntegrationTestScenario
metadata:
  annotations:
    test.appstudio.openshift.io/kind: enterprise-contract
  name: rust-builder-enterprise-contract
  namespace: <tenant>
spec:
  application: rust-builder
  contexts:
    - name: application
      description: Application testing
  resolverRef:
    params:
      - name: url
        value: https://github.com/konflux-ci/build-definitions
      - name: revision
        value: main
      - name: pathInRepo
        value: pipelines/enterprise-contract.yaml
    resolver: git
    resourceKind: pipeline
```

---

### Release Configuration (konflux-release-data Side)

#### RPA: Dual-Component Mapping

The `rust-builder-dual.yaml` RPA maps both components to their respective registries:

```yaml
apiVersion: appstudio.redhat.com/v1alpha1
kind: ReleasePlanAdmission
metadata:
  labels:
    release.appstudio.openshift.io/block-releases: 'false'
  name: rust-builder-dual
  namespace: rhtap-releng-tenant
spec:
  applications:
    - rust-builder
  policy: registry-rust-sig-prod
  origin: rust-sig-tenant
  data:
    mapping:
      components:
        - name: rust-builder-ubi9
          repositories:
            - url: "registry.redhat.io/rust-builder-image/rust-rhel9"
              tags:
                - latest
                - "{{ git_sha }}"
                - "{{ digest_sha }}"
                - "{{ labels.version }}"
                - "{{ labels.version }}-{{ timestamp }}"
          public: false
        - name: rust-builder-ubi10
          repositories:
            - url: "registry.redhat.io/rust-builder-image/rust-rhel10"
              tags:
                - latest
                - "{{ git_sha }}"
                - "{{ digest_sha }}"
                - "{{ labels.version }}"
                - "{{ labels.version }}-{{ timestamp }}"
          public: false
      defaults:
        pushSourceContainer: true
    intention: production
  pipeline:
    pipelineRef:
      resolver: git
      params:
        - name: url
          value: "https://github.com/konflux-ci/release-service-catalog.git"
        - name: revision
          value: production
        - name: pathInRepo
          value: "pipelines/managed/rh-push-to-registry-redhat-io/rh-push-to-registry-redhat-io.yaml"
    serviceAccountName: release-registry-prod
    timeouts:
      pipeline: "1h15m0s"
      tasks: 1h15m0s
```

The old `rust-builder.yaml` RPA must have `block-releases: 'true'` to prevent conflicting registry pushes. Both images release together as a single Application Snapshot.

---

## Architecture Diagram

```
rust-builder repo (GitHub)
  |
  |-- Containerfile.ubi9        # hardcoded FROM ubi9/ubi:latest
  |-- Containerfile.ubi10       # hardcoded FROM ubi10/ubi:latest
  |-- ubi9/                     # RPM config (rpms.in.yaml, rpms.lock.yaml, ubi.repo)
  |-- ubi10/                    # RPM config (rpms.in.yaml, rpms.lock.yaml, ubi.repo)
  |-- .tekton/
        |-- rust-builder-pipeline.yaml            # shared Pipeline (tasks defined once)
        |-- rust-builder-ubi9-pull-request.yaml   # lightweight PipelineRun (pipelineRef)
        |-- rust-builder-ubi9-push.yaml           # lightweight PipelineRun (pipelineRef)
        |-- rust-builder-ubi10-pull-request.yaml  # lightweight PipelineRun (pipelineRef)
        |-- rust-builder-ubi10-push.yaml          # lightweight PipelineRun (pipelineRef)

PR opened
  |
  +--> Component: rust-builder-ubi9   --> Build Pipeline --> quay.io/<org>/rust-builder-ubi9
  |
  +--> Component: rust-builder-ubi10  --> Build Pipeline --> quay.io/<org>/rust-builder-ubi10
  |
  +--> Group Snapshot (both builds) --> IntegrationTest

PR merged
  |
  +--> Both builds (no CEL filter) --> Snapshot
  |
  +--> Atomic Release (via RPA mapping)
         |
         +--> rust-builder-ubi9  --> registry.redhat.io/rust-builder-image/rust-rhel9
         +--> rust-builder-ubi10 --> registry.redhat.io/rust-builder-image/rust-rhel10
```

---

## Reference Material

| Resource | Link |
|----------|------|
| Sample multi-component repo | [olm-operator-konflux-sample](https://github.com/konflux-ci/olm-operator-konflux-sample) |
| Monorepo guide | [Managing Monorepo Applications](https://konflux-ci.dev/docs/patterns/managing-monorepo-applications/) |
| Config-as-code | [Configuration as Code](https://konflux-ci.dev/docs/building/configuration-as-code/) |
| Release plans | [Creating a Release Plan](https://konflux-ci.dev/docs/releasing/create-release-plan/) |
| Centralized pipelines | [Centralizing Pipeline Definitions](https://konflux-ci.dev/docs/patterns/centralize-pipeline-definitions/) |
| Group testing contexts | [Choosing Contexts](https://konflux-ci.dev/docs/testing/integration/choosing-contexts/) |
| RPM lockfile docs | [MintMaker RPM Lockfiles](https://konflux-ci.dev/docs/mintmaker/rpm-lockfile/) |

---

## What Was Done (Summary of Changes)

| Change | Files | Why |
|--------|-------|-----|
| Separate Containerfiles with hardcoded base images | `Containerfile.ubi9`, `Containerfile.ubi10` | RPM lockfiles differ per OS; single parameterized Containerfile can't separate prefetch paths |
| Removed original `Containerfile` | deleted | Dead code — no pipeline referenced it |
| Symmetric RPM config directories | `ubi9/`, `ubi10/` | Each UBI version needs its own lockfile; symmetric layout is self-documenting |
| Generated UBI10 RPM lockfile | `ubi10/rpms.lock.yaml` | Required for hermetic builds and EC compliance |
| Enabled hermetic mode on UBI10 | `.tekton/rust-builder-ubi10-*.yaml` | EC requires `hermetic: "true"` for production releases |
| Updated UBI10 base image to `:latest` | `Containerfile.ubi10` | `:10.0` was outdated (10.0 GA); `:latest` = 10.2 with `rust-1.92.0` |
| Changed `python` → `python3` | `build.sh`, both Containerfiles, both `rpms.in.yaml` | UBI10 may not provide unversioned `python` package |
| Renamed original pipelines to `ubi9` | `.tekton/rust-builder-ubi9-*.yaml` | Eliminated triple-trigger (3 pipeline sets firing on same event) |
| Added prefetch-input (generic + rpm) per variant | `.tekton/*.yaml` | `build.sh` requires cachi2 tarballs at `/cachi2/output/deps/generic/`; RPM prefetch uses versioned path |
| Extracted shared Pipeline from inline pipelineSpec | `.tekton/rust-builder-pipeline.yaml` | Eliminated ~2,200 lines of duplication; 4 PipelineRuns now use `pipelineRef` (~62 lines each) |

---

## Follow-up Items

1. ~~**Reduce PipelineRun duplication**~~ **Done** — extracted shared Pipeline to `.tekton/rust-builder-pipeline.yaml`, PipelineRuns use `pipelineRef` (2,370 → 783 lines, 67% reduction)
2. **Add IntegrationTestScenario** — group snapshot test (PR phase) and EC check (post-merge)
3. **Clean up orphan component** — delete or deprecate the old `rust-builder` component in Konflux if no longer needed
4. **Production tenant migration** — update namespace, CEL triggers, repo URL, and output-image paths from test tenant (`xjiangplnsvc-tenant`) to production (`rust-sig-tenant`)
5. **Remove unused `mkdir /usr/local/lib/rust`** — present in both Containerfiles but Rust installs to `/usr/local/share/rust` (pre-existing issue)

---

## Verification Plan

1. Open a test PR — verify two separate build PipelineRuns trigger (not three)
2. Check both builds complete with hermetic mode (no network access during build)
3. Verify both images push to their respective Quay repositories
4. Verify group Snapshot is created during PR testing
5. Trigger release — verify both images land in correct target repositories via RPA mapping
6. Confirm old RPA is blocked and does not trigger conflicting releases
