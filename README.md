# zavai-embedder — binary distribution

This repository publishes **built artifacts only** for `zavai-embedder`, the
SharePoint ingestion and corpus administration tool for the zavai retrieval
corpus. The source code is maintained in a private repository and is not
published here.

## What is available

Each release (all of them are development prereleases) carries:

| Asset | Purpose |
|---|---|
| `zavai-embedder_<version>_amd64.deb` | the application, a bundled CPython 3.12, and every Python dependency |
| `zavai-embedder-models_<version>_all.deb` | offline Docling layout/table/OCR weights |
| `zavai-embedder-<version>-linux-x86_64.tar.gz` | the same tree for hosts without `dpkg` |
| `install.sh` | the installer |
| `SHA256SUMS`, `release-manifest.json` | integrity and exact build inputs |

## Requirements

* Debian 12 or newer (glibc 2.36+), x86_64
* An existing PostgreSQL 16 server with pgvector **available**
* An OpenAI-compatible embedding endpoint
* A SharePoint app registration (read-only, site-scoped)

No Python, pip, or CUDA is needed on the host. Relevance: embeddings are
computed by your endpoint; a GPU only accelerates PDF OCR.

## Install

```bash
curl -fsSLO https://raw.githubusercontent.com/codersidprogrammer/zavai-embedder-dist/main/install.sh
less install.sh                       # review before running as root
sudo bash install.sh --release <tag>  # newest development build if omitted
```

`install.sh` asks for the existing PostgreSQL URL and the Graph/LLM secrets,
writes `/etc/zavai-embedder/embedder.env` (0640 root:zavai), applies the
migrations, and runs `doctor`. It provisions no database.

You can also download the `.deb` files from the release page and pass them
explicitly:

```bash
sudo bash install.sh --deb ./zavai-embedder_<version>_amd64.deb \
                     --models-deb ./zavai-embedder-models_<version>_all.deb
```

## Verify what you downloaded

```bash
sha256sum -c SHA256SUMS
```

The checksums are published beside the artifacts, so they detect a corrupted
transfer — they do not defend against a compromised release. Pin a tag and
record the checksums you accepted.

## Upgrading and removing

```bash
sudo /usr/sbin/zavai-embedder-install --deb ./zavai-embedder_<newer>_amd64.deb
sudo /usr/sbin/zavai-embedder-install --reconfigure
sudo /usr/sbin/zavai-embedder-install --uninstall   # keeps data and config
```

## Support

No source, issues, or pull requests are accepted in this repository. Report
problems through your agreed support channel and include:

```bash
zavai-embedder version --json
zavai-embedder doctor --json
```
