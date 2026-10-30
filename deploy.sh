#!/usr/bin/env bash
set -euo pipefail

NS="demo"
CLUSTER="kind"
CTX="kind-${CLUSTER}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-install}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Errore: $1 non installato."; exit 1; }; }
need kind
need kubectl

case "$ACTION" in
  install)
    echo "[INFO] Avvio il deploy di Podinfo..."
    if ! kind get clusters | grep -qx "$CLUSTER"; then
      echo "[INFO] Creazione del cluster Kind..."
      kind create cluster --name "$CLUSTER"
    fi
    kubectl config use-context "$CTX"

      # Create namespace if it does not exist.
      kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

      # Generate a random Secret only if it does not exist.
      if ! kubectl -n "$NS" get secret podinfo-secret >/dev/null 2>&1; then
        SECRET_FILE="$(mktemp)"
        trap 'rm -f "$SECRET_FILE"' EXIT

        head -c 32 /dev/urandom | base64 | tr -d '\n' > "$SECRET_FILE"

        kubectl create secret generic podinfo-secret \
          --namespace "$NS" \
          --from-file="API_KEY=${SECRET_FILE}" \
          --dry-run=client -o yaml | kubectl apply -f -

        rm -f "$SECRET_FILE"
        trap - EXIT

        echo "[INFO] Secret created."
      else
        echo "[INFO] Secret already exists, keeping the existing one."
      fi

      # Apply Kubernetes manifests. The Secret was created separately.
      # Apply Kubernetes manifests. The Secret was created separately.
      # Apply Kubernetes manifests. The Secret was created separately.
    echo "[INFO] Applicazione dei manifest Kubernetes..."
    kubectl apply -f "${SCRIPT_DIR}/podinfo.yaml"

    # Attende che il Pod sia pronto
    echo "[INFO] In attesa che il Pod sia pronto..."
    kubectl -n "$NS" rollout status deployment/podinfo --timeout=120s

    echo "[INFO] Deploy completato con successo."
    echo "[INFO] Per accedere: kubectl -n $NS port-forward svc/podinfo 9898:9898"
    ;;

  cleanup)
    echo "[INFO] Rimozione dell'applicazione..."

    if ! kind get clusters >/dev/null 2>&1; then
      echo "[ERROR] Impossibile contattare Kind." >&2
      exit 1
    fi

    if ! kind get clusters | grep -Fxq "$CLUSTER"; then
      echo "[INFO] Cluster '$CLUSTER' inesistente: nulla da rimuovere."
      exit 0
    fi

    kubectl config use-context "$CTX"

    kubectl delete deployment/podinfo \
      service/podinfo \
      configmap/podinfo-config \
      secret/podinfo-secret \
      -n "$NS" --ignore-not-found

    kubectl delete namespace "$NS" --ignore-not-found

    echo "[INFO] Cleanup completato."
    ;;
  destroy)
    if ! kind get clusters >/dev/null 2>&1; then
      echo "[ERROR] Impossibile contattare Kind." >&2
      exit 1
    fi

    if kind get clusters | grep -Fxq "$CLUSTER"; then
      echo "[INFO] Distruzione del cluster Kind '$CLUSTER'..."
      kind delete cluster --name "$CLUSTER"
      echo "[INFO] Cluster distrutto."
    else
      echo "[INFO] Il cluster '$CLUSTER' non esiste."
    fi
    ;;

  *)
    echo "Uso: $0 [install|cleanup|destroy]" >&2
    exit 1
    ;;
esac