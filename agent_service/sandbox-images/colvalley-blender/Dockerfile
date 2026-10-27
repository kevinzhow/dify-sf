# syntax=docker/dockerfile:1.7
# Sandbox image of the executor profile `colvalley-blender` (docs/agent-v2.md, "Profile colvalley-blender").
#
# Built by agent_service/tool/build_sandbox_image.sh colvalley-blender, which passes the named build context
# `blender` = a directory holding the official Blender archive (never downloaded here):
#
#   blender-5.2.3-linux-x64.tar.xz   https://download.blender.org/release/Blender5.2/ (SHA-256 below is the one
#                                    published in blender-5.2.3.sha256)
#
# Contents: Dify's sandbox (shellctl, Python 3.12, Node, git; Debian 12) plus
#   /opt/blender       Blender 5.2.3, used with -b; EEVEE/Workbench through EGL on a DRI render node
#   Weston, D-Bus, GTK 3, fonts and Mesa 25 (bookworm-backports: Debian 12's Mesa 22.3 does not drive Intel Xe2 /
#                      Lunar Lake on the `xe` kernel driver, K17's GPU) for the colvalley-3d Flutter Linux bundle
#   /opt/cv3d-venv     Python with the board tool's packages (requirements.txt), because sandboxes have no egress
# The colvalley-3d checkout itself is not in the image: the profile mounts a prepared checkout read-only at
# /opt/colvalley-3d (tools/board/prepare_checkout.sh in colvalley-3d).
FROM langgenius/dify-agent-local-sandbox:1.17.1@sha256:f4d404c9dcdf80bd72f65e84c3f2bbd1f3404fd4b363db837176da8aaf771b1d

ARG BLENDER_ARCHIVE=blender-5.2.3-linux-x64.tar.xz
ARG BLENDER_SHA256=78486c018b4443efe5e75ab54c290ed8c15abafd249b862c2c9ce2530a918eec

USER root

# Mesa (and its libdrm / LLVM) from bookworm-backports; everything else from bookworm.
RUN printf '%s\n' 'Types: deb' 'URIs: http://deb.debian.org/debian' 'Suites: bookworm-backports' 'Components: main' \
      'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' > /etc/apt/sources.list.d/backports.sources \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      weston dbus dbus-user-session libgtk-3-0 libgtk-3-common shared-mime-info fontconfig fonts-dejavu-core xkb-data \
      libx11-6 libx11-xcb1 libxi6 libxxf86vm1 libxfixes3 libxrender1 libxext6 libxrandr2 libxinerama1 libxcursor1 \
      libxkbcommon0 libxkbcommon-x11-0 libsm6 libice6 libwayland-client0 libwayland-cursor0 libwayland-egl1 \
      libdecor-0-0 libglvnd0 libgl1 libegl1 libgles2 libvulkan1 xz-utils \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -t bookworm-backports \
      libgl1-mesa-dri libegl-mesa0 libglx-mesa0 libgbm1 mesa-libgallium mesa-vulkan-drivers \
 && rm -rf /var/lib/apt/lists/*

RUN --mount=type=bind,from=blender,target=/ctx/blender \
    echo "$BLENDER_SHA256  /ctx/blender/$BLENDER_ARCHIVE" | sha256sum -c - \
 && tar -xJf "/ctx/blender/$BLENDER_ARCHIVE" -C /opt \
 && mv /opt/blender-5.2.3-linux-x64 /opt/blender \
 && /opt/blender/blender --version > /tmp/blender-version.txt 2>&1 && head -1 /tmp/blender-version.txt \
 && grep -qx 'Blender 5.2.3 LTS' /tmp/blender-version.txt && rm /tmp/blender-version.txt

COPY requirements.txt /opt/cv3d-requirements.txt
RUN python3 -m venv /opt/cv3d-venv \
 && /opt/cv3d-venv/bin/pip install --no-cache-dir --disable-pip-version-check -r /opt/cv3d-requirements.txt \
 && /opt/cv3d-venv/bin/python -I -c 'import numpy, scipy, trimesh, rtree, PIL; rtree.index.Index()'

COPY VERSION /opt/dify-sf-sandbox-version
LABEL org.opencontainers.image.title="dify-sf sandbox colvalley-blender" \
      dify-sf.sandbox-image="colvalley-blender"

USER dify
