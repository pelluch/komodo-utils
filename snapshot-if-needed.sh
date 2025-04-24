#!/bin/bash

make_request() {
  local type="$1"
  local url="$2"
  local data="${3:-}"

  curl -s -X "$type" \
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

  echo "Creating snapshot '$name' for $machine_type ID $id (stack: $stack)"

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
      key=$([[ "$type" == "lxc" ]] && echo "hostname" || echo "name")
      hostname=$(make_request "GET" "$type/$id/config" | jq -r ".data[\"$key\"]")
      if [ "$hostname" == "$current_hostname" ]; then
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
    local image_id image_name local_images
    image_id=$(docker inspect --format '{{.Image}}' "$cid")
    image_name=$(docker inspect --format '{{.Config.Image}}' "$cid")
    local_images=$(docker images --no-trunc --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep "^$image_name ")

    while read -r line; do
      local id
      id=$(cut -d' ' -f2 <<< "$line")
      if [[ "$id" != "$image_id" ]]; then
        updated_found=1
        break 2
      fi
    done <<< "$local_images"
  done

  if [[ $updated_found -eq 1 ]]; then
    echo "🆕 Newer image detected. Creating snapshot..."
    snapshot_self
  else
    echo "✅ All images are up to date. No action needed."
  fi
}

# Run it
check_newer_compose_images
