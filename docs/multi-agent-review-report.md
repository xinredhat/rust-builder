# Multi-Agent Code Review Report: `tc-5149` Dual UBI9/UBI10 Build

| Field | Value |
|-------|-------|
| **Branch** | `tc-5149` (7 commits ahead of main) |
| **Reviewers** | Claude Code (bugs/security/correctness), Antigravity CLI (architecture/design) |
| **Rounds** | 3 (initial review → fixes → re-review → fixes → final review) |
| **Date** | 2026-07-18 |
| **Docs consulted** | [Konflux prefetch docs](https://konflux-ci.dev/docs/building/prefetching-dependencies/), [RHEL 10 Rust Toolset docs](https://docs.redhat.com/en/documentation/red_hat_developer_tools/1/html-single/using_rust_1.88.0_toolset/index), [UBI content article](https://access.redhat.com/articles/4238681) |

---

## Executive Summary

The branch adds dual UBI9/UBI10 container image builds for the Rust toolchain builder. After 3 review rounds and multiple fix iterations, the **UBI9 pipeline is functional** but the **UBI10 pipeline has 3 independent failure paths** that prevent it from producing a working image. None are design flaws — they are missing implementation pieces that the existing docs (`ubi10-build-failure-investigation.md`, `dual-image-build-plan.md`) already identified but haven't been fully executed.

---

## Current Architecture

```
Containerfile.ubi9      # hardcoded FROM ubi9/ubi:latest — used by ubi9 pipelines
Containerfile.ubi10     # hardcoded FROM ubi10/ubi:latest — used by ubi10 pipelines

.tekton/
  rust-builder-ubi9-pull-request.yaml   # hermetic, prefetch-input (generic "." + rpm "ubi9")
  rust-builder-ubi9-push.yaml           # hermetic, prefetch-input (generic "." + rpm "ubi9")
  rust-builder-ubi10-pull-request.yaml  # hermetic, prefetch-input (generic "." + rpm "ubi10")
  rust-builder-ubi10-push.yaml          # hermetic, prefetch-input (generic "." + rpm "ubi10")

ubi9/                    # UBI9 RPM config (symmetric with ubi10/)
  rpms.in.yaml           #   package list, references ./ubi.repo
  rpms.lock.yaml         #   resolved lockfile (el9 packages)
  ubi.repo               #   ubi-9-for-* repos

ubi10/                   # UBI10 RPM config
  rpms.in.yaml           #   package list, references ./ubi.repo
  rpms.lock.yaml         #   (pending MintMaker generation)
  ubi.repo               #   ubi-10-for-* repos
```

---

## Critical Issues (3) — UBI10 Build Non-Functional

### C1. ~~Missing cachi2 prefetch artifacts — build.sh will crash~~ **RESOLVED**

| Field | Detail |
|-------|--------|
| **Source** | Both reviewers (Round 3) |
| **Status** | **Fixed** — added generic-only `prefetch-input` to both UBI10 pipelines |

> `build.sh` unconditionally reads Rust source tarballs from `/cachi2/output/deps/generic/rustc-$TO-src.tar.xz`. This path is only populated when `prefetch-input` includes `{"type": "generic", "path": "."}`. The UBI10 pipelines have **no `prefetch-input`** — the directory won't exist. `set -ex` kills the script.
>
> There is NO internet fallback in `build.sh`. Even with `hermetic: "false"` (network available), the build still fails.

**Fix:** Add generic-only `prefetch-input` to both UBI10 pipelines (omit `"type": "rpm"` to avoid the lockfile mismatch). This is a YAML-only change:

```yaml
- name: prefetch-input
  value: |
    [
      {
        "type": "generic",
        "path": "."
      }
    ]
```

---

### C2. ~~Bootstrap Rust version gap — compilation will fail~~ **RESOLVED**

| Field | Detail |
|-------|--------|
| **Source** | Claude (Round 3), verified via [RHEL 10 Rust Toolset docs](https://docs.redhat.com/en/documentation/red_hat_developer_tools/1/html-single/using_rust_1.88.0_toolset/index) |
| **Status** | **Fixed** — added 4 intermediate build steps (1.89→1.90→1.91→1.92) to `Containerfile.ubi10` before the 1.93.1 entry point. Tarballs already present in `artifacts.lock.yaml`. |

> The build chain starts with `./build.sh 1.93.1` (single arg = use system `rustc` as bootstrap). Rust's build system requires approximately version N-1 for bootstrapping.
>
> - UBI9 ships `rust-1.92.0` → builds 1.93.1 (1-version jump) **OK**
> - ~~UBI10 `:10.0` (RHEL 10.0 GA) ships `rust-1.84.0` → builds 1.93.1 (9-version jump) **FAILS**~~ *(resolved — updated to `:latest`)*
> - UBI10 `:latest` (UBI 10.2) ships `rust-1.88.0` → builds 1.93.1 (5-version jump) **FAILS**

**Key insight:** The "stale" entries in `artifacts.lock.yaml` (Rust 1.89.0 through 1.92.0) are NOT stale — they are **essential for UBI10's extended bootstrap chain**. The earlier suggestion to remove them was incorrect.

**Fix:** Update `Containerfile.ubi10` to include intermediate build steps:

```dockerfile
# If using :latest (rust 1.88.0):
RUN ./build.sh 1.89.0
RUN ./build.sh 1.89.0 1.90.0
RUN ./build.sh 1.90.0 1.91.0
RUN ./build.sh 1.91.0 1.92.0
RUN ./build.sh 1.92.0 1.93.1
RUN ./build.sh 1.93.1 1.94.1
RUN ./build.sh 1.94.1 1.95.0
RUN ./build.sh 1.95.0 1.96.0
RUN ./build.sh 1.96.0 1.97.0
```

This also justifies having separate Containerfiles — the build chains must differ between UBI9 and UBI10.

**Also:** Update `Containerfile.ubi10` FROM tag to `:latest` (ships 1.88.0) instead of `:10.0` (ships 1.84.0, would require even more intermediate steps).

---

### C3. ~~No UBI10 RPM lockfile — blocks hermetic builds and Enterprise Contract~~ **IN PROGRESS**

| Field | Detail |
|-------|--------|
| **Source** | Both reviewers (all 3 rounds) |
| **Status** | **Partially fixed** — symmetric `ubi9/` and `ubi10/` directories created with repo configs; all 4 pipelines updated with `hermetic: 'true'` and `prefetch-input` pointing to their respective directories. Remaining: generate `ubi10/rpms.lock.yaml` (push to trigger MintMaker auto-generation, or run `rpm-lockfile-prototype --image ubi10/ubi:latest ubi10/rpms.in.yaml` on a Linux system). |

> The current workaround (dropping hermetic mode) unblocks the build but fails EC policy checks. EC enforces SLSA provenance and `hermetic: "true"` for production images. Non-hermetic images cannot ship.

**Short-term fix (already applied):** Non-hermetic mode with generic-only prefetch (C1 fix).

**Long-term fix:** Create UBI10-specific RPM config per the `ubi10-build-failure-investigation.md` doc:

```
ubi10/
  ubi.repo          # ubi-10-for-* repos
  rpms.in.yaml      # same packages, references ./ubi10/ubi.repo
  rpms.lock.yaml    # generated via rpm-lockfile-prototype --image ubi10/ubi:latest
```

Update UBI10 pipelines to use full prefetch:

```yaml
- name: hermetic
  value: 'true'
- name: prefetch-input
  value: |
    [
      {"type": "generic", "path": "."},
      {"type": "rpm", "path": "ubi10"}
    ]
```

---

## Warnings (5) — Must Fix Before Production Merge

### W1. Test tenant artifacts hardcoded in all pipeline files

| Item | Current (test) | Production |
|------|---------------|------------|
| CEL target_branch | `tc-5149-xjiangplnsvc-tenant` | `main` |
| namespace | `xjiangplnsvc-tenant` | production tenant |
| repo annotation | `xinredhat/rust-builder` | `konflux-ci/rust-builder` |
| output-image path | `xjiangplnsvc-tenant/...` | production tenant path |

**Files:** All 4 `.tekton/*.yaml`

---

### W2. ~~`python` may not resolve on UBI10 — use `python3`~~ **RESOLVED**

> Changed `python` → `python3` in `build.sh`, `Containerfile.ubi9`, `Containerfile.ubi10`, `ubi9/rpms.in.yaml`, and `ubi10/rpms.in.yaml`. Backward-compatible with UBI9.

---

### W3. ~~Original `Containerfile` is dead code~~ **RESOLVED**

> Removed `Containerfile`. All pipelines use `Containerfile.ubi9` or `Containerfile.ubi10`.

---

### W4. ~~UBI10 `:10.0` tag is pinned to GA release~~ **RESOLVED**

> `:latest` now resolves to UBI **10.2** (verified via `skopeo inspect`). `Containerfile.ubi10` updated to use `:latest`, which ships `rust-1.88.0` and reduces the bootstrap chain to 4 intermediate steps (vs 8 with `:10.0`).

---

### W5. ~~Asymmetric RPM config layout~~ **RESOLVED**

> UBI9 RPM config (`rpms.in.yaml`, `rpms.lock.yaml`, `ubi.repo`) lived at the repo root while UBI10's was in `ubi10/`. The implicit "root = UBI9" convention was not obvious and would cause confusion when adding future UBI versions (UBI11, etc.).

**Fix applied:** Moved UBI9 config into `ubi9/` for symmetry. Updated UBI9 pipeline `prefetch-input` paths from `"."` to `"ubi9"`. Updated `README.md` lockfile refresh commands. Both variants now follow the same `ubi{version}/` pattern, making the repo self-documenting and the per-version lockfile refresh process uniform.

---

### W6. ~~Containerfile duplication across UBI9/UBI10~~ **RESOLVED**

> Files now legitimately differ in 3 areas: base image, bootstrap chain (UBI10 needs 4 extra steps from rust 1.88→1.92), and RPM lockfile directory. Added a comment at the top of each Containerfile explaining why separate files are needed.

---

## Suggestions (3) — Non-Blocking

### S1. Remove unused `mkdir /usr/local/lib/rust`

> All Containerfiles create `/usr/local/lib/rust` (line 30) but the Rust installation goes to `/usr/local/share/rust`. Pre-existing issue.

### S2. ~2,200 lines of duplicated pipeline YAML

> The `pipelineSpec` body is identical across all 4 pipeline files (~535 lines each). This is inherent to Konflux's inline pipelineSpec model. Consider extracting to a shared Pipeline bundle via `pipelineRef` in the future (documented in `dual-image-build-plan.md` as follow-up item #1).

### S3. Source image provenance incomplete for UBI10

> UBI10 push pipeline sets `build-source-image: "true"` but without prefetch, the source image won't contain Rust tarballs. Either add prefetch (C1 fix) or set `build-source-image: "false"` until prefetch works.

---

## Fix Implementation Order

| Step | Fix | Effort | Unblocks |
|------|-----|--------|----------|
| ~~1~~ | ~~Update `Containerfile.ubi10` FROM to `:latest`~~ | ~~Trivial~~ | ~~C2~~ **Done** |
| ~~2~~ | ~~Add generic-only `prefetch-input` to UBI10 pipelines~~ | ~~Trivial~~| ~~C1~~ **Done** |
| ~~3~~ | ~~Extend UBI10 build chain (1.89→...→1.97)~~ | ~~Small~~ | ~~C2~~ **Done** |
| ~~4~~ | ~~`python` → `python3` in build.sh, Containerfiles, rpms.in.yaml~~ | ~~Small~~ | ~~W2~~ **Done** |
| ~~5~~ | ~~Remove dead `Containerfile`~~ | ~~Trivial~~ | ~~W3~~ **Done** |
| ~~6~~ | ~~Create `ubi10/` RPM lockfile + re-enable hermetic~~ | ~~Medium~~ | ~~C3~~ **Partial** — config + pipelines done, lockfile generation pending |
| 7 | Revert test tenant → production values | Small | W1 (merge gate) |

Steps 1-5 make UBI10 **functionally buildable**.
Step 6 makes it **EC-compliant for production release**.
Step 7 is the **merge gate**.

---

## Review Convergence Across 3 Rounds

| Finding | Round 1 | Round 2 | Round 3 | Status |
|---------|---------|---------|---------|--------|
| Triple-trigger (3 pipeline sets) | Critical | — | — | **Fixed** (R1→R2) |
| Containerfile symlinks/defaults | Critical | — | — | **Fixed** (R1→R2) |
| No explicit build-args for UBI9 | Warning | Fixed | Removed (hardcoded) | **Resolved** |
| Shared RPM lockfile | Critical | Critical | Critical (C3) | **Partial** (config done, lockfile pending) |
| Missing cachi2 tarballs | — | — | Critical (C1) | **New** (caused by hermetic removal) |
| Bootstrap version gap | — | Warning | Critical (C2) | **Escalated** (verified via RHEL docs) |
| Test tenant artifacts | Warning | Warning | Warning (W1) | **Persistent** (expected for test branch) |
| `python` vs `python3` | Warning | Warning | Warning (W2) | **Fixed** |
| Pipeline YAML duplication | Suggestion | Suggestion | Suggestion (S2) | **Accepted** (Konflux constraint) |
| Dead `Containerfile` | — | — | Warning (W3) | **Fixed** (removed) |
| UBI10 `:10.0` tag | — | Critical | Warning (W4) | **Downgraded** (valid tag, but not ideal) |

---

## Reviewer Agreement Summary

| Finding | Claude | Antigravity | Agreement |
|---------|--------|-------------|-----------|
| Missing cachi2 prefetch (C1) | Critical | Critical | **Full** |
| Bootstrap version gap (C2) | Critical | Not flagged | Claude unique — deeper build chain analysis |
| EC compliance (C3) | Not flagged | Critical | Antigravity unique — release policy expertise |
| Generic-only prefetch fix | Mentioned as option | **Recommended as Option A** | Antigravity provided concrete fix path |
| Test tenant artifacts (W1) | Warning | Warning | **Full** |
| `python` → `python3` (W2) | Warning | Suggestion | Claude escalated (correctly) |
| Dead Containerfile (W3) | Warning | Critical | Both flagged, Antigravity escalated |
| Pipeline duplication (S2) | Suggestion | Warning | Different severity, same finding |

---

## Appendix: RHEL Rust Version Reference

| Base Image | Rust Version | Bootstrap Gap to 1.93.1 | Intermediate Steps Needed |
|------------|-------------|------------------------|--------------------------|
| UBI9 `:latest` | 1.92.0 | 1 version | 0 (direct: 1.92→1.93.1) |
| ~~UBI10 `:10.0`~~ | ~~1.84.0~~ | ~~9 versions~~ | ~~8 (1.85→1.86→...→1.93.1)~~ *(no longer used)* |
| UBI10 `:latest` (10.2) | 1.88.0 | 5 versions | 4 (1.89→1.90→1.91→1.92→1.93.1) |

Source: [Red Hat Developer Tools — Using Rust 1.88.0 Toolset](https://docs.redhat.com/en/documentation/red_hat_developer_tools/1/html-single/using_rust_1.88.0_toolset/index), [RHEL 10 Considerations — Compilers and Development Tools](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/considerations_in_adopting_rhel_10/compilers-and-development-tools)
