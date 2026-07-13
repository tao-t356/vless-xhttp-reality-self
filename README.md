# vless-xhttp-reality-self

Public bootstrap installer for the compiled binary assets.

Current public assets support Linux `amd64` only. `arm64` and `armv7` hosts are rejected before any asset download.

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tao-t356/vless-xhttp-reality-self/main/install.sh)
```

The default command installs the current mutable assets from the public repository's `main/dist` path. The archive still carries an internal VERSION and a required SHA256 sidecar, but `latest` is not a pinned release tag.

Optionally use a separate repository that publishes GitHub Release assets:

```bash
RELEASE_REPO=your-name/your-binary-release-repo \
bash <(curl -fsSL https://raw.githubusercontent.com/tao-t356/vless-xhttp-reality-self/main/install.sh)
```

To install a fixed version, the matching GitHub Release tag and assets must exist. For releases published in the default public repository:

```bash
VERSION=v0.20.0 \
bash <(curl -fsSL https://raw.githubusercontent.com/tao-t356/vless-xhttp-reality-self/main/install.sh)
```

For a separate binary Release repository:

```bash
RELEASE_REPO=your-name/your-binary-release-repo \
VERSION=v0.20.0 \
bash <(curl -fsSL https://raw.githubusercontent.com/tao-t356/vless-xhttp-reality-self/main/install.sh)
```

The implementation is shipped as executable assets. Some installer entrypoints still contain reversible packaged script payloads, so these assets prevent accidental source-tree publication but are not a cryptographic source-confidentiality boundary. Do not publish private source, generated state, subscriptions, certificates, or keys in this repository.

The bootstrap accepts HTTPS downloads only, requires a valid SHA256 sidecar, rejects unexpected archive members, and installs each version under `/usr/local/lib/vless-xhttp-reality-self/` before atomically updating `/usr/local/bin` links. A failed checksum or malformed archive is never installed.
