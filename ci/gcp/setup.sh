#!/usr/bin/env bash
# One-time GCP setup for FreeOS CI. Run it in Google Cloud Shell
# (https://shell.cloud.google.com), which already has gcloud and is logged in.
#
#   git clone https://github.com/Rolbubx/Free-os && cd Free-os
#   RUNNER_TOKEN=<token from GitHub> bash ci/gcp/setup.sh
#
# It creates:
#   - a build VM (spot, 64 GB RAM) with a persistent data disk for source/out/ccache
#   - a service account that can only start/stop VMs
#   - Workload Identity Federation so GitHub Actions can use that account
#     without any stored key
# Safe to re-run: existing resources are left alone.
set -euo pipefail

PROJECT=${PROJECT:-$(gcloud config get-value project 2>/dev/null)}
ZONE=${ZONE:-us-central1-a}
VM=${VM:-freeos-aosp-builder}
MACHINE=${MACHINE:-n2-standard-32}     # 32 vCPU / 128 GB; free-trial accounts: use n2-highmem-8
DATA_DISK_GB=${DATA_DISK_GB:-400}
SPOT=${SPOT:-true}                     # ~70% cheaper; may be preempted mid-build
GITHUB_REPO=${GITHUB_REPO:-Rolbubx/Free-os}
: "${RUNNER_TOKEN:?Set RUNNER_TOKEN (GitHub repo > Settings > Actions > Runners > New self-hosted runner)}"
[ -n "$PROJECT" ] || { echo "No project: run 'gcloud config set project <id>' or set PROJECT" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
# Git Bash on Windows: gcloud needs a Windows-style path
command -v cygpath >/dev/null 2>&1 && HERE=$(cygpath -w "$HERE")
SA_NAME=freeos-ci
SA="$SA_NAME@$PROJECT.iam.gserviceaccount.com"
ROLE=freeosVmStartStop
POOL=github-actions
PROVIDER=github

gcloud config set project "$PROJECT" >/dev/null
echo "== Enabling APIs"
gcloud services enable compute.googleapis.com iam.googleapis.com \
  iamcredentials.googleapis.com sts.googleapis.com
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')

echo "== Service account + minimal role"
gcloud iam service-accounts describe "$SA" >/dev/null 2>&1 ||
  gcloud iam service-accounts create "$SA_NAME" --display-name="FreeOS CI (start/stop build VM)"
gcloud iam roles describe "$ROLE" --project "$PROJECT" >/dev/null 2>&1 ||
  gcloud iam roles create "$ROLE" --project "$PROJECT" --title="FreeOS VM start/stop" \
    --permissions=compute.instances.get,compute.instances.start,compute.instances.stop,compute.zoneOperations.get
gcloud projects add-iam-policy-binding "$PROJECT" --condition=None --quiet \
  --member="serviceAccount:$SA" --role="projects/$PROJECT/roles/$ROLE" >/dev/null

echo "== Workload Identity Federation for $GITHUB_REPO"
gcloud iam workload-identity-pools describe "$POOL" --location=global >/dev/null 2>&1 ||
  gcloud iam workload-identity-pools create "$POOL" --location=global --display-name="GitHub Actions"
gcloud iam workload-identity-pools providers describe "$PROVIDER" --location=global \
    --workload-identity-pool="$POOL" >/dev/null 2>&1 ||
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" --location=global \
    --workload-identity-pool="$POOL" --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
    --attribute-condition="assertion.repository=='$GITHUB_REPO'"
gcloud iam service-accounts add-iam-policy-binding "$SA" --quiet --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL/attribute.repository/$GITHUB_REPO" >/dev/null

echo "== Build VM $VM ($MACHINE, ${DATA_DISK_GB} GB data disk) in $ZONE"
if gcloud compute instances describe "$VM" --zone "$ZONE" >/dev/null 2>&1; then
  echo "VM already exists, updating runner token metadata only"
  gcloud compute instances add-metadata "$VM" --zone "$ZONE" --metadata=gh-runner-token="$RUNNER_TOKEN"
else
  spot_flags=()
  [ "$SPOT" = true ] && spot_flags=(--provisioning-model=SPOT --instance-termination-action=STOP)
  gcloud compute instances create "$VM" --zone "$ZONE" --machine-type "$MACHINE" \
    --image-family=ubuntu-2204-lts --image-project=ubuntu-os-cloud \
    --boot-disk-size=30GB --boot-disk-type=pd-balanced \
    --create-disk=name="$VM-data",size="${DATA_DISK_GB}GB",type=pd-balanced,device-name=aosp,auto-delete=no \
    --no-service-account --no-scopes \
    --metadata=gh-repo="$GITHUB_REPO",gh-runner-token="$RUNNER_TOKEN" \
    --metadata-from-file=startup-script="$HERE/vm-startup.sh" \
    "${spot_flags[@]}"
fi

cat <<EOF

Done. The VM is installing build tools and registering the runner (~10 min);
it powers itself off after 30 idle minutes.

Add these as GitHub repository *variables* (Settings > Secrets and variables > Actions > Variables):

  GCP_PROJECT       $PROJECT
  GCP_ZONE          $ZONE
  GCP_VM_NAME       $VM
  GCP_SA_EMAIL      $SA
  GCP_WIF_PROVIDER  projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL/providers/$PROVIDER

Then run the "Build FreeOS (AOSP Android TV)" workflow from the Actions tab.
EOF
