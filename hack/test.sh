#!/bin/sh
# Runs the router's Vector unit tests and validates the kustomize build, in
# Docker, the same way CI does. No cluster needed.
set -eu
cd "$(dirname "$0")/.."
docker run --rm -v "$PWD/router":/etc/k8s-log-router:ro -e NATS_URL=nats://127.0.0.1:4222 \
  timberio/vector:0.53.0-distroless-libc \
  test /etc/k8s-log-router/vector.yaml /etc/k8s-log-router/tests/k8s-router.yaml
docker run --rm -v "$PWD":/w:ro registry.k8s.io/kubectl:v1.33.0 kustomize /w > /dev/null
echo "kustomize build ok"
