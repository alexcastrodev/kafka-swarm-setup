#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Gera certificados SSL para o Kafka (mTLS — broker + cliente)
# Saída: ./ssl/
#
# Uso:
#   ./keys.sh                        # gera com passwords aleatórias
#   ./keys.sh --out /outro/caminho   # pasta de saída personalizada
#   ./keys.sh --days 730             # validade em dias (default: 3650)
# ---------------------------------------------------------------------------

# ── Defaults ────────────────────────────────────────────────────────────────
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ssl"
VALIDITY_DAYS=3650
BROKER_CN="acme_kafka_kafka"
CLIENT_CN="acme-kafka-client"

# ── Argumentos ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)   OUT_DIR="$2";       shift 2 ;;
    --days)  VALIDITY_DAYS="$2"; shift 2 ;;
    *) echo "Opção desconhecida: $1"; exit 1 ;;
  esac
done

# ── Verificar dependências ───────────────────────────────────────────────────
for cmd in openssl keytool; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' não encontrado. Instala o JDK (keytool) e o openssl."; exit 1; }
done

# ── Passwords ────────────────────────────────────────────────────────────────
CA_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)
KEYSTORE_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)
TRUSTSTORE_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)
CLIENT_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)

# ── Preparar pasta ────────────────────────────────────────────────────────────
mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ""
echo "=== Kafka SSL Generator (mTLS) ==="
echo "Pasta de saída : $OUT_DIR"
echo "Validade        : ${VALIDITY_DAYS} dias"
echo "Broker CN       : $BROKER_CN"
echo "Cliente CN      : $CLIENT_CN"
echo ""

# ── 1. CA (Certificate Authority) ────────────────────────────────────────────
echo "[1/7] Gerando CA..."
openssl req -new -x509 \
  -keyout "$WORK/ca-key" \
  -out    "$WORK/ca-cert" \
  -days   "$VALIDITY_DAYS" \
  -passout "pass:$CA_PASS" \
  -subj   "/CN=acme-kafka-ca/O=Acme/C=PT" \
  -newkey rsa:4096 2>/dev/null

# ── 2. Broker keystore ────────────────────────────────────────────────────────
echo "[2/7] Gerando keystore do broker..."
keytool -genkey -noprompt \
  -alias kafka-broker \
  -dname "CN=${BROKER_CN},O=Acme,C=PT" \
  -keystore "$WORK/kafka.server.keystore.jks" \
  -storetype JKS \
  -keyalg RSA -keysize 2048 \
  -validity "$VALIDITY_DAYS" \
  -storepass "$KEYSTORE_PASS" \
  -keypass   "$KEYSTORE_PASS" 2>/dev/null

# ── 3. Assinar o certificado do broker com a CA ───────────────────────────────
echo "[3/7] Assinando certificado do broker..."
keytool -keystore "$WORK/kafka.server.keystore.jks" \
  -alias kafka-broker \
  -certreq -file "$WORK/broker-cert-req" \
  -storepass "$KEYSTORE_PASS" 2>/dev/null

# SAN obrigatório — Java 17+ rejeita certificados sem SAN (não faz fallback para CN)
cat > "$WORK/san.ext" <<EXTEOF
subjectAltName=DNS:${BROKER_CN},DNS:kafka,DNS:acme_infra_kafka,DNS:localhost,IP:127.0.0.1
EXTEOF

openssl x509 -req \
  -CA      "$WORK/ca-cert" \
  -CAkey   "$WORK/ca-key" \
  -in      "$WORK/broker-cert-req" \
  -out     "$WORK/broker-cert-signed" \
  -days    "$VALIDITY_DAYS" \
  -CAcreateserial \
  -passin  "pass:$CA_PASS" \
  -extfile "$WORK/san.ext" 2>/dev/null

# keytool -import para um cert assinado requer a chain completa (leaf + CA)
cat "$WORK/broker-cert-signed" "$WORK/ca-cert" > "$WORK/broker-cert-chain"

# Importar CA + chain no keystore do broker
keytool -keystore "$WORK/kafka.server.keystore.jks" \
  -alias CARoot -import -noprompt \
  -storetype JKS \
  -file "$WORK/ca-cert" \
  -storepass "$KEYSTORE_PASS" 2>/dev/null

keytool -keystore "$WORK/kafka.server.keystore.jks" \
  -alias kafka-broker -import -noprompt \
  -file "$WORK/broker-cert-chain" \
  -storepass "$KEYSTORE_PASS" 2>/dev/null

# ── 4. Broker truststore ──────────────────────────────────────────────────────
echo "[4/7] Gerando truststore do broker..."
# Only the CA goes into the truststore. Kafka's SSL self-test (and inter-broker
# handshake) builds a PKIX chain from the broker cert (in the keystore) up to a
# trusted CA root (in the truststore). Importing the leaf cert directly as a
# trustedCertEntry does NOT satisfy PKIX chain building and causes the
# "unable to find valid certification path" error on Kafka 3.x startup.
keytool -keystore "$WORK/kafka.server.truststore.jks" \
  -alias CARoot -import -noprompt \
  -storetype JKS \
  -file "$WORK/ca-cert" \
  -storepass "$TRUSTSTORE_PASS" 2>/dev/null

# ── 5. Certificado de cliente (mTLS) ─────────────────────────────────────────
echo "[5/7] Gerando certificado de cliente..."
openssl req -newkey rsa:2048 -nodes \
  -keyout "$WORK/client.key.pem" \
  -out    "$WORK/client-cert-req" \
  -subj   "/CN=${CLIENT_CN}/O=Acme/C=PT" 2>/dev/null

openssl x509 -req \
  -CA     "$WORK/ca-cert" \
  -CAkey  "$WORK/ca-key" \
  -in     "$WORK/client-cert-req" \
  -out    "$WORK/client.certificate.pem" \
  -days   "$VALIDITY_DAYS" \
  -CAcreateserial \
  -passin "pass:$CA_PASS" 2>/dev/null

# ── 6. Keystore PKCS12 do cliente (para rdkafka ssl.keystore.location) ───────
echo "[6/7] Gerando keystore PKCS12 do cliente..."
openssl pkcs12 -export \
  -in     "$WORK/client.certificate.pem" \
  -inkey  "$WORK/client.key.pem" \
  -CAfile "$WORK/ca-cert" \
  -name   kafka-client \
  -out    "$WORK/kafka.client.keystore.p12" \
  -passout "pass:$CLIENT_PASS" 2>/dev/null

# ── 7. Ficheiros de credenciais (exigidos pela imagem apache/kafka) ───────────
echo "[7/7] Criando ficheiros de credenciais e ca-cert.pem..."
echo "$KEYSTORE_PASS"   > "$WORK/keystore_creds"
echo "$KEYSTORE_PASS"   > "$WORK/key_creds"
echo "$TRUSTSTORE_PASS" > "$WORK/truststore_creds"

# ca-cert em PEM para o Karafka/librdkafka (ssl.ca.location)
cp "$WORK/ca-cert" "$WORK/ca-cert.pem"

# ── Copiar para pasta de saída ────────────────────────────────────────────────
# Broker
cp "$WORK/kafka.server.keystore.jks"   "$OUT_DIR/"
cp "$WORK/kafka.server.truststore.jks" "$OUT_DIR/"
cp "$WORK/keystore_creds"              "$OUT_DIR/"
cp "$WORK/key_creds"                   "$OUT_DIR/"
cp "$WORK/truststore_creds"            "$OUT_DIR/"
cp "$WORK/ca-cert.pem"                 "$OUT_DIR/"
# Cliente
cp "$WORK/kafka.client.keystore.p12"   "$OUT_DIR/"
cp "$WORK/client.certificate.pem"      "$OUT_DIR/"
cp "$WORK/client.key.pem"              "$OUT_DIR/"

# Replicate production layout: librdkafka clients (Karafka via karafka_base.rb)
# expect kafka.client.keystore.jks. The file is actually PKCS12 — librdkafka
# autodetects the format from the content, ignoring the .jks extension.
cp "$WORK/kafka.client.keystore.p12"   "$OUT_DIR/kafka.client.keystore.jks"

chmod 600 "$OUT_DIR/"*.jks "$OUT_DIR/"*.p12 "$OUT_DIR/"*.pem "$OUT_DIR/"*_creds

# ── Resumo e variáveis de ambiente ───────────────────────────────────────────
CREDS_FILE="$OUT_DIR/ssl_passwords.env"
cat > "$CREDS_FILE" <<EOF
# Gerado em $(date -u +"%Y-%m-%dT%H:%M:%SZ") — NÃO commitar este ficheiro
CA_PASS=$CA_PASS
KAFKA_KEYSTORE_PASS=$KEYSTORE_PASS
KAFKA_TRUSTSTORE_PASS=$TRUSTSTORE_PASS
KAFKA_CLIENT_PASS=$CLIENT_PASS
EOF
chmod 600 "$CREDS_FILE"

# ── Actualizar .env com as passwords geradas ──────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  # Update existing values
  sed -i.bak \
    -e "s|^KAFKA_TRUSTSTORE_PASS=.*|KAFKA_TRUSTSTORE_PASS=$TRUSTSTORE_PASS|" \
    -e "s|^KAFKA_CLIENT_TRUSTSTORE_PASS=.*|KAFKA_CLIENT_TRUSTSTORE_PASS=$CLIENT_PASS|" \
    -e "s|^KAFKA_CLIENT_PASS=.*|KAFKA_CLIENT_PASS=$CLIENT_PASS|" \
    "$ENV_FILE"
  rm -f "$ENV_FILE.bak"
  # Add KAFKA_CLIENT_PASS if it does not yet exist in the file
  grep -q "^KAFKA_CLIENT_PASS=" "$ENV_FILE" || echo "KAFKA_CLIENT_PASS=$CLIENT_PASS" >> "$ENV_FILE"
  echo "[env] .env actualizado com as novas passwords."
else
  echo "[env] AVISO: $ENV_FILE não encontrado — actualiza manualmente:"
  echo "  KAFKA_TRUSTSTORE_PASS=$TRUSTSTORE_PASS"
  echo "  KAFKA_CLIENT_TRUSTSTORE_PASS=$CLIENT_PASS"
  echo "  KAFKA_CLIENT_PASS=$CLIENT_PASS"
fi

echo ""
echo "=== Concluído ==="
echo ""
echo "Ficheiros gerados em $OUT_DIR:"
ls -lh "$OUT_DIR/"
echo ""
echo "Passwords guardadas em: $CREDS_FILE"
echo ""
echo "── Variáveis a adicionar ao .env ──────────────────────────────────────"
echo "KAFKA_BOOTSTRAP_SERVERS=acme_kafka_kafka:9095"
echo "KAFKA_SECURITY_PROTOCOL=SSL"
echo "KAFKA_SSL_CA_LOCATION=/kafka_ssl/ca-cert.pem"
echo "KAFKA_SSL_KEYSTORE_LOCATION=/kafka_ssl/kafka.client.keystore.p12"
echo "KAFKA_SSL_CERTIFICATE_LOCATION=/kafka_ssl/client.certificate.pem"
echo "KAFKA_CLIENT_TRUSTSTORE_PASS=$CLIENT_PASS"
echo ""
echo "── Próximos passos ─────────────────────────────────────────────────────"
echo "1. Actualiza acme/.env com as variáveis acima"
echo "2. Faz redeploy do broker:  ./kafka/deploy.sh"
echo "3. Faz redeploy da app:     ./deploy.sh"
