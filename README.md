# Rust builder image

test

This is an image to build applications based on Rust. As Rust versions are backwards compatible, we only have
the `latest` version available.

## Adding a new version

Rust guarantees to build the next version with the current one. We start with the RHEL provided Rust version and
incrementally build up to the most recent released version.

* Add the source tarball to `artifacts.lock.yaml`
* Add the new version to the list of build instructions:

  ```diff
   RUN ./build.sh 1.89.0 1.90.0
  +RUN ./build.sh 1.90.0 1.91.0
  ```
* Change the version in the last stage:
  
  ```diff
  -ARG RUST_VERSION=1.90.0
  +ARG RUST_VERSION=1.91.0
  ```

## Rebase RHEL Rust version

When RHEL updates its Rust version, it is possible to remove older Rust versions. For example, should RHEL upgrade from
`1.85.0` to `1.87.0`:

```diff
-RUN ./build.sh 1.85.0
-RUN ./build.sh 1.85.0 1.86.0
-RUN ./build.sh 1.86.0 1.87.0
-RUN ./build.sh 1.87.0 1.88.0
+RUN ./build.sh 1.88.0
RUN ./build.sh 1.88.0 1.89.0
RUN ./build.sh 1.89.0 1.90.0
```

## Refreshing RPM dependencies

You will need:

* An installation
  of [rpm-lockfile-prototype](https://github.com/konflux-ci/rpm-lockfile-prototype?tab=readme-ov-file#installation)

Then run:

```bash
# UBI9
rpm-lockfile-prototype --image registry.access.redhat.com/ubi9/ubi:latest ubi9/rpms.in.yaml

# UBI10
rpm-lockfile-prototype --image registry.access.redhat.com/ubi10/ubi:latest ubi10/rpms.in.yaml
```

## Consuming

The builder image has `cargo` in its path. It can be used to build applications right away.

It is also possible to copy the toolchain over to another container, using:

```Dockerfile
FROM registry.access.redhat.com/ubi10/ubi:latest

COPY --from=quay.io/konflux-ci/rust-builder:latest /usr/local/share/rust /usr/local/share/rust

ENV PATH=$PATH:/usr/local/share/rust/bin
```
