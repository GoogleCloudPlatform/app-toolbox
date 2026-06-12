#!/usr/bin/env python3
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

import os
import sys

if len(sys.argv) < 4:
    print("Usage: container-exec <target_host_pid> <host_binary_path> <args...>")
    sys.exit(1)

target_pid = sys.argv[1]
binary_path = sys.argv[2]
binary_args = sys.argv[3:]

# 1. Open the host binary to get a file descriptor
try:
    binary_fd = os.open(binary_path, os.O_RDONLY)
except Exception as e:
    print(f"Failed to open binary {binary_path}: {e}")
    sys.exit(1)

# 2. Open target container namespace descriptors
try:
    mnt_ns = os.open(f"/proc/{target_pid}/ns/mnt", os.O_RDONLY)
    pid_ns = os.open(f"/proc/{target_pid}/ns/pid", os.O_RDONLY)
except Exception as e:
    print(f"Failed to open namespace files for PID {target_pid}: {e}")
    sys.exit(1)

# 3. Enter target PID namespace (requires fork to activate)
try:
    os.setns(pid_ns, 0)
except Exception as e:
    print(f"Failed to setns PID: {e}")
    sys.exit(1)

child_pid = os.fork()
if child_pid == 0:
    # Inside child (now running in container's PID namespace)
    # 4. Enter target Mount namespace
    try:
        os.setns(mnt_ns, 0)
    except Exception as e:
        print(f"Failed to setns Mount: {e}")
        sys.exit(1)
    
    # Close namespace file descriptors as they are no longer needed
    os.close(mnt_ns)
    os.close(pid_ns)
    
    # 5. Execute the binary directly via /proc/self/fd/<fd>
    try:
        os.execve(f"/proc/self/fd/{binary_fd}", [binary_path] + binary_args, os.environ)
    except Exception as e:
        print(f"execve failed: {e}")
        sys.exit(1)
else:
    # Parent waits for child
    # Close file descriptors in parent since they are not needed here
    os.close(binary_fd)
    os.close(mnt_ns)
    os.close(pid_ns)
    _, status = os.waitpid(child_pid, 0)
    sys.exit(os.waitstatus_to_exitcode(status))
