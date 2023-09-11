#!/usr/bin/env bash

# Copyright (c) 2023 Microsoft Corporation
#
# SPDX-License-Identifier: Apache-2.0

set -o errexit
set -o nounset
set -o pipefail

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${tests_dir}/common.bash"

K8S_TEST_HOST_TYPE="${K8S_TEST_HOST_TYPE:-small}"

function _print_instance_type() {
    case ${K8S_TEST_HOST_TYPE} in
        small)
            echo "Standard_D2s_v5"
            ;;
        normal)
            echo "Standard_D4s_v5"
            ;;
        *)
            echo "Unknown instance type '${K8S_TEST_HOST_TYPE}'" >&2
            exit 1
    esac
}

function _print_cluster_name() {
    test_type="${1:-k8s}"

    short_sha="$(git rev-parse --short=12 HEAD)"
    echo "${test_type}-${GH_PR_NUMBER}-${short_sha}-${KATA_HYPERVISOR}-${KATA_HOST_OS}-amd64-${K8S_TEST_HOST_TYPE:0:1}"
}

function _print_rg_name() {
    test_type="${1:-k8s}"

    echo "${AZ_RG:-"kataCI-$(_print_cluster_name ${test_type})"}"
}

function install_azure_cli() {
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    # The aks-preview extension is required while the Mariner Kata host is in preview.
    az extension add --name aks-preview
}

function login_azure() {
    az login \
        --service-principal \
        -u "${AZ_APPID}" \
        -p "${AZ_PASSWORD}" \
        --tenant "${AZ_TENANT_ID}"
}

function create_cluster() {
    test_type="${1:-k8s}"

    # First ensure it didn't fail to get cleaned up from a previous run.
    delete_cluster "${test_type}" || true

    local rg="$(_print_rg_name ${test_type})"

    az group create \
        -l eastus2 \
        -n "${rg}"

    az aks create \
        -g "${rg}" \
	--node-resource-group "node-${rg}" \
        -n "$(_print_cluster_name ${test_type})" \
        -s "$(_print_instance_type)" \
        --node-count 1 \
        --generate-ssh-keys \
        $([ "${KATA_HOST_OS}" = "cbl-mariner" ] && echo "--os-sku AzureLinux --workload-runtime KataMshvVmIsolation")
}

function install_bats() {
    # Installing bats from the lunar repo.
    # This installs newer version of the bats which supports setup_file and teardown_file functions.
    # These functions are helpful when adding new tests that require one time setup.

    sudo apt install -y software-properties-common
    sudo add-apt-repository 'deb http://archive.ubuntu.com/ubuntu/ lunar universe'
    sudo apt install -y bats
    sudo add-apt-repository --remove 'deb http://archive.ubuntu.com/ubuntu/ lunar universe'
}

function install_kubectl() {
    sudo az aks install-cli
}

function get_cluster_credentials() {
    test_type="${1:-k8s}"

    az aks get-credentials \
        -g "$(_print_rg_name ${test_type})" \
        -n "$(_print_cluster_name ${test_type})"
}

function delete_cluster() {
    test_type="${1:-k8s}"

    az group delete \
        -g "$(_print_rg_name ${test_type})" \
        --yes
}

function get_nodes_and_pods_info() {
    kubectl debug $(kubectl get nodes -o name) -it --image=quay.io/kata-containers/kata-debug:latest || true
    kubectl get pods -o name | grep node-debugger | xargs kubectl delete || true
}

function deploy_k3s() {
	curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644

	# This is an arbitrary value that came up from local tests
	sleep 120s

	# Download the kubectl binary into /usr/bin and remove /usr/local/bin/kubectl
	#
	# We need to do this to avoid hitting issues like:
	# ```sh
	# error: open /etc/rancher/k3s/k3s.yaml.lock: permission denied
	# ```
	# Which happens basically because k3s links `/usr/local/bin/kubectl`
	# to `/usr/local/bin/k3s`, and that does extra stuff that vanilla
	# `kubectl` doesn't do.
	ARCH=$(uname -m)
	if [ "${ARCH}" = "x86_64" ]; then
		ARCH=amd64
	fi
	kubectl_version=$(/usr/local/bin/k3s kubectl version --short 2>/dev/null | grep "Client Version" | sed -e 's/Client Version: //' -e 's/\+k3s1//')
	sudo curl -fL --progress-bar -o /usr/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/${kubectl_version}/bin/linux/${ARCH}/kubectl
	sudo chmod +x /usr/bin/kubectl
	sudo rm -rf /usr/local/bin/kubectl

	mkdir -p ~/.kube
	cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
}

function deploy_k8s() {
	echo "::group::Deploying ${KUBERNETES}"

	case ${KUBERNETES} in
		k3s) deploy_k3s ;;
		*) >&2 echo "${KUBERNETES} flavour is not supported"; exit 2 ;;
	esac

	echo "::endgroup::"
}
