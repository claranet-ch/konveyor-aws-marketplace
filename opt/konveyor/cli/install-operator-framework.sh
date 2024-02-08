#!/usr/bin/env bash

set -e

OPERATOR_FRAMEWORK_VERSION="v1.33.0"
OPERATOR_FRAMEWORK_URL="https://github.com/operator-framework/operator-sdk/releases/download/$OPERATOR_FRAMEWORK_VERSION"

curl -LO --output-dir /tmp/ "${OPERATOR_FRAMEWORK_URL}/operator-sdk_linux_amd64"
curl -LO --output-dir /tmp/ "${OPERATOR_FRAMEWORK_URL}/checksums.txt"

(cd /tmp && grep operator-sdk_linux_amd64 checksums.txt | sha256sum -c -)

chmod +x /tmp/operator-sdk_linux_amd64 && mv /tmp/operator-sdk_linux_amd64 /usr/local/bin/operator-sdk