#!/usr/bin/env bash
#
# Deploys the network stack, builds the capture Lambda and query service
# artifacts, deploys the service stack, and publishes the static frontend.
# Everything is driven by environment variables so the script works unchanged
# against different accounts and regions.
#
#   ./deploy.sh [all|vpc|lambda|query|frontend]  stage defaults to all
#
#   vpc       deploy the network stack (VPC, subnets, gateways), no artifacts
#   all       build both artifacts, deploy the stack, sync the frontend
#   lambda    build the capture artifact, deploy the Lambda side of the stack
#   query     build the query artifact, deploy the EC2/ALB side of the stack
#   frontend  sync frontend/ and invalidate CloudFront, no stack update
#
# Required, by stage:
#
#   vpc          none
#   all, query   DB_HOST, DB_PASSWORD, and the query network (see below)
#   lambda       DB_HOST, DB_PASSWORD
#   frontend     none; the stack must already exist
#
# The query network (QUERY_VPC_ID, QUERY_SUBNET_ID, ALB_SUBNET_IDS) is read from
# the network stack outputs when those variables are not set in the environment,
# so run './deploy.sh vpc' once before the first all/query deploy. Environment
# values override the stack outputs. A stage that finds no existing service
# stack is upgraded to a cold start: it builds both artifacts and resolves the
# query network the same way, because QueryVpcId, QuerySubnetId and AlbSubnetIds
# have no template defaults and the stack cannot be created without them.
#
# Optional:
#
#   DB_USER                      default admin
#   DB_NAME                      default image-metadata
#   DB_PORT                      default 3306
#   IMAGE_BUCKET_NAME            default image-bucket
#   LAMBDA_ROLE_NAME             default LabRole
#   QUERY_INSTANCE_TYPE          default t3.micro
#   QUERY_INSTANCE_PROFILE_NAME  default LabInstanceProfile
#   QUERY_KEY_NAME               default empty (no SSH key)
#   DB_SECURITY_GROUP_ID         default empty (security group of the RDS instance)
#   CLOUDFRONT_PREFIX_LIST_ID    default empty (falls back to 0.0.0.0/0 on port 80)
#   FRONTEND_BUCKET_NAME         default empty (generated from account and region)
#   STACK_NAME                   default image-capture-service
#   VPC_STACK_NAME               default image-vpc
#   ARTIFACT_BUCKET              default image-capture-artifacts-<account-id>
#   AWS_REGION                   default us-east-1
#   AWS_PROFILE                  default empty (ambient credentials)
#   CLEAR_OPTIONAL               1 sends the sticky parameters below as empty
#   SKIP_HEALTH_WAIT             1 skips waiting for a replaced query instance
#   QUERY_HEALTH_TIMEOUT         default 300 seconds
#
# Artifact keys are content addressed (capture-<hash>.zip, query-<hash>.zip).
# Changing a source file changes the key, and that is what makes the deploy take
# effect: a new key changes the Lambda Code.S3Key and the query instance's
# UserData, and the UserData change replaces the instance so its user data
# re-runs against the new object. Set LAMBDA_CODE_KEY or QUERY_CODE_KEY to pin a
# fixed name, which loses that change detection.
#
# QUERY_KEY_NAME, DB_SECURITY_GROUP_ID and CLOUDFRONT_PREFIX_LIST_ID are sticky:
# they are only sent when non-empty, so a later run without them keeps the value
# already on the stack. Set CLEAR_OPTIONAL=1 to send them as empty and remove the
# conditional resources.
#
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-image-capture-service}"
VPC_STACK_NAME="${VPC_STACK_NAME:-image-vpc}"
IMAGE_BUCKET_NAME="${IMAGE_BUCKET_NAME:-image-bucket}"
DB_NAME="${DB_NAME:-image-metadata}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-admin}"
LAMBDA_ROLE_NAME="${LAMBDA_ROLE_NAME:-LabRole}"
QUERY_INSTANCE_TYPE="${QUERY_INSTANCE_TYPE:-t3.micro}"
QUERY_INSTANCE_PROFILE_NAME="${QUERY_INSTANCE_PROFILE_NAME:-LabInstanceProfile}"
QUERY_KEY_NAME="${QUERY_KEY_NAME:-}"
DB_SECURITY_GROUP_ID="${DB_SECURITY_GROUP_ID:-}"
CLOUDFRONT_PREFIX_LIST_ID="${CLOUDFRONT_PREFIX_LIST_ID:-}"
FRONTEND_BUCKET_NAME="${FRONTEND_BUCKET_NAME:-}"
CLEAR_OPTIONAL="${CLEAR_OPTIONAL:-0}"
STAGE="${1:-all}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${ROOT}/templates/ImageServiceInfrastructrure.yaml"
VPC_TEMPLATE="${ROOT}/templates/ImageVPC.yaml"
BUILD_DIR="${ROOT}/build"

AWS=()
if command -v aws >/dev/null 2>&1; then
  AWS=(aws)
else
  echo "aws is required but was not found on PATH" >&2
  exit 1
fi
if [[ -n "${AWS_PROFILE:-}" ]]; then
  AWS+=(--profile "${AWS_PROFILE}")
fi
AWS+=(--region "${REGION}")

case "${STAGE}" in
  all|vpc|lambda|query|frontend) ;;
  *)
    echo "usage: $(basename "$0") [all|vpc|lambda|query|frontend]" >&2
    exit 2
    ;;
esac

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required but was not found on PATH" >&2
    exit 1
  fi
}

require() {
  local name="$1" hint="${2:-}"
  if [[ -z "${!name:-}" ]]; then
    if [[ -n "${hint}" ]]; then
      echo "${name} is required (${hint})" >&2
    else
      echo "${name} is required" >&2
    fi
    exit 1
  fi
}

hash_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    cat "$@" | sha256sum | cut -c1-8
  else
    cat "$@" | shasum -a 256 | cut -c1-8
  fi
}

add_param() {
  if [[ -n "$2" ]]; then
    PARAMS+=("$1=$2")
  fi
}

add_optional_param() {
  if [[ -n "$2" ]]; then
    PARAMS+=("$1=$2")
  elif [[ "${CLEAR_OPTIONAL}" == 1 ]]; then
    PARAMS+=("$1=")
  fi
}

stack_exists() {
  "${AWS[@]}" cloudformation describe-stacks --stack-name "${1:-${STACK_NAME}}" >/dev/null 2>&1
}

stack_output() {
  "${AWS[@]}" cloudformation describe-stacks \
    --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" \
    --output text
}

output() {
  stack_output "${STACK_NAME}" "$1"
}

COLD_START=0
if [[ "${STAGE}" != vpc ]]; then
  if [[ "${STAGE}" == frontend ]]; then
    if ! stack_exists; then
      echo "stack ${STACK_NAME} does not exist; run './deploy.sh all' first" >&2
      exit 1
    fi
  elif ! stack_exists; then
    COLD_START=1
    echo ">> stack ${STACK_NAME} does not exist; this is a cold start, building and deploying everything"
  fi
fi

BUILD_LAMBDA=0
BUILD_QUERY=0
DEPLOY_QUERY_PARAMS=0
DEPLOY_VPC=0
if [[ "${STAGE}" == vpc ]]; then
  DEPLOY_VPC=1
elif [[ "${STAGE}" == all || "${COLD_START}" == 1 ]]; then
  BUILD_LAMBDA=1
  BUILD_QUERY=1
  DEPLOY_QUERY_PARAMS=1
elif [[ "${STAGE}" == lambda ]]; then
  BUILD_LAMBDA=1
elif [[ "${STAGE}" == query ]]; then
  BUILD_QUERY=1
  DEPLOY_QUERY_PARAMS=1
fi

if [[ "${BUILD_LAMBDA}" == 1 || "${BUILD_QUERY}" == 1 ]]; then
  require_cmd zip
  require_cmd python3
fi
if [[ "${STAGE}" != frontend && "${STAGE}" != vpc ]] && ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  echo "sha256sum or shasum is required" >&2
  exit 1
fi

LAMBDA_SOURCES=("${ROOT}/lambda/lambda_function.py" "${ROOT}/lambda/requirements.txt")
QUERY_SOURCES=("${ROOT}/query/app.py" "${ROOT}/query/requirements.txt")

require_sources() {
  local source_file
  for source_file in "$@"; do
    if [[ ! -f "${source_file}" ]]; then
      echo "missing source file ${source_file}" >&2
      exit 1
    fi
  done
}

resolve_query_network() {
  if [[ -z "${QUERY_VPC_ID:-}" || -z "${QUERY_SUBNET_ID:-}" || -z "${ALB_SUBNET_IDS:-}" ]] \
    && ! stack_exists "${VPC_STACK_NAME}"; then
    echo "query network parameters are missing and stack ${VPC_STACK_NAME} does not exist" >&2
    echo "run './deploy.sh vpc' first, or set QUERY_VPC_ID, QUERY_SUBNET_ID and ALB_SUBNET_IDS" >&2
    exit 1
  fi
  if [[ -z "${QUERY_VPC_ID:-}" ]]; then
    QUERY_VPC_ID="$(stack_output "${VPC_STACK_NAME}" VpcId)"
  fi
  if [[ -z "${QUERY_SUBNET_ID:-}" ]]; then
    QUERY_SUBNET_ID="$(stack_output "${VPC_STACK_NAME}" PrivateSubnet)"
  fi
  if [[ -z "${ALB_SUBNET_IDS:-}" ]]; then
    ALB_SUBNET_IDS="$(stack_output "${VPC_STACK_NAME}" PublicSubnetIds)"
  fi
  if [[ -z "${QUERY_VPC_ID:-}" || -z "${QUERY_SUBNET_ID:-}" || -z "${ALB_SUBNET_IDS:-}" ]]; then
    echo "could not resolve the query network from stack ${VPC_STACK_NAME}" >&2
    echo "set QUERY_VPC_ID, QUERY_SUBNET_ID and ALB_SUBNET_IDS explicitly" >&2
    exit 1
  fi
  echo ">> query network: vpc ${QUERY_VPC_ID}, subnet ${QUERY_SUBNET_ID}, alb subnets ${ALB_SUBNET_IDS}"
}

if [[ "${STAGE}" == all || "${STAGE}" == query ]]; then
  require DB_HOST "e.g. image-metadata.abc123.us-east-1.rds.amazonaws.com"
  require DB_PASSWORD
  resolve_query_network
elif [[ "${STAGE}" == lambda ]]; then
  require DB_HOST "e.g. image-metadata.abc123.us-east-1.rds.amazonaws.com"
  require DB_PASSWORD
fi

if [[ "${COLD_START}" == 1 ]]; then
  resolve_query_network
fi

LAMBDA_CODE_KEY="${LAMBDA_CODE_KEY:-}"
QUERY_CODE_KEY="${QUERY_CODE_KEY:-}"

if [[ "${STAGE}" != frontend && "${STAGE}" != vpc ]]; then
  require_sources "${LAMBDA_SOURCES[@]}"
  if [[ -z "${LAMBDA_CODE_KEY}" ]]; then
    LAMBDA_CODE_KEY="capture-$(hash_of "${LAMBDA_SOURCES[@]}").zip"
  fi
fi

if [[ "${DEPLOY_QUERY_PARAMS}" == 1 ]]; then
  require_sources "${QUERY_SOURCES[@]}"
  if [[ -z "${QUERY_CODE_KEY}" ]]; then
    QUERY_CODE_KEY="query-$(hash_of "${QUERY_SOURCES[@]}").zip"
  fi
fi

if [[ -z "${ARTIFACT_BUCKET:-}" ]]; then
  ACCOUNT_ID="$("${AWS[@]}" sts get-caller-identity --query Account --output text)"
  ARTIFACT_BUCKET="image-capture-artifacts-${ACCOUNT_ID}"
fi

PREVIOUS_INSTANCE_ID=""
if [[ "${STAGE}" != frontend && "${STAGE}" != vpc && "${COLD_START}" == 0 ]]; then
  PREVIOUS_INSTANCE_ID="$(output QueryInstanceId)"
fi

build_lambda() {
  echo ">> building Lambda artifact ${LAMBDA_CODE_KEY}"
  rm -rf "${BUILD_DIR}/capture" "${ROOT}/${LAMBDA_CODE_KEY}"
  mkdir -p "${BUILD_DIR}/capture"
  python3 -m pip install --quiet --target "${BUILD_DIR}/capture" -r "${ROOT}/lambda/requirements.txt"
  cp "${ROOT}/lambda/lambda_function.py" "${BUILD_DIR}/capture/"
  ( cd "${BUILD_DIR}/capture" && zip -qr "${ROOT}/${LAMBDA_CODE_KEY}" . )
}

build_query() {
  echo ">> building query artifact ${QUERY_CODE_KEY}"
  rm -f "${ROOT}/${QUERY_CODE_KEY}"
  ( cd "${ROOT}/query" && zip -qr "${ROOT}/${QUERY_CODE_KEY}" app.py requirements.txt )
}

ensure_artifact_bucket() {
  echo ">> ensuring artifact bucket ${ARTIFACT_BUCKET}"
  if ! "${AWS[@]}" s3api head-bucket --bucket "${ARTIFACT_BUCKET}" 2>/dev/null; then
    "${AWS[@]}" s3 mb "s3://${ARTIFACT_BUCKET}"
  fi
}

upload_artifact() {
  "${AWS[@]}" s3 cp "${ROOT}/$1" "s3://${ARTIFACT_BUCKET}/$1"
}

sync_frontend() {
  local bucket distribution
  bucket="$(output FrontendBucketName)"
  distribution="$(output DistributionId)"

  echo ">> syncing frontend to s3://${bucket}"
  "${AWS[@]}" s3 sync "${ROOT}/frontend/" "s3://${bucket}/" --delete

  echo ">> invalidating CloudFront distribution ${distribution}"
  "${AWS[@]}" cloudfront create-invalidation \
    --distribution-id "${distribution}" \
    --paths '/*' >/dev/null
}

wait_for_query() {
  local alb url deadline status
  alb="$(output QueryAlbDnsName)"
  if [[ -z "${alb}" ]] || ! command -v curl >/dev/null 2>&1; then
    return 0
  fi

  url="http://${alb}/health"
  echo ">> waiting for the replaced query instance to answer ${url}"
  deadline=$((SECONDS + ${QUERY_HEALTH_TIMEOUT:-300}))
  while ((SECONDS < deadline)); do
    status="$(curl -sS -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || true)"
    if [[ "${status}" == 200 ]]; then
      echo ">> query instance is healthy"
      return 0
    fi
    sleep 10
  done
  echo ">> warning: query instance was not healthy within ${QUERY_HEALTH_TIMEOUT:-300}s" >&2
}

if [[ "${BUILD_LAMBDA}" == 1 ]]; then
  build_lambda
fi
if [[ "${BUILD_QUERY}" == 1 ]]; then
  build_query
fi

if [[ "${BUILD_LAMBDA}" == 1 || "${BUILD_QUERY}" == 1 ]]; then
  ensure_artifact_bucket
  if [[ "${BUILD_LAMBDA}" == 1 ]]; then
    upload_artifact "${LAMBDA_CODE_KEY}"
  fi
  if [[ "${BUILD_QUERY}" == 1 ]]; then
    upload_artifact "${QUERY_CODE_KEY}"
  fi
fi

if [[ "${DEPLOY_VPC}" == 1 ]]; then
  echo ">> validating ${VPC_TEMPLATE}"
  "${AWS[@]}" cloudformation validate-template --template-body "file://${VPC_TEMPLATE}" >/dev/null

  echo ">> deploying stack ${VPC_STACK_NAME}"
  "${AWS[@]}" cloudformation deploy \
    --template-file "${VPC_TEMPLATE}" \
    --stack-name "${VPC_STACK_NAME}" \
    --no-fail-on-empty-changeset
fi

if [[ "${STAGE}" != frontend && "${STAGE}" != vpc ]]; then
  PARAMS=()
  add_param LambdaCodeBucket "${ARTIFACT_BUCKET}"
  add_param LambdaCodeKey "${LAMBDA_CODE_KEY}"
  add_param ImageBucketName "${IMAGE_BUCKET_NAME}"
  add_param LambdaRoleName "${LAMBDA_ROLE_NAME}"
  add_param DbHost "${DB_HOST:-}"
  add_param DbPort "${DB_PORT}"
  add_param DbName "${DB_NAME}"
  add_param DbUser "${DB_USER}"
  add_param DbPassword "${DB_PASSWORD:-}"
  add_optional_param FrontendBucketName "${FRONTEND_BUCKET_NAME}"

  if [[ "${DEPLOY_QUERY_PARAMS}" == 1 ]]; then
    add_param QueryCodeKey "${QUERY_CODE_KEY}"
    add_param QueryInstanceType "${QUERY_INSTANCE_TYPE}"
    add_param QueryInstanceProfileName "${QUERY_INSTANCE_PROFILE_NAME}"
    add_param QueryVpcId "${QUERY_VPC_ID:-}"
    add_param QuerySubnetId "${QUERY_SUBNET_ID:-}"
    add_param AlbSubnetIds "${ALB_SUBNET_IDS:-}"
    add_optional_param QueryKeyName "${QUERY_KEY_NAME}"
    add_optional_param DbSecurityGroupId "${DB_SECURITY_GROUP_ID}"
    add_optional_param CloudFrontPrefixListId "${CLOUDFRONT_PREFIX_LIST_ID}"
  fi

  echo ">> validating ${TEMPLATE}"
  "${AWS[@]}" cloudformation validate-template --template-body "file://${TEMPLATE}" >/dev/null

  echo ">> deploying stack ${STACK_NAME}"
  "${AWS[@]}" cloudformation deploy \
    --template-file "${TEMPLATE}" \
    --stack-name "${STACK_NAME}" \
    --no-fail-on-empty-changeset \
    --parameter-overrides "${PARAMS[@]}"
fi

if [[ "${STAGE}" == all || "${STAGE}" == frontend ]]; then
  sync_frontend
fi

if [[ "${STAGE}" != frontend && "${STAGE}" != vpc ]]; then
  INSTANCE_ID="$(output QueryInstanceId)"
  if [[ -n "${INSTANCE_ID}" && "${INSTANCE_ID}" != "${PREVIOUS_INSTANCE_ID}" ]]; then
    if [[ "${SKIP_HEALTH_WAIT:-0}" != 1 ]]; then
      wait_for_query
    fi
  fi
fi

echo ">> done"
if [[ "${STAGE}" == vpc ]]; then
  echo "   vpc      : $(stack_output "${VPC_STACK_NAME}" VpcId)"
  echo "   subnets  : $(stack_output "${VPC_STACK_NAME}" PublicSubnetIds)"
  echo "   private  : $(stack_output "${VPC_STACK_NAME}" PrivateSubnet)"
else
  echo "   frontend : $(output FrontendURL)"
  echo "   bucket   : $(output FrontendBucketName)"
  echo "   capture  : $(output CaptureEndpoint)"
  if [[ "${DEPLOY_QUERY_PARAMS}" == 1 || "${STAGE}" == frontend ]]; then
    echo "   alb      : $(output QueryAlbDnsName)"
    echo "   listing  : $(output QueryImagesEndpoint)"
    echo "   image    : $(output QueryImageEndpoint)"
    echo "   instance : $(output QueryInstanceId)"
  fi
fi
