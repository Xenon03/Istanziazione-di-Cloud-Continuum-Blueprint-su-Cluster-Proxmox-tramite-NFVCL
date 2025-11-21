#!/bin/bash
set -euo pipefail

# Uso:
#   sudo ./setup_k3s_crossplane.sh <IP_KEYCLOAK> <PATH_CA_FILE> [OIDC_CLIENT_ID]
#
# Esempio:
#   sudo ./setup_k3s_crossplane.sh 192.168.17.115 /root/experiment/rootCA.crt bologna1

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Uso: $0 <IP_KEYCLOAK> <PATH_CA_FILE> [OIDC_CLIENT_ID]"
  exit 1
fi

IP_KEYCLOAK="$1"
CA_FILE="$2"
OIDC_CLIENT_ID="${3:-bologna1}"

OIDC_ISSUER_URL="https://${IP_KEYCLOAK}:8443/realms/kubernetes"

REPO_URL="https://gitlab.com/MMw_Unibo/platformeng/slices-blueprint.git"
REPO_DIR="slices-blueprint"

if [ ! -f "$CA_FILE" ]; then
  echo "[ERRORE] Il file CA '$CA_FILE' non esiste."
  exit 1
fi

echo "[INFO] IP Keycloak:      ${IP_KEYCLOAK}"
echo "[INFO] OIDC issuer URL:  ${OIDC_ISSUER_URL}"
echo "[INFO] CA file:          ${CA_FILE}"
echo "[INFO] OIDC client-id:   ${OIDC_CLIENT_ID}"

############################################
# 0. Clona la repo se non esiste
############################################
if [ ! -d "$REPO_DIR" ]; then
  echo "[INFO] Clono la repo ${REPO_URL}..."
  git clone "$REPO_URL"
fi
cd "$REPO_DIR"

############################################
# 1. Installa k3s con OIDC
############################################
if ! command -v k3s >/dev/null 2>&1; then
  echo "[INFO] Installo k3s con OIDC..."
  curl -sfL https://get.k3s.io | sh -s - \
    --kube-apiserver-arg="oidc-ca-file=${CA_FILE}" \
    --kube-apiserver-arg="oidc-groups-claim=groups" \
    --kube-apiserver-arg="oidc-issuer-url=${OIDC_ISSUER_URL}" \
    --kube-apiserver-arg="oidc-client-id=${OIDC_CLIENT_ID}" \
    --kube-apiserver-arg="oidc-username-claim=name" \
    --bind-address=0.0.0.0
else
  echo "[WARN] k3s risulta già installato. NON lo reinstallo."
fi

chmod 644 /etc/rancher/k3s/k3s.yaml
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "[INFO] Attendo che i nodi siano visibili..."
sleep 10
kubectl get nodes

############################################
# 2. Installa Helm
############################################
if ! command -v helm >/dev/null 2>&1; then
  echo "[INFO] Installo Helm..."
  curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
  chmod 700 get_helm.sh
  ./get_helm.sh
else
  echo "[INFO] Helm è già installato, salto."
fi

############################################
# 3. Installa Crossplane
############################################
echo "[INFO] Installo Crossplane..."
kubectl create namespace crossplane-system 2>/dev/null || true
helm repo add crossplane-stable https://charts.crossplane.io/stable 2>/dev/null || true
helm repo update

# Stesso comportamento Vagrant: install semplice (se fallisce perché esiste, ignora)
if ! helm status crossplane -n crossplane-system >/dev/null 2>&1; then
  helm install crossplane --namespace crossplane-system crossplane-stable/crossplane
else
  echo "[INFO] Crossplane è già presente, non reinstallo."
fi

echo "[INFO] Attendo 30s per Crossplane..."
sleep 30

############################################
# 4. CRD Experiment provider
############################################
echo "[INFO] Installo CRD Experiment provider..."
kubectl apply -f ./deployments/experiment-provider/crds

kubectl wait --for=create crd/providerconfigs.experiment.mmwunibo.it --timeout=60s || true
kubectl wait --for=create crd/providerconfigusages.experiment.mmwunibo.it --timeout=60s || true
kubectl wait --for=create crd/slices.experiment.mmwunibo.it --timeout=60s || true
kubectl wait --for=create crd/storeconfigs.experiment.mmwunibo.it --timeout=60s || true

echo "[INFO] Pausa 30s dopo le CRD Experiment..."
sleep 30

############################################
# 5. Provider-kubernetes
############################################
echo "[INFO] Installo provider-kubernetes..."
kubectl apply -f ./deployments/kubernetes-provider/provider-kubernetes.yaml
kubectl wait --for=condition=Healthy provider.pkg/provider-kubernetes --timeout=80s || {
  echo "[WARN] provider-kubernetes non è Healthy entro 80s (controlla con: kubectl describe provider.pkg/provider-kubernetes)."
}

############################################
# 6. Config provider-kubernetes
############################################
echo "[INFO] Configuro RBAC per provider-kubernetes..."
SA=$(kubectl -n crossplane-system get sa -o name | grep provider-kubernetes | sed -e 's|serviceaccount/|crossplane-system:|g' || true)

if [ -n "${SA}" ]; then
  kubectl create clusterrolebinding provider-kubernetes-admin-binding \
    --clusterrole cluster-admin \
    --serviceaccount="${SA}" 2>/dev/null || true
else
  echo "[WARN] Non ho trovato la ServiceAccount di provider-kubernetes."
fi

kubectl apply -f ./deployments/kubernetes-provider/config-in-cluster.yaml
sleep 10

############################################
# 7. XRDS definitions
############################################
echo "[INFO] Installo XRD definitions..."
kubectl apply -f ./deployments/compositeResources/xdrs/
sleep 10

kubectl wait --for=create crd/xslicenamespaces.experiment.mmwunibo.it --timeout=60s || true
kubectl wait --for=create crd/remoteproviderconfigs.experiment.mmwunibo.it  --timeout=60s || true
kubectl wait --for=create crd/remoteresources.experiment.mmwunibo.it --timeout=60s || true

echo "[INFO] Pausa 30s dopo le XRD..."
sleep 30

############################################
# 8. XRDS compositions
############################################
echo "[INFO] Installo composition definitions..."
kubectl apply -f ./deployments/compositeResources/compositions/
sleep 10

############################################
# 9. couchDBsyncoperator
############################################
echo "[INFO] Installo couchDBsyncoperator..."
kubectl apply -f ./deployments/couchDBsyncoperator/deploy.yaml
kubectl wait --for=condition=Available deployment/couchdbsyncoperator --timeout=60s || {
  echo "[WARN] couchdbsyncoperator non è Available entro 60s."
}

############################################
# 10. Experiment provider
############################################
echo "[INFO] Installo experiment provider..."
kubectl apply -f ./deployments/experiment-provider/experiment-provider.yaml
kubectl wait --for=condition=Healthy provider.pkg/provider-experiment --timeout=80s || {
  echo "[WARN] provider-experiment non è Healthy entro 80s."
}

echo "[INFO] Applico la provider-config dell'experiment provider..."
kubectl apply -f ./deployments/experiment-provider/experiment-provider-config.yaml
sleep 10

echo "[INFO] Script completato ✅"
