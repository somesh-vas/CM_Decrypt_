#!/bin/sh
# Collect host/device specifications and detailed GPU properties.

set -u

usage() {
    echo "Usage: $0 [output_file]" >&2
    echo "Example: $0 specs_report.txt" >&2
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

section() {
    printf '\n========== %s ==========\n' "$1"
}

print_kv() {
    printf '%-22s %s\n' "$1:" "$2"
}

run_cmd() {
    label="$1"
    shift
    printf '\n-- %s --\n' "$label"
    if "$@"; then
        :
    else
        echo "Unavailable or command failed."
    fi
}

print_dmi() {
    label="$1"
    path="$2"
    if [ -r "$path" ]; then
        value="$(cat "$path" 2>/dev/null || true)"
        if [ -n "${value:-}" ]; then
            print_kv "$label" "$value"
        fi
    fi
}

OUT_FILE=""

if [ "$#" -gt 1 ]; then
    usage
    exit 1
fi

if [ "$#" -eq 1 ]; then
    OUT_FILE="$1"
    exec 3>&1
    : > "$OUT_FILE" || {
        echo "Error: cannot write to output file: $OUT_FILE" >&2
        exit 1
    }
    exec >"$OUT_FILE" 2>&1
fi

section "Report Metadata"
print_kv "Generated" "$(date 2>/dev/null || echo N/A)"

section "System Overview"
print_kv "Hostname" "$(hostname 2>/dev/null || echo N/A)"

if [ -r /etc/os-release ]; then
    os_name="$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'=' -f2- | tr -d '"' 2>/dev/null)"
    print_kv "Operating System" "${os_name:-N/A}"
fi

print_kv "Kernel" "$(uname -r 2>/dev/null || echo N/A)"
print_kv "Architecture" "$(uname -m 2>/dev/null || echo N/A)"
print_kv "Uptime" "$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo N/A)"

section "CPU"
if has_cmd lscpu; then
    run_cmd "CPU details (lscpu)" lscpu
elif [ -r /proc/cpuinfo ]; then
    run_cmd "CPU details (/proc/cpuinfo summary)" sh -c \
        "grep -m1 'model name' /proc/cpuinfo; grep -m1 'vendor_id' /proc/cpuinfo; grep -m1 'cpu cores' /proc/cpuinfo; grep -c '^processor' /proc/cpuinfo | awk '{print \"logical_cpus: \" \$1}'"
else
    echo "CPU details unavailable."
fi

section "Memory"
if has_cmd free; then
    run_cmd "Memory usage (free -h)" free -h
fi

if [ -r /proc/meminfo ]; then
    run_cmd "Memory details (/proc/meminfo)" sh -c \
        "grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree' /proc/meminfo"
fi

section "Storage"
if has_cmd lsblk; then
    run_cmd "Block devices (lsblk)" lsblk -o NAME,MODEL,SIZE,TYPE,FSTYPE,MOUNTPOINT
fi

if has_cmd df; then
    run_cmd "Filesystem usage (df -hT)" df -hT
fi

section "Motherboard / BIOS"
print_dmi "System Vendor" /sys/class/dmi/id/sys_vendor
print_dmi "Product Name" /sys/class/dmi/id/product_name
print_dmi "Product Version" /sys/class/dmi/id/product_version
print_dmi "Board Vendor" /sys/class/dmi/id/board_vendor
print_dmi "Board Name" /sys/class/dmi/id/board_name
print_dmi "Board Version" /sys/class/dmi/id/board_version
print_dmi "BIOS Version" /sys/class/dmi/id/bios_version
print_dmi "BIOS Date" /sys/class/dmi/id/bios_date

section "Display Adapters (PCI)"
if has_cmd lspci; then
    run_cmd "PCI display devices (lspci)" sh -c \
        "lspci | grep -Ei 'VGA|3D|Display'"
else
    echo "lspci not installed."
fi

section "GPU - NVIDIA"
if has_cmd nvidia-smi; then
    run_cmd "GPU list (nvidia-smi -L)" nvidia-smi -L
    run_cmd "Driver and live status (nvidia-smi)" nvidia-smi
    run_cmd "Per-GPU properties (CSV query)" nvidia-smi \
        --query-gpu=index,name,uuid,pci.bus_id,driver_version,vbios_version,memory.total,memory.used,memory.free,utilization.gpu,utilization.memory,temperature.gpu,power.draw,power.limit,clocks.current.graphics,clocks.current.sm,clocks.current.memory \
        --format=csv
    run_cmd "Full NVIDIA query (nvidia-smi -q)" nvidia-smi -q
else
    echo "nvidia-smi not installed or no NVIDIA GPU detected."
fi

if has_cmd nvcc; then
    run_cmd "CUDA compiler version (nvcc --version)" nvcc --version
fi

section "GPU - AMD / ROCm"
if has_cmd rocm-smi; then
    run_cmd "ROCm SMI (rocm-smi)" rocm-smi
else
    echo "rocm-smi not installed."
fi

if has_cmd rocminfo; then
    run_cmd "ROCm hardware info (rocminfo)" rocminfo
fi

section "GPU - OpenCL"
if has_cmd clinfo; then
    run_cmd "OpenCL platforms/devices (clinfo)" clinfo
else
    echo "clinfo not installed."
fi

section "End Of Report"
echo "Completed."

if [ -n "$OUT_FILE" ]; then
    printf 'Report written to: %s\n' "$OUT_FILE" >&3
    exec 3>&-
fi
