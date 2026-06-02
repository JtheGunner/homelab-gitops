# Website onboarding tool for kubernetes-config

# New website:  just new-website <name> <repo> <host> <port> [owner]
# Target repo via KCONFIG_ROOT (default: this staging mirror).
new-website name repo host port owner="":
    ./scripts/new-website.sh "{{name}}" "{{repo}}" "{{host}}" "{{port}}" "{{owner}}"

# Local validation (requires kustomize + kubeconform).
validate:
    #!/usr/bin/env bash
    set -euo pipefail
    for k in apps/base/webhosting/websites/*/; do
      [ -f "$k/kustomization.yaml" ] || continue
      echo "== $k"
      kustomize build "$k" | kubeconform -strict -ignore-missing-schemas -summary
    done

# Flux / kpack status.
status:
    flux get kustomizations
    flux get image repository -n webhosting
    flux get image policy -n webhosting
    kubectl -n webhosting get images.kpack.io,builds.kpack.io
