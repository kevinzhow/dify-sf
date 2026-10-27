#!/usr/bin/env bash
# Builds a sandbox image of an executor profile and prints the reference to put in the profile file.
#
#   agent_service/tool/build_sandbox_image.sh NAME [docker build options...]
#
# NAME is a directory under agent_service/sandbox-images/ (Dockerfile and VERSION). The image is tagged
# dify-sf/sandbox-NAME:<VERSION>. Extra options go to `docker build`, e.g. the named contexts an image needs:
#
#   colvalley-blender: --build-context blender=DIR   (DIR holds blender-5.2.3-linux-x64.tar.xz)
#
# The last line of the output is `dify-sf/sandbox-NAME@sha256:...`: the image's digest on this host (the Docker
# containerd image store gives a locally built image a content digest), to be used as the profile's "image".
set -euo pipefail
[[ $# -ge 1 ]] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 64; }
NAME=$1; shift
HERE=$(cd "$(dirname "$0")/.." && pwd)
DIR=$HERE/sandbox-images/$NAME
[[ $NAME =~ ^[a-z0-9][a-z0-9-]*$ && -f $DIR/Dockerfile && -f $DIR/VERSION ]] \
  || { echo "build_sandbox_image.sh: no sandbox image $NAME (want $DIR/Dockerfile and VERSION)" >&2; exit 64; }
VERSION=$(tr -d '[:space:]' < "$DIR/VERSION")
TAG=dify-sf/sandbox-$NAME:$VERSION
docker build --pull=false --label "dify-sf.sandbox-image=$NAME" --label "dify-sf.sandbox-image.version=$VERSION" \
  -t "$TAG" "$@" "$DIR" >&2
ID=$(docker image inspect -f '{{.Id}}' "$TAG")
[[ $ID == sha256:* ]] || { echo "build_sandbox_image.sh: unexpected image ID $ID" >&2; exit 1; }
REF=dify-sf/sandbox-$NAME@$ID
docker image inspect "$REF" >/dev/null || { echo "build_sandbox_image.sh: $REF does not resolve on this host" >&2; exit 1; }
echo "$TAG"
echo "$REF"
