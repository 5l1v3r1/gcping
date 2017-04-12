#!/bin/bash

PROJECT_ID=gcping-1369
REGIONS="us-central1 us-east1 us-west1 europe-west1 asia-east1 asia-northeast1 asia-southeast1"

if [[ -z $CREATE_ADDRS ]]; then
  # Create static addresses
  for r in $REGIONS; do
    gcloud compute --project=$PROJECT_ID addresses create "$r" --region=$r
  done
fi

# Create VMs
for r in $REGIONS; do
  gcloud compute --project=$PROJECT_ID instances delete "$r" --zone="$r-b" || true

  addr=$(gcloud compute --project=$PROJECT_ID addresses describe "$r" --region=$r | grep "address:" | cut -d' ' -f2)
  echo $r $addr

  gcloud compute --project=$PROJECT_ID instances create "$r" \
    --zone="$r-b" \
    --machine-type=f1-micro \
    --metadata-from-file startup-script=startupscript.sh \
    --network=network \
    --subnet=subnet \
    --address=$addr \
    --tags=http-server \
    --maintenance-policy=MIGRATE \
    --image-project=ubuntu-os-cloud \
    --image-family=ubuntu-1610 \
    --boot-disk-size=10 \
    --boot-disk-type=pd-standard \
    --boot-disk-device-name="$r" \
    --no-scopes \
    --no-service-account
done
