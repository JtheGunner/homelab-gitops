# Website deployer for `kubernetes-config`

Tooling + manifests to build your own web apps (Node/Python/PHP) **without a Dockerfile**
from a GitHub repo and deploy them into the cluster automatically.

- **Build:** [kpack](https://github.com/buildpacks-community/kpack) watches each repo and
  builds immutable, digest-pinned images via Cloud Native Buildpacks, pushing to `ghcr.io`.
- **Deploy:** [Flux image automation](https://fluxcd.io/flux/guides/image-update/) detects the
  new image, writes the tag into the `HelmRelease` (git commit), and Flux rolls it out —
  via [`bjw-s/app-template`](https://bjw-s-labs.github.io/helm-charts/).

```
git commit → kpack builds (buildpacks) → ghcr.io/<owner>/<app>@sha256:…
           → Flux ImageRepository/Policy detects it
           → Flux ImageUpdateAutomation writes the tag into the HelmRelease (git)
           → Flux helm-controller deploys   (single field owner, immutable, audit trail in git)
```

## Layout of this folder

`templates/` and `scripts/` are **the tooling** (not part of the Flux sync). Everything else is a
**1:1 mirror** of the paths the files belong to inside `kubernetes-config/`:

| Here | → in `kubernetes-config/` | Action |
|---|---|---|
| `sources/app-template-repo.yaml` | `sources/` | add to `sources/kustomization.yaml` |
| `infrastructure/kpack/` | `infrastructure/kpack/` | copy |
| `infrastructure/flux-image-automation/` | `infrastructure/flux-image-automation/` | copy |
| `infrastructure/controllers/{kpack,flux-image-automation}.yaml` | `infrastructure/controllers/` | add to the controllers aggregate |
| `apps/base/webhosting/websites/` | `apps/base/webhosting/websites/` | reference `websites` from the `webhosting` aggregate |

> All tool websites run in the shared namespace **`webhosting`**. The ghcr credentials and the
> kpack ServiceAccount live there once (`ghcr-push-secret.yaml`, `ghcr-pull-secret.yaml`,
> `github-git-secret.yaml`, `kpack-ghcr-push-serviceaccount.yaml` — secrets SOPS-encrypted).

## One-time cluster preparation

### 1. Enable the Flux image-automation controllers + a write-capable deploy key
They are **not** part of a standard bootstrap, and the automation must push commits back to git:
```sh
flux bootstrap github \
  --owner=<you> --repository=kubernetes-config \
  --branch=main --path=clusters/production --personal \
  --read-write-key=true \
  --components-extra=image-reflector-controller,image-automation-controller
```
(idempotent; `--read-write-key` makes the deploy key writable so `ImageUpdateAutomation` can push).

### 2. ghcr credentials (private packages)
Do **not** use a broad all-repo token. Three tokens:
- **`ghcr-push`** — **classic** PAT with `read:packages` + `write:packages` (not fine-grained!).
  kpack pulls the public lifecycle image from `ghcr.io/buildpacks-community/kpack/lifecycle`
  with these creds; a fine-grained PAT is rejected with `DENIED` for that foreign namespace.
- **`ghcr-pull`** — fine-grained PAT "Packages: read" → Flux scan + kubelet pull.
- **`github-git`** — fine-grained PAT "Contents: read" → kpack clones private source repos.

Create the secrets in `webhosting` and SOPS-encrypt them — see the comments in
`apps/base/webhosting/websites/ghcr-*-secret.yaml`. The templates wire the pull secret
automatically (`ImageRepository.secretRef` + `defaultPodOptions.imagePullSecrets`).

### 3. Vendor the kpack core
kpack has no Helm chart; the release YAML is committed to git:
```sh
KPACK_VERSION=v0.17.1   # check the latest: github.com/buildpacks-community/kpack/releases
curl -sSL -o infrastructure/kpack/release.yaml \
  https://github.com/buildpacks-community/kpack/releases/download/$KPACK_VERSION/release-${KPACK_VERSION#v}.yaml
```
Then wait for `kubectl get clusterbuilder paketo-full` → `READY=True`.

### 4. Pin the app-template version
Set `tag:` in `sources/app-template-repo.yaml` to the current chart version.

## Onboard a new website

```sh
# write straight into the real repo:
KCONFIG_ROOT=/path/to/kubernetes-config GHCR_OWNER=<you> \
  ./scripts/new-website.sh myblog https://github.com/<you>/myblog myblog.example.com 3000

# or via just (default target = this staging mirror):
just new-website myblog https://github.com/<you>/myblog myblog.example.com 3000 <you>
```
Generates `apps/base/webhosting/websites/myblog/` and adds it to the kustomization.
Review (port!), commit, push → kpack builds, Flux deploys.

### With a bundled database (MariaDB)

Pass `mariadb` as the 6th argument to bundle a database into the website's
HelmRelease (a second `db` controller — MariaDB StatefulSet — plus a 5Gi PVC and
a service on `3306`):

```sh
just new-website myblog https://github.com/<you>/myblog myblog.example.com 3000 <you> mariadb
```

This additionally writes `db-secret.yaml` (credentials) and `db-patch.yaml` (a
Kustomize strategic-merge patch that adds the DB to the release without touching
`release.yaml`). The app container gets `DB_HOST`/`DB_PORT`/`DB_DATABASE`/
`DB_USERNAME`/`DB_PASSWORD` injected — **rename those keys in `db-patch.yaml` to
match your framework** (e.g. Laravel uses exactly these; others differ). MariaDB
speaks the MySQL wire protocol, so apps connect as they would to MySQL.

> ⚠️ `db-secret.yaml` is generated with **plaintext** random passwords. Encrypt it
> before committing, like the other secrets: `sops --encrypt --in-place db-secret.yaml`.

For production-grade DBs (HA, automated backups) prefer a dedicated operator
(e.g. CloudNativePG for Postgres) installed under `infrastructure/controllers/`.

## App requirements (buildpacks, no Dockerfile)

- App at the repo root (otherwise set `spec.source.subPath` in `image.yaml`).
- A long-running web process listening on a port (ideally honoring `$PORT`).
- A start command buildpacks can detect — a `Procfile` (`web: …`) works for every stack.
- **Node:** `package.json` with a `start` script (or Procfile). **Python:** usually a `Procfile`
  (e.g. `web: gunicorn app:app -b 0.0.0.0:$PORT`). **PHP:** `composer.json`; set `BP_PHP_WEB_DIR`
  for a custom web root.

## Polyglot / non-buildpack apps (escape hatch)

Some apps don't fit the "detect one language" model — e.g. a **Laravel app with a Vite/Vue
frontend** whose asset build calls `php artisan` (needs PHP *and* Node at build time). Build
those with a **multi-stage Dockerfile in GitHub Actions** and push to `ghcr.io/<you>/<app>`;
drop `image.yaml` (kpack), keep `imagepolicy.yaml` + `release.yaml`. For the CI tag scheme
(numeric `run_number`) use `filterTags: { pattern: '^[0-9]+$' }` in the ImagePolicy.

## Placeholders you must replace
- `<you>` / `__OWNER__` → GitHub owner (or set `GHCR_OWNER`). Owner must be lowercase for ghcr.
- Version pins: kpack `v0.17.1`, app-template `5.0.1`, Paketo image tags — **verify against the
  current releases**.
- Ingress: `className: traefik` + the `traefik.ingress.kubernetes.io/router.entrypoints`
  annotation — adapt to your Traefik/cert-manager convention (TLS is terminated by Traefik;
  see `templates/website/release.yaml`).
