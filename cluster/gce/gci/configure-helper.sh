#!/bin/bash

# Copyright 2016 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script is for configuring kubernetes master and node instances. It is
# uploaded in the manifests tar ball.

set -o errexit
set -o nounset
set -o pipefail

function config-ip-firewall {
  echo "Configuring IP firewall rules"
  # The GCI image has host firewall which drop most inbound/forwarded packets.
  # We need to add rules to accept all TCP/UDP packets.
  if iptables -L INPUT | grep "Chain INPUT (policy DROP)" > /dev/null; then
    echo "Add rules to accept all inbound TCP/UDP packets"
    iptables -A INPUT -w -p TCP -j ACCEPT
    iptables -A INPUT -w -p UDP -j ACCEPT
  fi
  if iptables -L FORWARD | grep "Chain FORWARD (policy DROP)" > /dev/null; then
    echo "Add rules to accept all forwarded TCP/UDP packets"
    iptables -A FORWARD -w -p TCP -j ACCEPT
    iptables -A FORWARD -w -p UDP -j ACCEPT
  fi
}

function create-dirs {
  echo "Creating required directories"
  mkdir -p /var/lib/kubelet
  mkdir -p /etc/kubernetes/manifests
  if [[ "${KUBERNETES_MASTER:-}" == "false" ]]; then
    mkdir -p /var/lib/kube-proxy
  fi
}

# Finds the master PD device; returns it in MASTER_PD_DEVICE
function find-master-pd {
  MASTER_PD_DEVICE=""
  if [[ ! -e /dev/disk/by-id/google-master-pd ]]; then
    return
  fi
  device_info=$(ls -l /dev/disk/by-id/google-master-pd)
  relative_path=${device_info##* }
  MASTER_PD_DEVICE="/dev/disk/by-id/${relative_path}"
}

# Mounts a persistent disk (formatting if needed) to store the persistent data
# on the master -- etcd's data, a few settings, and security certs/keys/tokens.
# safe_format_and_mount only formats an unformatted disk, and mkdir -p will
# leave a directory be if it already exists.
function mount-master-pd {
  find-master-pd
  if [[ -z "${MASTER_PD_DEVICE:-}" ]]; then
    return
  fi

  echo "Mounting master-pd"
  local -r pd_path="/dev/disk/by-id/google-master-pd"
  local -r mount_point="/mnt/disks/master-pd"
  # Format and mount the disk, create directories on it for all of the master's
  # persistent data, and link them to where they're used.
  mkdir -p "${mount_point}"
  /usr/share/google/safe_format_and_mount -m "mkfs.ext4 -F" "${pd_path}" "${mount_point}" &>/var/log/master-pd-mount.log || \
    { echo "!!! master-pd mount failed, review /var/log/master-pd-mount.log !!!"; return 1; }

  # NOTE: These locations on the PD store persistent data, so to maintain
  # upgradeability, these locations should not change.  If they do, take care
  # to maintain a migration path from these locations to whatever new
  # locations.

  # Contains all the data stored in etcd.
  mkdir -m 700 -p "${mount_point}/var/etcd"
  ln -s -f "${mount_point}/var/etcd" /var/etcd
  mkdir -p /etc/srv
  # Contains the dynamically generated apiserver auth certs and keys.
  mkdir -p "${mount_point}/srv/kubernetes"
  ln -s -f "${mount_point}/srv/kubernetes" /etc/srv/kubernetes
  # Directory for kube-apiserver to store SSH key (if necessary).
  mkdir -p "${mount_point}/srv/sshproxy"
  ln -s -f "${mount_point}/srv/sshproxy" /etc/srv/sshproxy

  if ! id etcd &>/dev/null; then
    useradd -s /sbin/nologin -d /var/etcd etcd
  fi
  chown -R etcd "${mount_point}/var/etcd"
  chgrp -R etcd "${mount_point}/var/etcd"
}

# After the first boot and on upgrade, these files exist on the master-pd
# and should never be touched again (except perhaps an additional service
# account, see NB below.)
function create-master-auth {
  echo "Creating master auth files"
  local -r auth_dir="/etc/srv/kubernetes"
  if [[ ! -e "${auth_dir}/ca.crt" && ! -z "${CA_CERT:-}" && ! -z "${MASTER_CERT:-}" && ! -z "${MASTER_KEY:-}" ]]; then
    echo "${CA_CERT}" | base64 --decode > "${auth_dir}/ca.crt"
    echo "${MASTER_CERT}" | base64 --decode > "${auth_dir}/server.cert"
    echo "${MASTER_KEY}" | base64 --decode > "${auth_dir}/server.key"
  fi
  local -r basic_auth_csv="${auth_dir}/basic_auth.csv"
  if [[ ! -e "${basic_auth_csv}" ]]; then
    echo "${KUBE_PASSWORD},${KUBE_USER},admin" > "${basic_auth_csv}"
  fi
  local -r known_tokens_csv="${auth_dir}/known_tokens.csv"
  if [[ ! -e "${known_tokens_csv}" ]]; then
    echo "${KUBE_BEARER_TOKEN},admin,admin" > "${known_tokens_csv}"
    echo "${KUBELET_TOKEN},kubelet,kubelet" >> "${known_tokens_csv}"
    echo "${KUBE_PROXY_TOKEN},kube_proxy,kube_proxy" >> "${known_tokens_csv}"
  fi
  local use_cloud_config="false"
  cat <<EOF >/etc/gce.conf
[global]
EOF
  if [[ -n "${PROJECT_ID:-}" && -n "${TOKEN_URL:-}" && -n "${TOKEN_BODY:-}" && -n "${NODE_NETWORK:-}" ]]; then
    use_cloud_config="true"
    cat <<EOF >>/etc/gce.conf
token-url = ${TOKEN_URL}
token-body = ${TOKEN_BODY}
project-id = ${PROJECT_ID}
network-name = ${NODE_NETWORK}
EOF
  fi
  if [[ -n "${NODE_INSTANCE_PREFIX:-}" ]]; then
    use_cloud_config="true"
    cat <<EOF >>/etc/gce.conf
node-tags = ${NODE_INSTANCE_PREFIX}
EOF
  fi
  if [[ -n "${MULTIZONE:-}" ]]; then
    use_cloud_config="true"
    cat <<EOF >>/etc/gce.conf
multizone = ${MULTIZONE}
EOF
  fi
  if [[ "${use_cloud_config}" != "true" ]]; then
    rm -f /etc/gce.conf
  fi

  if [[ -n "${GCP_AUTHN_URL:-}" ]]; then
    cat <<EOF >/etc/gcp_authn.config
clusters:
  - name: gcp-authentication-server
    cluster:
      server: ${GCP_AUTHN_URL}
users:
  - name: kube-apiserver
    user:
      auth-provider:
        name: gcp
current-context: webhook
contexts:
- context:
    cluster: gcp-authentication-server
    user: kube-apiserver
  name: webhook
EOF
  fi

  if [[ -n "${GCP_AUTHZ_URL:-}" ]]; then
    cat <<EOF >/etc/gcp_authz.config
clusters:
  - name: gcp-authorization-server
    cluster:
      server: ${GCP_AUTHZ_URL}
users:
  - name: kube-apiserver
    user:
      auth-provider:
        name: gcp
current-context: webhook
contexts:
- context:
    cluster: gcp-authorization-server
    user: kube-apiserver
  name: webhook
EOF
  fi
}

function create-kubelet-kubeconfig {
  echo "Creating kubelet kubeconfig file"
  if [[ -z "${KUBELET_CA_CERT:-}" ]]; then
    KUBELET_CA_CERT="${CA_CERT}"
  fi
  cat <<EOF >/var/lib/kubelet/kubeconfig
apiVersion: v1
kind: Config
users:
- name: kubelet
  user:
    client-certificate-data: ${KUBELET_CERT}
    client-key-data: ${KUBELET_KEY}
clusters:
- name: local
  cluster:
    certificate-authority-data: ${KUBELET_CA_CERT}
contexts:
- context:
    cluster: local
    user: kubelet
  name: service-account-context
current-context: service-account-context
EOF
}

# Uses KUBELET_CA_CERT (falling back to CA_CERT), KUBELET_CERT, and KUBELET_KEY
# to generate a kubeconfig file for the kubelet to securely connect to the apiserver.
function create-master-kubelet-auth {
  # Only configure the kubelet on the master if the required variables are
  # set in the environment.
  if [[ -n "${KUBELET_APISERVER:-}" && -n "${KUBELET_CERT:-}" && -n "${KUBELET_KEY:-}" ]]; then
    create-kubelet-kubeconfig
  fi
}

function create-kubeproxy-kubeconfig {
  echo "Creating kube-proxy kubeconfig file"
  cat <<EOF >/var/lib/kube-proxy/kubeconfig
apiVersion: v1
kind: Config
users:
- name: kube-proxy
  user:
    token: ${KUBE_PROXY_TOKEN}
clusters:
- name: local
  cluster:
    certificate-authority-data: ${CA_CERT}
contexts:
- context:
    cluster: local
    user: kube-proxy
  name: service-account-context
current-context: service-account-context
EOF
}

function assemble-docker-flags {
  local docker_opts="-p /var/run/docker.pid --bridge=cbr0 --iptables=false --ip-masq=false"
  if [[ "${TEST_CLUSTER:-}" == "true" ]]; then
    docker_opts+=" --debug"
  fi
  echo "DOCKER_OPTS=\"${docker_opts} ${EXTRA_DOCKER_OPTS:-}\"" > /etc/default/docker
}

# A helper function for loading a docker image. It keeps trying up to 5 times.
#
# $1: Full path of the docker image
function try-load-docker-image {
  local -r img=$1
  echo "Try to load docker image file ${img}"
  # Temporarily turn off errexit, because we don't want to exit on first failure.
  set +e
  local -r max_attempts=5
  local -i attempt_num=1
  until timeout 30 docker load -i "${img}"; do
    if [[ "${attempt_num}" == "${max_attempts}" ]]; then
      echo "Fail to load docker image file ${img} after ${max_attempts} retries. Exist!!"
      exit 1
    else
      attempt_num=$((attempt_num+1))
      sleep 5
    fi
  done
  # Re-enable errexit.
  set -e
}

# Loads kube-system docker images. It is better to do it before starting kubelet,
# as kubelet will restart docker daemon, which may interfere with loading images.
function load-docker-images {
  echo "Start loading kube-system docker images"
  local -r img_dir="${KUBE_HOME}/kube-docker-files"
  if [[ "${KUBERNETES_MASTER:-}" == "true" ]]; then
    try-load-docker-image "${img_dir}/kube-apiserver.tar"
    try-load-docker-image "${img_dir}/kube-controller-manager.tar"
    try-load-docker-image "${img_dir}/kube-scheduler.tar"
  else
    try-load-docker-image "${img_dir}/kube-proxy.tar"
  fi
}

# A kubelet systemd service is built in GCI image, but by default it is not started
# when an instance is up. To start kubelet, the command line flags should be written
# to /etc/default/kubelet in the format "KUBELET_OPTS=<flags>", and then start kubelet
# using systemctl. This function assembles the command line and start the kubelet
# systemd service.
function start-kubelet {
  echo "Start kubelet"
  local flags="${KUBELET_TEST_LOG_LEVEL:-"--v=2"} ${KUBELET_TEST_ARGS:-}"
  flags+=" --allow-privileged=true"
  flags+=" --babysit-daemons=true"
  flags+=" --cgroup-root=/"
  flags+=" --cloud-provider=gce"
  flags+=" --cluster-dns=${DNS_SERVER_IP}"
  flags+=" --cluster-domain=${DNS_DOMAIN}"
  flags+=" --config=/etc/kubernetes/manifests"
  flags+=" --kubelet-cgroups=/kubelet"
  flags+=" --system-cgroups=/system"

  if [[ -n "${KUBELET_PORT:-}" ]]; then
    flags+=" --port=${KUBELET_PORT}"
  fi
  if [[ "${KUBERNETES_MASTER:-}" == "true" ]]; then
    flags+=" --enable-debugging-handlers=false"
    flags+=" --hairpin-mode=none"
    if [[ ! -z "${KUBELET_APISERVER:-}" && ! -z "${KUBELET_CERT:-}" && ! -z "${KUBELET_KEY:-}" ]]; then
      flags+=" --api-servers=https://${KUBELET_APISERVER}"
      flags+=" --register-schedulable=false"
      flags+=" --reconcile-cidr=false"
      flags+=" --pod-cidr=10.123.45.0/30"
    else
      flags+=" --pod-cidr=${MASTER_IP_RANGE}"
    fi
  else # For nodes
    flags+=" --enable-debugging-handlers=true"
    flags+=" --api-servers=https://${KUBERNETES_MASTER_NAME}"
    if [[ "${HAIRPIN_MODE:-}" == "promiscuous-bridge" ]] || \
       [[ "${HAIRPIN_MODE:-}" == "hairpin-veth" ]] || \
       [[ "${HAIRPIN_MODE:-}" == "none" ]]; then
      flags+=" --hairpin-mode=${HAIRPIN_MODE}"
    fi
  fi
  if [[ "${ENABLE_MANIFEST_URL:-}" == "true" ]]; then
    flags+=" --manifest-url=${MANIFEST_URL}"
    flags+=" --manifest-url-header=${MANIFEST_URL_HEADER}"
  fi
  if [[ -n "${ENABLE_CUSTOM_METRICS:-}" ]]; then
    flags+=" --enable-custom-metrics=${ENABLE_CUSTOM_METRICS}"
  fi
  if [[ -n "${NODE_LABELS:-}" ]]; then
    flags+=" --node-labels=${NODE_LABELS}"
  fi
  if [[ "${ALLOCATE_NODE_CIDRS:-}" == "true" ]]; then
     flags+=" --configure-cbr0=${ALLOCATE_NODE_CIDRS}"
  fi
  echo "KUBELET_OPTS=\"${flags}\"" > /etc/default/kubelet

  systemctl start kubelet.service
}

# Create the log file and set its properties.
#
# $1 is the file to create.
function prepare-log-file {
  touch $1
  chmod 644 $1
  chown root:root $1
}

# Starts kube-proxy pod.
function start-kube-proxy {
  echo "Start kube-proxy pod"
  prepare-log-file /var/log/kube-proxy.log
  local -r src_file="${KUBE_HOME}/kube-manifests/kubernetes/kube-proxy.manifest"
  remove-salt-config-comments "${src_file}"

  local -r kubeconfig="--kubeconfig=/var/lib/kube-proxy/kubeconfig"
  local kube_docker_registry="gcr.io/google_containers"
  if [[ -n "${KUBE_DOCKER_REGISTRY:-}" ]]; then
    kube_docker_registry=${KUBE_DOCKER_REGISTRY}
  fi
  local -r kube_proxy_docker_tag=$(cat /home/kubernetes/kube-docker-files/kube-proxy.docker_tag)
  local api_servers="--master=https://${KUBERNETES_MASTER_NAME}"
  sed -i -e "s@{{kubeconfig}}@${kubeconfig}@g" ${src_file}
  sed -i -e "s@{{pillar\['kube_docker_registry'\]}}@${kube_docker_registry}@g" ${src_file}
  sed -i -e "s@{{pillar\['kube-proxy_docker_tag'\]}}@${kube_proxy_docker_tag}@g" ${src_file}
  sed -i -e "s@{{test_args}}@${KUBEPROXY_TEST_ARGS:-}@g" ${src_file}
  sed -i -e "s@{{ cpurequest }}@20m@g" ${src_file}
  sed -i -e "s@{{log_level}}@${KUBEPROXY_TEST_LOG_LEVEL:-"--v=2"}@g" ${src_file}
  sed -i -e "s@{{api_servers_with_port}}@${api_servers}@g" ${src_file}
  if [[ -n "${CLUSTER_IP_RANGE:-}" ]]; then
    sed -i -e "s@{{cluster_cidr}}@--cluster-cidr=${CLUSTER_IP_RANGE}@g" ${src_file}
  fi
  cp "${src_file}" /etc/kubernetes/manifests
}

# Replaces the variables in the etcd manifest file with the real values, and then
# copy the file to the manifest dir
# $1: value for variable 'suffix'
# $2: value for variable 'port'
# $3: value for variable 'server_port'
# $4: value for variable 'cpulimit'
# $5: pod name, which should be either etcd or etcd-events
function prepare-etcd-manifest {
  local -r temp_file="/tmp/$5"
  cp "${KUBE_HOME}/kube-manifests/kubernetes/gci-trusty/etcd.manifest" "${temp_file}"
  sed -i -e "s@{{ *suffix *}}@$1@g" "${temp_file}"
  sed -i -e "s@{{ *port *}}@$2@g" "${temp_file}"
  sed -i -e "s@{{ *server_port *}}@$3@g" "${temp_file}"
  sed -i -e "s@{{ *cpulimit *}}@\"$4\"@g" "${temp_file}"
  # Replace the volume host path.
  sed -i -e "s@/mnt/master-pd/var/etcd@/mnt/disks/master-pd/var/etcd@g" "${temp_file}"
  mv "${temp_file}" /etc/kubernetes/manifests
}

# Starts etcd server pod (and etcd-events pod if needed).
# More specifically, it prepares dirs and files, sets the variable value
# in the manifests, and copies them to /etc/kubernetes/manifests.
function start-etcd-servers {
  echo "Start etcd pods"
  if [[ -d /etc/etcd ]]; then
    rm -rf /etc/etcd
  fi
  if [[ -e /etc/default/etcd ]]; then
    rm -f /etc/default/etcd
  fi
  if [[ -e /etc/systemd/system/etcd.service ]]; then
    rm -f /etc/systemd/system/etcd.service
  fi
  if [[ -e /etc/init.d/etcd ]]; then
    rm -f /etc/init.d/etcd
  fi
  prepare-log-file /var/log/etcd.log
  prepare-etcd-manifest "" "4001" "2380" "200m" "etcd.manifest"

  prepare-log-file /var/log/etcd-events.log
  prepare-etcd-manifest "-events" "4002" "2381" "100m" "etcd-events.manifest"
}

# Calculates the following variables based on env variables, which will be used
# by the manifests of several kube-master components.
#   CLOUD_CONFIG_VOLUME
#   CLOUD_CONFIG_MOUNT
#   DOCKER_REGISTRY
function compute-master-manifest-variables {
  CLOUD_CONFIG_VOLUME=""
  CLOUD_CONFIG_MOUNT=""
  if [[ -n "${PROJECT_ID:-}" && -n "${TOKEN_URL:-}" && -n "${TOKEN_BODY:-}" && -n "${NODE_NETWORK:-}" ]]; then
    CLOUD_CONFIG_VOLUME="{\"name\": \"cloudconfigmount\",\"hostPath\": {\"path\": \"/etc/gce.conf\"}},"
    CLOUD_CONFIG_MOUNT="{\"name\": \"cloudconfigmount\",\"mountPath\": \"/etc/gce.conf\", \"readOnly\": true},"
  fi
  DOCKER_REGISTRY="gcr.io/google_containers"
  if [[ -n "${KUBE_DOCKER_REGISTRY:-}" ]]; then
    DOCKER_REGISTRY="${KUBE_DOCKER_REGISTRY}"
  fi
}

# A helper function for removing salt configuration and comments from a file.
# This is mainly for preparing a manifest file.
#
# $1: Full path of the file to manipulate
function remove-salt-config-comments {
  # Remove salt configuration.
  sed -i "/^[ |\t]*{[#|%]/d" $1
  # Remove comments.
  sed -i "/^[ |\t]*#/d" $1
}

# Starts kubernetes apiserver.
# It prepares the log file, loads the docker image, calculates variables, sets them
# in the manifest file, and then copies the manifest file to /etc/kubernetes/manifests.
#
# Assumed vars (which are calculated in function compute-master-manifest-variables)
#   CLOUD_CONFIG_VOLUME
#   CLOUD_CONFIG_MOUNT
#   DOCKER_REGISTRY
function start-kube-apiserver {
  echo "Start kubernetes api-server"
  prepare-log-file /var/log/kube-apiserver.log

  # Calculate variables and assemble the command line.
  local params="${API_SERVER_TEST_LOG_LEVEL:-"--v=2"} ${APISERVER_TEST_ARGS:-}"
  params+=" --address=127.0.0.1"
  params+=" --allow-privileged=true"
  params+=" --authorization-policy-file=/etc/srv/kubernetes/abac-authz-policy.jsonl"
  params+=" --basic-auth-file=/etc/srv/kubernetes/basic_auth.csv"
  params+=" --cloud-provider=gce"
  params+=" --client-ca-file=/etc/srv/kubernetes/ca.crt"
  params+=" --etcd-servers=http://127.0.0.1:4001"
  params+=" --etcd-servers-overrides=/events#http://127.0.0.1:4002"
  params+=" --secure-port=443"
  params+=" --tls-cert-file=/etc/srv/kubernetes/server.cert"
  params+=" --tls-private-key-file=/etc/srv/kubernetes/server.key"
  params+=" --token-auth-file=/etc/srv/kubernetes/known_tokens.csv"
  if [[ -n "${SERVICE_CLUSTER_IP_RANGE:-}" ]]; then
    params+=" --service-cluster-ip-range=${SERVICE_CLUSTER_IP_RANGE}"
  fi
  if [[ -n "${ADMISSION_CONTROL:-}" ]]; then
    params+=" --admission-control=${ADMISSION_CONTROL}"
  fi
  if [[ -n "${KUBE_APISERVER_REQUEST_TIMEOUT:-}" ]]; then
    params+=" --min-request-timeout=${KUBE_APISERVER_REQUEST_TIMEOUT}"
  fi
  if [[ -n "${RUNTIME_CONFIG:-}" ]]; then
    params+=" --runtime-config=${RUNTIME_CONFIG}"
  fi
  if [[ -n "${PROJECT_ID:-}" && -n "${TOKEN_URL:-}" && -n "${TOKEN_BODY:-}" && -n "${NODE_NETWORK:-}" ]]; then
    local -r vm_external_ip=$(curl --retry 5 --retry-delay 3 --fail --silent -H 'Metadata-Flavor: Google' "http://metadata/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip")
    params+=" --advertise-address=${vm_external_ip}"
    params+=" --cloud-config=/etc/gce.conf"
    params+=" --ssh-user=${PROXY_SSH_USER}"
    params+=" --ssh-keyfile=/etc/srv/sshproxy/.sshkeyfile"
  fi

  webhook_authn_config_mount=""
  webhook_authn_config_volume=""
  if [[ -n "${GCP_AUTHN_URL:-}" ]]; then
    params+=" --authentication-token-webhook-config-file=/etc/gcp_authn.config"
    webhook_authn_config_mount="{\"name\": \"webhookauthnconfigmount\",\"mountPath\": \"/etc/gcp_authn.config\", \"readOnly\": false},"
    webhook_authn_config_volume="{\"name\": \"webhookauthnconfigmount\",\"hostPath\": {\"path\": \"/etc/gcp_authn.config\"}},"
  fi

  params+=" --authorization-mode=ABAC"
  webhook_config_mount=""
  webhook_config_volume=""
  if [[ -n "${GCP_AUTHZ_URL:-}" ]]; then
    params+=",Webhook --authorization-webhook-config-file=/etc/gcp_authz.config"
    webhook_config_mount="{\"name\": \"webhookconfigmount\",\"mountPath\": \"/etc/gcp_authz.config\", \"readOnly\": false},"
    webhook_config_volume="{\"name\": \"webhookconfigmount\",\"hostPath\": {\"path\": \"/etc/gcp_authz.config\"}},"
  fi
  local -r src_dir="${KUBE_HOME}/kube-manifests/kubernetes/gci-trusty"
  cp "${src_dir}/abac-authz-policy.jsonl" /etc/srv/kubernetes/
  src_file="${src_dir}/kube-apiserver.manifest"
  remove-salt-config-comments "${src_file}"
  # Evaluate variables.
  local -r kube_apiserver_docker_tag=$(cat /home/kubernetes/kube-docker-files/kube-apiserver.docker_tag)
  sed -i -e "s@{{params}}@${params}@g" "${src_file}"
  sed -i -e "s@{{srv_kube_path}}@/etc/srv/kubernetes@g" "${src_file}"
  sed -i -e "s@{{srv_sshproxy_path}}@/etc/srv/sshproxy@g" "${src_file}"
  sed -i -e "s@{{cloud_config_mount}}@${CLOUD_CONFIG_MOUNT}@g" "${src_file}"
  sed -i -e "s@{{cloud_config_volume}}@${CLOUD_CONFIG_VOLUME}@g" "${src_file}"
  sed -i -e "s@{{pillar\['kube_docker_registry'\]}}@${DOCKER_REGISTRY}@g" "${src_file}"
  sed -i -e "s@{{pillar\['kube-apiserver_docker_tag'\]}}@${kube_apiserver_docker_tag}@g" "${src_file}"
  sed -i -e "s@{{pillar\['allow_privileged'\]}}@true@g" "${src_file}"
  sed -i -e "s@{{secure_port}}@443@g" "${src_file}"
  sed -i -e "s@{{secure_port}}@8080@g" "${src_file}"
  sed -i -e "s@{{additional_cloud_config_mount}}@@g" "${src_file}"
  sed -i -e "s@{{additional_cloud_config_volume}}@@g" "${src_file}"
  sed -i -e "s@{{webhook_authn_config_mount}}@${webhook_authn_config_mount}@g" "${src_file}"
  sed -i -e "s@{{webhook_authn_config_volume}}@${webhook_authn_config_volume}@g" "${src_file}"
  sed -i -e "s@{{webhook_config_mount}}@${webhook_config_mount}@g" "${src_file}"
  sed -i -e "s@{{webhook_config_volume}}@${webhook_config_volume}@g" "${src_file}"
  cp "${src_file}" /etc/kubernetes/manifests
}

# Starts kubernetes controller manager.
# It prepares the log file, loads the docker image, calculates variables, sets them
# in the manifest file, and then copies the manifest file to /etc/kubernetes/manifests.
#
# Assumed vars (which are calculated in function compute-master-manifest-variables)
#   CLOUD_CONFIG_VOLUME
#   CLOUD_CONFIG_MOUNT
#   DOCKER_REGISTRY
function start-kube-controller-manager {
  echo "Start kubernetes controller-manager"
  prepare-log-file /var/log/kube-controller-manager.log
  # Calculate variables and assemble the command line.
  local params="${CONTROLLER_MANAGER_TEST_LOG_LEVEL:-"--v=2"} ${CONTROLLER_MANAGER_TEST_ARGS:-}"
  params+=" --cloud-provider=gce"
  params+=" --master=127.0.0.1:8080"
  params+=" --root-ca-file=/etc/srv/kubernetes/ca.crt"
  params+=" --service-account-private-key-file=/etc/srv/kubernetes/server.key"
  if [[ -n "${PROJECT_ID:-}" && -n "${TOKEN_URL:-}" && -n "${TOKEN_BODY:-}" && -n "${NODE_NETWORK:-}" ]]; then
    params+=" --cloud-config=/etc/gce.conf"
  fi
  if [[ -n "${INSTANCE_PREFIX:-}" ]]; then
    params+=" --cluster-name=${INSTANCE_PREFIX}"
  fi
  if [[ -n "${CLUSTER_IP_RANGE:-}" ]]; then
    params+=" --cluster-cidr=${CLUSTER_IP_RANGE}"
  fi
  if [[ -n "${SERVICE_CLUSTER_IP_RANGE:-}" ]]; then
    params+=" --service-cluster-ip-range=${SERVICE_CLUSTER_IP_RANGE}"
  fi
  if [[ "${ALLOCATE_NODE_CIDRS:-}" == "true" ]]; then
    params+=" --allocate-node-cidrs=${ALLOCATE_NODE_CIDRS}"
  fi
  if [[ -n "${TERMINATED_POD_GC_THRESHOLD:-}" ]]; then
    params+=" --terminated-pod-gc-threshold=${TERMINATED_POD_GC_THRESHOLD}"
  fi
  local -r kube_rc_docker_tag=$(cat /home/kubernetes/kube-docker-files/kube-controller-manager.docker_tag)

  local -r src_file="${KUBE_HOME}/kube-manifests/kubernetes/gci-trusty/kube-controller-manager.manifest"
  remove-salt-config-comments "${src_file}"
  # Evaluate variables.
  sed -i -e "s@{{srv_kube_path}}@/etc/srv/kubernetes@g" "${src_file}"
  sed -i -e "s@{{pillar\['kube_docker_registry'\]}}@${DOCKER_REGISTRY}@g" "${src_file}"
  sed -i -e "s@{{pillar\['kube-controller-manager_docker_tag'\]}}@${kube_rc_docker_tag}@g" "${src_file}"
  sed -i -e "s@{{params}}@${params}@g" "${src_file}"
  sed -i -e "s@{{cloud_config_mount}}@${CLOUD_CONFIG_MOUNT}@g" "${src_file}"
  sed -i -e "s@{{cloud_config_volume}}@${CLOUD_CONFIG_VOLUME}@g" "${src_file}"
  sed -i -e "s@{{additional_cloud_config_mount}}@@g" "${src_file}"
  sed -i -e "s@{{additional_cloud_config_volume}}@@g" "${src_file}"
  cp "${src_file}" /etc/kubernetes/manifests
}

# Starts kubernetes scheduler.
# It prepares the log file, loads the docker image, calculates variables, sets them
# in the manifest file, and then copies the manifest file to /etc/kubernetes/manifests.
#
# Assumed vars (which are calculated in compute-master-manifest-variables)
#   DOCKER_REGISTRY
function start-kube-scheduler {
  echo "Start kubernetes scheduler"
  prepare-log-file /var/log/kube-scheduler.log

  # Calculate variables and set them in the manifest.
  params="${SCHEDULER_TEST_LOG_LEVEL:-"--v=2"} ${SCHEDULER_TEST_ARGS:-}"
  local -r kube_scheduler_docker_tag=$(cat "${KUBE_HOME}/kube-docker-files/kube-scheduler.docker_tag")

  # Remove salt comments and replace variables with values.
  local -r src_file="${KUBE_HOME}/kube-manifests/kubernetes/gci-trusty/kube-scheduler.manifest"
  remove-salt-config-comments "${src_file}"

  sed -i -e "s@{{params}}@${params}@g" "${src_file}"
  sed -i -e "s@{{pillar\['kube_docker_registry'\]}}@${DOCKER_REGISTRY}@g" "${src_file}"
  sed -i -e "s@{{pillar\['kube-scheduler_docker_tag'\]}}@${kube_scheduler_docker_tag}@g" "${src_file}"
  cp "${src_file}" /etc/kubernetes/manifests
}

# Starts cluster autoscaler.
function start-cluster-autoscaler {
  if [ "${ENABLE_NODE_AUTOSCALER:-}" = "true" ]; then
    echo "Start kubernetes cluster autoscaler"
    prepare-log-file /var/log/cluster-autoscaler.log

    # Remove salt comments and replace variables with values
    local -r src_file="${KUBE_HOME}/kube-manifests/kubernetes/gci-trusty/cluster-autoscaler.manifest"
    remove-salt-config-comments "${src_file}"

    local params="${AUTOSCALER_MIG_CONFIG}"
    if [[ -n "${PROJECT_ID:-}" && -n "${TOKEN_URL:-}" && -n "${TOKEN_BODY:-}" && -n "${NODE_NETWORK:-}" ]]; then
      params+=" --cloud-config=/etc/gce.conf"
    fi

    sed -i -e "s@{{params}}@${params}@g" "${src_file}"
    sed -i -e "s@{{cloud_config_mount}}@${CLOUD_CONFIG_MOUNT}@g" "${src_file}"
    sed -i -e "s@{{cloud_config_volume}}@${CLOUD_CONFIG_VOLUME}@g" "${src_file}"
    sed -i -e "s@{%.*%}@@g" "${src_file}"

    cp "${src_file}" /etc/kubernetes/manifests
  fi
}

# A helper function for copying addon manifests and set dir/files
# permissions.
#
# $1: addon category under /etc/kubernetes
# $2: manifest source dir
function setup-addon-manifests {
  local -r src_dir="${KUBE_HOME}/kube-manifests/kubernetes/gci-trusty/$2"
  local -r dst_dir="/etc/kubernetes/$1/$2"
  if [[ ! -d "${dst_dir}" ]]; then
    mkdir -p "${dst_dir}"
  fi
  local files=$(find "${src_dir}" -maxdepth 1 -name "*.yaml")
  if [[ -n "${files}" ]]; then
    cp "${src_dir}/"*.yaml "${dst_dir}"
  fi
  files=$(find "${src_dir}" -maxdepth 1 -name "*.json")
  if [[ -n "${files}" ]]; then
    cp "${src_dir}/"*.json "${dst_dir}"
  fi
  files=$(find "${src_dir}" -maxdepth 1 -name "*.yaml.in")
  if [[ -n "${files}" ]]; then
    cp "${src_dir}/"*.yaml.in "${dst_dir}"
  fi
  chown -R root:root "${dst_dir}"
  chmod 755 "${dst_dir}"
  chmod 644 "${dst_dir}"/*
}

# Prepares the manifests of k8s addons, and starts the addon manager.
function start-kube-addons {
  echo "Prepare kube-addons manifests and start kube addon manager"
  local -r src_dir="${KUBE_HOME}/kube-manifests/kubernetes/gci-trusty"
  local -r dst_dir="/etc/kubernetes/addons"
  # Set up manifests of other addons.
  if [[ "${ENABLE_CLUSTER_MONITORING:-}" == "influxdb" ]] || \
     [[ "${ENABLE_CLUSTER_MONITORING:-}" == "google" ]] || \
     [[ "${ENABLE_CLUSTER_MONITORING:-}" == "standalone" ]] || \
     [[ "${ENABLE_CLUSTER_MONITORING:-}" == "googleinfluxdb" ]]; then
    local -r file_dir="cluster-monitoring/${ENABLE_CLUSTER_MONITORING}"
    setup-addon-manifests "addons" "${file_dir}"
    # Replace the salt configurations with variable values.
    base_metrics_memory="200Mi"
    metrics_memory="${base_metrics_memory}"
    base_eventer_memory="200Mi"
    eventer_memory="${base_eventer_memory}"
    local -r metrics_memory_per_node="4"
    local -r eventer_memory_per_node="500"
    if [[ -n "${NUM_NODES:-}" && "${NUM_NODES}" -ge 1 ]]; then
      num_kube_nodes="$((${NUM_NODES}-1))"
      metrics_memory="$((${num_kube_nodes} * ${metrics_memory_per_node} + 200))Mi"
      eventer_memory="$((${num_kube_nodes} * ${eventer_memory_per_node} + 200 * 1024))Ki"
    fi
    controller_yaml="${dst_dir}/${file_dir}"
    if [[ "${ENABLE_CLUSTER_MONITORING:-}" == "googleinfluxdb" ]]; then
      controller_yaml="${controller_yaml}/heapster-controller-combined.yaml"
    else
      controller_yaml="${controller_yaml}/heapster-controller.yaml"
    fi
    remove-salt-config-comments "${controller_yaml}"
    sed -i -e "s@{{ *base_metrics_memory *}}@${base_metrics_memory}@g" "${controller_yaml}"
    sed -i -e "s@{{ *metrics_memory *}}@${metrics_memory}@g" "${controller_yaml}"
    sed -i -e "s@{{ *base_eventer_memory *}}@${base_eventer_memory}@g" "${controller_yaml}"
    sed -i -e "s@{{ *eventer_memory *}}@${eventer_memory}@g" "${controller_yaml}"
    sed -i -e "s@{{ *metrics_memory_per_node *}}@${metrics_memory_per_node}@g" "${controller_yaml}"
    sed -i -e "s@{{ *eventer_memory_per_node *}}@${eventer_memory_per_node}@g" "${controller_yaml}"
  fi
  if [[ "${ENABLE_L7_LOADBALANCING:-}" == "glbc" ]]; then
    setup-addon-manifests "addons" "cluster-loadbalancing/glbc"
  fi
  if [[ "${ENABLE_CLUSTER_DNS:-}" == "true" ]]; then
    setup-addon-manifests "addons" "dns"
    local -r dns_rc_file="${dst_dir}/dns/skydns-rc.yaml"
    local -r dns_svc_file="${dst_dir}/dns/skydns-svc.yaml"
    mv "${dst_dir}/dns/skydns-rc.yaml.in" "${dns_rc_file}"
    mv "${dst_dir}/dns/skydns-svc.yaml.in" "${dns_svc_file}"
    # Replace the salt configurations with variable values.
    sed -i -e "s@{{ *pillar\['dns_replicas'\] *}}@${DNS_REPLICAS}@g" "${dns_rc_file}"
    sed -i -e "s@{{ *pillar\['dns_domain'\] *}}@${DNS_DOMAIN}@g" "${dns_rc_file}"
    sed -i -e "s@{{ *pillar\['dns_server'\] *}}@${DNS_SERVER_IP}@g" "${dns_svc_file}"
  fi
  if [[ "${ENABLE_CLUSTER_REGISTRY:-}" == "true" ]]; then
    setup-addon-manifests "addons" "registry"
    local -r registry_pv_file="${dst_dir}/registry/registry-pv.yaml"
    local -r registry_pvc_file="${dst_dir}/registry/registry-pvc.yaml"
    mv "${dst_dir}/registry/registry-pv.yaml.in" "${registry_pv_file}"
    mv "${dst_dir}/registry/registry-pvc.yaml.in" "${registry_pvc_file}"
    # Replace the salt configurations with variable values.
    remove-salt-config-comments "${controller_yaml}"
    sed -i -e "s@{{ *pillar\['cluster_registry_disk_size'\] *}}@${CLUSTER_REGISTRY_DISK_SIZE}@g" "${registry_pv_file}"
    sed -i -e "s@{{ *pillar\['cluster_registry_disk_size'\] *}}@${CLUSTER_REGISTRY_DISK_SIZE}@g" "${registry_pvc_file}"
    sed -i -e "s@{{ *pillar\['cluster_registry_disk_name'\] *}}@${CLUSTER_REGISTRY_DISK}@g" "${registry_pvc_file}"
  fi
  if [[ "${ENABLE_NODE_LOGGING:-}" == "true" ]] && \
     [[ "${LOGGING_DESTINATION:-}" == "elasticsearch" ]] && \
     [[ "${ENABLE_CLUSTER_LOGGING:-}" == "true" ]]; then
    setup-addon-manifests "addons" "fluentd-elasticsearch"
  fi
  if [[ "${ENABLE_CLUSTER_UI:-}" == "true" ]]; then
    setup-addon-manifests "addons" "dashboard"
  fi
  if echo "${ADMISSION_CONTROL:-}" | grep -q "LimitRanger"; then
    setup-addon-manifests "admission-controls" "limit-range"
  fi

  # Place addon manager pod manifest.
  cp "${src_dir}/kube-addon-manager.yaml" /etc/kubernetes/manifests
}

# Starts a fluentd static pod for logging.
function start-fluentd {
  echo "Start fluentd pod"
  if [[ "${ENABLE_NODE_LOGGING:-}" == "true" ]]; then
    if [[ "${LOGGING_DESTINATION:-}" == "gcp" ]]; then
      cp "${KUBE_HOME}/kube-manifests/kubernetes/fluentd-gcp.yaml" /etc/kubernetes/manifests/
    elif [[ "${LOGGING_DESTINATION:-}" == "elasticsearch" ]]; then
      cp "${KUBE_HOME}/kube-manifests/kubernetes/fluentd-es.yaml" /etc/kubernetes/manifests/
    fi
  fi
}

# Starts a l7 loadbalancing controller for ingress.
function start-lb-controller {
  if [[ "${ENABLE_L7_LOADBALANCING:-}" == "glbc" ]]; then
    echo "Starting GCE L7 pod"
    prepare-log-file /var/log/glbc.log
    local -r src_file="${KUBE_HOME}/kube-manifests/kubernetes/gci-trusty/glbc.manifest"
    cp "${src_file}" /etc/kubernetes/manifests/
  fi
}


function reset-motd {
  # kubelet is installed both on the master and nodes, and the version is easy to parse (unlike kubectl)
  local -r version="$(/usr/bin/kubelet --version=true | cut -f2 -d " ")"
  # This logic grabs either a release tag (v1.2.1 or v1.2.1-alpha.1),
  # or the git hash that's in the build info.
  local gitref="$(echo "${version}" | sed -r "s/(v[0-9]+\.[0-9]+\.[0-9]+)(-[a-z]+\.[0-9]+)?.*/\1\2/g")"
  local devel=""
  if [[ "${gitref}" != "${version}" ]]; then
    devel="
Note: This looks like a development version, which might not be present on GitHub.
If it isn't, the closest tag is at:
  https://github.com/kubernetes/kubernetes/tree/${gitref}
"
    gitref="${version//*+/}"
  fi
  cat > /etc/motd <<EOF

Welcome to Kubernetes ${version}!

You can find documentation for Kubernetes at:
  http://docs.kubernetes.io/

You can download the build image for this release at:
  https://storage.googleapis.com/kubernetes-release/release/${version}/kubernetes-src.tar.gz

It is based on the Kubernetes source at:
  https://github.com/kubernetes/kubernetes/tree/${gitref}
${devel}
For Kubernetes copyright and licensing information, see:
  /home/kubernetes/LICENSES

EOF
}


########### Main Function ###########
echo "Start to configure instance for kubernetes"

KUBE_HOME="/home/kubernetes"
if [[ ! -e "${KUBE_HOME}/kube-env" ]]; then
  echo "The ${KUBE_HOME}/kube-env file does not exist!! Terminate cluster initialization."
  exit 1
fi

source "${KUBE_HOME}/kube-env"
config-ip-firewall
create-dirs
if [[ "${KUBERNETES_MASTER:-}" == "true" ]]; then
  mount-master-pd
  create-master-auth
  create-master-kubelet-auth
else
  create-kubelet-kubeconfig
  create-kubeproxy-kubeconfig
fi

assemble-docker-flags
load-docker-images
start-kubelet

if [[ "${KUBERNETES_MASTER:-}" == "true" ]]; then
  compute-master-manifest-variables
  start-etcd-servers
  start-kube-apiserver
  start-kube-controller-manager
  start-kube-scheduler
  start-kube-addons
  start-cluster-autoscaler
  start-lb-controller
else
  start-kube-proxy
  # Kube-registry-proxy.
  if [[ "${ENABLE_CLUSTER_REGISTRY:-}" == "true" ]]; then
    cp "${KUBE_HOME}/kube-manifests/kubernetes/kube-registry-proxy.yaml" /etc/kubernetes/manifests
	fi
fi
start-fluentd
reset-motd
echo "Done for the configuration for kubernetes"
