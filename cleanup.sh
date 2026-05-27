#!/bin/bash
set -euo pipefail

docker stack rm acme_kafka 2>/dev/null || true
until [ -z "$(docker stack ls --format '{{.Name}}' | grep -x acme_kafka || true)" ]; do sleep 2; done

docker volume rm acme_kafka_kafka_data 2>/dev/null || true
