#!/bin/bash
set -euo pipefail

# 1. Clona la repo solo se non esiste già
if [ ! -d slices-blueprint ]; then
  git clone https://gitlab.com/MMw_Unibo/platformeng/slices-blueprint
fi
cd slices-blueprint

# 2. Usa Docker esistente, non reinstallarlo se c'è già
if ! command -v docker >/dev/null 2>&1; then
  echo "[INFO] Docker non trovato, lo installo..."
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
  groupadd docker 2>/dev/null || true
  usermod -aG docker "$SUDO_USER"
else
  echo "[INFO] Docker è già installato, salto l’installazione."
fi

# 3. Pulla SOLO le immagini che userai davvero, con tag fisso
docker pull couchdb:3.4.2
docker pull quay.io/keycloak/keycloak:26.0.7

# 4. Pulisci eventuali container esistenti con lo stesso nome
docker rm -f keycloak couchdb 2>/dev/null || true

# 5. Crea i certificati
if [[ -d $HOME/experiment/cert/ ]]; then
	rm -r $HOME/experiment/cert/
fi

mkdir $HOME/experiment/cert/
mkdir $HOME/experiment/import
cp $HOME/experiment/keycloak.crt $HOME/experiment/cert/ && cp $HOME/experiment/keycloak.key $HOME/experiment/cert/
cp $HOME/experiment/slices-blueprint/realm.json "$HOME/experiment/import/"
chmod 644 "$HOME/experiment/cert/keycloak.crt" "$HOME/experiment/cert/keycloak.key"

# 6. Avvia Keycloak con la versione fissa (NON :latest)
docker run -d --name keycloak \
  -p 8443:8443 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  -v $HOME/experiment/import:/opt/keycloak/data/import \
  -v $HOME/experiment/cert:/cert \
  quay.io/keycloak/keycloak:26.0.7 \
  start \
    --https-certificate-file=/cert/keycloak.crt \
    --https-certificate-key-file=/cert/keycloak.key \
    --hostname-strict=false \
    --import-realm \
    --verbose

# 7. Avvia CouchDB con versione fissa e senza duplicare --name
docker run -d \
  -p 5984:5984 \
  --name couchdb \
  -e COUCHDB_USER=admin \
  -e COUCHDB_PASSWORD=password \
  couchdb:3.4.2

# 8. Installa curl (aspettando il lock se necessario)
echo "[INFO] Installo curl..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  echo "  dpkg lockato da un altro processo, aspetto 5s..."
  sleep 5
done
apt-get update -y
apt-get install -y curl

# 9. Config CouchDB
echo "[INFO] Attendo che CouchDB sia pronto..."
sleep 60

curl -u admin:password -X PUT http://127.0.0.1:5984/experiments

curl --location '127.0.0.1:5984/experiments/' \
  --header 'Authorization: Basic YWRtaW46cGFzc3dvcmQ=' \
  --header 'Content-Type: application/json' \
  --data '{
  "_id": "experiment1",
  "ExperimentName": "exp1a",
  "ExperimentGroup": "experiment1",
  "EndTime": "1/1/1",
  "SiteID": "bologna1",
  "ResourceKind": "xslicenamespaces.experiment.mmwunibo.it",
  "ResourceObject": {
      "virtualMemory": "4Gb",
      "virtualCpu": "2",
      "experimentGroup": "experiment1"
    }
}'
