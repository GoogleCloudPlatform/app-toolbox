#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Production-grade Interactive Diagnostic Script for Customers/TSEs
# Pure File-System based discovery (No kubectl or crictl)
# Supports Java, Python, Node.js, and eBPF tools
# No colors (plain text output)

set -e
set -u

clear
echo "======================================================="
echo "         Application Performance Collector             "
echo "======================================================="

LOG_DIR="/media/root/var/log/containers"

# Check if log directory exists
if [ ! -d "$LOG_DIR" ]; then
    echo "Error: Directory $LOG_DIR not found."
    echo "Please ensure the host's /var/log is mounted at /media/root/var/log."
    exit 1
fi

# Step 1: Get Pod Name
POD_NAME=""
if [ $# -ge 1 ]; then
    POD_NAME="$1"
else
    read -r -p "Enter the Pod Name: " POD_NAME
fi

if [ -z "$POD_NAME" ]; then
    echo "Error: Pod Name cannot be empty."
    exit 1
fi

# Step 2: Find containers in the pod using file-system logic
echo ""
echo "[1/5] Searching for containers in Pod '$POD_NAME'..."

# List files, filter by pod name, and extract container names
options=($(ls "$LOG_DIR" | grep "^${POD_NAME}_" | awk -F'_' '{print $3}' | sed 's/\.log$//' | sed 's/-[^-]*$//' | sort -u))

if [ ${#options[@]} -eq 0 ]; then
    echo "Error: No logs found for Pod '$POD_NAME' in $LOG_DIR."
    exit 1
fi

echo "Select the Container to profile:"
select opt in "${options[@]}"
do
    if [ -n "$opt" ]; then
        echo "Selected Container: $opt"
        break
    else
        echo "Invalid selection, try again."
    fi
done

# Step 3: Extract Container ID from the filename
echo ""
echo "[2/5] Resolving Container ID..."
SPECIFIC_FILE=$(ls "$LOG_DIR" | grep "^${POD_NAME}_.*_${opt}-" | head -n 1)
TEMP=${SPECIFIC_FILE%.log}
CONTAINER_ID=${TEMP##*-}

if [ -z "$CONTAINER_ID" ]; then
    echo "Error: Could not resolve Container ID."
    exit 1
fi
echo "Resolved Container ID: $CONTAINER_ID"

# Step 4: Resolve Host PID via /proc
echo ""
echo "[3/5] Resolving Host PID via /proc..."
PID=$(find /proc -maxdepth 2 -name cgroup -exec grep -l "$CONTAINER_ID" {} + | head -n 1 | cut -d'/' -f3)

if [ -z "$PID" ] || [ "$PID" -eq 0 ]; then
    echo "Error: Could not resolve Host PID. Ensure you have host PID access."
    exit 1
fi
echo "Resolved Host PID: $PID"

# Step 5: Ask for Language
echo ""
echo "[4/5] Select Application Language"
langs=("Java" "Python" "Node.js" "Golang")
select lang in "${langs[@]}"
do
    case $lang in
        "Java") LANG="java"; break;;
        "Python") LANG="python"; break;;
        "Node.js") LANG="node"; break;;
        "Golang") LANG="go"; break;;
        *) echo "Invalid option, try again.";;
    esac
done
echo "Selected Language: $lang"

# Step 5.5: Ask for Duration (No colors, explicit message)
echo ""
echo "[5/5] Enter Profiling Duration"
read -r -p "Enter duration in seconds [Press Enter for default 60s, Max 120s]: " DURATION

# If the user just presses Enter, default to 60 seconds
DURATION=${DURATION:-60}

# Safety Guardrail: Hard cap at 120 seconds
if [ "$DURATION" -gt 120 ]; then
    echo "Error: For safety, the maximum allowed duration is 120 seconds."
    exit 1
fi

echo "Selected Duration: ${DURATION}s"

# Step 6: Collect Data
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_DIR="profile_${opt}_${TIMESTAMP}"
WORK_DIR="/var/${REPORT_DIR}"
mkdir -p "$WORK_DIR"
FILE_PREFIX="${WORK_DIR}/profile"

echo ""
echo "Starting Data Collection (Production Optimized)..."
# Production safety: Cap duration for potentially heavy tools (Node eBPF, Go perf) to max 30s
SAFE_DURATION=$(( DURATION > 30 ? 30 : DURATION ))

case $LANG in
    "java")
        echo "Starting JDK Flight Recorder (JFR) profiling via zero-copy jattach..."
        # 1. Start the JFR recording inside the container namespaces (zero copy)
        container-exec "$PID" /usr/bin/jattach 1 jcmd "JFR.start name=prod_profile settings=profile filename=/tmp/profile.jfr" || true
        
        # 2. Capture initial diagnostics (Thread Dump, Class Histogram, VM Info)
        echo "Capturing initial diagnostics (Thread Dump, Class Histogram, VM Info)..."
        container-exec "$PID" /usr/bin/jattach 1 threaddump > "${FILE_PREFIX}_threaddump_start.txt" || true
        container-exec "$PID" /usr/bin/jattach 1 jcmd "GC.class_histogram" > "${FILE_PREFIX}_class_histogram.txt" || true
        container-exec "$PID" /usr/bin/jattach 1 jcmd "VM.info" > "${FILE_PREFIX}_vm_info.txt" || true
        
        # 3. Wait for the profiling duration
        echo "Profiling for ${DURATION} seconds..."
        sleep "$DURATION"
        
        # 4. Capture final thread dump (to compare thread states over time)
        echo "Capturing final thread dump..."
        container-exec "$PID" /usr/bin/jattach 1 threaddump > "${FILE_PREFIX}_threaddump_end.txt" || true
        
        # 5. Stop the JFR recording inside the container namespaces
        container-exec "$PID" /usr/bin/jattach 1 jcmd "JFR.stop name=prod_profile" || true
        
        # 6. Move the JFR file from the container's /tmp to the report folder
        if [ -f "/proc/$PID/root/tmp/profile.jfr" ]; then
            mv "/proc/$PID/root/tmp/profile.jfr" "${FILE_PREFIX}.jfr"
            echo "Successfully retrieved JFR profile."
        else
            echo "Error: JFR profile was not generated."
        fi
        ;;
    "python")
        echo "Running py-spy..."
        nice -n 19 py-spy record -d "$DURATION" --idle --nonblocking -o "${FILE_PREFIX}.svg" --pid "$PID" || true
        ;;
    "node")
        echo "Node.js: Will capture off-cpu profile via bpftrace in the next step..."
        ;;
    "go")
        echo "Golang: Running bpftrace on-CPU profiler (sampling user stacks at 99Hz for ${DURATION}s)..."
        if command -v bpftrace &> /dev/null; then
            nice -n 19 timeout "$DURATION" bpftrace -e '
            profile:hz:99 /pid == '"$PID"'/ {
                @[ustack] = count();
            }' > "${FILE_PREFIX}_go_cpu_profile.txt" || true
            echo "On-CPU stack traces saved to ${FILE_PREFIX}_go_cpu_profile.txt"
        else
            echo "Warning: bpftrace not found. Skipping Go CPU profiling."
            sleep "$DURATION"
        fi
        ;;
esac
# Always run core eBPF tools for system view
echo ""
echo "Collecting eBPF Diagnostics (Disk & Network)..."

# Resolve target container network namespace inode
CONTAINER_NETNS=""
if [ -f "/proc/$PID/ns/net" ]; then
    CONTAINER_NETNS=$(readlink "/proc/$PID/ns/net" | sed -E 's/net:\[([0-9]+)\]/\1/')
fi

find_bpftrace_tool() {
    local tool_name="$1"
    local paths=(
        "/usr/share/bpftrace/tools"
        "/usr/sbin"
        "/usr/local/share/bpftrace/tools"
    )
    for p in "${paths[@]}"; do
        if [ -f "${p}/${tool_name}" ]; then
            echo "${p}/${tool_name}"
            return 0
        fi
    done
    return 1
}

if command -v bpftrace &> /dev/null; then
    # 1. Disk Latency (Separated by resolved device names)
    echo "Running biolatency (15s)..."
    nice -n 19 timeout 15 bpftrace -e '
    tracepoint:block:block_rq_issue {
      @start[args->dev, args->sector] = nsecs;
    }
    tracepoint:block:block_rq_complete /@start[args->dev, args->sector]/ {
      @usecs[args->dev] = hist((nsecs - @start[args->dev, args->sector]) / 1000);
      delete(@start[args->dev, args->sector]);
    }
    END { clear(@start); }' > "${FILE_PREFIX}_biolatency.txt" || true

    # 2. Network Retransmits (Tagging both Container and Node events)
    echo "Running tcpretrans (15s)..."
    nice -n 19 timeout 15 bpftrace -e '
    tracepoint:tcp:tcp_retransmit_skb {
      if (curtask->nsproxy->net_ns->ns.inum == '"$CONTAINER_NETNS"') {
        printf("[CONTAINER] TCP Retransmit: %s:%d -> %s:%d\n", 
               ntop(args->saddr), args->sport, 
               ntop(args->daddr), args->dport);
      } else {
        printf("[NODE] TCP Retransmit: %s:%d -> %s:%d\n", 
               ntop(args->saddr), args->sport, 
               ntop(args->daddr), args->dport);
      }
    }' > "${FILE_PREFIX}_tcpretrans.txt" || true

    # 3. Off-CPU Time (Inline script to avoid missing file error)
    echo "Running offcputime for PID $PID (15s)..."
    nice -n 19 timeout 15 bpftrace -e '
    tracepoint:sched:sched_switch {
      if (pid == '"$PID"') {
        @start[args->prev_pid] = nsecs;
        @stack[args->prev_pid] = ustack;
      }
      $start = @start[args->next_pid];
      if ($start) {
        @offcpu[@stack[args->next_pid]] = sum((nsecs - $start) / 1000);
        delete(@start[args->next_pid]);
        delete(@stack[args->next_pid]);
      }
    }
    END { clear(@start); clear(@stack); }' > "${FILE_PREFIX}_offcpu.txt" || true
else
    echo "Warning: bpftrace not found. Skipping Node-Level eBPF Diagnostics."
fi

# Post-process Biolatency to resolve raw device IDs to actual device names
if [ -f "${FILE_PREFIX}_biolatency.txt" ]; then
  dev_ids=$(grep -oE '@usecs\[[0-9]+\]:' "${FILE_PREFIX}_biolatency.txt" | grep -oE '[0-9]+' | sort -u)
  for dev_id in $dev_ids; do
    major=$(( dev_id >> 20 ))
    minor=$(( dev_id & 0xfffff ))
    if [ -L "/sys/dev/block/${major}:${minor}" ]; then
      dev_name=$(basename "$(readlink "/sys/dev/block/${major}:${minor}")")
      sed -i "s/\[${dev_id}\([]|,]\)/[${dev_name}\1/g" "${FILE_PREFIX}_biolatency.txt"
    fi
  done
fi

TARBALL="/var/${REPORT_DIR}.tar.xz"
echo "Packaging report into ${TARBALL}..."
tar -cJf "$TARBALL" -C "/var" "$REPORT_DIR"
rm -rf "$WORK_DIR"
CHECKSUM=$(sha256sum "$TARBALL" | cut -d' ' -f1)

echo "======================================================="
echo "Success! Your report has been generated and saved in:"
echo "  $TARBALL"
echo ""
echo "The checksum is: $CHECKSUM"
echo "======================================================="
