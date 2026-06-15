<!--
Copyright 2026 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# App Toolbox with Application Performance Collector

This is a customized version of the COS Toolbox image, modified to include a suite of production-grade profiling tools for multiple languages and system-level diagnostics.

## Features

*   **Java**: Zero-copy JDK Flight Recorder (JFR) profiling via `jattach` (Production-safe, works on read-only containers, no files written/copied to container filesystem).
*   **Python**: `py-spy` (Optimized with `--nonblocking` and `--idle` for production safety).
*   **Golang**: eBPF-based on-CPU profiling via `bpftrace` (sampling user stacks at 99Hz).
*   **Node.js**: Fallback to eBPF-based off-CPU profiling.
*   **eBPF Diagnostics**: CO-RE (Compile Once - Run Everywhere) versions of `biolatency`, `tcpretrans`, and `offcputime` via `bpftrace` (No kernel headers needed!).
*   **Auto-Packaging**: Results are saved in a unique directory, compressed into a `.tar.xz` file, and checksummed with SHA-256.

---

## Prerequisites (Node Configuration)

To run eBPF tools successfully inside this container on a Container-Optimized OS (COS) node, you **must** override the default `toolbox` binds and permissions. 

Add the following lines to your `${HOME}/.toolboxrc` file on the COS host:

```

TOOLBOX_DOCKER_IMAGE="<your-artifact-registry-path>/app-toolbox"
TOOLBOX_DOCKER_TAG="0.2"
TOOLBOX_BIND="--bind=/:/media/root --bind=/usr:/media/root/usr --bind=/run:/media/root/run --bind=/sys:/sys --bind=/proc:/proc"
TOOLBOX_ENV="--system-call-filter=bpf --system-call-filter=perf_event_open"
```

*Note: The `TOOLBOX_BIND` adds `/sys` and `/proc` mounts, and `TOOLBOX_ENV` unlocks the necessary system calls for eBPF.*

---

## How to Build

To build the image using Google Cloud Build:

```

gcloud builds submit --config cloudbuild.yaml .
```

This will push the image to your configured Artifact Registry location.

---

## How to Use

1.  SSH into your GKE node.
2.  Ensure your `~/.toolboxrc` is configured as shown in the Prerequisites.
3.  Launch the toolbox:

    ```
    toolbox
    ```

4.  Run the interactive collector script:

    ```
    app-collector
    ```

5.  Follow the prompts to select the Pod, Container, Language, and Duration.

At the end of the run, the script will output the path to the generated `.tar.xz` report file in `/var`.

### Transferring Files Into and Out of the Toolbox

* The host root filesystem is accessible inside the toolbox container at **`/media/root`**.
* The toolbox filesystem is accessible from the host at **`/var/lib/toolbox/<USER>-gcr.io_cos-cloud_toolbox-<VERSION>/root/`** (where `<USER>` is your username and `<VERSION>` is the toolbox image version).

#### Examples:

1. **Access the host filesystem inside the toolbox:**

   ```
   USER@cos-dev ~ $ toolbox
   root@cos-dev:~# ls /media/root
   bin  boot  dev  etc  home  lib  lib64  ...
   root@cos-dev:~# cp /media/root/home/USER/some-file .
   ```

2. **Access the toolbox directory from the host:**

   ```
   USER@cos-dev ~ $ sudo cp some-file /var/lib/toolbox/USER-gcr.io_cos-cloud_toolbox-v20220722/root
   ```

3. **Run a command inside the toolbox and save its output to the host user's home directory:**

   ```
   USER@cos-dev ~ $ toolbox strace -o /media/root/$HOME/ls.strace ls
   USER@cos-dev ~ $ more $HOME/ls.strace
   ```

---

## Disclaimer

This is not an officially supported Google product. This project is not eligible for the [Google Open Source Software Vulnerability Rewards Program](https://bughunters.google.com/open-source-security).

