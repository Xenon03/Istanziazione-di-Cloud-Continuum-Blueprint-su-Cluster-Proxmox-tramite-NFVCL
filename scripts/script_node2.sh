#!/bin/bash
set -euo pipefail

# 0. Variabili
REPO_URL="https://gitlab.com/MMw_Unibo/platformeng/slices-blueprint.git"
REPO_DIR="slices-blueprint"

# 1. Clona la repo solo se non esiste già
if [ ! -d "$REPO_DIR" ]; then
  git clone "$REPO_URL"
fi
cd "$REPO_DIR"

# 2. Usa kubeconfig utente
if [ -f "$HOME/.kube/config" ]; then
  chmod 644 "$HOME/.kube/config"
  export KUBECONFIG="$HOME/.kube/config"
else
  echo "[ERRORE] Kubeconfig $HOME/.kube/config non esiste. Configura prima l'accesso al cluster."
  exit 1
fi

echo "[INFO] Attendo che il cluster sia pronto..."

API_READY=false
for i in {1..30}; do
  if kubectl get --raw=/healthz &>/dev/null; then
    echo "[INFO] API pronta ✅"
    API_READY=true
    break
  fi
  echo "  API non ancora pronta, tentativo $i/30..."
  sleep 10
done

if [ "$API_READY" = false ]; then
  echo "[ERRORE] API server non pronta dopo 30 tentativi. Esco."
  exit 1
fi

kubectl get nodes

# 3. Install Helm (se non presente)
if ! command -v helm >/dev/null 2>&1; then
  echo "[INFO] Installo Helm..."
  curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
  chmod 700 get_helm.sh
  ./get_helm.sh
else
  echo "[INFO] Helm è già installato, salto installazione."
fi

############################################
# 4. Install Crossplane (stile Vagrant, ma idempotente)
############################################
kubectl create namespace crossplane-system 2>/dev/null || true
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
helm repo update

if ! helm status crossplane -n crossplane-system >/dev/null 2>&1; then
  echo "[INFO] Installo Crossplane (prima volta)..."
  helm install crossplane crossplane-stable/crossplane \
    --namespace crossplane-system \
    --create-namespace
else
  echo "[INFO] Crossplane è già installato, non faccio upgrade."
fi

echo "[INFO] Attendo che Crossplane sia pronto..."
kubectl wait --for=condition=ready pod -l app=crossplane -n crossplane-system --timeout=300s || {
   echo "[WARN] I pod crossplane non sono tutti Ready entro il timeout, continuo comunque..."
}

# Assicuro che il CRD Provider esista davvero prima di applicare provider-kubernetes
CRD_FOUND=false
for i in {1..30}; do
  if kubectl get crd providers.pkg.crossplane.io &>/dev/null; then
    echo "[INFO] CRD providers.pkg.crossplane.io presente ✅"
    CRD_FOUND=true
    break
  fi
  echo "  CRD providers.pkg.crossplane.io non ancora presente, tentativo $i/30..."
  sleep 5
done

if [ "$CRD_FOUND" = false ]; then
  echo "[ERRORE] Il CRD providers.pkg.crossplane.io non è stato trovato dopo 30 tentativi. Controlla l'installazione di Crossplane."
  exit 1
fi

############################################
# 5. Install CRD Experiment provider
############################################
kubectl apply -f ./deployments/experiment-provider/crds

kubectl wait --for=create crd/providerconfigs.experiment.mmwunibo.it --timeout=60s || true
kubectl wait --for=create crd/providerconfigusages.experiment.mmwunibo.it --timeout=60s || true
kubectl wait --for=create crd/slices.experiment.mmwunibo.it --timeout=60s || true
kubectl wait --for=create crd/storeconfigs.experiment.mmwunibo.it --timeout=60s || true

sleep 30

############################################
# 6. provider-kubernetes
############################################
kubectl apply -f ./deployments/kubernetes-provider/provider-kubernetes.yaml
kubectl wait --for=condition=Healthy provider.pkg/provider-kubernetes --timeout=120s

SA=$(kubectl -n crossplane-system get sa -o name | grep provider-kubernetes | sed -e 's|serviceaccount/|crossplane-system:|g')
kubectl create clusterrolebinding provider-kubernetes-admin-binding \
  --clusterrole cluster-admin \
  --serviceaccount="${SA}" 2>/dev/null || true

kubectl apply -f ./deployments/kubernetes-provider/config-in-cluster.yaml
sleep 10

############################################
# 7. XRDs definitions
############################################
kubectl apply -f ./deployments/compositeResources/xdrs/

kubectl wait --for=create crd/xslicenamespaces.experiment.mmwunibo.it --timeout=60s || true
kubectl wait --for=create crd/remoteproviderconfigs.experiment.mmwunibo.it  --timeout=60s || true
kubectl wait --for=create crd/remoteresources.experiment.mmwunibo.it --timeout=60s || true

############################################
# 8. XRDs compositions
############################################
kubectl apply -f ./deployments/compositeResources/compositions/
sleep 10

############################################
# 9. couchDB sync operator
############################################
kubectl apply -f ./deployments/couchDBsyncoperator/deploy.yaml
kubectl wait --for=condition=Available deployment/couchdbsyncoperator --timeout=120s -n default || true

############################################
# 10. experiment provider
############################################
kubectl apply -f ./deployments/experiment-provider/experiment-provider.yaml
kubectl wait --for=condition=Healthy provider.pkg/provider-experiment --timeout=120s

kubectl apply -f ./deployments/experiment-provider/experiment-provider-config.yaml
sleep 10

############################################
# 11. Kubernetes provider remote resource stuff
############################################
kubectl apply -f ./deployments/kubernetes-provider/remoteResourceXDR.yaml
kubectl apply -f ./deployments/kubernetes-provider/providerconfigXRD.yaml
sleep 10
kubectl apply -f ./deployments/kubernetes-provider/providerconfigComposition.yaml
kubectl apply -f ./deployments/kubernetes-provider/remoteResourceComposition.yaml
sleep 10

echo "[INFO] Setup node2 completato ✅"
