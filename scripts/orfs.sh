#!/usr/bin/env bash
# orfs.sh — run a command inside the ORFS container with this repo mounted.
#
#   bash scripts/orfs.sh <command...>          run a shell command in the container
#   bash scripts/orfs.sh --make <make args>    run the repo's `make asic` with those args
#
#   --user $(id -u):$(id -g)   or the outputs are root-owned and cannot be cleaned
#   LEC_CHECK=0                skips an optional equivalence check whose binary needs
#                              an AVX-512 CPU; it affects no reported result
# The image is pinned by digest, not by :latest: Docker Hub publishes nightly tags,
# and two images four weeks apart differ by about 1,800 OpenROAD commits, enough to
# re-map the design. The digest below (OpenROAD 26Q3-2276-g4a7cf9b22a) produced every
# published result. Override with ORFS_IMAGE to use another.
set -u
cd "$(dirname "$0")/.."
REPO=$(pwd)
WORK=${ORFS_WORK:-$HOME/ASIC/rv32i-soc-asic-work}
IMAGE=${ORFS_IMAGE:-openroad/orfs@sha256:69bcb4701e02e7760db11d670818325caf2fbd37c3df241f47ab4c3181bdbdc4}
# The volare PDK is mounted read-only at /pdk because the ORFS image's sky130hd
# platform ships no SRAM macros, and the macro's GDS alone is 15 MB -- too big to
# keep in the repo. flow/config.mk refers to /pdk/sky130A/libs.ref/...
PDK=${ORFS_PDK:-$HOME/.volare}
mkdir -p "$WORK"

if [[ ${1:-} == "--make" ]]; then
  shift
  # drive the ORFS flow makefile directly; REPO_ROOT is what flow/config.mk uses
  # to find the RTL and the SDC, and inside the container the repo is /work
  CMD="REPO_ROOT=/work make -C /OpenROAD-flow-scripts/flow \
       DESIGN_CONFIG=/work/flow/config.mk WORK_HOME=/orfs_work LEC_CHECK=0 $*"
else
  CMD="cd /work && $*"
fi

exec docker run --rm --user "$(id -u):$(id -g)" \
  -v "$REPO":/work -v "$WORK":/orfs_work -v "$PDK":/pdk:ro \
  "$IMAGE" bash -c "source /OpenROAD-flow-scripts/env.sh >/dev/null 2>&1; $CMD"
