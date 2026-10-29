#!/usr/bin/env bash
set -euo pipefail

NS="demo"
CLUSTER="kind"
ACTION="${1:-install}"

for cmd in kind kubectl helm openssl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command '$cmd' not found."
        exit 1
    fi
done

case "$ACTION" in
  install)
    if ! kind get clusters | grep -qx "$CLUSTER"; then
        kind create cluster --name "$CLUSTER"
    fi
    
    kubectl config use-context "kind-$CLUSTER"

    kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n "$NS" create secret generic podinfo-secret \
        --from-literal=API_KEY="$(openssl rand -base64 32)" \
        --dry-run=client -o yaml | kubectl apply -f -

    helm upgrade --install podinfo-release ./helm -n "$NS"
    
    kubectl -n "$NS" rollout status deployment/podinfo --timeout=120s
    
    echo "Deployment completed successfully."
    echo "Run: kubectl -n $NS port-forward svc/podinfo 9898:9898"
    ;;
    
  cleanup)
    helm uninstall podinfo-release -n "$NS" --ignore-not-found
    kubectl delete secret podinfo-secret -n "$NS" --ignore-not-found
    ;;
    
  destroy)
    kind delete cluster --name "$CLUSTER"
    ;;
    
  *)
    echo "Usage: $0 {install|cleanup|destroy}"
    exit 1
    ;;
esac
