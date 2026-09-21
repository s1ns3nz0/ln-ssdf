#!/usr/bin/env bash
# Bootstrap ArgoCD and the local in-cluster Git protocol server. The Application
# source is git://git-server..., never a host filesystem path.
set -euo pipefail

context=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) context="$2"; shift 2 ;;
    *) echo "usage: $0 --context kind-ln-ssdf-phase0" >&2; exit 2 ;;
  esac
done
[[ "$context" == "kind-ln-ssdf-phase0" ]] || { echo "explicit Phase 0 context is required" >&2; exit 2; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for command in curl git helm jq kubectl shasum tar; do
  command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }
done
git -C "$repo_root" rev-parse --verify main^{commit} >/dev/null
git_revision="$(git -C "$repo_root" rev-parse main)"

k() { kubectl --context "$context" "$@"; }
wait_app() {
  local app="$1" expected_revision="${2:-}" status
  for _ in $(seq 1 90); do
    status="$(k -n argocd get application "$app" -o json 2>/dev/null || true)"
    if jq -e --arg revision "$expected_revision" \
      '.status.sync.status == "Synced" and .status.health.status == "Healthy" and ($revision == "" or .status.sync.revision == $revision)' \
      <<<"$status" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "ArgoCD application did not become Synced and Healthy: $app" >&2
  k -n argocd get application "$app" -o json >&2 || true
  return 1
}

k create namespace gitops-system >/dev/null 2>&1 || true
helm upgrade --install git-server "$repo_root/charts/git-server" \
  --kube-context "$context" --namespace gitops-system
k -n gitops-system rollout status deployment/git-server --timeout=180s

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
git clone --bare "$repo_root" "$temporary_dir/ln-ssdf.git" >/dev/null
touch "$temporary_dir/ln-ssdf.git/git-daemon-export-ok"
git_pod="$(k -n gitops-system get pod -l app=git-server -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}')"
[[ -n "$git_pod" ]] || { echo "no running git-server pod" >&2; exit 1; }
k -n gitops-system exec "$git_pod" -- rm -rf /srv/git/ln-ssdf.git
k -n gitops-system cp "$temporary_dir/ln-ssdf.git" "$git_pod:/srv/git/ln-ssdf.git"

chart_file="$temporary_dir/argo-cd-10.9.2.tgz"
curl --fail --location --proto '=https' --tlsv1.2 \
  https://github.com/argoproj/argo-helm/releases/download/argo-cd-10.9.2/argo-cd-10.9.2.tgz \
  -o "$chart_file"
[[ "$(shasum -a 256 "$chart_file" | awk '{print $1}')" == "970ced346a0ddc3e475a7ff780e9b9c2fdebc07d9a367d2edb6ef4f49832c24a" ]] || {
  echo "ArgoCD chart checksum mismatch" >&2; exit 1;
}

k create namespace argocd >/dev/null 2>&1 || true
helm upgrade --install argocd "$chart_file" --kube-context "$context" --namespace argocd \
  --set-string global.image.tag='v3.5.3@sha256:dd3f47d5a5e4da563a7a398506e892481b358a7cec50abdf320c71aa55904bfa' \
  --set-string redis.image.tag='8.6.4-alpine@sha256:2cc044fc5a07c9b701f8f1255a309ae9ad7856e694ac03513bf3648c01e40763' \
  --set dex.enabled=false \
  --set notifications.enabled=false
for workload in statefulset/argocd-application-controller deployment/argocd-repo-server deployment/argocd-server; do
  k -n argocd rollout status "$workload" --timeout=300s
done

k apply -f "$repo_root/gitops/root-application.yaml"
for app in ln-ssdf-root vault-unsealer vault-main postgres bitcoind phase1-vso-resources phase2-vso-resources lnd observability gitops-probe; do
  wait_app "$app" "$git_revision"
done
wait_app vault-secrets-operator

# The ConfigMap is intentionally non-sensitive. A direct mutation must be
# self-healed from Git before this gate can pass.
probe_revision="$(k -n ssdf-system get configmap gitops-probe -o jsonpath='{.data.revision}')"
k -n ssdf-system patch configmap gitops-probe --type=merge -p '{"data":{"revision":"out-of-band"}}' >/dev/null
for _ in $(seq 1 90); do
  [[ "$(k -n ssdf-system get configmap gitops-probe -o jsonpath='{.data.revision}')" == "$probe_revision" ]] && break
  sleep 2
done
[[ "$(k -n ssdf-system get configmap gitops-probe -o jsonpath='{.data.revision}')" == "$probe_revision" ]] || {
  echo "ArgoCD did not self-heal the GitOps probe" >&2; exit 1;
}
echo "Phase 4 bootstrap gate passed: ArgoCD applications are Synced and Healthy from the in-cluster Git source."
