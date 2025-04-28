#!/bin/bash

set -euo pipefail

# Print error and exit on failure
trap 'echo "❌ Error on line $LINENO. Exiting."; exit 1' ERR

make_request() {
  local type="$1"
  local url="$2"
  local data="${3:-}"

  curl -sS -X "$type" \
    -H "Content-Type: application/json" \
    -H "Authorization: PVEAPIToken=$PROXMOX_API_TOKEN" \
    -k "$PROXMOX_HOST/api2/json/nodes/pve/$url" \
    ${data:+-d "$data"}
}

create_snapshot() {
  local machine_type="$1"
  local id="$2"
  local stack
  stack=$(basename "$PWD")
  local timestamp
  timestamp=$(date +"%d_%m_%Y_%H_%M_%S")
  local name="pre_deploy_${timestamp}"
  local description="Pre-deployment of stack $stack at $(date)"

  echo "📸 Creating snapshot '$name' for $machine_type ID $id (stack: $stack)"

  local payload
  if [ "$machine_type" == "lxc" ]; then
    payload=$(jq -nc --arg name "$name" --arg desc "$description" \
      '{snapname: $name, description: $desc}')
  else
    payload=$(jq -nc --arg name "$name" --arg desc "$description" \
      '{snapname: $name, description: $desc, vmstate: false}')
  fi

  make_request "POST" "$machine_type/$id/snapshot" "$payload" > /dev/null
}

snapshot_self() {
  local current_hostname
  current_hostname="$(hostname)"

  for type in lxc qemu; do
    ids=$(make_request "GET" "$type" | jq -r '.data[].vmid')
    for id in $ids; do
      if [[ "$type" == "lxc" ]]; then
        hostname=$(make_request "GET" "$type/$id/config" | jq -r '.data.hostname')
      else
        hostname=$(make_request "GET" "$type/$id/agent/get-host-name" | jq -r '.data.result["host-name"]')
      fi

      if [[ "$hostname" == "$current_hostname" ]]; then
        create_snapshot "$type" "$id"
      fi
    done
  done
}


check_newer_compose_images() {
  local updated_found=0
  local container_ids
  container_ids=$(docker compose ps --status=running --quiet)

  for cid in $container_ids; do
    local image_id image_name newest_image_id
    image_id=$(docker inspect --format '{{.Image}}' "$cid")

    # Get the canonical image name from docker images (avoid compose-defined aliases)
    image_name=$(docker images --no-trunc --format '{{.Repository}} {{.ID}}' \
      | awk -v img="$image_id" '$2 == img { print $1 }')


    if [[ -z "$image_name" ]]; then
      echo "⚠ Could not resolve image name for container $cid (image ID $image_id)"
      continue
    fi

    # Get the ID of the newest pulled image matching this name
    newest_image_id=$(docker images --no-trunc --format '{{.Repository}} {{.ID}} {{.CreatedAt}}' \
      | grep "^$image_name" | sort -rk3 | head -n1 | awk '{print $2}')

    if [[ -z "$newest_image_id" ]]; then
      echo "⚠ No pulled images found for $image_name"
      continue
    fi

    if [[ "$newest_image_id" != "$image_id" ]]; then
      updated_found=1
      echo "🔄 Detected updated image for $image_name"
      break
    fi
  done

  if [[ $updated_found -eq 1 ]]; then
    echo "🆕 Newer image detected. Creating snapshot..."
    snapshot_self
  else
    echo "✅ All images are up to date. No action needed."
  fi
}


# Execute the workflow
check_newer_compose_images

echo "✅ Script completed successfully."
exit 0
