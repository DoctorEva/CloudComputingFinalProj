#!/usr/bin/env bash
#
# Packages the query service and deploys the service stack (which also carries
# the EC2/ALB resources). The Lambda artifact is not rebuilt here - run
# lambda/build.sh first so capture.zip exists in the artifact bucket.
#
# Required:
#   DB_HOST                  RDS endpoint hostname
#   DB_PASSWORD              RDS master password
#   QUERY_VPC_ID             VPC shared with the RDS instance
#   QUERY_SUBNET_ID          private subnet for the query instance
#   ALB_SUBNET_IDS           comma separated public subnet ids (at least two)
#
# Optional:
#   DB_USER                  default admin
#   DB_NAME                  default image-metadata
#   DB_PORT                  default 3306
#   IMAGE_BUCKET_NAME        default image-bucket
#   LAMBDA_ROLE_NAME         default LabRole
#   QUERY_INSTANCE_PROFILE_NAME default LabInstanceProfile
#   STACK_NAME               default image-capture-service
#   ARTIFACT_BUCKET          default image-capture-artifacts-<account-id>
#   QUERY_INSTANCE_TYPE      default t3.micro
#   QUERY_KEY_NAME           default empty (no SSH key)
#   DB_SECURITY_GROUP_ID     default empty (security group of the RDS instance)
#   CLOUDFRONT_PREFIX_LIST_ID default empty (falls back to 0.0.0.0/0 on port 80)
#   AWS_REGION               default us-east-1
#
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-image-capture-service}"
IMAGE_BUCKET_NAME="${IMAGE_BUCKET_NAME:-image-bucket}"
DB_NAME="${DB_NAME:-image-metadata}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-admin}"
LAMBDA_ROLE_NAME="${LAMBDA_ROLE_NAME:-LabRole}"
LAMBDA_ZIP_NAME="${LAMBDA_ZIP_NAME:-capture.zip}"
QUERY_ZIP_NAME="${QUERY_ZIP_NAME:-query.zip}"
QUERY_INSTANCE_TYPE="${QUERY_INSTANCE_TYPE:-t3.micro}"
QUERY_INSTANCE_PROFILE_NAME="${QUERY_INSTANCE_PROFILE_NAME:-LabInstanceProfile}"
QUERY_KEY_NAME="${QUERY_KEY_NAME:-}"
DB_SECURITY_GROUP_ID="${DB_SECURITY_GROUP_ID:-}"
CLOUDFRONT_PREFIX_LIST_ID="${CLOUDFRONT_PREFIX_LIST_ID:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require() {
  if [[ -z "${!1:-}" ]]; then
    echo "$1 is required" >&2
    exit 1
  fi
}

require DB_HOST
require DB_PASSWORD
require QUERY_VPC_ID
require QUERY_SUBNET_ID
require ALB_SUBNET_IDS

if [[ -z "${ARTIFACT_BUCKET:-}" ]]; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  ARTIFACT_BUCKET="image-capture-artifacts-${ACCOUNT_ID}"
fi

echo ">> building query artifact ${QUERY_ZIP_NAME}"
rm -f "${ROOT}/${QUERY_ZIP_NAME}"
( cd "${ROOT}/query" && zip -qr "${ROOT}/${QUERY_ZIP_NAME}" app.py requirements.txt )

echo ">> ensuring artifact bucket ${ARTIFACT_BUCKET}"
if ! aws s3api head-bucket --bucket "${ARTIFACT_BUCKET}" 2>/dev/null; then
  aws s3 mb "s3://${ARTIFACT_BUCKET}" --region "${REGION}"
fi
aws s3 cp "${ROOT}/${QUERY_ZIP_NAME}" "s3://${ARTIFACT_BUCKET}/${QUERY_ZIP_NAME}" --region "${REGION}"

OVERRIDES=(
  LambdaCodeBucket="${ARTIFACT_BUCKET}"
  LambdaCodeKey="${LAMBDA_ZIP_NAME}"
  LambdaRoleName="${LAMBDA_ROLE_NAME}"
  ImageBucketName="${IMAGE_BUCKET_NAME}"
  DbHost="${DB_HOST}"
  DbPort="${DB_PORT}"
  DbName="${DB_NAME}"
  DbUser="${DB_USER}"
  DbPassword="${DB_PASSWORD}"
  QueryCodeKey="${QUERY_ZIP_NAME}"
  QueryInstanceType="${QUERY_INSTANCE_TYPE}"
  QueryInstanceProfileName="${QUERY_INSTANCE_PROFILE_NAME}"
  QueryVpcId="${QUERY_VPC_ID}"
  QuerySubnetId="${QUERY_SUBNET_ID}"
  AlbSubnetIds="${ALB_SUBNET_IDS}"
)

if [[ -n "${QUERY_KEY_NAME}" ]]; then
  OVERRIDES+=(QueryKeyName="${QUERY_KEY_NAME}")
fi
if [[ -n "${DB_SECURITY_GROUP_ID}" ]]; then
  OVERRIDES+=(DbSecurityGroupId="${DB_SECURITY_GROUP_ID}")
fi
if [[ -n "${CLOUDFRONT_PREFIX_LIST_ID}" ]]; then
  OVERRIDES+=(CloudFrontPrefixListId="${CLOUDFRONT_PREFIX_LIST_ID}")
fi

echo ">> deploying stack ${STACK_NAME}"
aws cloudformation deploy \
  --template-file "${ROOT}/templates/ImageServiceInfrastructrure.yaml" \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --parameter-overrides "${OVERRIDES[@]}"

output() {
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

echo ">> done"
echo "   alb      : $(output QueryAlbDnsName)"
echo "   listing  : $(output QueryImagesEndpoint)"
echo "   image    : $(output QueryImageEndpoint)"
