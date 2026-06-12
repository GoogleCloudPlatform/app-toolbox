# App Toolbox & Collector FAQ

This FAQ covers the architectural choices, configuration, and troubleshooting methods for all languages and system diagnostics supported by the custom App Toolbox and the `app-collector` orchestrator.

---

## 1. What is this tool?

The **App Toolbox** is a specialized version of the Google Container-Optimized OS (COS) Toolbox container image. It is pre-packaged with production-safe runtime diagnostic tools (`jattach`, `py-spy`, `bpftrace`) and a wrapper orchestrator script called **`app-collector`**.

**`app-collector`** detects running container PIDs on the GKE node, identifies their runtime languages, and executes targeted diagnostic collections, packaging the results into a single checksummed `.tar.xz` archive.

---

## 2. Why not use Kubernetes Ephemeral Debug Containers (`kubectl debug`)?

### Q: Why is `kubectl debug` a bad choice for profiling running applications?
To profile or debug a process (using tools like `py-spy` for Python) from another container, the debugging tool must execute the **`ptrace`** system call. In Linux, this requires the **`SYS_PTRACE`** security capability.

1. **The Restart Trap:** GKE production pods are run with strict security profiles that block `SYS_PTRACE` and isolate process namespaces. If a pod was not deployed with `shareProcessNamespace: true` and `cap_add: [SYS_PTRACE]` at boot time, launching an ephemeral debug container against it will fail to trace the application process.
2. **Downtime & State Destruction:** To add these permissions to a debug container, you must edit the pod spec and **restart/recreate the target pod**. Restarting a production pod:
   * Triggers temporary service disruption.
   * **Destroys the transient error state** (leaked memory, hung threads, deadlocks) that you were trying to diagnose, making it impossible to capture the root cause.

### Q: Why is the Node-level Toolbox approach superior?
* The COS Toolbox runs directly inside the host node's namespace with elevated privileges.
* Since the toolbox has host-level permissions, it can trace **any container running on that GKE node** on-demand.
* This allows you to attach to and profile **live, unmodified production containers with zero downtime, zero restarts, and zero prior security modifications** to the target application pods.

---

## 3. What makes profiling Java inside containers difficult, and how do we solve it?

### The Java Attach Obstacles
Java diagnostic attachment (the JVM Attach Protocol) relies on Unix Domain Sockets and filesystem visibility. In GKE, three major barriers prevent standard tools from attaching:

1. **The Mount Namespace Barrier (Socket Path Resolution):**
   * When you run an attach client, the JVM inside the container creates a socket file at `/tmp/.java_pid<PID>` (where `<PID>` is the container-internal PID, usually `1`).
   * If you try to run `jcmd` from the host node, the client looks for the socket in the host's `/tmp` directory, which is completely isolated from the container's `/tmp` filesystem. The attach client will fail to find the socket and abort.
2. **The File Ownership & UID Check:**
   * For security reasons, the target JVM checks the credentials of the incoming socket attachment. The attaching client's UID **must exactly match** the UID of the JVM process inside the container. 
   * If the container runs as a non-root user (e.g., UID `1000`) and the toolbox runs as `root` on the host, the JVM rejects the attach request.
3. **The Library Visibility Constraint:**
   * Traditional profilers (like `async-profiler`) work by instructing the target JVM to dynamically load a `.so` library from the host. Because the container mount namespace is isolated, the JVM inside the container cannot access the host filesystem to load this library, resulting in silent attachment failures.

### Our Solution
We bypass all three barriers by combining **`container-exec`** and **`jattach`**:
* **Namespace Alignment:** `container-exec` enters both the target container's PID namespace and Mount namespace.
* **Internal Path Resolution:** By executing inside the container's Mount namespace, the `jattach` binary searches for the socket directly in the container's own `/tmp/` directory, resolving `/tmp/.java_pid1` successfully.
* **UID Switching:** `jattach` matches the target container's UID when creating the attachment handshake files, satisfying the JVM's ownership security check.
* **Zero-copy Built-ins:** Instead of loading a host-level dynamic library, we run standard `jcmd` commands via `jattach` to invoke **JDK Flight Recorder (JFR)**. Since JFR is built directly into the OpenJDK runtime, it does not need to load any files from the host node filesystem, running fully in memory on the container side.

---

## 4. Diagnostics by Language & Runtime

### ☕ Java
* **Tools used:** `jattach` (interacting with the JVM's built-in `jcmd` listener via container namespaces).
* **Outputs:** `profile.jfr` (Flight Recorder profile), `profile_threaddump_start.txt`, `profile_threaddump_end.txt`, `profile_class_histogram.txt`, `profile_vm_info.txt`.
* **Why this approach:** 
  * **Zero-Copy Security:** `jattach` transitions to the container mount namespace using `container-exec` in memory, writing zero bytes to the container's disk. This allows it to run on secure `readOnlyRootFilesystem=true` pods without triggering file-integrity alerts.
  * **Zero-Overhead profiling:** JDK Flight Recorder (JFR) runs in the JVM kernel with `<1%` overhead, saving raw binary events and avoiding the JVM-freezing HTML rendering cycles of tools like `async-profiler`.

### 🐍 Python
* **Tools used:** `py-spy` (sampling profiler).
* **Outputs:** `profile.svg` (Interactive SVG flame graph of Python execution).
* **Why this approach:**
  * **Non-intrusive:** `py-spy` reads the process memory space (`process_vm_readv`) from the host side, meaning it doesn't need to run code inside the Python container.
  * **GIL Protection (`--nonblocking`):** We use `--nonblocking` to prevent `py-spy` from pausing the Python Global Interpreter Lock (GIL). If the app is busy, standard profilers block the lock and cause production requests to time out.
  * **I/O Detection (`--idle`):** We use `--idle` so that Python threads blocked on I/O (sleeping/waiting) are still sampled. This is critical for web servers that spend most of their time waiting on DBs or external APIs.

### 🐹 Golang
* **Tools used:** `bpftrace` (sampling on-CPU user stacks at 99Hz).
* **Outputs:** `profile_go_cpu_profile.txt` (On-CPU user stack traces).
* **Why this approach:**
  * Go binaries are fully compiled and have no runtime agent loop. By sampling user stack traces directly from the Linux kernel using eBPF, we can profile CPU hotspots in production Go applications with negligible overhead ($\approx 1\%$), completely avoiding the need to run intrusive debuggers (like Delve) or expose debugger ports.

### 🟢 Node.js
* **Approach:** Node.js applications do not have a built-in zero-copy runtime diagnostic socket. 
* **Collection:** The tool falls back to system-level **off-CPU eBPF tracing** targeting the Node PID to locate scheduling bottlenecks and identify if threads are spending time in asynchronous event loop delays.

---

## 5. System-Level eBPF Diagnostics (Always Active)

Regardless of the target language, `app-collector` executes three system-level **`bpftrace`** scripts. These run directly in the Linux kernel space using BTF (BPF Type Format) on the COS host, requiring no kernel headers or compilers.

| Tool / Output | What it measures | Why it's useful |
| :--- | :--- | :--- |
| **`profile_biolatency.txt`** | Disk block I/O latency histogram | Traces if slowness is caused by slow cloud disks (high IOPS latency). |
| **`profile_tcpretrans.txt`** | TCP network packet retransmissions | Detects network packet drops or broken routes on the GKE node. |
| **`profile_offcpu.txt`** | Off-CPU scheduling time for target PID | Pinpoints if the target process is sleeping/blocked on resources rather than computing. |

---

## 6. How do I build and run it?

### Q: How do I build the custom image?
Run this command from the toolbox directory on your workspace:

```bash
gcloud builds submit --config cloudbuild.yaml .
```

### Q: What are the GKE host prerequisites?
Tracepoints and eBPF diagnostics require kernel mounts. Place this in `~/.toolboxrc` on the COS node host filesystem:

```bash
TOOLBOX_DOCKER_IMAGE="<your-artifact-registry-path>/app-toolbox"
TOOLBOX_DOCKER_TAG="0.2"
TOOLBOX_BIND="--bind=/:/media/root --bind=/usr:/media/root/usr --bind=/run:/media/root/run --bind=/sys:/sys --bind=/proc:/proc"
TOOLBOX_ENV="--system-call-filter=bpf --system-call-filter=perf_event_open"
```

### Q: How do I run a diagnostic collection?
1. SSH into the GKE Node.
2. Start the toolbox:
   ```bash
   toolbox
   ```
3. Launch the interactive script:
   ```bash
   app-collector
   ```

---

## 7. Detailed Output Analysis Guide

### ☕ Analyzing Java Diagnostics

#### A. High CPU / Code Bottleneck
1. Open JDK Mission Control (JMC) and load **`profile.jfr`**.
2. Go to **Method Profiling** -> **Flame View**.
3. Locate the horizontal bars. A flame graph displays method execution calls stacked vertically:
   * The **horizontal width** of a block represents the percentage of total CPU cycles consumed by that method.
   * If a method like `FlawedApp.burnCpu()` takes up 95% of the frame width, you have found the CPU burner.
   * Look for deep call stack structures that repeat (indicating unoptimized loops or deep recursions).

#### B. Lock Contention & Thread Blocking
1. Open and compare **`profile_threaddump_start.txt`** and **`profile_threaddump_end.txt`** side-by-side using `diff` or a text editor.
2. Search for threads in the **`BLOCKED`** state:
   ```text
   "pool-1-thread-2" #15 prio=5 os_prio=0 cpu=1.23ms elapsed=42s tid=0x000079c6d4008a00 nid=0x250b waiting for monitor entry  [0x000079c6da04b000]
      java.lang.Thread.State: BLOCKED (on object monitor)
       at FlawedApp$1.handle(FlawedApp.java:29)
       - waiting to lock <0x0000000780a1c1d8> (a java.lang.Object)
       - waiting on ... held by thread "pool-1-thread-1"
   ```
3. Trace the monitor memory address (`<0x0000000780a1c1d8>`).
4. Find the holder thread (`pool-1-thread-1`). Look at its stack trace to see what it is doing while holding the lock (e.g. `java.lang.Thread.sleep()` or waiting on an un-timed socket read).

#### C. Memory Leaks & GC Pause Spikes
1. Open **`profile_class_histogram.txt`**.
2. Examine the top instances:
   ```text
    num     #instances         #bytes  class name (module)
   -------------------------------------------------------
      1:         120352       35234120  [B (java.base@21.0.11)
      2:          22100         530400  java.lang.String (java.base@21.0.11)
   ```
   * **`[B`** means primitive **byte arrays** (`byte[]`).
   * **`[C`** means primitive **character arrays** (`char[]`).
   * **`[Ljava.lang.Object;`** means an array of Object references.
3. If `[B` is consuming 80%+ of the heap bytes, the leak is byte-buffer related. Search your code for static lists, un-closed streams, or heavy cache blocks.
4. Load **`profile.jfr`** in JMC, go to the **Garbage Collections** view. Verify if the GC Pauses graph shows a diagonal rising line of heap memory and if the GC execution intervals approach `100%` duration.

---

### 🐍 Analyzing Python Diagnostics

1. Open **`profile.svg`** in any web browser.
2. The graph displays stack depth vertically and CPU usage horizontally.
3. **Interpret the colors and layout:**
   * Hover over any method to see its full path, file source, and line number.
   * Search (Ctrl+F or top-right search box) for specific package names.
   * **GIL Contention:** Python's Global Interpreter Lock (GIL) limits execution to one thread. If multiple thread bars stack up on `acquire_lock` or internal lock frames, your application is blocked on GIL synchronization. You will need to move CPU-heavy tasks to multiprocessing blocks instead of multithreading.
   * **IO Block:** Since we used the `--idle` flag, threads blocked on database operations or network reads (e.g. `socket.recv`) will show up with wide blocks. Look at the stack frames below them to find which DB query or external API call is slowing down the application.

---

### 🐹 Analyzing Go Diagnostics

1. Open **`profile_go_cpu_profile.txt`**.
2. This file contains kernel-level CPU sampling stack dumps:
   * The leaf functions (at the top of the dump groups) represent functions that were active on the CPU when the scheduler sampled them.
   * Look for user functions that accumulate the highest sample count. If a runtime scheduler function like `runtime.cgocall` or `runtime.selectgo` appears frequently, it indicates high system overhead or continuous channel multiplexing loops.

---

### 🔍 Analyzing Host & System Diagnostics (eBPF)

#### A. Disk Latency (`profile_biolatency.txt`)
* Shows a log-linear histogram of disk block I/O execution times in microseconds:
  ```text
     usecs               : count    distribution
       256 -> 511        : 14       |**********                          |
       512 -> 1023       : 42       |************************************|
      1024 -> 2047       : 3        |**                                  |
  ```
* **Interpretation:** 
  * Latency under `2000 usecs` (2ms) is normal for SSDs.
  * If you see counts in the ranges `16384 -> 32767` (16ms to 32ms) or higher, the GKE node storage disks are throttled or saturated, causing execution slowness.

#### B. Network Packet Loss (`profile_tcpretrans.txt`)
* Records occurrences of kernel-level TCP packet retransmissions:
  ```text
  [CONTAINER] TCP Retransmit: 10.68.8.5:8080 -> 34.120.5.2:54812
  ```
* **Interpretation:** 
  * If this file is empty, the GKE node has no packet loss.
  * If you see logs starting with `[CONTAINER]`, there is active GKE network packet loss or TCP connection drops occurring inside your container namespace.

#### C. CPU Scheduler Wait Time (`profile_offcpu.txt`)
* Lists execution stacks representing time spent sleeping or blocked off-CPU:
  ```text
  @offcpu[
      [ustack]
      java.lang.Thread.sleep+0x52
      FlawedApp$1.handle+0x8a
  ]: 1205400
  ```
* **Interpretation:** 
  * The numbers show cumulative off-CPU duration in milliseconds. 
  * This validates whether a thread is slow because it is blocked (high off-cpu time) or because it is executing heavy logic on the CPU core (low off-cpu time, high JFR execution samples).
