#!/bin/bash -l

provision_directive=$1

cwd=$(pwd)

cluster_domain="abatoolbox.com"
cluster_hostname="local.${cluster_domain}"
application_hostnames="admin.${cluster_hostname} lc.${cluster_hostname} s3.${cluster_hostname} minio.${cluster_hostname} mail.${cluster_hostname}"
registry_hostname="registry.${cluster_hostname}"
cluster_support_namespace="cluster-support"
provision_namespace="provision-k8s"
cluster_configuration="development"

provisioner_image_version="1.5.0"
kubectl_version="1.27.4"
helm_dist_version="3.12.3"
sudo_command="sudo"

git_repo="https://github.com/relenteny/provision-k8s.git"
# TODO Update tag
git_tag="rancher-desktop"

if [[ -z "${provision_directive}" ]]
then
    provision_directive="provision"
fi

uname=$(uname)
if [[ ${uname} == "Darwin" ]]
then
    host_os="mac"
    helm_file="darwin-amd64"
elif [[ -n ${WSL_DISTRO_NAME} ]]
then
    host_os="windows"
    helm_file="linux-amd64"
    windows_hosts="/mnt/c/Windows/System32/drivers/etc/hosts"
    # Ensure .kube/config permissions are correct to prevent warning messages
    chmod 600 ~/.kube/config
    if [[ ! -w "${windows_hosts}" ]]
    then
        echo " "
        echo "***** Windows hosts file is not writable *****"
        echo " "
        echo "The current process is unable to make changes to the Windows hosts table. In order to configure access"
        echo "to the Kubernetes cluster, including access from WSL, the Windows hosts file needs to be updated."
        echo " "
        echo "There are various methods available to handle this issue. The most straightforward is to execute this"
        echo "script in a WSL session started with Administrator privileges (Run as administrator). Once the script has"
        echo "succesfully executed, subsequent WSL sessions will not require Administrator privileges."
        echo " "
        exit 1
    fi
elif [[ ${uname} == "Linux" ]]
then
    host_os="linux"
    helm_file="linux-amd64"
else
    mingw_host=$(echo ${uname} | tr '[:upper:]' '[:lower:]' | grep "mingw")
    if [[ -n "${mingw_host}" ]]
    then
        host_os="windows"
        sudo_command=""
        helm_file="linux-amd64"
        windows_hosts="/c/Windows/System32/drivers/etc/hosts"
        if [[ ! -w "${windows_hosts}" ]]
        then
            echo " "
            echo "***** Windows hosts file is not writable *****"
            echo " "
            echo "The current process is unable to make changes to the Windows hosts table. In order to configure access"
            echo "to the Kubernetes cluster, the Windows hosts file needs to be updated."
            echo " "
            echo "There are various methods available to handle this issue. The most straightforward is to execute this"
            echo "script in a Git Bash session started with Administrator privileges (Run as administrator). Once the script has"
            echo "succesfully executed, subsequent access to Kubernetes will not require Administrator privileges."
            echo " "
            exit 1
        fi
    else
        echo "Unable to determine operating system."
        echo "Ensure you're running the script on a supported operating system and that, either"
        echo "Docker for Mac/Windows, minikube, or Rancher Desktop are installed."
        exit 1
    fi
fi

command -v kubectl >/dev/null
if [[ $? == 1 ]]
then
    echo " "
    echo "Unable to locate kubectl. Before proceeding, ensure kubectl is installed and is able"
    echo "access your cluster."
    echo " "
    exit
fi

kubectl get nodes || { echo "This script requires a Kubernetes cluster to be to be installed and running."; exit 1;}

hosts_ip="127.0.0.1"
command -v minikube >/dev/null
if [[ $? == 0 ]]
then
    minikube_ip=$(minikube ip)
    if [[ $? == 0 ]]
    then
        hosts_ip=${minikube_ip}
        eval $(minikube -p minikube docker-env)
        minikube_options="-e \"CLUSTER_IP=${minikube_ip}\" --network host"
    else
        minikube_ip=""
    fi
fi

echo " "
echo "Retrieving provisioning code from GitHub."
echo " "

mkdir -p "${HOME}/kubernetes"

cd "${HOME}/kubernetes" || { echo "Error creating ${HOME}/kubernetes directory."; exit 1; }
rm -rf ./provision-k8s

git clone ${git_repo}

cd provision-k8s || { echo "Error with provision-k8s directory."; exit 1; }
git checkout ${git_tag}

image_output=$(docker image ls --format "{{.Repository}}:{{.Tag}}" | grep "k8s-provisioner:${provisioner_image_version}")
if [[ -z "${image_output}" ]]
then
    echo " "
    echo "Building provision image..."
    echo " "

    command -v docker >/dev/null
    if [[ $? == 1 ]]
    then
        echo " "
        echo "Unable to locate docker. Before proceeding, ensure docker is installed and is able"
        echo "access your Docker daemon."
        echo " "
        exit
    fi

    cd images/k8s-provisioner || { echo "Error with images/k8s-provisioner directory."; exit 1; }
    docker build . --tag k8s-provisioner:${provisioner_image_version}
fi

hosts_entry=$(grep -F "${cluster_hostname}" /etc/hosts)
if [[ "${provision_directive}" == "provision" ]] && [[ -z "${hosts_entry}" ]]
then
    echo " "
    echo " "
    echo "Updating hosts table. You may be asked for your password."
    echo " "
    grep -q -F "${hosts_ip}       ${registry_hostname}" /etc/hosts || echo "${hosts_ip}       ${registry_hostname}" | ${sudo_command} tee -a /etc/hosts > /dev/null
    grep -q -F "${hosts_ip}       ${cluster_hostname}" /etc/hosts || echo "${hosts_ip}       ${cluster_hostname}" | ${sudo_command} tee -a /etc/hosts > /dev/null
    grep -q -F "${hosts_ip}       ${application_hostnames}" /etc/hosts || echo "${hosts_ip}       ${application_hostnames}" | ${sudo_command} tee -a /etc/hosts > /dev/null

    if [[ "${host_os}" == "windows" && -w "${windows_hosts}" ]]
    then
        grep -q -F "${hosts_ip}       ${registry_hostname}" ${windows_hosts} || echo "${hosts_ip}       ${registry_hostname}" | ${sudo_command} tee -a ${windows_hosts} > /dev/null
        grep -q -F "${hosts_ip}       ${cluster_hostname}" ${windows_hosts} || echo "${hosts_ip}       ${cluster_hostname}" | ${sudo_command} tee -a ${windows_hosts} > /dev/null
        grep -q -F "${hosts_ip}       ${application_hostnames}" ${windows_hosts} || echo "${hosts_ip}       ${application_hostnames}" | ${sudo_command} tee -a ${windows_hosts} > /dev/null
    fi
fi

cd ${HOME}/kubernetes/provision-k8s

echo "CLUSTER_HOSTNAME=${cluster_hostname}" > scripts/pod-env.txt
echo "REGISTRY_HOSTNAME=${registry_hostname}" >> scripts/pod-env.txt
echo "CLUSTER_SUPPORT_NAMESPACE=${cluster_support_namespace}" >> scripts/pod-env.txt
echo "PROVISION_NAMESPACE=${provision_namespace}" >> scripts/pod-env.txt
echo "CLUSTER_CONFIGURATION=${cluster_configuration}" >> scripts/pod-env.txt
echo "GIT_REPO=${git_repo}" >> scripts/pod-env.txt
echo "GIT_TAG=${git_tag}" >> scripts/pod-env.txt
echo "PROVISION_DIRECTIVE=${provision_directive}" >> scripts/pod-env.txt
readme_configmap=$(date "+%d%m%Y-%H%M")
readme_configmap="readme-${readme_configmap}"
echo "README_CONFIGMAP=${readme_configmap}" >> scripts/pod-env.txt

check_rancher=$(kubectl get node -o yaml | grep rancher)
if [[ -n "${check_rancher}" ]]
then
    cluster_ip=$(kubectl get node -o yaml | grep k3s.io/external-ip | cut -d':' -f2 | xargs)
    if [[ -z "${cluster_ip}" ]]
    then
        cluster_ip=$(kubectl get node -o yaml | grep k3s.io/internal-ip | cut -d':' -f2 | xargs)
    fi
    echo "CLUSTER_IP=${cluster_ip}" >> scripts/pod-env.txt
fi

cd scripts
chmod +x "create-pod.sh"
./create-pod.sh
cd ${HOME}/kubernetes/provision-k8s

if [[ -n "${minikube_ip}" && "${provision_directive}" == "provision" ]]
then
    mkdir -p ${HOME}/.minikube/files/etc/docker/certs.d/${registry_hostname}
    kubectl get secret cluster-registry-local-registry-ingress -n ${cluster_support_namespace} -o go-template='{{index .data "tls.crt"|base64decode}}' > ${HOME}/.minikube/files/etc/docker/certs.d/${registry_hostname}/ca.crt
    echo "127.0.0.1       localhost minikube" > ${HOME}/.minikube/files/etc/hosts
    echo "${hosts_ip}       ${registry_hostname}" >> ${HOME}/.minikube/files/etc/hosts
    minikube cp ${HOME}/.minikube/files/etc/hosts minikube:/etc/hosts
    minikube ssh "sudo mkdir -p /etc/docker/certs.d/${registry_hostname}"
    minikube cp ${HOME}/.minikube/files/etc/docker/certs.d/${registry_hostname}/ca.crt minikube:/etc/docker/certs.d/${registry_hostname}/ca.crt
fi

cd "${HOME}/kubernetes" || { echo "Error with kubernetes directory."; exit 1; }
rm -rf provision-k8s

if [[ "${provision_directive}" == "provision" ]]
then
    mkdir -p "${HOME}/kubernetes/readme"
    readme_filename=$(kubectl get configmap ${readme_configmap} -n ${provision_namespace} -o jsonpath='{.data.filename}')
    kubectl get configmap ${readme_configmap} -n ${provision_namespace} -o jsonpath='{.data.content}' > ${HOME}/kubernetes/readme/${readme_filename}

    command -v helm version >/dev/null
    if [[ $? == 1 ]]
    then
        curl -s https://get.helm.sh/helm-v${helm_dist_version}-${helm_file}.tar.gz -o helm.tar.gz
        tar xf helm.tar.gz
        mkdir -p "${HOME}/.local/bin"
        cp ${helm_file}/helm "${HOME}/.local/bin/"
        echo " "
        echo "The helm command, version ${helm_dist_version}, has been installed in ${HOME}/.local/bin. Ensure"
        echo "${HOME}/.local/bin has been set in \$PATH."
        echo " "
        rm -rf ${helm_file}
        rm helm.tar.gz
        helm_bindir="${HOME}/.local/bin/"
    else
        helm_bindir=""
    fi

    if [[ "${cluster_configuration}" == "development" ]]
    then
        "${helm_bindir}helm" repo remove local >/dev/null 2>&1
        "${helm_bindir}helm" repo add local http://${cluster_hostname}/chartmuseum

        "${helm_bindir}helm" repo remove bitnami >/dev/null 2>&1
        "${helm_bindir}helm" repo add bitnami https://charts.bitnami.com/bitnami

        "${helm_bindir}helm" repo update
    fi

    cd "${HOME}/kubernetes/readme" || { echo "Error with readme directory."; exit 1; }
    readme_file=$(find . -maxdepth 1 -name "README*" | sort -r | head -1)
    if [[ -f "${readme_file}" ]]
    then
        less "${readme_file}"
    fi
else
    hosts_entry=$(grep "${cluster_hostname}" /etc/hosts)
    if [[ -n "${hosts_entry}" ]]
    then
        echo " "
        echo " "
        echo "Updating hosts table. You may be asked for your password."
        echo " "
        ${sudo_command} sed -i.bak "/${cluster_hostname}/d" /etc/hosts
        ${sudo_command} sed -i.bak "/${registry_hostname}/d" /etc/hosts
        ${sudo_command} sed -i.bak "/${application_hostnames}/d" /etc/hosts
        ${sudo_command} rm /etc/hosts.bak
        if [[ "${host_os}" == "windows" && -w "${windows_hosts}" ]]
        then
            sed -i.bak "/${cluster_hostname}/d" ${windows_hosts}
            sed -i.bak "/${registry_hostname}/d" ${windows_hosts}
            sed -i.bak "/${application_hostnames}/d" ${windows_hosts}
            rm ${windows_hosts}.bak
        fi
    fi
fi

cd ${cwd}
