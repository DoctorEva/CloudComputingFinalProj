#!/usr/bin/env bash
#
# Packages the Capture Lambda, deploys the service stack, and publishes the
# static frontend. Everything is driven by environment variables so the script
# works unchanged against different accounts and regions.
#
#   DB_HOST        (required) RDS endpoint hostname
#   DB_PASSWORD    (required) RDS master password
#   DB_USER        default admin
#   DB_NAME        default image-metadata
#   IMAGE_BUCKET_NAME default image-bucket
#   LAMBDA_ROLE_NAME default LabRole
#   STACK_NAME     default image-capture-service
#   ARTIFACT_BUCKET default image-capture-artifacts-<account-id>
#   AWS_REGION     default us-east-1
#
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-image-capture-service}"
IMAGE_BUCKET_NAME="${IMAGE_BUCKET_NAME:-image-bucket}"
DB_NAME="${DB_NAME:-image-metadata}"
DB_USER="${DB_USER:-admin}"
LAMBDA_ROLE_NAME="${LAMBDA_ROLE_NAME:-LabRole}"
ZIP_NAME="${ZIP_NAME:-capture.zip}"
FRONTEND_BUCKET_NAME="${FRONTEND_BUCKET_NAME:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${DB_HOST:-}" ]]; then
  echo "DB_HOST is required, e.g. image-metadata.abc123.us-east-1.rds.amazonaws.com" >&2
  exit 1
fi

if [[ -z "${DB_PASSWORD:-}" ]]; then
  echo "DB_PASSWORD is required" >&2
  exit 1
fi

if [[ -z "${ARTIFACT_BUCKET:-}" ]]; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  ARTIFACT_BUCKET="image-capture-artifacts-${ACCOUNT_ID}"
fi

echo ">> building Lambda artifact ${ZIP_NAME}"
rm -rf "${ROOT}/build" "${ROOT}/${ZIP_NAME}"
mkdir -p "${ROOT}/build"
pip install --quiet --target "${ROOT}/build" -r "${ROOT}/lambda/requirements.txt"
cp "${ROOT}/lambda/lambda_function.py" "${ROOT}/build/"
( cd "${ROOT}/build" && zip -qr "${ROOT}/${ZIP_NAME}" . )

echo ">> ensuring artifact bucket ${ARTIFACT_BUCKET}"
if ! aws s3api head-bucket --bucket "${ARTIFACT_BUCKET}" 2>/dev/null; then
  aws s3 mb "s3://${ARTIFACT_BUCKET}" --region "${REGION}"
fi
aws s3 cp "${ROOT}/${ZIP_NAME}" "s3://${ARTIFACT_BUCKET}/${ZIP_NAME}" --region "${REGION}"

echo ">> deploying stack ${STACK_NAME}"
aws cloudformation deploy \
  --template-file "${ROOT}/templates/ImageServiceInfrastructrure.yaml" \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --parameter-overrides \
      LambdaCodeBucket="${ARTIFACT_BUCKET}" \
      LambdaCodeKey="${ZIP_NAME}" \
      LambdaRoleName="${LAMBDA_ROLE_NAME}" \
      ImageBucketName="${IMAGE_BUCKET_NAME}" \
      DbHost="${DB_HOST}" \
      DbName="${DB_NAME}" \
      DbUser="${DB_USER}" \
      DbPassword="${DB_PASSWORD}" \
      FrontendBucketName="${FRONTEND_BUCKET_NAME}"

output() {
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

FRONTEND_BUCKET="$(output FrontendBucketName)"
DISTRIBUTION_ID="$(output DistributionId)"

echo ">> syncing frontend to s3://${FRONTEND_BUCKET}"
aws s3 sync "${ROOT}/frontend/" "s3://${FRONTEND_BUCKET}/" --delete --region "${REGION}"

echo ">> invalidating CloudFront distribution ${DISTRIBUTION_ID}"
aws cloudfront create-invalidation \
  --distribution-id "${DISTRIBUTION_ID}" \
  --paths '/*' >/dev/null

echo ">> done"
echo "   frontend : $(output FrontendURL)"
echo "   capture  : $(output CaptureEndpoint)"
