# Security and OWASP Alignment

This project packages upstream Goose Desktop for Fedora Asahi. It does not claim formal OWASP certification. The controls below document how the build and release process addresses risks relevant to the OWASP Top 10 and software supply-chain security.

## Supported releases

Only the newest GitHub release is actively maintained. Report vulnerabilities privately through GitHub Security Advisories for this repository. For vulnerabilities in Goose itself, use the upstream Goose security process.

## Build and release controls

- **A01 Broken Access Control:** releases are published through an authenticated GitHub account; build containers run as an unprivileged user.
- **A02 Cryptographic Failures:** each RPM release includes a SHA-256 checksum. Secrets are not embedded in the image, source tree, SPEC, RPM, or provenance file.
- **A03 Injection:** version and release values are derived from trusted project metadata and validated; shell execution uses strict mode and quoted paths.
- **A04 Insecure Design:** upstream source, packaging code, container definition, and generated artifacts are separated. Builds occur in an isolated clean Git worktree.
- **A05 Security Misconfiguration:** the workflow is aarch64-only, fails on dirty upstream source, normalizes unsafe write permissions, and validates RPM metadata and desktop integration.
- **A06 Vulnerable and Outdated Components:** Node dependencies install from the committed pnpm lockfile using `--frozen-lockfile`; Rust uses upstream `Cargo.lock`; the builder uses a supported Fedora release. Dependency updates still require upstream review and periodic rebuilds.
- **A07 Identification and Authentication Failures:** GitHub release publication uses GitHub CLI authentication; credentials are not stored by this repository.
- **A08 Software and Data Integrity Failures:** build provenance records the exact upstream Git commit, Fedora builder version, architecture, RPM iteration, and UTC timestamp. Release checksums permit artifact integrity verification.
- **A09 Security Logging and Monitoring Failures:** build output records tool versions and RPM validation results; release notes should retain known lint exceptions.
- **A10 Server-Side Request Forgery:** this packaging layer does not add network request functionality. Runtime network behavior belongs to upstream Goose.

## Reproducibility and trust boundaries

The workflow pins pnpm itself and enforces upstream lockfiles, but the Fedora base currently uses the mutable `fedora:45` tag and Fedora packages are updated during image construction. Builds are therefore traceable but not bit-for-bit reproducible. A future hardening step is to pin the Fedora image digest and record installed package versions.

The RPM bundles Electron/Chromium and other upstream binaries. `rpmlint` currently reports the known Chromium `chrome-sandbox` setuid-analysis finding. This project does not patch or disable that sandbox because doing so could weaken or break Electron runtime security.

## Verifying a release

Download the RPM and `SHA256SUMS`, then run:

```bash
sha256sum -c SHA256SUMS
rpm -qip goose-desktop-*.aarch64.rpm
rpm -qlp goose-desktop-*.aarch64.rpm
```

On macOS, use `shasum -a 256 -c SHA256SUMS`.
