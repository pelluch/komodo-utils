#!/bin/bash
#
# Pre-deploy snapshot script for Komodo.
# Creates a Proxmox snapshot before deploying a stack.
#
# Supports multiple Proxmox instances via auto-discovery.
# Handles LXC mount points by temporarily removing them before snapshotting.
#

set -euo pipefail

# Configuration
DEFAULT_CONFIG_PATH="/config/proxmox.json"
TASK_POLL_INTERVAL=2
TASK_TIMEOUT=120

# Global variables set by find_host_in_proxmox
FOUND_HOST_URL=""
FOUND_HOST_TOKEN=""
FOUND_HOST_NODE=""
FOUND_VM_TYPE=""
FOUND_VM_ID=""

# Mount points to restore (for cleanup trap)
RESTORE_VMID=""
RESTORE_MOUNT_POINTS=""

fatal() {
    echo "ERROR: $1" >&2
    exit 1
}

info() {
    echo "INFO: $1"
}

# Make a request to the Proxmox API
# Usage: make_request METHOD ENDPOINT [DATA]
# Returns: JSON response body
make_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local url="${FOUND_HOST_URL}/api2/json/nodes/${FOUND_HOST_NODE}/${endpoint}"

    local curl_args=(
        -sS
        -k
        -X "$method"
        -H "Authorization: PVEAPIToken=${FOUND_HOST_TOKEN}"
        -H "Content-Type: application/x-www-form-urlencoded"
        --fail-with-body
    )

    if [[ -n "$data" ]]; then
        curl_args+=(-d "$data")
    fi

    local response
    local http_code

    # Capture both response and exit code
    if ! response=$(curl "${curl_args[@]}" "$url" 2>&1); then
        fatal "API request failed: $method $endpoint - $response"
    fi

    echo "$response"
}

# Make a request during discovery (before FOUND_HOST_* are set)
# Usage: make_request_to HOST_URL HOST_TOKEN HOST_NODE METHOD ENDPOINT
make_request_to() {
    local host_url="$1"
    local host_token="$2"
    local host_node="$3"
    local method="$4"
    local endpoint="$5"

    local url="${host_url}/api2/json/nodes/${host_node}/${endpoint}"

    curl -sS -k -X "$method" \
        -H "Authorization: PVEAPIToken=${host_token}" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        "$url" 2>/dev/null || echo ""
}

# Load and validate the config file
load_config() {
    local config_path="${PROXMOX_CONFIG_PATH:-$DEFAULT_CONFIG_PATH}"

    if [[ ! -f "$config_path" ]]; then
        fatal "Config file not found: $config_path"
    fi

    if ! jq empty "$config_path" 2>/dev/null; then
        fatal "Invalid JSON in config file: $config_path"
    fi

    local host_count
    host_count=$(jq '.proxmox_hosts | length' "$config_path")

    if [[ "$host_count" -eq 0 ]]; then
        fatal "No Proxmox hosts configured in $config_path"
    fi

    echo "$config_path"
}

# Find the current host in any configured Proxmox instance
# Sets global FOUND_* variables on success
find_host_in_proxmox() {
    local config_path="$1"
    local target_hostname="$2"

    local host_count
    host_count=$(jq '.proxmox_hosts | length' "$config_path")

    for ((i = 0; i < host_count; i++)); do
        local host_url host_token host_node
        host_url=$(jq -r ".proxmox_hosts[$i].url" "$config_path")
        host_token=$(jq -r ".proxmox_hosts[$i].api_token" "$config_path")
        host_node=$(jq -r ".proxmox_hosts[$i].node" "$config_path")

        info "Searching Proxmox at $host_url..."

        # Check LXC containers
        local lxc_list
        lxc_list=$(make_request_to "$host_url" "$host_token" "$host_node" "GET" "lxc")

        if [[ -n "$lxc_list" ]]; then
            local lxc_ids
            lxc_ids=$(echo "$lxc_list" | jq -r '.data[].vmid' 2>/dev/null || echo "")

            for vmid in $lxc_ids; do
                local config_response hostname
                config_response=$(make_request_to "$host_url" "$host_token" "$host_node" "GET" "lxc/$vmid/config")
                hostname=$(echo "$config_response" | jq -r '.data.hostname // empty' 2>/dev/null || echo "")

                if [[ "$hostname" == "$target_hostname" ]]; then
                    info "Found LXC $vmid with hostname '$hostname'"
                    FOUND_HOST_URL="$host_url"
                    FOUND_HOST_TOKEN="$host_token"
                    FOUND_HOST_NODE="$host_node"
                    FOUND_VM_TYPE="lxc"
                    FOUND_VM_ID="$vmid"
                    return 0
                fi
            done
        fi

        # Check QEMU VMs
        local qemu_list
        qemu_list=$(make_request_to "$host_url" "$host_token" "$host_node" "GET" "qemu")

        if [[ -n "$qemu_list" ]]; then
            local qemu_ids
            qemu_ids=$(echo "$qemu_list" | jq -r '.data[].vmid' 2>/dev/null || echo "")

            for vmid in $qemu_ids; do
                local agent_response hostname
                # Guest agent might not be available, skip on failure
                agent_response=$(make_request_to "$host_url" "$host_token" "$host_node" "GET" "qemu/$vmid/agent/get-host-name")
                hostname=$(echo "$agent_response" | jq -r '.data.result."host-name" // empty' 2>/dev/null || echo "")

                if [[ -z "$hostname" ]]; then
                    # Guest agent not available, skip
                    continue
                fi

                if [[ "$hostname" == "$target_hostname" ]]; then
                    info "Found QEMU VM $vmid with hostname '$hostname'"
                    FOUND_HOST_URL="$host_url"
                    FOUND_HOST_TOKEN="$host_token"
                    FOUND_HOST_NODE="$host_node"
                    FOUND_VM_TYPE="qemu"
                    FOUND_VM_ID="$vmid"
                    return 0
                fi
            done
        fi
    done

    return 1
}

# Wait for a Proxmox task to complete
wait_for_task() {
    local upid="$1"

    info "Waiting for task to complete..."

    local start_time
    start_time=$(date +%s)

    while true; do
        local elapsed
        elapsed=$(($(date +%s) - start_time))

        if [[ $elapsed -gt $TASK_TIMEOUT ]]; then
            fatal "Task timed out after ${TASK_TIMEOUT} seconds"
        fi

        local status_response status exitstatus
        status_response=$(make_request "GET" "tasks/$upid/status")
        status=$(echo "$status_response" | jq -r '.data.status // empty')
        exitstatus=$(echo "$status_response" | jq -r '.data.exitstatus // empty')

        if [[ "$status" == "stopped" ]]; then
            if [[ "$exitstatus" == "OK" ]]; then
                info "Task completed successfully"
                return 0
            else
                fatal "Task failed with status: $exitstatus"
            fi
        fi

        sleep "$TASK_POLL_INTERVAL"
    done
}

# Create a snapshot request and return the UPID
create_snapshot_request() {
    local vm_type="$1"
    local vmid="$2"
    local snapname="$3"
    local description="$4"

    local data="snapname=$snapname&description=$description"

    if [[ "$vm_type" == "qemu" ]]; then
        data="${data}&vmstate=0"
    fi

    local response upid
    response=$(make_request "POST" "$vm_type/$vmid/snapshot" "$data")
    upid=$(echo "$response" | jq -r '.data // empty')

    if [[ -z "$upid" ]]; then
        fatal "Snapshot request did not return a task UPID"
    fi

    echo "$upid"
}

# Restore mount points (called from trap or directly)
restore_mount_points() {
    if [[ -z "$RESTORE_VMID" || -z "$RESTORE_MOUNT_POINTS" ]]; then
        return 0
    fi

    info "Restoring mount points..."

    # Parse the saved mount points (format: "key=value" per line)
    while IFS= read -r mp_line; do
        if [[ -z "$mp_line" ]]; then
            continue
        fi

        local mp_key="${mp_line%%=*}"
        local mp_value="${mp_line#*=}"

        info "  Restoring $mp_key"

        # Restore the mount point
        if ! make_request "PUT" "lxc/$RESTORE_VMID/config" "$mp_key=$mp_value" >/dev/null 2>&1; then
            echo "WARNING: Failed to restore $mp_key" >&2
        fi
    done <<< "$RESTORE_MOUNT_POINTS"

    # Clear the globals
    RESTORE_VMID=""
    RESTORE_MOUNT_POINTS=""
}

# Create snapshot for LXC container (handles mount points)
create_lxc_snapshot() {
    local vmid="$1"

    # Get current config and extract mount points
    local config_response
    config_response=$(make_request "GET" "lxc/$vmid/config")

    # Extract mount points (mp0, mp1, etc.) - format: "key=value" per line
    local mount_points
    mount_points=$(echo "$config_response" | jq -r '.data | to_entries | .[] | select(.key | startswith("mp")) | "\(.key)=\(.value)"')

    if [[ -n "$mount_points" ]]; then
        local mp_count
        mp_count=$(echo "$mount_points" | wc -l)
        info "Found $mp_count mount point(s), temporarily removing..."

        # Set up globals for trap-based cleanup
        RESTORE_VMID="$vmid"
        RESTORE_MOUNT_POINTS="$mount_points"

        # Set trap to restore on any exit
        trap restore_mount_points EXIT

        # Remove each mount point
        while IFS= read -r mp_line; do
            if [[ -z "$mp_line" ]]; then
                continue
            fi
            local mp_key="${mp_line%%=*}"
            info "  Removing $mp_key"
            make_request "PUT" "lxc/$vmid/config" "delete=$mp_key" >/dev/null
        done <<< "$mount_points"
    fi

    # Create snapshot
    local timestamp stack snapname description upid
    timestamp=$(date +"%d_%m_%Y_%H_%M_%S")
    stack=$(basename "$PWD")
    snapname="pre_deploy_${timestamp}"
    description="Pre-deployment of stack $stack at $(date)"

    info "Creating snapshot '$snapname'..."
    upid=$(create_snapshot_request "lxc" "$vmid" "$snapname" "$description")
    wait_for_task "$upid"

    # Restore mount points
    if [[ -n "$mount_points" ]]; then
        restore_mount_points
        trap - EXIT
    fi
}

# Create snapshot for QEMU VM
create_qemu_snapshot() {
    local vmid="$1"

    local timestamp stack snapname description upid
    timestamp=$(date +"%d_%m_%Y_%H_%M_%S")
    stack=$(basename "$PWD")
    snapname="pre_deploy_${timestamp}"
    description="Pre-deployment of stack $stack at $(date)"

    info "Creating snapshot '$snapname'..."
    upid=$(create_snapshot_request "qemu" "$vmid" "$snapname" "$description")
    wait_for_task "$upid"
}

# Main entry point
main() {
    info "Starting pre-deploy snapshot..."

    # Load configuration
    local config_path
    config_path=$(load_config)
    info "Loaded config from $config_path"

    # Get current hostname
    local current_hostname
    current_hostname=$(hostname)
    info "Current hostname: $current_hostname"

    # Find this host in Proxmox
    if ! find_host_in_proxmox "$config_path" "$current_hostname"; then
        fatal "Hostname '$current_hostname' not found in any configured Proxmox instance"
    fi

    # Create snapshot based on VM type
    if [[ "$FOUND_VM_TYPE" == "lxc" ]]; then
        create_lxc_snapshot "$FOUND_VM_ID"
    elif [[ "$FOUND_VM_TYPE" == "qemu" ]]; then
        create_qemu_snapshot "$FOUND_VM_ID"
    else
        fatal "Unknown VM type: $FOUND_VM_TYPE"
    fi

    info "Snapshot completed successfully!"
}

# Run main
main
