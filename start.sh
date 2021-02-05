#!/usr/bin/env bash
# Simple script to help test Ember-CSI and its operator
# Supported OS: Centos 8 and Fedora 32 or greater
# Centos 7 is supported if we don't rebuild containers from source.  When
# building containers from source we'll see
#   Error: failed to mount overlay for metacopy check with "nodev,metacopy=on" options: invalid argument
# As described in https://github.com/containers/podman/issues/8118
#
# If this script fails with
#   level=info msg="Starting libvirt service"
#   level=info msg="Will use root access: executing systemctl daemon-reload command"
#   level=info msg="Will use root access: executing systemctl start libvirtd"
#   Failed to start libvirt service
# Then it's bug: https://bugzilla.redhat.com/show_bug.cgi?id=1224211
# Can be fixed manually running (don't use sudo)
#    systemctl daemon-reexec
# Or updating your OS
#
# Logs are stored in the $ARTIFACTS_DIR that defaults to test-artifacts:
#   - execution.log => Output from running ./start.sh
#   - test-run.log => Output from e2e tests
#   - kubelet.log => Output from kubelet after running e2e tests
#   - <pod>-<container>.log => Output from the containers after e2e tests tests
#
# Examples:
#   - Create an OpenShift cluster in a VM, deploy the operator and a plugin,
#     and run the end-to-end tests:
#       ./start.sh e2e
#
#   - Remove the Ember-CSI container, build/pull it again, and run e2e tests
#       ./start.sh clean '' driver
#       ./start.sh e2e
#
#   - Remove the operator container, build/pull it again, deploy Ember-CSI, and
#     run e2e tests
#       ./start.sh clean '' driver operator
#       ./start.sh e2e
#
#   - Deploy the operator and push the CSI plugin container but don't run it.
#     This way we can do the driver deployment manually on the form (we must
#     replace the default name, example, with backend) and then run the
#     end-to-end tests.
#       ./start.sh container
#       # Go to the web console and create the driver:
#       #   Operators > Installed Operators > Ember CSI Operator > Create Instance
#       # For the LVM driver we would change:
#       #  Name: backend
#       #  Driver: LVMVolume
#       #  Target Helper: lioadm
#       # Volume Group: ember-volumes
#       # Target Ip Address: output from running command crc ip
#       # Now we run e2e tests and we'll see a message saying "Driver already
#       # present, skipping its deployment"
#       ./start.sh e2e
#
#
# The Ember-CSI backend configuration is stored in OpenShift as a secret, so
# if we want to see the configuration used we have 2 ways of doing it:
#   - Checking the secret:
#       oc get secret ember-csi-operator-backend -o jsonpath='{.data}'|python -c 'import json, sys, base64, pprint; data=sys.stdin.read(); pprint.pprint(json.loads(base64.decodestring(data.split(":")[1][:-1])));'
#   - See the environmental variable in use:
#       oc exec -t backend-controller-0 -c ember-csi -- /bin/bash -c 'echo $X_CSI_BACKEND_CONFIG'
#
#
# TODO: Allow building and testing a custom catalog:
#   - How to build a catalog:
#       https://github.com/operator-framework/community-operators/blob/master/docs/testing-operators.md#building-a-catalog-using-packagemanifest-format
#   - Adding the catalog
#       https://github.com/operator-framework/community-operators/blob/master/docs/testing-operators.md#2-adding-the-catalog-containing-your-operator

set -e
set -o pipefail

ACTION_PARAMS=("${@:3}")

COMMAND=${1}
CONFIG="${2}"

DEBUG=

DRIVER_FILE=lvmdriver.yaml
CATALOG=community-operators

PWD=`pwd`
SCRIPT_DIR=$(dirname `realpath $0`)
MANIFEST_DIR="${SCRIPT_DIR}/manifests"
ARTIFACTS_DIR="${SCRIPT_DIR}/test-artifacts"
CACHE_DIR="${ARTIFACTS_DIR}/caches"

# NOTE: Won't work if we don't include the port
INTERNAL_REGISTRY_URL='image-registry.openshift-image-registry.svc:5000'

CRC_DIR=~/crc-linux
SECRET_FILE='fake-secret'

OC_PATH=~/.crc/bin/oc/oc

DRIVER_REGISTRY=
DRIVER_CONTAINER='embercsi/ember-csi:master'
DRIVER_DOCKERFILE=
DRIVER_SOURCE=

OPERATOR_REGISTRY=
OPERATOR_CONTAINER='embercsi/ember-csi-operator:latest'
OPERATOR_DOCKERFILE='build/Dockerfile.multistage'
OPERATOR_SOURCE=

OPENSHIFT_VERSION='4.5'

if [[ -z "${CONFIG}" ]]; then
  echo 'No config file defined in command line'
  if [[ -e "${PWD}/config" ]]; then
    echo 'Default config file found in current directory, using it'
    CONFIG="${PWD}/config"
  fi
fi

if [[ -n "${CONFIG}" ]]; then
  echo "Using config file ${CONFIG}"
  source "${CONFIG}"
else
  echo 'Using program defaults'
fi

exec &> >(tee -a "${ARTIFACTS_DIR}/execution.log")

if [[ "${OPENSHIFT_VERSION}" == '4.6' ]]; then
  CRC_VERSION='1.20.0'
elif [[ "${OPENSHIFT_VERSION}" == '4.5' ]]; then
  CRC_VERSION='1.17.0'
else
  echo "Unknown OPENSHIFT_VERSION: ${OPENSHIFT_VERSION}"
  exit 4
fi


E2E_CONTAINER="embercsi/openshift-tests:${OPENSHIFT_VERSION}"

CRC_URL=https://mirror.openshift.com/pub/openshift-v4/clients/crc/${CRC_VERSION}/crc-linux-amd64.tar.xz
CRC_TEMP_FILE="${ARTIFACTS_DIR}/crc.tar.xz"
CRC="${CRC_DIR}/crc"

CLEAN_OPTIONS='tar vm crc artifacts operator operator-container driver container registries e2e'
DEFAULT_CLEAN_OPTIONS=('tar vm artifacts operator-container container')


if [[ -n $DEBUG ]]; then
  set -x
fi


# Login to OC as admin
function login {
  echo Waiting for the cluster to be up and running
  # Wait for CRC to be up and Running
  while [[ `"${CRC}" status | grep Running | wc -l` != '2' ]]; do
    sleep 5
  done

  echo "Loging in the OpenShift cluster"
  # Enable env variables
  eval $("${CRC}" oc-env)

  # Get the login command from CRC
  login_command=`"${CRC}" console --credentials | grep -o "oc login -u kubeadmin.*443"`
  echo Try to login into the cluster

  # Add parameter when running the command to prevent oc from prompting about insecure connections
  login_command="${login_command/oc login/oc login --insecure-skip-tls-verify}"
  while ! ${login_command}; do
    sleep 2
  done
}


# =============================================================================
# CRC DOWNLOAD, SETUP, & INSTALL
# =============================================================================

# Get the crc file, untar it, and leave it in a known location
function get_crc {
  if [[ ! -e "${CRC}" ]]; then
    if [[ ! -e "$CRC_TEMP_FILE" ]]; then
      echo "Downloading CRC file"
      curl -Lo "$CRC_TEMP_FILE" $CRC_URL
    else
      echo "CRC file "${CRC_TEMP_FILE}" already present in the system"
    fi

    if ! ls "${ARTIFACTS_DIR}"/crc-linux-* 1> /dev/null 2>&1; then
      echo "Untaring CRC file to $CRC_DIR"
      tar -C "${ARTIFACTS_DIR}" -xf "$CRC_TEMP_FILE"
    fi
    mv "${ARTIFACTS_DIR}"/crc-linux-* "${CRC_DIR}"

  else
    echo "CRC already present at ${CRC_DIR}"
  fi
}


function check_credentials {
  if [[ ! -e "${SECRET_FILE}" ]]; then
    echo "No secret present at ${SECRET_FILE}, writing a fake one"
    echo '{"auths":{"fake":{"auth": "bar"}}}' > "${SECRET_FILE}"
  fi

  if [[ "${OPENSHIFT_VERSION}" != '4.5' ]] && grep -q fake "${SECRET_FILE}" ; then
    echo "Fake credentials only work on OpenShift version 4.5"
    exit 5
  fi
}


# Setup CRC requirements, tinyproxy to access the web console remotely, and
# podman to run the tests.
function setup_crc {
  get_crc

  check_credentials

  echo "CRC version ${CRC_VERSION} with OpenShift ${OPENSHIFT_VERSION}"

  echo "Setting up CRC requirements"
  "${CRC}" setup

  # Setup tinyproxy so we can access the web console if we are running this on
  # a remote host/VM
  if ! which tinyproxy; then
    echo 'Installing tinyproxy'
    if grep CentOS /etc/redhat-release; then
      sudo yum -y install epel-release
    fi

    if ! yum info tinyproxy ; then
      # Centos 8 doesn't have the package
      if grep CentOS /etc/redhat-release; then
        sudo yum -y install https://download-ib01.fedoraproject.org/pub/epel/7/x86_64/Packages/t/tinyproxy-1.8.3-2.el7.x86_64.rpm
      else
        echo "Please manually install tinyproxy: https://pkgs.org/search/?q=tinyproxy"
        exit 6
      fi
    else
      sudo yum -y install tinyproxy > /dev/null
    fi
    sudo sed -i 's/Allow 127.0.0.1/#Allow 127.0.0.1/g' /etc/tinyproxy/tinyproxy.conf
    sudo sed -i '0,/^ConnectPort/s//ConnectPort 6443\nConnectPort/' /etc/tinyproxy/tinyproxy.conf
    sudo systemctl enable --now tinyproxy
  fi

  # # We need podman to run the tests
  if ! which podman; then
    sudo yum -y install podman podman-docker
  fi
}


function increase_timeout_marketplace {
  operator=$1
  if [[ "${CRC_VERSION}" == '1.20.0' ]]; then
    return
  fi

  echo "Increasing probe timeout for the ${operator} marketplace operator"
  while ! oc get -n openshift-marketplace deployment.apps/${operator}-operators ; do
    sleep 5
  done

  # Sometimes marketplace operators probes keep failing, so we increase their
  # timeouts, as per https://access.redhat.com/solutions/5388381
  patch_json="{\"spec\": {\"template\": {\"spec\": {\"containers\": [{\"name\": \"${operator}-operators\", \"livenessProbe\": {\"initialDelaySeconds\": 60, \"timeoutSeconds\": 5}, \"readinessProbe\": {\"initialDelaySeconds\": 120, \"timeoutSeconds\": 5}}]}}}}"
  oc patch deployment.apps/${operator}-operators -n openshift-marketplace --patch "$patch_json"
}


# Start CRC to get the OpenShift cluster
function run_crc {
  do_wait="$1"
  setup_crc

  start_crc=

  if "${CRC}" status; then
    if [[ `"${CRC}" status | grep Running | wc -l` != '2' ]]; then
      echo -e "Existing deployment is not running as expected, please check it manually with:\n\t\"${CRC}\" status"
      exit 3
    fi
  else
    start_crc=1
  fi

  if [[ -n ${start_crc} ]]; then
    "${CRC}" start -p "${SECRET_FILE}"

    login

    increase_timeout_marketplace 'certified'
    increase_timeout_marketplace 'community'

    if [[ -n "${do_wait}" ]]; then
      echo "Giving time for the cluster to stabilize (2 min sleep)"
      sleep 120
    fi
  fi

  login

  # Enable the csi-snapshot-controller-operator. This has been disabled in crc to
  # save some memory, details on these commands in:
  # https://code-ready.github.io/crc/#starting-monitoring-alerting-telemetry_gsg
  echo "Deploying the cluster wide snapshot controller"

  # AFAIK to deploy the csi-snapshot-controller with commented mechanism only
  # works if we are not using fake credentials, but since could be running with
  # fake credentials, we better use a custom manifest to deploy it.
  #
  if grep -q fake "${SECRET_FILE}"; then
    # These manifest come from https://github.com/kubernetes-csi/external-snapshotter/tree/master/deploy/kubernetes/csi-snapshotter
    oc apply -f "$MANIFEST_DIR/deployment/rbac-snapshot-controller.yaml"
    sed -e "s/latest/${OPENSHIFT_VERSION}/g" "$MANIFEST_DIR/deployment/setup-snapshot-controller.yaml" | oc apply -f -
    snap_namespace='default'

  else
    if ID=`oc get clusterversion version -ojsonpath='{range .spec.overrides[*]}{.name}{"\n"}{end}' | nl -v 0 -w 1 | grep csi-snapshot-controller-operator | cut -f 1`; then
      oc patch clusterversion/version --type='json' -p '[{"op":"remove", "path":"/spec/overrides/'${ID}'"}]'
    fi

    snap_namespace='openshift-cluster-storage-operator'

    echo -n "Waiting for the snapshot operator to be running ..."
    while true; do
      echo -n '.'
      oc wait --namespace $snap_namespace --for=condition=Ready --timeout=15s -l app=csi-snapshot-controller-operator pod 2>/dev/null && break
      sleep 5
    done
    echo
  fi

  echo -n "Waiting for the snapshot controller to be running ..."
  while [[ -z `oc get pod --namespace $snap_namespace -l app=csi-snapshot-controller 2>/dev/null` ]]; do
    sleep 5
  done

  echo -e "If you are running this on a different host/VM, you can access the web console by:\n  - Setting your browser's proxy to this host's IP and port 8888\n  - Going to https://console-openshift-console.apps-crc.testing\n  - Using below credentials (kubeadmin should be entered as kube:admin)\n`${CRC} console --credentials`\n"

  # For some reason the VM's iscsid fails to start on boot
  do_ssh 'sudo systemctl start iscsid'
}


# =============================================================================
# HELPER FUNCTIONS FOR CONTAINERS
# =============================================================================

# Get the location of the container we'll be impersonating based on the
# registry (which can be empty for unqualified) and the project/container:tag
function get_container_location {
  if [[ -n "$1" ]]; then
    echo -n "${1}/"
  fi
  echo "${2}"
}


# Spoof a container in our OpenShift cluster given a source location (directory
# or container), the registry and container we want to impersonate, and
# the docker file to generate the container if the source is a directory
# (source code).
function impersonate_container {
  source_location="$1"
  dest_registry=$2
  dest_container=$3
  docker_file="$4"

  if [[ -z "${source_location}" ]]; then return; fi

  container_location=$(get_container_location "$dest_registry" "$dest_container")

  if sudo podman inspect "${container_location}"; then
    echo "Container ${container_location} exists, skipping build/download"
  elif [[ -d "${source_location}" ]]; then
    if [[ ! -e "${source_location}/${docker_file}" ]]; then
      echo "Missing ${docker_file}, cannot build container"
      exit 2
    fi

    cache_name=`grep FROM "${source_location}/${docker_file}" | tail -n1 | cut -d' ' -f 2 | sed 's/:/_/'`
    cache_location="${CACHE_DIR}/cache-${cache_name}"

    echo "Building container from source at ${source_location}/${docker_file}"
    mkdir -p "${cache_location}"
    sudo podman build --build-arg RELEASE=master --build-arg VERSION=`date +%d.%m.%Y.dev%H%M%S%N`  -t "${container_location}" -v "${cache_location}:/var/cache:rw,shared,z" -f "${docker_file}" "${source_location}"

  else
    echo "Source is not a directory, assuming it's a container. Pulling custom container ${source_location}"
    sudo podman pull --tls-verify=false "${source_location}"
    sudo podman tag "${source_location}" "${container_location}"
  fi

  upload_impersonate "$dest_registry" "$dest_container"
}


# Upload a container to the cluster's internal registry and ensure it will be
# impersonating the original one.
# Requires the destination registry and the container name (project/name:tag)
function upload_impersonate {
  # Parameters: registry container_name
  registry=$1
  dest_container=$2
  container=(${2//\// })
  project=${container[0]}

  do_reset=''
  local_container=$(get_container_location "$registry" "$dest_container")

  # We need to create the project so the images on the registry match upstream.
  # We also need to add the role and rolebinding in the project to allow
  # pulling these images from any project (like the openshift namespace).
  echo "Ensuring that the ${project} registry/namespace/project exists and is accessible by all projects"
  sed -e "s/embercsi/${project}/g" "${MANIFEST_DIR}/deployment/emberproject" | oc apply -f -

  SSH_PARAMS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ~`whoami`/.crc/machines/crc/id_rsa"
  SSH_REMOTE="core@`${CRC} ip`"
  # Docs on registries.conf: https://github.com/containers/image/blob/master/docs/containers-registries.conf.5.md
  # For unqualified images we must add the internal registry to the search list
  if [[ -z $registry ]]; then
    # Make sure the internal registry is queried first for unqualified images
    # if it's not already there.
    if ! ssh $SSH_PARAMS $SSH_REMOTE "grep \"\['${INTERNAL_REGISTRY_URL}\" /etc/containers/registries.conf"; then
      echo "Setting the CRC VM to use the internal registry for unqualified images with the highest priority"
      ssh $SSH_PARAMS $SSH_REMOTE "sudo sed -i \"s/unqualified-search-registries = \[/unqualified-search-registries = \['${INTERNAL_REGISTRY_URL}',/\" /etc/containers/registries.conf && sudo systemctl restart crio kubelet"
      do_reset='yes'
    fi

  # For qualified images add a possible mirror for the registry we are
  # impersonating but allow going back to the original location if we don't
  # have a replacement.  Only add it if it's not already there.
  elif ! ssh $SSH_PARAMS $SSH_REMOTE "grep \"prefix = '${registry}'\" /etc/containers/registries.conf"; then
    ssh $SSH_PARAMS $SSH_REMOTE "echo -e \"\n[[registry]]\nprefix = '$registry'\nblocked = false\ninsecure = true\nlocation = '$registry'\n[[registry.mirror]]\nlocation = 'image-registry.openshift-image-registry.svc:5000'\" | sudo tee -a /etc/containers/registries.conf"
    do_reset='yes'
  fi

  # We have to reboot services to pick up changes to registries.conf
  if [[ -n $do_reset ]]; then
    ssh $SSH_PARAMS $SSH_REMOTE "sudo systemctl restart crio kubelet"
    echo "Giving some time for changes to take effect"
    sleep 60
  fi

  # Use a default route to gain access to the registry from outside the cluster
  # https://docs.openshift.com/container-platform/4.5/registry/securing-exposing-registry.html
  oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge
  HOST=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}')
  oc_user=`oc whoami`
  sudo podman login -u ${oc_user#*:} -p $(oc whoami -t) --tls-verify=false $HOST
  sudo podman push --tls-verify=false "${local_container}" docker://"${HOST}/${dest_container}"
}


# =============================================================================
# OPERATOR
# =============================================================================

function install_operator {
  # Pass parameter to select the source of the operator
  run_crc true
  login

  manifests="${MANIFEST_DIR}/deployment"

  impersonate_container "$OPERATOR_SOURCE" "$OPERATOR_REGISTRY" "$OPERATOR_CONTAINER" "${OPERATOR_DOCKERFILE}"

  echo -n "Wait for the community marketplace operator ..."
  if [[ "${OPENSHIFT_VERSION}" == '4.5' ]]; then
    label_match='marketplace.operatorSource=community-operators'
  # 4.6
  else
    label_match='olm.catalogSource=community-operators'
  fi

  while ! oc wait --for=condition=Ready --timeout=5s -n openshift-marketplace -l $label_match pod 2>/dev/null ; do
    echo -n '.'
    sleep 5
  done
  echo

  if [ "${CATALOG}" != "community-operators" ]; then
    echo "Setup custom marketplace to install devel branch of ember operator"
    oc apply -f "${manifests}/catalog.yaml"
  fi

  echo "Subscribing (installing) the operator"
  oc apply -f "$manifests/operatorgroup.yaml"
  sed -e "s/community-operators/${CATALOG}/g" "$manifests/subscription.yaml" | oc apply -f -

  echo -n "Waiting for the operator to be installed ..."
  while true; do
    echo -n '.'
    oc wait --for=condition=Ready --timeout=15s -l name=ember-csi-operator pod 2>/dev/null && break
    sleep 5
  done
  echo
}


# =============================================================================
# DRIVER INSTALLATION & DEPLOYMENT
# =============================================================================

function install_driver_container {
  install_operator
  impersonate_container "$DRIVER_SOURCE" "$DRIVER_REGISTRY" "$DRIVER_CONTAINER" "${DRIVER_DOCKERFILE}"
}


function deploy_driver {
  install_driver_container

  if oc get embercsis backend; then
    echo 'Driver already present, skipping its deployment'
    return
  fi

  oc apply -f "${DRIVER_FILE}"
  echo -n "Waiting for the driver to be installed ..."
  while true; do
    echo -n '.'
    oc wait --for=condition=Ready --timeout=15s -l app=embercsi pod 2>/dev/null && break
    sleep 5
  done
  echo

  # Create the VG if it doesn't exist yet
  do_ssh 'sudo bash -c '\''if [[ ! -e /dev/ember-volumes ]] ; then truncate -s 10G /var/lib/containers/ember-volumes && device=`losetup --show -f /var/lib/containers/ember-volumes ` && echo -e \"device is $device\n\" && pvcreate $device && vgcreate ember-volumes $device && vgscan && sed -i "s/^\tudev_sync = 1/\tudev_sync = 0/" /etc/lvm/lvm.conf && sed -i "s/^\tudev_rules = 1/\tudev_rules = 0/" /etc/lvm/lvm.conf; fi'\'

}


# =============================================================================
# E2E
# =============================================================================

function run_e2e_tests {
  deploy_driver

  test_manifests="$MANIFEST_DIR/tests"

  oc_realpath=$(realpath `which oc`)
  if ! ln -f "$oc_realpath" "${ARTIFACTS_DIR}/oc"; then
    rm -f "${ARTIFACTS_DIR}/oc"
    cp "$oc_realpath" "${ARTIFACTS_DIR}/oc"
  fi

  oc config view --raw > "${ARTIFACTS_DIR}/kubeconfig.yaml"

  # Due to golang's pauper regex library we cannot use --run to limit the tests
  # we run using regex negative lookahead.  So we do it in Python inside the
  # container.
  oc_path=`realpath "${OC_PATH}"`

  if ! sudo podman image exists ${E2E_CONTAINER}; then
    if ! sudo podman pull "${E2E_CONTAINER}"; then
      echo "Could not pull container ${E2E_CONTAINER}, building it"
      (cd "${SCRIPT_DIR}/e2e-container" && sudo ./build.sh $OPENSHIFT_VERSION)
      login
    fi
  fi

  set +e
  sudo podman run --rm -it --name=e2e --network=host \
          -v "${ARTIFACTS_DIR}":/artifacts \
          -v "${ARTIFACTS_DIR}/oc":/bin/oc \
          -v "${ARTIFACTS_DIR}/oc":/bin/kubectl \
          -v $test_manifests/test-sc.yaml:/home/vagrant/test-sc.yaml \
          -v $test_manifests/csi-test-config.yaml:/home/vagrant/csi-test-config.yaml \
          -e KUBECONFIG=/artifacts/kubeconfig.yaml \
          -e TEST_CSI_DRIVER_FILES=/home/vagrant/csi-test-config.yaml \
          -u root \
          ${E2E_CONTAINER} 2>&1 | tee "${ARTIFACTS_DIR}/test-run.log"
  result=$?
  set -e

  # Save controller and node logs
  pods=`oc get -l app=embercsi -o go-template='{{range .items}}{{.metadata.name}}{{" "}}{{end}}' pod`
  for pod in $pods; do
    containers=`oc get pods ${pod} -o jsonpath='{.spec.containers[*].name}'`
    for container in $containers; do
      oc logs $pod -c $container > "${ARTIFACTS_DIR}/${pod}-${container}.log"
    done
  done

  # Save kubelet logs
  oc adm node-logs --role=master -u kubelet > "${ARTIFACTS_DIR}/kubelet.log"

  exit $result

}


# =============================================================================
# HELP
# =============================================================================

function show_help {
        echo -e "\nEmber-CSI simple test tool on OpenShift:\n$1 <action> [<config-file>] [<action-options>]\n\n<action>:\n  download: downloads the CRC files\n  setup: setup CRC dependencies\n  run: starts the CRC VM running OpenShift\n  operator: installs the Ember-CSI operator from a catalog (defaults to the community)\n  container: build/download the custom driver container and upload to the cluster.\n  driver: deploys an Ember-CSI driver (defaults to lvmdriver.yaml)\n  e2e: runs end-to-end tests\n  stop: Stops the CRC VM\n  ssh: SSHs into the CRC VM for debugging purposes\n  login: Log in the OpenShift cluster\n  clean [<config-file> <what>]: Cleans different aspects of the test deployment.  Defaults to everything except the crc installation. We can limit what to clean if we provide a configuration file (it can be '') and then what we want to clean as a series of parameters. Passing \"$0 clean '' all\" is equivalent to: \"$0 '' clean $CLEAN_OPTIONS\".\n\n<config-file>: Configuration file, which defaults to "config" in the current directory (check the "sample_config" file for available options).\n\nEvery action will ensure required steps will have been completed.\nFor example, if we run the operator action it will ensure downloads, setup, and run have been completed."
}


# =============================================================================
# STOP
# =============================================================================

function crc_status {
  if [[ -e "${CRC}" ]]; then
    if "${CRC}" status; then
      return 0
    fi
  fi
  return 1
}


function stop_crc {
  echo 'Stopping and removing the CRC VM'
  if crc_status; then
    "${CRC}" -f delete
  fi
}


# =============================================================================
# SSH
# =============================================================================

function do_ssh {
  SSH_PARAMS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ~`whoami`/.crc/machines/crc/id_rsa"
  SSH_REMOTE="core@`${CRC} ip`"
  ssh $SSH_PARAMS $SSH_REMOTE "$@"
}


# =============================================================================
# CLEAN
# =============================================================================

function clean_container {
  source_location="$1"
  dest_registry=$2
  dest_container=$3

  if [[ -z "${source_location}" ]]; then return; fi

  container_location=$(get_container_location "$dest_registry" "$dest_container")
  if [[ ! -d "${source_location}" ]]; then
    if sudo podman image exists ${source_location}; then
      sudo podman rmi ${source_location} || true
    fi
  fi
  if sudo podman image exists ${container_location}; then
    sudo podman rmi ${container_location} || true
  fi
}


function clean_crc {
  case "${#ACTION_PARAMS[@]}" in
    '0')
      ACTION_PARAMS=$DEFAULT_CLEAN_OPTIONS
      ;;
    '1')
      if [[ "${ACTION_PARAMS[0]}" == "all" ]]; then
        ACTION_PARAMS=($CLEAN_OPTIONS)
      fi
      ;;
  esac

  for element in ${ACTION_PARAMS[@]}; do
    echo "Cleaning $element"
    case $element in
      tar)
        rm -f "${CRC_TEMP_FILE}" || true
        ;;
      crc)
        rm -rf "$CRC_DIR"
        ;;

      vm)
        stop_crc
        ;;
      artifacts)
        rm -f "${ARTIFACTS_DIR}"/*
        ;;
      container)
        clean_container "$DRIVER_SOURCE" "$DRIVER_REGISTRY" "$DRIVER_CONTAINER"
        ;;
      driver)
        if crc_status; then
          login
          oc delete -f "${DRIVER_FILE}" || true
        fi
        ;;
      operator-container)
        clean_container "$OPERATOR_SOURCE" "$OPERATOR_REGISTRY" "$OPERATOR_CONTAINER"
        ;;
      operator)
        if crc_status; then
          login
          manifests="${MANIFEST_DIR}/deployment"

          if oc get subscription ember-csi-operator; then
            csv_name=`oc get subscription ember-csi-operator -o jsonpath='{.status.currentCSV}'`
            oc delete subscription ember-csi-operator -n default || true
            oc delete clusterserviceversion "${csv_name}" -n default || true
          fi
          oc delete operatorgroup ember-operatorgroup -n default || true

          if [ "${CATALOG}" != "community-operators" ]; then
            oc delete -f "${manifests}/catalog.yaml" || true
          fi
        fi
        ;;
      registries)
        if crc_status; then
          login
          SSH_PARAMS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ~`whoami`/.crc/machines/crc/id_rsa"
          SSH_REMOTE="core@`${CRC} ip`"
          ssh $SSH_PARAMS $SSH_REMOTE "echo -e \"unqualified-search-registries = ['registry.access.redhat.com', 'docker.io']\" | sudo tee /etc/containers/registries.conf"
        fi
        ;;
      e2e)
        sudo podman rmi ${E2E_CONTAINER} || true
        ;;
      *)
        echo "Unkown cleanable element ${element}"
    esac
  done

}

# =============================================================================
# MAIN
# =============================================================================


case $COMMAND in
  help)
    show_help $0
    ;;

  download)
    get_crc
    ;;

  setup)
    setup_crc
    ;;

  run)
    run_crc
    ;;

  operator)
    install_operator
    ;;

  container)
    install_driver_container
    ;;

  driver)
    deploy_driver
    ;;

  e2e)
    run_e2e_tests
    ;;

  stop)
    stop_crc
    ;;

  clean)
    clean_crc
    ;;

  ssh)
    do_ssh "${@:3}"
    ;;

  login)
    login
    ;;

  *)
    echo -e "\nUnknown action. Usage:\n"
    show_help $0
    exit 1
esac
