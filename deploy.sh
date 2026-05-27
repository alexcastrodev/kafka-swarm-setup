#!/bin/bash
# Deploy do stack Kafka no Docker Swarm.
#
# Uso (a partir da pasta kafka/):
#   ./deploy.sh           # deploy normal
#   ./deploy.sh --reset   # remove o stack antes de fazer deploy
#
# Pré-requisitos:
#   1. Gerar os certificados: ./keys.sh
#   2. Node no modo Swarm: docker swarm init (se ainda não estiver)
#   3. Rede externa criada: docker network create --driver overlay acme
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset) RESET=true; shift ;;
    *) echo "Opção desconhecida: $1"; exit 1 ;;
  esac
done

# ── Carregar .env ────────────────────────────────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE não encontrado — corre ./keys.sh primeiro."; exit 1; }
set -a; source "$ENV_FILE"; set +a

# ── Validar ficheiros SSL ────────────────────────────────────────────────────
SSL_DIR="${SCRIPT_DIR}/ssl"
for f in ca-cert.pem kafka.server.keystore.jks kafka.server.truststore.jks keystore_creds key_creds truststore_creds; do
  [[ -f "$SSL_DIR/$f" ]] || { echo "ERROR: ficheiro SSL não encontrado: $SSL_DIR/$f — corre ./keys.sh primeiro."; exit 1; }
done

# ── Reset opcional ───────────────────────────────────────────────────────────
if [[ "$RESET" == "true" ]]; then
  echo "→ A remover stack acme_kafka..."
  docker stack rm acme_kafka 2>/dev/null || true
  until [ -z "$(docker stack ls --format '{{.Name}}' | grep -x acme_kafka || true)" ]; do sleep 2; done
  echo "✓ Stack removido."
fi

# ── Deploy ───────────────────────────────────────────────────────────────────
echo "→ A fazer deploy do stack acme_kafka..."
docker stack deploy -c "${SCRIPT_DIR}/kafka.yml" acme_kafka
echo "✓ Stack acme_kafka em deploy."
