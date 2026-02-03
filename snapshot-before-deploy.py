#!/usr/bin/env python3
"""
Pre-deploy snapshot script for Komodo.
Creates a Proxmox snapshot before deploying a stack.

Supports multiple Proxmox instances via auto-discovery.
Handles LXC mount points by temporarily removing them before snapshotting.
"""

import json
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from typing import Any
from urllib.parse import urlencode

# Configuration
DEFAULT_CONFIG_PATH = "/config/proxmox.json"
TASK_POLL_INTERVAL = 2  # seconds
TASK_TIMEOUT = 120  # seconds


def fatal(msg: str) -> None:
    """Print error message and exit with code 1."""
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def info(msg: str) -> None:
    """Print info message."""
    print(f"INFO: {msg}")


def load_config(path: str) -> dict:
    """Load and validate the Proxmox configuration file."""
    if not os.path.exists(path):
        fatal(f"Config file not found: {path}")

    try:
        with open(path, "r") as f:
            config = json.load(f)
    except json.JSONDecodeError as e:
        fatal(f"Invalid JSON in config file: {e}")

    if "proxmox_hosts" not in config:
        fatal("Config missing 'proxmox_hosts' key")

    hosts = config["proxmox_hosts"]
    if not isinstance(hosts, list) or len(hosts) == 0:
        fatal("'proxmox_hosts' must be a non-empty list")

    for i, host in enumerate(hosts):
        for key in ("url", "api_token", "node"):
            if key not in host:
                fatal(f"Host {i} missing required key: {key}")

    return config


def make_request(
    host_config: dict,
    method: str,
    endpoint: str,
    data: dict | None = None,
) -> dict:
    """
    Make an HTTP request to the Proxmox API.

    Args:
        host_config: Dict with 'url', 'api_token', 'node' keys
        method: HTTP method (GET, POST, PUT, DELETE)
        endpoint: API endpoint (e.g., 'lxc' or 'lxc/100/config')
        data: Optional data for POST/PUT requests

    Returns:
        Parsed JSON response

    Raises:
        Exits on any error
    """
    url = f"{host_config['url']}/api2/json/nodes/{host_config['node']}/{endpoint}"

    # Prepare request
    headers = {
        "Authorization": f"PVEAPIToken={host_config['api_token']}",
        "Content-Type": "application/x-www-form-urlencoded",
    }

    body = None
    if data is not None:
        body = urlencode(data).encode("utf-8")

    req = urllib.request.Request(url, data=body, headers=headers, method=method)

    # Create SSL context that doesn't verify certificates (like curl -k)
    ssl_context = ssl.create_default_context()
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE

    try:
        with urllib.request.urlopen(req, context=ssl_context, timeout=30) as response:
            response_body = response.read().decode("utf-8")
            return json.loads(response_body)
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8") if e.fp else ""
        fatal(f"HTTP {e.code} from {url}: {error_body}")
    except urllib.error.URLError as e:
        fatal(f"Failed to connect to {url}: {e.reason}")
    except json.JSONDecodeError:
        fatal(f"Invalid JSON response from {url}")

    return {}  # unreachable, but satisfies type checker


def list_vms(host_config: dict, vm_type: str) -> list[dict]:
    """List all VMs/LXCs of the given type."""
    response = make_request(host_config, "GET", vm_type)
    return response.get("data", [])


def get_lxc_config(host_config: dict, vmid: int) -> dict:
    """Get the full config for an LXC container."""
    response = make_request(host_config, "GET", f"lxc/{vmid}/config")
    return response.get("data", {})


def get_lxc_hostname(host_config: dict, vmid: int) -> str | None:
    """Get the hostname of an LXC container."""
    config = get_lxc_config(host_config, vmid)
    return config.get("hostname")


def get_qemu_hostname(host_config: dict, vmid: int) -> str | None:
    """
    Get the hostname of a QEMU VM via guest agent.
    Returns None if guest agent is not available.
    """
    try:
        response = make_request(host_config, "GET", f"qemu/{vmid}/agent/get-host-name")
        result = response.get("data", {}).get("result", {})
        return result.get("host-name")
    except SystemExit:
        # Guest agent not available - return None to skip this VM
        return None


def find_host_in_proxmox(
    hosts: list[dict], target_hostname: str
) -> tuple[dict, str, int] | None:
    """
    Search all Proxmox instances for a VM/LXC matching the target hostname.

    Returns:
        Tuple of (host_config, vm_type, vmid) if found, None otherwise
    """
    for host_config in hosts:
        info(f"Searching Proxmox at {host_config['url']}...")

        # Check LXC containers
        for lxc in list_vms(host_config, "lxc"):
            vmid = lxc.get("vmid")
            if vmid is None:
                continue
            hostname = get_lxc_hostname(host_config, vmid)
            if hostname == target_hostname:
                info(f"Found LXC {vmid} with hostname '{hostname}'")
                return (host_config, "lxc", vmid)

        # Check QEMU VMs
        for qemu in list_vms(host_config, "qemu"):
            vmid = qemu.get("vmid")
            if vmid is None:
                continue
            hostname = get_qemu_hostname(host_config, vmid)
            if hostname is None:
                # Guest agent not available, skip
                continue
            if hostname == target_hostname:
                info(f"Found QEMU VM {vmid} with hostname '{hostname}'")
                return (host_config, "qemu", vmid)

    return None


def wait_for_task(host_config: dict, upid: str) -> None:
    """
    Poll a Proxmox task until it completes.
    Exits with error if task fails or times out.
    """
    info(f"Waiting for task {upid}...")
    start_time = time.time()

    while True:
        elapsed = time.time() - start_time
        if elapsed > TASK_TIMEOUT:
            fatal(f"Task timed out after {TASK_TIMEOUT} seconds")

        response = make_request(host_config, "GET", f"tasks/{upid}/status")
        status = response.get("data", {})

        if status.get("status") == "stopped":
            exitstatus = status.get("exitstatus", "")
            if exitstatus == "OK":
                info("Task completed successfully")
                return
            else:
                fatal(f"Task failed with status: {exitstatus}")

        time.sleep(TASK_POLL_INTERVAL)


def create_snapshot_request(
    host_config: dict, vm_type: str, vmid: int, snapname: str, description: str
) -> str:
    """
    Create a snapshot and return the task UPID.
    """
    data: dict[str, Any] = {
        "snapname": snapname,
        "description": description,
    }

    # QEMU VMs can optionally include VM state, we skip it for faster snapshots
    if vm_type == "qemu":
        data["vmstate"] = 0

    response = make_request(host_config, "POST", f"{vm_type}/{vmid}/snapshot", data)
    upid = response.get("data")

    if not upid:
        fatal("Snapshot request did not return a task UPID")

    return upid


def delete_lxc_mount_point(host_config: dict, vmid: int, mp_key: str) -> None:
    """Delete a mount point from LXC config."""
    # Proxmox API: setting a key to empty string or using 'delete' param removes it
    make_request(host_config, "PUT", f"lxc/{vmid}/config", {"delete": mp_key})


def restore_lxc_mount_point(
    host_config: dict, vmid: int, mp_key: str, mp_value: str
) -> None:
    """Restore a mount point to LXC config."""
    make_request(host_config, "PUT", f"lxc/{vmid}/config", {mp_key: mp_value})


def create_lxc_snapshot(host_config: dict, vmid: int) -> None:
    """
    Create a snapshot for an LXC container.
    Handles mount points by temporarily removing them.
    """
    # Get current config and extract mount points
    config = get_lxc_config(host_config, vmid)
    mount_points = {k: v for k, v in config.items() if k.startswith("mp")}

    if mount_points:
        info(f"Found {len(mount_points)} mount point(s), temporarily removing...")

    try:
        # Remove mount points
        for mp_key in mount_points:
            info(f"  Removing {mp_key}")
            delete_lxc_mount_point(host_config, vmid, mp_key)

        # Create snapshot
        timestamp = datetime.now().strftime("%d_%m_%Y_%H_%M_%S")
        stack = os.path.basename(os.getcwd())
        snapname = f"pre_deploy_{timestamp}"
        description = f"Pre-deployment of stack {stack} at {datetime.now()}"

        info(f"Creating snapshot '{snapname}'...")
        upid = create_snapshot_request(host_config, "lxc", vmid, snapname, description)
        wait_for_task(host_config, upid)

    finally:
        # ALWAYS restore mount points
        if mount_points:
            info("Restoring mount points...")
            for mp_key, mp_value in mount_points.items():
                info(f"  Restoring {mp_key}")
                try:
                    restore_lxc_mount_point(host_config, vmid, mp_key, mp_value)
                except SystemExit as e:
                    # Log but don't exit - we want to try restoring all mount points
                    print(
                        f"WARNING: Failed to restore {mp_key}: {e}", file=sys.stderr
                    )


def create_qemu_snapshot(host_config: dict, vmid: int) -> None:
    """Create a snapshot for a QEMU VM."""
    timestamp = datetime.now().strftime("%d_%m_%Y_%H_%M_%S")
    stack = os.path.basename(os.getcwd())
    snapname = f"pre_deploy_{timestamp}"
    description = f"Pre-deployment of stack {stack} at {datetime.now()}"

    info(f"Creating snapshot '{snapname}'...")
    upid = create_snapshot_request(host_config, "qemu", vmid, snapname, description)
    wait_for_task(host_config, upid)


def snapshot_vm(host_config: dict, vm_type: str, vmid: int) -> None:
    """Dispatch to the appropriate snapshot function based on VM type."""
    if vm_type == "lxc":
        create_lxc_snapshot(host_config, vmid)
    elif vm_type == "qemu":
        create_qemu_snapshot(host_config, vmid)
    else:
        fatal(f"Unknown VM type: {vm_type}")


def main() -> None:
    """Main entry point."""
    # Load configuration
    config_path = os.environ.get("PROXMOX_CONFIG_PATH", DEFAULT_CONFIG_PATH)
    info(f"Loading config from {config_path}")
    config = load_config(config_path)

    # Get current hostname
    current_hostname = socket.gethostname()
    info(f"Current hostname: {current_hostname}")

    # Find this host in Proxmox
    result = find_host_in_proxmox(config["proxmox_hosts"], current_hostname)

    if result is None:
        fatal(
            f"Hostname '{current_hostname}' not found in any configured Proxmox instance"
        )

    host_config, vm_type, vmid = result

    # Create snapshot
    snapshot_vm(host_config, vm_type, vmid)

    info("Snapshot completed successfully!")


if __name__ == "__main__":
    main()
