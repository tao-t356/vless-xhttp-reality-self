# vless-xhttp-reality-self

Public bootstrap installer for the compiled binary assets.

## Install

```bash
bash <(curl -Ls https://raw.githubusercontent.com/tao-t356/vless-xhttp-reality-self/main/install.sh)
```

Use a separate release repository for fixed-version assets:

```bash
RELEASE_REPO=your-name/your-binary-release-repo \
bash <(curl -Ls https://raw.githubusercontent.com/tao-t356/vless-xhttp-reality-self/main/install.sh)
```

Install a fixed version:

```bash
VERSION=v0.20.0 bash <(curl -Ls https://raw.githubusercontent.com/tao-t356/vless-xhttp-reality-self/main/install.sh)
```

The full implementation is shipped as compiled binary assets. Do not publish private source, generated state, subscriptions, certificates, or keys in this repository.
