#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
# Shared settings for variant 08-cicd-attributes. Sourced by the other scripts.
# Override any of them from the environment, e.g. IMAGE_PREFIX=... ./04-deploy.sh

# Where the GitHub Actions workflow pushes. Lowercase owner (ghcr.io requires it).
IMAGE_PREFIX="${IMAGE_PREFIX:-ghcr.io/david-m-l21s/cicd-attributes}"
CLUSTER="${CLUSTER:-obs-vm-tests}"
NS="08-cicd-attributes"
WEB_PORT="${WEB_PORT:-8089}"
# ClickHouse on the Lima VM, forwarded to the Mac's localhost:8123.
CH="${CH:-http://localhost:8123/?user=otel&password=otelpass&database=cicd_attributes}"
APPS="rating-api quote-api quote-web"
