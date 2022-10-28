#!/bin/bash

###
# Yet Another Podman Régisseur
# 
# Script to help automate the management of podman kube and generated systemd files. 
##

set -e

POD=$1
KUBE_FILE="pods/${POD}.yaml"
SERVICE_FILE="systemd/pod-${POD}.service"

function insert() {
  PATTERN=$1
  NEW_LINE=$2

  awk -i inplace \
    -v "pattern=${PATTERN}" \
    -v "line=${NEW_LINE}" \
    '$0 ~ pattern && !x {print line; x=1} 1' \
    ${SERVICE_FILE}
}

# Tare-down if exists 
if systemctl list-units --full -all | grep -Fq "pod-${POD}.service"; then
  systemctl --user stop pod-${POD}
  podman pod stop ${POD}
  podman pod rm ${POD}
fi

if podman pod ps | grep -Fq "${POD}"; then
  podman pod stop ${POD}
  podman pod rm ${POD}
fi

# Create
ENV_FILE="env/${POD}-config.yml"
NETWORK=$(yq '.metadata.network' ${KUBE_FILE})
IP=$(yq '.metadata.ip' ${KUBE_FILE})
PLAY_CMD="podman play kube ${KUBE_FILE}"

if [ -f "$ENV_FILE" ]; then
 PLAY_CMD+=" --configmap=${ENV_FILE}"
fi

if [ "${NETWORK}" != null ]; then
  PLAY_CMD+=" --network ${NETWORK}:ip=${IP}"
fi

echo -e "Executing:\n$PLAY_CMD"
eval ${PLAY_CMD}

cd systemd 
SERVICE_FILES=$(podman generate systemd --name -f ${POD})
cd ..

# TODO: 
#   - Loop all instances of port mapping and not only the first?

# Add firewalld ports to generated systemd file 
KUBE_CONTENT="$(< ${KUBE_FILE})"
REGEX="(?<= hostPort: )(\d{2,5})(?: protocol: (UDP|TCP))"
echo ${KUBE_CONTENT} | grep -oP "${REGEX}" | while read -r match ; do
  PORT=$(echo "${match/ protocol: /\/}" | tr "[:upper:]" "[:lower:]")
  ADD_CMD="ExecStartPre=sudo firewall-cmd --permanent --add-port=${PORT}"
  REMOVE_CMD="ExecStopPost=sudo firewall-cmd --permanent --remove-port=${PORT}"
  insert "ExecStart" "${ADD_CMD}"
  insert "PIDFile" "${REMOVE_CMD}"
done

RELOAD_CMD="sudo firewall-cmd --reload"
insert "ExecStart=" "ExecStartPre=${RELOAD_CMD}"
insert "PIDFile" "ExecStopPost=${RELOAD_CMD}"

# Update systemd files
while IFS= read -r file ; do
  systemctl --user link ${file}
done <<< ${SERVICE_FILES}

systemctl --user daemon-reload

# Restart pod from systemd right away to open required ports 
podman pod stop ${POD}
systemctl --user enable pod-${POD}
systemctl --user start pod-${POD}

echo "Done!"
