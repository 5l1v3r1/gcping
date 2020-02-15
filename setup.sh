#!/bin/bash

set -x

export CLOUDSDK_CORE_PROJECT=gcping-1369
NETWORK_NAME=network
SUBNET_NAME=subnet

# Write list of regions to regions.txt
listRegions() {
  gcloud compute regions list --format="value(name)" > regions.txt
}

# Ensure a static IP address exists for each region.
ensureAddrs() {
  while read r; do
    addr=$(gcloud compute addresses describe "$r" --region=$r | grep "address:" | cut -d' ' -f2)
    if [[ -z $addr ]]; then
      echo "No static IP address for $r, creating"
      gcloud compute addresses create "$r" --region=$r
    fi
  done < regions.txt
}

# Delete network and recreate it with subnets for each region.
recreateNetwork() {
  # Delete network and firewall rule.
  FWR_NAME=network-allow-http
  gcloud -q compute firewall-rules delete $FWR_NAME || true
  gcloud -q compute networks delete $NETWORK_NAME || true

  # Create network with subnets and firewall rule..
  gcloud compute networks create $NETWORK_NAME \
    --subnet-mode=custom \
    --description="Non-default network"
  gcloud compute firewall-rules create $FWR_NAME \
    --network=network \
    --allow=tcp:80 \
    --target-tags=http-server

  part=22
  while read r; do
    gcloud compute networks subnets create $SUBNET_NAME \
      --region=$r \
      --network=$NETWORK_NAME \
      --range="10.$part.0.0/20"
    part=$((part+2))
  done < regions.txt
}

# Delete VMs in each region.
deleteVMs() {
  while read r; do
    # b-zones just happen to exist in every region. Let's hope that doesn't
    # change...
    zone=$r-b

    gcloud -q compute instances delete "$r" --zone=$zone || true
  done < regions.txt
}

# Create VMs in each region.
createVMs() {
  # Build the image.
  image=$(KO_DOCKER_REPO=gcr.io/${CLOUDSDK_CORE_PROJECT} ko publish -B ./cmd/ping/)

  while read region; do
    # b-zones just happen to exist in every region. Let's hope that doesn't
    # change...
    zone=$region-b

    addr=$(gcloud compute addresses describe "$region" --region=$region | grep "address:" | cut -d' ' -f2)
    echo $region $addr

    gcloud compute instances create-with-container "$region" \
      --zone=$zone \
      --machine-type=f1-micro \
      --container-image=${image} \
      --container-env=REGION=${region} \
      --tags=http-server \
      --address=$addr \
      --network=$NETWORK_NAME \
      --subnet=$SUBNET_NAME \
      --maintenance-policy=MIGRATE \
      --boot-disk-size=10 \
      --boot-disk-type=pd-standard \
      --boot-disk-device-name="$region"
  done < regions.txt
}

# Delete and create the global loadbalancer with a instance group for each region. 
recreateLB() {
  gcloud -q compute forwarding-rules    delete http-content-rule --global
  gcloud -q compute target-http-proxies delete http-lb-proxy
  gcloud -q compute url-maps            delete web-map
  gcloud -q compute backend-services    delete backend-service --global
  gcloud -q compute http-health-checks  delete http-basic-check

  while read r; do
    ig=instance-group-$r
    zone=$r-b
    gcloud -q compute instance-groups unmanaged delete $ig --zone=$zone
  done < regions.txt

  # Create LB.
  lb_addr=$(gcloud compute addresses describe global --global | grep "address: " | cut -d' ' -f2)
  if [[ -z $lb_addr ]]; then
    echo "No IP address found, creating"
    lb_addr=$(gcloud compute addresses create global --global | grep "address: " | cut -d' ' -f2)
  fi
  echo "Load Balance IP address:" $lb_addr

  # Create health check that hits /ping
  gcloud compute http-health-checks create http-basic-check \
    --request-path=/ping

  # Create backend service using that health check
  gcloud compute backend-services create backend-service \
    --protocol=HTTP \
    --http-health-checks=http-basic-check \
    --global \
    --enable-cdn

  # Create URL map to map all incoming requests to all instances
  gcloud compute url-maps create web-map \
    --default-service=backend-service

  # Create target HTTP proxy to route requests to URL map
  gcloud compute target-http-proxies create http-lb-proxy \
    --url-map=web-map

  # Create global forwarding rule to route requests to HTTP proxy
  gcloud compute forwarding-rules create http-content-rule \
    --address=$lb_addr \
    --global \
    --target-http-proxy=http-lb-proxy \
    --ports=80

  while read r; do
    ig=instance-group-$r
    zone=$r-b

    # Create instance group for each zone
    gcloud compute instance-groups unmanaged create $ig --zone=$zone

    # Add region's VM to instance group
    gcloud compute instance-groups unmanaged add-instances $ig \
      --instances=$r \
      --zone=$zone

    # Define HTTP service and map a named port
    gcloud compute instance-groups unmanaged set-named-ports $ig \
      --named-ports=http:80 \
      --zone=$zone

    # Add instance groups as backends to backend service
    gcloud compute backend-services add-backend backend-service \
      --balancing-mode UTILIZATION \
      --max-utilization 0.8 \
      --capacity-scaler 1 \
      --instance-group=$ig \
      --instance-group-zone=$zone \
      --global
  done < regions.txt

  # Ping LB IP until it gets a pong.
  while true; do
    got=$(curl http://$lb_addr/ping 2>/dev/null | grep "pong")
    echo $got
    if [[ $got -eq "pong" ]]; then
      break
    fi
    sleep 10
  done

  echo "Load balance IP:" $lb_addr
}

deployCloudRunServices() {
  # List all available Cloud Run regions.
  curl -H "Authorization: Bearer $(gcloud auth print-access-token)" https://run.googleapis.com/v1/projects/${CLOUDSDK_CORE_PROJECT}/locations | jq .locations[].locationId | sed -e 's/"//g' > run_regions.txt

  # Build the image (again...)
  image=$(KO_DOCKER_REPO=gcr.io/${CLOUDSDK_CORE_PROJECT} ko publish -B ./cmd/ping/)

  while read region; do
    gcloud beta run deploy ping \
      --platform=managed \
      --region=${region} \
      --allow-unauthenticated \
      --update-env-vars=REGION=${region} \
      --image=${image} || echo $region is not a Cloud Run region
  done < run_regions.txt
}

regenConfig() {
  go run cmd/regen/main.go -tok=$(gcloud auth print-access-token)
}

uploadPages() {
  BUCKET=gs://www.gcping.com
  gsutil cp config.js ${BUCKET}
  gsutil cp descs.js ${BUCKET}
  gsutil cp index.html ${BUCKET}
  gsutil cp icon.png ${BUCKET}
  gsutil acl ch -u AllUsers:R ${BUCKET}/*
  gsutil web set -m index.html ${BUCKET}
}

#listRegions
#ensureAddrs
#deleteVMs
#recreateNetwork
#createVMs
#recreateLB
deployCloudRunServices
regenConfig
#uploadPages

