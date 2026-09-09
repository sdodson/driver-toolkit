#!/bin/bash
#
# Installs the kernel-devel/headers/modules/rt/64k packages that must match
# the RHCOS kernel exactly, sourced from a rhel-coreos-extensions /
# rhel-coreos-10-extensions image, rather than baking them into this image
# at build time.
#
# Two ways to provide that image's content:
#
#  1. (preferred, no elevated privileges needed) Mount it yourself at
#     DTK_EXTENSIONS_MOUNT (default /mnt/rhcos-extensions) before running
#     this script - e.g. a Kubernetes/OpenShift `image` volume:
#
#       volumes:
#       - name: rhcos-extensions
#         image:
#           reference: <rhel-coreos-extensions-pullspec>
#           pullPolicy: IfNotPresent
#       containers:
#       - volumeMounts:
#         - name: rhcos-extensions
#           mountPath: /mnt/rhcos-extensions
#
#     If the extensions image's content is already present at that path,
#     it's used directly and no podman/privilege is needed at all.
#
#  2. (fallback, needs elevated privileges) Pass the extensions image
#     pullspec as $1. This script pulls and mounts it itself via nested
#     podman, which requires running with enough privilege for podman to
#     create its own mount namespaces (e.g. --privileged).
#
# Usage:
#   dtk-install-kernel-packages.sh [extensions-image-pullspec]
set -euo pipefail

DTK_EXTENSIONS_MOUNT=${DTK_EXTENSIONS_MOUNT:-/mnt/rhcos-extensions}
RPM_OSTREE_DIR="${DTK_EXTENSIONS_MOUNT}/usr/share/rpm-ostree"

if [ -f "${RPM_OSTREE_DIR}/extensions.json" ]; then
    echo "INFO: found extensions content already mounted at ${DTK_EXTENSIONS_MOUNT}, skipping podman"
else
    EXTENSIONS_IMAGE=${1:?"usage: $(basename "$0") [extensions-image-pullspec] (required when extensions content isn't already mounted at ${DTK_EXTENSIONS_MOUNT})"}
    STORAGE_DRIVER=${DTK_PODMAN_STORAGE_DRIVER:-vfs}

    podman_() {
        podman --storage-driver "${STORAGE_DRIVER}" "$@"
    }

    echo "INFO: pulling ${EXTENSIONS_IMAGE}"
    podman_ pull "${EXTENSIONS_IMAGE}"

    cid=$(podman_ create "${EXTENSIONS_IMAGE}")
    cleanup() {
        podman_ unmount "${cid}" >/dev/null 2>&1 || true
        podman_ rm "${cid}" >/dev/null 2>&1 || true
        rm -f "${REPO_FILE:-}"
    }
    trap cleanup EXIT

    echo "INFO: mounting ${EXTENSIONS_IMAGE}"
    mnt=$(podman_ mount "${cid}")
    RPM_OSTREE_DIR="${mnt}/usr/share/rpm-ostree"
fi

EXTENSIONS_REPO_DIR="${RPM_OSTREE_DIR}/extensions"
EXTENSIONS_JSON="${RPM_OSTREE_DIR}/extensions.json"

[ -d "${EXTENSIONS_REPO_DIR}" ] || { echo "ERROR: ${EXTENSIONS_REPO_DIR} not found" >&2; exit 1; }
[ -f "${EXTENSIONS_JSON}" ] || { echo "ERROR: ${EXTENSIONS_JSON} not found" >&2; exit 1; }

REPO_FILE=/etc/yum.repos.d/rhcos-extensions.repo
printf '[rhcos-extensions]\nname=RHCOS Extensions\nbaseurl=file://%s\nenabled=1\ngpgcheck=0\n' "${EXTENSIONS_REPO_DIR}" > "${REPO_FILE}"
dnf -y makecache

evr() { jq -r --arg p "$1" '.[$p]' "${EXTENSIONS_JSON}"; }

# kernel packages needed to build drivers / kmods.
KD=$(evr kernel-devel)
KH=$(evr kernel-headers)
KM=$(evr kernel-modules)
KME=$(evr kernel-modules-extra)
dnf -y install kernel-devel-${KD} kernel-headers-${KH}
dnf -y install kernel-modules-${KM} kernel-modules-extra-${KME}

# kernel-devel-matched is not currently published in the extensions image.
# Pin it to the exact kernel-devel NVR we just installed - otherwise dnf is
# free to satisfy it with the latest kernel-devel-matched in the RHEL repos,
# pulling in a second, unrelated kernel-devel side by side. It will resolve
# from the extensions repo automatically once openshift/os starts shipping
# it there.
INSTALLED_KERNEL=$(rpm -q --qf "%{VERSION}-%{RELEASE}" kernel-devel)
dnf -y install kernel-devel-matched-${INSTALLED_KERNEL}

# real-time kernel packages
# Also, assert that the kernel and kernel-rt rpms come from the same build.
if [ "$(arch)" = x86_64 ]; then
    RTD=$(evr kernel-rt-devel)
    RTM=$(evr kernel-rt-modules)
    RTME=$(evr kernel-rt-modules-extra)
    dnf -y install kernel-rt-devel-${RTD} kernel-rt-modules-${RTM} kernel-rt-modules-extra-${RTME}
    diff --side-by-side <(rpm -qi kernel-core | grep 'Source RPM') <(rpm -qi kernel-rt-core | grep 'Source RPM')
fi

# 64k-pages kernel packages for aarch64
if [ "$(arch)" = aarch64 ]; then
    K64D=$(evr kernel-64k-devel)
    K64M=$(evr kernel-64k-modules)
    K64ME=$(evr kernel-64k-modules-extra)
    dnf -y install kernel-64k-devel-${K64D} kernel-64k-modules-${K64M} kernel-64k-modules-extra-${K64ME}
fi

# kernel-rpm-macros is not currently published in the extensions image
# either; it isn't kernel-version-specific so this stays a plain unversioned
# install.
dnf -y install kernel-rpm-macros

RHEL_VERSION=$(</etc/dnf/vars/releasever)
INSTALLED_KERNEL=$(rpm -q --qf "%{VERSION}-%{RELEASE}.%{ARCH}" kernel-devel)
INSTALLED_RT_KERNEL=$(rpm -q --qf "%{VERSION}-%{RELEASE}.%{ARCH}+rt" kernel-rt-core 2>/dev/null || echo "")
echo "{ \"KERNEL_VERSION\": \"${INSTALLED_KERNEL}\", \"RT_KERNEL_VERSION\": \"${INSTALLED_RT_KERNEL}\", \"RHEL_VERSION\": \"${RHEL_VERSION}\" }" > /etc/driver-toolkit-release.json

dnf clean all

echo "INFO: installed kernel packages:"
rpm -qa 'kernel*'
