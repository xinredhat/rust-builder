# Implementation Guide: Adding UBI10 Dual Image Build to rust-builder

## Purpose

Step-by-step guide to reproduce the changes from `main` to the current branch. Intended for applying the same pattern to the production repo (`konflux-ci/rust-builder`) or as onboarding documentation.

## Starting Point (main branch)

```
Containerfile                            # single, hardcoded FROM ubi9/ubi:latest
build.sh                                # uses `python ./x.py`
rpms.in.yaml                            # package list, references ./ubi.repo
rpms.lock.yaml                          # resolved UBI9 lockfile
ubi.repo                                # ubi-9-for-* repos
artifacts.lock.yaml                     # Rust source tarballs (generic prefetch)
.tekton/
  rust-builder-pull-request.yaml        # single component, hermetic, prefetch generic+rpm at "."
  rust-builder-push.yaml                # same for push events
```

## End State (current branch)

```
Containerfile.ubi9                       # hardcoded FROM ubi9/ubi:latest
Containerfile.ubi10                      # hardcoded FROM ubi10/ubi:latest
build.sh                                # uses `python3 ./x.py`
artifacts.lock.yaml                     # unchanged
ubi9/
  rpms.in.yaml                          # package list (python3), references ./ubi.repo
  rpms.lock.yaml                        # resolved UBI9 lockfile (moved from root)
  ubi.repo                              # ubi-9-for-* repos (moved from root)
ubi10/
  rpms.in.yaml                          # package list (python3), references ./ubi.repo
  rpms.lock.yaml                        # resolved UBI10 lockfile (generated)
  ubi.repo                              # ubi-10-for-* repos (created)
.tekton/
  rust-builder-pipeline.yaml            # shared Pipeline (~537 lines, tasks defined once)
  rust-builder-ubi9-pull-request.yaml   # lightweight PipelineRun (~62 lines, pipelineRef)
  rust-builder-ubi9-push.yaml           # lightweight PipelineRun (~61 lines, pipelineRef)
  rust-builder-ubi10-pull-request.yaml  # lightweight PipelineRun (~62 lines, pipelineRef)
  rust-builder-ubi10-push.yaml          # lightweight PipelineRun (~61 lines, pipelineRef)
```

---

## Step-by-Step Implementation

### Step 1: Create Containerfile.ubi9

Copy `Containerfile` to `Containerfile.ubi9`. Change `python` to `python3` in both `dnf install` lines. Add a comment at the top explaining why separate files exist.

```diff
+# Separate from Containerfile.ubi10: different base image and RPM lockfile (ubi9/)
 FROM registry.access.redhat.com/ubi9/ubi:latest AS builder
-RUN dnf install ... python ...
+RUN dnf install ... python3 ...
```

### Step 2: Create Containerfile.ubi10

Copy `Containerfile.ubi9` and change both `FROM` lines to `ubi10/ubi:latest`. The build chain is identical — UBI10 `:latest` ships `rust-1.92.0` (same as UBI9), so no intermediate bootstrap steps are needed.

```dockerfile
# Separate from Containerfile.ubi9: different base image and RPM lockfile (ubi10/)
# UBI10 :latest ships rust-1.92.0 (same as UBI9), so the build chain is identical
FROM registry.access.redhat.com/ubi10/ubi:latest AS builder
...
FROM registry.access.redhat.com/ubi10/ubi:latest
```

**Important:** Verify the Rust version in UBI10 before assuming the build chain matches. If UBI10 ships a lower version (e.g., `rust-1.88.0`), add intermediate `build.sh` steps. Check via lockfile generation or `podman run ubi10/ubi:latest rpm -q rust`.

### Step 3: Remove original Containerfile

```bash
git rm Containerfile
```

No pipeline will reference it — both variants use `Containerfile.ubi9` / `Containerfile.ubi10`.

### Step 4: Update build.sh

Change `python` to `python3`:

```diff
-python ./x.py dist
+python3 ./x.py dist
-python ./x.py install
+python3 ./x.py install
```

`python3` works on both UBI9 and UBI10. The unversioned `python` may not resolve on UBI10.

### Step 5: Create symmetric RPM config directories

Move UBI9 RPM files into `ubi9/`:

```bash
mkdir ubi9
git mv rpms.in.yaml ubi9/rpms.in.yaml
git mv rpms.lock.yaml ubi9/rpms.lock.yaml
git mv ubi.repo ubi9/ubi.repo
```

No content changes needed — `rpms.in.yaml` references `"./ubi.repo"` which resolves correctly from within `ubi9/`.

Update `python` to `python3` in `ubi9/rpms.in.yaml`.

### Step 6: Create UBI10 RPM config

Create `ubi10/` directory with three files:

**`ubi10/ubi.repo`** — mirror of `ubi9/ubi.repo` with `ubi9/9` → `ubi10/10` and `ubi-9-for-*` → `ubi-10-for-*`:

```ini
[ubi-10-for-$basearch-baseos-rpms]
baseurl = https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi10/10/$basearch/baseos/os
...
[ubi-10-for-$basearch-appstream-rpms]
baseurl = https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi10/10/$basearch/appstream/os
...
[codeready-builder-for-ubi-10-$basearch-rpms]
baseurl = https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi10/10/$basearch/codeready-builder/os
...
```

Include the same debug/source sections as the UBI9 repo file (debug repos `enabled = 0`, source repos `enabled = 1`).

**`ubi10/rpms.in.yaml`** — same package list as UBI9, references `./ubi.repo`:

```yaml
packages:
  - git
  - python3
  - gcc
  - g++
  - cmake
  - rust
  - cargo
  - ninja-build
  - openssl-devel
  - xz
  - npm
  - clang-devel
contentOrigin:
  repofiles:
    - "./ubi.repo"
arches:
  - aarch64
  - x86_64
  - s390x
  - ppc64le
```

**`ubi10/rpms.lock.yaml`** — generate via `rpm-lockfile-prototype`:

```bash
# On a Linux system with python3-dnf:
rpm-lockfile-prototype --image registry.access.redhat.com/ubi10/ubi:latest ubi10/rpms.in.yaml

# On macOS via podman:
podman run --rm -v $(pwd)/ubi10:/work:Z registry.access.redhat.com/ubi10/ubi:latest bash -c "
  dnf install -y python3 python3-pip python3-dnf skopeo &&
  pip3 install --break-system-packages \
    https://github.com/konflux-ci/rpm-lockfile-prototype/archive/refs/heads/main.zip &&
  cd /work &&
  rpm-lockfile-prototype --image registry.access.redhat.com/ubi10/ubi:latest rpms.in.yaml
"
```

This resolves all RPM dependencies against the UBI10 base image for all 4 architectures and writes the lockfile.

### Step 7: Rename UBI9 pipelines

Rename existing pipeline files to include `ubi9` in the name:

```bash
git mv .tekton/rust-builder-pull-request.yaml .tekton/rust-builder-ubi9-pull-request.yaml
git mv .tekton/rust-builder-push.yaml .tekton/rust-builder-ubi9-push.yaml
```

Update inside both files:
- `metadata.labels.appstudio.openshift.io/component`: `rust-builder` → `rust-builder-ubi9`
- `metadata.name`: `rust-builder-on-pull-request` → `rust-builder-ubi9-on-pull-request`
- `spec.params.output-image`: add `/rust-builder-ubi9` to the path
- `spec.params.dockerfile`: `Containerfile` → `Containerfile.ubi9`
- `prefetch-input` rpm path: `"."` → `"ubi9"`
- `serviceAccountName`: `build-pipeline-rust-builder` → `build-pipeline-rust-builder-ubi9`

### Step 8: Create UBI10 pipelines

Copy the UBI9 pull-request pipeline to create the UBI10 variant:

```bash
cp .tekton/rust-builder-ubi9-pull-request.yaml .tekton/rust-builder-ubi10-pull-request.yaml
cp .tekton/rust-builder-ubi9-push.yaml .tekton/rust-builder-ubi10-push.yaml
```

Update inside both UBI10 files:
- `component` label: `rust-builder-ubi9` → `rust-builder-ubi10`
- `name`: `ubi9` → `ubi10`
- `output-image`: `rust-builder-ubi9` → `rust-builder-ubi10`
- `dockerfile`: `Containerfile.ubi9` → `Containerfile.ubi10`
- `prefetch-input` rpm path: `"ubi9"` → `"ubi10"`
- `serviceAccountName`: `rust-builder-ubi9` → `rust-builder-ubi10`

Both pipelines keep `hermetic: 'true'` and `prefetch-input` with both `generic` (path `.`) and `rpm` (path `ubi10`).

### Step 9: Update README.md

Add UBI10 lockfile refresh command:

```bash
# UBI9
rpm-lockfile-prototype --image registry.access.redhat.com/ubi9/ubi:latest ubi9/rpms.in.yaml

# UBI10
rpm-lockfile-prototype --image registry.access.redhat.com/ubi10/ubi:latest ubi10/rpms.in.yaml
```

### Step 10: Register Konflux Components

Before pipelines can trigger, register two Component CRs in the Konflux tenant:

- **rust-builder-ubi9** — pointing to the repo, component name matching the pipeline label
- **rust-builder-ubi10** — same repo, different component name

Both under the same Application (`rust-builder`). See [`docs/create-app-components-plan.md`](create-app-components-plan.md) for details.

---

## File-by-File Diff Summary

| File | Change | Why |
|------|--------|-----|
| `Containerfile` | **Deleted** | Replaced by version-specific Containerfiles |
| `Containerfile.ubi9` | **New** (from Containerfile) | Hardcoded UBI9 base, `python3`, comment header |
| `Containerfile.ubi10` | **New** | Hardcoded UBI10 base, identical build chain |
| `build.sh` | **Modified** (2 lines) | `python` → `python3` (lines 59, 63) |
| `README.md` | **Modified** (6 lines) | Added UBI10 lockfile refresh command |
| `rpms.in.yaml` | **Moved** → `ubi10/rpms.in.yaml` | Symmetric layout; git detects as rename due to content similarity |
| `rpms.lock.yaml` | **Moved** → `ubi9/rpms.lock.yaml` | Symmetric layout; content unchanged |
| `ubi.repo` | **Moved** → `ubi9/ubi.repo` | Symmetric layout; content unchanged |
| `ubi9/rpms.in.yaml` | **New** | Copy of root rpms.in.yaml with `python` → `python3` |
| `ubi10/rpms.in.yaml` | **New** (git shows as rename) | Same packages, references `./ubi.repo` (UBI10) |
| `ubi10/rpms.lock.yaml` | **New** (5,512 lines) | Generated via `rpm-lockfile-prototype` against UBI10 |
| `ubi10/ubi.repo` | **New** | UBI10 repo definitions (ubi-10-for-* URLs) |
| `.tekton/rust-builder-pull-request.yaml` | **Renamed** → `rust-builder-ubi9-pull-request.yaml` | Component rename + rpm path `"."` → `"ubi9"` |
| `.tekton/rust-builder-push.yaml` | **Renamed** → `rust-builder-ubi9-push.yaml` | Same changes as above |
| `.tekton/rust-builder-ubi10-pull-request.yaml` | **New** (593 lines) | UBI10 component, hermetic, rpm path `"ubi10"` |
| `.tekton/rust-builder-ubi10-push.yaml` | **New** (592 lines) | Same for push events |
| `docs/multi-agent-review-report.md` | **New** | Multi-agent review findings and resolution log |

---

## Prerequisites for Production

Before merging to the production repo (`konflux-ci/rust-builder`), update these test-specific values in all 4 `.tekton/` files:

| Field | Test value | Production value |
|-------|-----------|-----------------|
| CEL `target_branch` | `tc-5149-xjiangplnsvc-tenant` | `main` |
| `namespace` | `xjiangplnsvc-tenant` | `rust-sig-tenant` |
| `repo` annotation | `xinredhat/rust-builder` | `konflux-ci/rust-builder` |
| `output-image` | `xjiangplnsvc-tenant/...` | `rust-sig-tenant/...` |

Also ensure:
- Component CRs `rust-builder-ubi9` and `rust-builder-ubi10` exist in the production tenant
- Service accounts `build-pipeline-rust-builder-ubi9` and `build-pipeline-rust-builder-ubi10` are provisioned
- Old single-component RPA has `block-releases: 'true'`
- New dual-component RPA is created (see [`docs/dual-image-build-plan.md`](dual-image-build-plan.md))

---

## Related Documentation

- [`docs/dual-image-build-plan.md`](dual-image-build-plan.md) — Architecture, design decisions, and full Konflux integration plan
- [`docs/multi-agent-review-report.md`](multi-agent-review-report.md) — 3-round review findings and resolution tracker
- [`docs/ubi10-build-failure-investigation.md`](ubi10-build-failure-investigation.md) — Root cause analysis of UBI10 RPM conflicts
- [`docs/create-app-components-plan.md`](create-app-components-plan.md) — Konflux Application/Component CR creation steps
