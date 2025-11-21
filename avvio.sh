#!/bin/bash
set -euo pipefail

# Uso:
# ./deploy_and_run.sh utente host locale_file1 locale_file2 /remote/path file_da_eseguire
#
# Esempio:
# ./deploy_and_run.sh vagrant 192.168.56.10 script1.sh script2.sh /home/vagrant script1.sh

if [ "$#" -ne 3 ]; then
  echo "Uso: $0 <IP fedcontr> <IP node2>"
  exit 1
fi

## FEDCONTR ##

REMOTE_USER=root
REMOTE_HOST="$1"
SCRIPT1=/home/federico/tesi/Istanziazione-di-Cloud-Continuum-Blueprint-su-Cluster-Proxmox-tramite-NFVCL/scripts/script_fedcontr.sh
SCRIPT2=/home/federico/tesi/Istanziazione-di-Cloud-Continuum-Blueprint-su-Cluster-Proxmox-tramite-NFVCL/scripts/script_fixK8Sflags.sh

REMOTE_DIR=experiment
CERTS_DIR=/home/federico/tesi/Istanziazione-di-Cloud-Continuum-Blueprint-su-Cluster-Proxmox-tramite-NFVCL/certs/
echo "[INFO] Copio i file su ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}"

# Crea la directory remota se non esiste
ssh -i $HOME/.ssh/nfvcl_rsa "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '${REMOTE_DIR}'"

# Copia i due file
scp -i $HOME/.ssh/nfvcl_rsa "$SCRIPT1" "$SCRIPT2" "$CERTS_DIR/keycloak.key" "$CERTS_DIR/keycloak.crt" "$CERTS_DIR/rootCA.crt" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"

# Rende eseguibile il file scelto ed esegue
echo "[INFO] Rendo eseguibile e lancio ${SCRIPT1} su ${REMOTE_HOST}"
ssh -i $HOME/.ssh/nfvcl_rsa "${REMOTE_USER}@${REMOTE_HOST}" "cd '${REMOTE_DIR}' && chmod +x script_fedcontr.sh && ./script_fedcontr.sh"

# Rende eseguibile il file scelto ed esegue
echo "[INFO] Rendo eseguibile e lancio ${SCRIPT2} su ${REMOTE_HOST}"
ssh -i $HOME/.ssh/nfvcl_rsa "${REMOTE_USER}@${REMOTE_HOST}" "cd '${REMOTE_DIR}' && chmod +x script_fixK8Sflags.sh && ./script_fixK8Sflags.sh $1 bologna1 rootCA.crt"


## NODE 2 ##

REMOTE_HOST="$2"
SCRIPT=/home/federico/tesi/Istanziazione-di-Cloud-Continuum-Blueprint-su-Cluster-Proxmox-tramite-NFVCL/scripts/script_node2.sh
echo "[INFO] Copio i file su ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}"

# Crea la directory remota se non esiste
ssh -i $HOME/.ssh/nfvcl_rsa "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '${REMOTE_DIR}'"

# Copia i file
scp -i $HOME/.ssh/nfvcl_rsa "$SCRIPT" "$CERTS_DIR/keycloak.key" "$CERTS_DIR/keycloak.crt" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"

# Rende eseguibile il file scelto ed esegue
echo "[INFO] Rendo eseguibile e lancio ${SCRIPT} su ${REMOTE_HOST}"
ssh -i $HOME/.ssh/nfvcl_rsa "${REMOTE_USER}@${REMOTE_HOST}" "cd '${REMOTE_DIR}' && chmod +x script_node2.sh && ./script_node2.sh"


## NODE 3 ##

REMOTE_HOST="$3"
SCRIPT=/home/federico/tesi/Istanziazione-di-Cloud-Continuum-Blueprint-su-Cluster-Proxmox-tramite-NFVCL/scripts/script_node3.sh
echo "[INFO] Copio i file su ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}"

# Crea la directory remota se non esiste
ssh -i $HOME/.ssh/nfvcl_rsa "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '${REMOTE_DIR}'"

# Copia i file
scp -i $HOME/.ssh/nfvcl_rsa "$SCRIPT" "$CERTS_DIR/keycloak.key" "$CERTS_DIR/keycloak.crt" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"

# Rende eseguibile il file scelto ed esegue
echo "[INFO] Rendo eseguibile e lancio ${SCRIPT} su ${REMOTE_HOST}"
ssh -i $HOME/.ssh/nfvcl_rsa "${REMOTE_USER}@${REMOTE_HOST}" "cd '${REMOTE_DIR}' && chmod +x script_node3.sh && ./script_node3.sh $1 $HOME/$REMOTE_DIR/certs/rootCA.crt bologna1"