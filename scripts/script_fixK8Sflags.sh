#!/bin/bash
set -euo pipefail

# Uso:
#   sudo ./enable-oidc-kubeadm.sh <IP_KEYCLOAK> <OIDC_CLIENT_ID> <CA_FILE_PATH>
#
# Esempio:
#   sudo ./enable-oidc-kubeadm.sh 192.168.56.48 bologna1 /home/vagrant/rootCA.crt

if [ "$#" -ne 3 ]; then
  echo "Uso: $0 <IP_KEYCLOAK> <OIDC_CLIENT_ID> <CA_FILE_PATH>"
  exit 1
fi

OIDC_ISSUER_IP="$1"
OIDC_CLIENT_ID="$2"
OIDC_CA_FILE="$3"
OIDC_ISSUER_URL="https://${OIDC_ISSUER_IP}:8443/realms/kubernetes"

APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
KUBECONFIG="/etc/kubernetes/admin.conf"

if [ ! -f "$APISERVER_MANIFEST" ]; then
  echo "[ERRORE] Non trovo $APISERVER_MANIFEST. Sei sicuro che questo sia un control-plane kubeadm?"
  exit 1
fi

if [ ! -f "$OIDC_CA_FILE" ]; then
  echo "[ERRORE] CA file $OIDC_CA_FILE non esiste."
  exit 1
fi

echo "[INFO] Configuro OIDC sull'API server kubeadm:"
echo "       issuer-url = $OIDC_ISSUER_URL"
echo "       client-id  = $OIDC_CLIENT_ID"
echo "       ca-file    = $OIDC_CA_FILE"

# Backup di sicurezza
BACKUP="${APISERVER_MANIFEST}.bak-$(date +%s)"
cp "$APISERVER_MANIFEST" "$BACKUP"
echo "[INFO] Backup creato: $BACKUP"

# Se OIDC è già presente, non faccio nulla
if grep -q "oidc-issuer-url" "$APISERVER_MANIFEST"; then
  echo "[INFO] Parametri OIDC già presenti in $APISERVER_MANIFEST, non modifico nulla."
else
  echo "[INFO] Inserisco parametri OIDC nel manifest kube-apiserver..."

  # Inserisco i flag subito dopo la riga con --secure-port=6443 (pattern tipico)
  sed -i "/- --secure-port=6443/a\    - --oidc-issuer-url=${OIDC_ISSUER_URL}\n    - --oidc-client-id=${OIDC_CLIENT_ID}\n    - --oidc-ca-file=${OIDC_CA_FILE}\n    - --oidc-username-claim=name\n    - --oidc-groups-claim=groups" "$APISERVER_MANIFEST"
fi

echo "[INFO] Kubelet riavvierà automaticamente il pod kube-apiserver (static pod)."
echo "[INFO] Attendo che l'API Kubernetes torni disponibile..."

export KUBECONFIG="$KUBECONFIG"

# Attesa healthz
for i in {1..30}; do
  if kubectl get --raw=/healthz &>/dev/null; then
    echo "[INFO] API Kubernetes pronta ✅"
    kubectl get nodes
    exit 0
  fi
  echo "  API non ancora pronta, tentativo $i/30..."
  sleep 5
done

echo "[ERRORE] API Kubernetes non pronta dopo 30 tentativi."
echo "Puoi ripristinare il manifest originale con:"
echo "  sudo cp $BACKUP $APISERVER_MANIFEST"
exit 1
