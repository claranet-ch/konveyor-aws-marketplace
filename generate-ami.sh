#!/usr/bin/env bash
if packer build "$@" base-image.pkr.hcl; then
  echo "packer build succeeded"
  AMI_ID=$(jq -r '.builds[-1].artifact_id' out/manifest.json | cut -d ":" -f2)
  echo "the following AMI was produced: ${AMI_ID}"
  cat template.yaml | sed 's/GENERATED_IMAGE_ID/'"${AMI_ID}"'/g' > out/generated-template.yaml
else
  echo "error detected"
fi