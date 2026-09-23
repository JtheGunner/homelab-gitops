<div align="center">

# 🚀 homelab-gitops

**Push to GitHub, get a website. No Dockerfile needed.**
Tooling and Flux manifests that build your Node / Python / PHP apps with Cloud Native
Buildpacks and roll them out into a Kubernetes cluster automatically.

<code>📦 git push</code> &nbsp;→&nbsp; <code>🏗️ kpack</code> &nbsp;→&nbsp; <code>🐙 ghcr.io</code> &nbsp;→&nbsp; <code>🔄 Flux</code> &nbsp;→&nbsp; <code>🌐 https://your.site</code>

![License](https://img.shields.io/badge/license-MIT-22c55e?style=flat-square)
![Flux](https://img.shields.io/badge/GitOps-Flux-3776ab?style=flat-square&logo=flux&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-k3s-0ea5e9?style=flat-square&logo=kubernetes&logoColor=white)
![Buildpacks](https://img.shields.io/badge/build-Buildpacks%20·%20no%20Dockerfile-8b5cf6?style=flat-square)
![PRs welcome](https://img.shields.io/badge/PRs-welcome-f59e0b?style=flat-square)

</div>

---

## 🎯 What it is

A small toolkit on top of an existing Flux-managed cluster (referred to below as your **`kubernetes-config`** repo) that turns "a GitHub repo with a web app" into "a running,
auto-updating website" with one command.

|    | Piece                                                                | Role                                                                                                                                                    |
|:--:|----------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| 🏗️ | [kpack](https://github.com/buildpacks-community/kpack)               | watches each app repo and builds an immutable, digest-pinned image with [Paketo buildpacks](https://paketo.io) on every commit, pushing it to `ghcr.io` |
| 🔍 | [Flux image automation](https://fluxcd.io/flux/guides/image-update/) | scans ghcr for new builds and commits the newest tag back into the app's `HelmRelease`                                                                  |
| 🚢 | [`bjw-s/app-template`](https://bjw-s-labs.github.io/helm-charts/)    | generic Helm chart that runs the app: Deployment, Service, Traefik Ingress                                                                              |
| 🧰 | `just new-website`                                                   | generates all manifests for a new site, optionally with a bundled MariaDB                                                                               |

```text
git push (app repo)
   └─▶ kpack Image builds via buildpacks ──▶ ghcr.io/<owner>/<app>:b<N>.<timestamp>
          └─▶ Flux ImageRepository + ImagePolicy pick the highest build number
                 └─▶ Flux ImageUpdateAutomation commits the tag into release.yaml (git)
                        └─▶ Flux helm-controller rolls out the HelmRelease
```

Every deployed version is a git commit — one field owner, full audit trail, trivial rollback.

---

## 🗂️ Repository layout

This repo is a **staging mirror**: everything outside `templates/`, `scripts/` and the
`justfile` mirrors the path it belongs to inside `kubernetes-config/`, so you can copy it 1:1.

|    | Here                                                            | → in `kubernetes-config/`               | Action                                                                |
|:--:|-----------------------------------------------------------------|-----------------------------------------|-----------------------------------------------------------------------|
| 📚 | `sources/app-template-repo.yaml`                                | `sources/`                              | add to `sources/kustomization.yaml`                                   |
| 🏗️ | `infrastructure/kpack/`                                         | `infrastructure/kpack/`                 | copy, then vendor `release.yaml` ([step 3](#3-vendor-the-kpack-core)) |
| 🔍 | `infrastructure/flux-image-automation/`                         | `infrastructure/flux-image-automation/` | copy                                                                  |
| 🎛️ | `infrastructure/controllers/{kpack,flux-image-automation}.yaml` | `infrastructure/controllers/`           | add to the controllers aggregate                                      |
| 🌐 | `apps/base/webhosting/websites/`                                | `apps/base/webhosting/websites/`        | reference `websites` from the `webhosting` aggregate                  |
| 🧩 | `templates/website/`                                            | —                                       | manifest templates used by the onboarding script                      |
| 🧰 | `scripts/new-website.sh`, `justfile`                            | —                                       | onboarding and helper commands                                        |

All websites share the namespace **`webhosting`**. The registry/git credentials and the
kpack ServiceAccount live there exactly once. `websites/demo/` is a sample site that shows
the generated output — replace or delete it.

> [!NOTE]
> The secret files in this repo contain **placeholders only**. In `kubernetes-config` they
> must hold real values and be SOPS-encrypted — Flux needs SOPS decryption configured for
> the Kustomization that applies `apps/`.

---

## 🧱 Prerequisites

- A Kubernetes cluster managed by **Flux v2** from a GitHub repo, with **SOPS** decryption set up
- **Traefik** as ingress controller (see *Adapt to your cluster*)
- A GitHub account for `ghcr.io` packages
- Local tools: [`just`](https://github.com/casey/just), `openssl`, `sops`, `flux`, `kubectl`;
  for `just validate` additionally `kustomize` and `kubeconform`

---

## 🛠️ One-time cluster setup

### 1. Enable Flux image automation with a write-capable deploy key

The image controllers are **not** part of a standard bootstrap, and the automation has to
push commits back to git:

```sh
flux bootstrap github \
  --owner=<you> --repository=kubernetes-config \
  --branch=main --path=clusters/production --personal \
  --read-write-key=true \
  --components-extra=image-reflector-controller,image-automation-controller
```

Re-running bootstrap is idempotent. `ImageUpdateAutomation` checks out and pushes to `main`
and only touches files under `apps/base/webhosting/websites/`.

### 2. Create the credentials

Use three narrowly scoped tokens instead of one broad all-repo token:

|    | Secret       | Token                                               | Used by                                 |
|:--:|--------------|-----------------------------------------------------|-----------------------------------------|
| ⬆️ | `ghcr-push`  | **classic** PAT: `read:packages` + `write:packages` | kpack pushes images and the builder     |
| ⬇️ | `ghcr-pull`  | fine-grained PAT: *Packages: read*                  | Flux registry scan + kubelet image pull |
| 📥 | `github-git` | fine-grained PAT: *Contents: read* on the app repos | kpack clones private source repos       |

> [!IMPORTANT]
> `ghcr-push` **must be a classic PAT**. kpack pulls its lifecycle image from
> `ghcr.io/buildpacks-community/kpack/lifecycle` with these credentials, and a fine-grained
> PAT is rejected with `DENIED` for that foreign namespace.

Fill in and encrypt the files in `apps/base/webhosting/websites/` — each one documents a
`kubectl create secret … --dry-run=client -o yaml | sops --encrypt` one-liner. The website
templates wire `ghcr-pull` in automatically (`ImageRepository.secretRef` and
`defaultPodOptions.imagePullSecrets`).

### 3. Vendor the kpack core

kpack ships no Helm chart, so its release YAML is committed to git:

```sh
KPACK_VERSION=v0.17.1   # check the latest: github.com/buildpacks-community/kpack/releases
curl -sSL -o infrastructure/kpack/release.yaml \
  https://github.com/buildpacks-community/kpack/releases/download/$KPACK_VERSION/release-${KPACK_VERSION#v}.yaml
```

Also set your owner in `infrastructure/kpack/cluster-builder.yaml`
(`tag: ghcr.io/<you>/kpack-builder`). After Flux has applied it, wait for:

```sh
kubectl get clusterbuilder paketo-full   # READY=True
```

### 4. Pin the app-template version

Set `ref.tag` in `sources/app-template-repo.yaml` to the current
[app-template release](https://github.com/bjw-s-labs/helm-charts/releases).

---

## 🌐 Onboard a new website

```sh
just new-website <name> <repo-url> <host> <port> [owner] [db]

# example
just new-website myblog https://github.com/<you>/myblog myblog.example.com 3000 <you>
```

|    | Argument   | Meaning                                                                    |
|:--:|------------|----------------------------------------------------------------------------|
| 🏷️ | `name`     | resource name and ghcr package name; only `[a-z0-9-]`                      |
| 🔗 | `repo-url` | GitHub repo kpack builds from (branch **`main`**)                          |
| 🌍 | `host`     | public hostname for the Ingress                                            |
| 🔌 | `port`     | port the app listens on; also exported as `$PORT`                          |
| 👤 | `owner`    | ghcr owner; falls back to `$GHCR_OWNER`, lowercased automatically          |
| 🗄️ | `db`       | empty = no database, `mariadb` = bundle one (see *Bundled database* below) |

This writes `apps/base/webhosting/websites/<name>/` and registers the folder in the
websites `kustomization.yaml`. By default the target is this repo; point it at your real
config repo with `KCONFIG_ROOT`:

```sh
KCONFIG_ROOT=/path/to/kubernetes-config GHCR_OWNER=<you> \
  ./scripts/new-website.sh myblog https://github.com/<you>/myblog myblog.example.com 3000
```

Review the output (especially the port), commit, push — kpack builds, Flux deploys.

### 🗄️ Bundled database (MariaDB)

Pass `mariadb` as the sixth argument (`mysql` and `maria` are accepted aliases):

```sh
just new-website myblog https://github.com/<you>/myblog myblog.example.com 3000 <you> mariadb
```

This adds a second controller `db` to the same HelmRelease — a MariaDB 11.4 StatefulSet with
a 5 Gi PVC and a service `<name>-db:3306` — through two extra files:

- **`db-secret.yaml`** — database name, user and random passwords; the single source of
  truth for both MariaDB and the app
- **`db-patch.yaml`** — a Kustomize strategic-merge patch, so `release.yaml` stays untouched

The app container receives `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME` and
`DB_PASSWORD`. Laravel uses exactly these names; for other frameworks **rename the keys in
`db-patch.yaml`**. MariaDB speaks the MySQL wire protocol, so apps connect as to MySQL.

> [!WARNING]
> `db-secret.yaml` is generated with **plaintext** passwords. Encrypt it before committing:
> `sops --encrypt --in-place apps/base/webhosting/websites/<name>/db-secret.yaml`

The bundled DB has no HA and no automated backups. For production-grade databases install a
dedicated operator (e.g. CloudNativePG for Postgres) under `infrastructure/controllers/`.

---

## 📦 App requirements

The ClusterBuilder `paketo-full` detects the language in this order: **Node.js → Python → PHP**.

- The app sits at the repo root — otherwise set `spec.source.subPath` in `image.yaml`.
- Builds track the **`main`** branch — change `spec.source.git.revision` in `image.yaml` if needed.
- It runs a long-lived web process on a port, ideally honoring `$PORT`.
- Buildpacks can detect a start command; a `Procfile` (`web: …`) works for every stack.

|    | Stack   | Minimum                                                                                                            |
|:--:|---------|--------------------------------------------------------------------------------------------------------------------|
| 🟩 | Node.js | `package.json` with a `start` script (or a `Procfile`)                                                             |
| 🐍 | Python  | usually a `Procfile`, e.g. `web: gunicorn app:app -b 0.0.0.0:$PORT`                                                |
| 🐘 | PHP     | `composer.json`; set `BP_PHP_WEB_DIR` (e.g. `public`) under `spec.build.env` in `image.yaml` for a custom web root |

### 🚪 Escape hatch: apps that need a Dockerfile

Some apps don't fit "detect one language" — e.g. a **Laravel app with a Vite/Vue frontend**
whose asset build calls `php artisan` and so needs PHP *and* Node at build time. Build those
with a multi-stage Dockerfile in GitHub Actions and push to `ghcr.io/<you>/<app>`, then:

1. delete `image.yaml` and remove it from the site's `kustomization.yaml`;
2. in `imagepolicy.yaml`, replace `filterTags` with `pattern: '^[0-9]+$'` (drop `extract`)
   and tag the CI images with the numeric `run_number`;
3. keep `release.yaml` unchanged.

---

## ⚙️ Adapt to your cluster

|    | What                                                                                                                                  | Where                                                                  |
|:--:|---------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------|
| 👤 | `<you>` / `you` → your lowercase GitHub owner                                                                                         | `cluster-builder.yaml`, `websites/demo/`, secret comments              |
| 📌 | Version pins: kpack `v0.17.1`, app-template `5.0.1`, MariaDB `11.4`, Paketo images (unpinned) — **verify against current releases**   | `infrastructure/kpack/`, `sources/`, `templates/website/db-patch.yaml` |
| 🚦 | Ingress: `className: traefik`, entrypoint `websecure`, middleware `traefik-security-chain@kubernetescrd` (must exist in your cluster) | `templates/website/release.yaml`                                       |
| 🔒 | TLS is terminated by Traefik; uncomment the `tls:` block to use a per-site certificate secret instead                                 | `templates/website/release.yaml`                                       |

---

## 🩺 Day-2 commands

|    | Command         | What it does                                                                        |
|:--:|-----------------|-------------------------------------------------------------------------------------|
| ✅ | `just validate` | renders every site with `kustomize` and checks it with `kubeconform`                |
| 📊 | `just status`   | shows Flux kustomizations, image repositories and policies, and kpack images/builds |

---

## 🤝 Contributing

Issues and pull requests are welcome. For larger changes, open an issue first. Run
`just validate` before submitting changes to the manifests or templates.

---

## 📄 License

MIT — see [LICENSE](LICENSE). © 2026 Jeffry Würmli.

---

<div align="center"><sub>Built for a homelab — kpack builds, Flux ships, git remembers.</sub></div>
