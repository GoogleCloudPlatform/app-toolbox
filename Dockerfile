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

FROM marketplace.gcr.io/google/ubuntu2404

ENV DEBIAN_FRONTEND noninteractive

# Install prerequisites and tools
RUN apt-get update && apt-get install -y -qq --no-install-recommends \
    python3-pip \
    xz-utils \
    procps \
    bpftrace \
    jattach \
    && apt-get clean

# Install py-spy
RUN pip3 install py-spy --break-system-packages

# Copy the namespace runner helper
COPY container-exec.py /usr/local/bin/container-exec
RUN chmod +x /usr/local/bin/container-exec

# Copy the interactive collector script and make it executable
COPY app-collector.sh /usr/local/bin/app-collector
RUN chmod +x /usr/local/bin/app-collector

# Copy Third-Party Notices and Licenses
COPY third_party/THIRD_PARTY_NOTICES.txt /THIRD_PARTY_NOTICES.txt

# Set the working directory
WORKDIR /usr/local/bin

CMD ["/bin/bash"]
