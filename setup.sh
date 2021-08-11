#!/usr/bin/env bash

set -eo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
if [ ! -f "${DIR}/.env" ]; then
    echo "Missing ${DIR}/.env configuration file."
    exit 1;
fi

set -a
# shellcheck disable=SC1090,SC1091
source "$DIR/.env"
set -a

# Required service accounts
# GKE Cluster
GKE_SA=gitpod-gke
GKE_SA_EMAIL="${GKE_SA}"@"${PROJECT_NAME}".iam.gserviceaccount.com
# Cloud SQL - mysql
MYSQL_SA=gitpod-mysql
MYSQL_SA_EMAIL="${MYSQL_SA}"@"${PROJECT_NAME}".iam.gserviceaccount.com
# Object storage
OBJECT_STORAGE_SA=gitpod-storage
OBJECT_STORAGE_SA_EMAIL="${OBJECT_STORAGE_SA}"@"${PROJECT_NAME}".iam.gserviceaccount.com
# Cloud DNS
DNS_SA=gitpod-dns01-solver
DNS_SA_EMAIL="${DNS_SA}"@"${PROJECT_NAME}".iam.gserviceaccount.com
# Name of the node-pools for Gitpod services and workspaces
SERVICES_POOL="workload-services"
WORKSPACES_POOL="workload-workspaces"

GKE_VERSION=${GKE_VERSION:="1.20.8-gke.900"}

GITPOD_VERSION=${GITPOD_VERSION:="aledbf-mk3.55"}

function check_prerequisites() {
    if [ -z "${PROJECT_NAME}" ]; then
        echo "Missing PROJECT_NAME environment variable."
        exit 1;
    fi

    if [ -z "${DOMAIN}" ]; then
        echo "Missing DOMAIN environment variable."
        exit 1;
    fi

    if [ -z "${CLUSTER_NAME}" ]; then
        echo "Missing CLUSTER_NAME environment variable."
        exit 1
    fi

    if [ -z "${REGION}" ]; then
        echo "Missing REGION environment variable. Using us-central1"
        REGION="us-central1"
        export REGION
    fi

    if [ -n "${PREEMPTIBLE}" ] && [ "${PREEMPTIBLE}" == "true" ]; then
        PREEMPTIBLE="--preemptible"
        export PREEMPTIBLE
    fi

    NODES_LOCATIONS=
    if [ -n "${ZONES}" ]; then
        NODES_LOCATIONS="--node-locations=${ZONES}"
    fi
    export NODES_LOCATIONS
}

function create_node_pool() {
    local POOL_NAME=$1
    local NODES_LABEL=$2

    gcloud container node-pools \
        create "${POOL_NAME}" \
        --cluster="${CLUSTER_NAME}" \
        --disk-type="pd-ssd" --disk-size="100GB" \
        --image-type="UBUNTU_CONTAINERD" \
        --machine-type="n2-standard-4" \
        --num-nodes=1 \
        --no-enable-autoupgrade --enable-autorepair --enable-autoscaling \
        --metadata disable-legacy-endpoints=true \
        --scopes="gke-default,https://www.googleapis.com/auth/ndev.clouddns.readwrite" \
        --node-labels="${NODES_LABEL}" \
        --max-pods-per-node=110 --min-nodes=1 --max-nodes=50 \
        --region="${REGION}" \
        "${PREEMPTIBLE}"
}

function setup_mysql_database() {
    if [ "$(gcloud sql instances list --filter="name:${MYSQL_INSTANCE_NAME}" --format="value(name)" | grep "${MYSQL_INSTANCE_NAME}" || echo "empty")" == "${MYSQL_INSTANCE_NAME}" ]; then
        echo "Cloud SQL (MySQL) Instance already exists."
    else
        # https://cloud.google.com/sql/docs/mysql/create-instance
        echo "Creating Mysql instance..."
        gcloud sql instances create "${MYSQL_INSTANCE_NAME}" \
            --database-version=MYSQL_5_7 \
            --storage-size=20 \
            --storage-auto-increase \
            --tier=db-n1-standard-2 \
            --region="${REGION}" \
            --replica-type=FAILOVER \
            --enable-bin-log

        gcloud sql instances patch "${MYSQL_INSTANCE_NAME}" --database-flags \
            explicit_defaults_for_timestamp=off --quiet

        echo "Creating gitpod Mysql database..."
        gcloud sql databases create gitpod --instance="${MYSQL_INSTANCE_NAME}"
    fi

    echo "Creating gitpod Mysql user and setting a password..."
    MYSQL_GITPOD_PASSWORD=$(openssl rand -base64 20)
    export MYSQL_GITPOD_PASSWORD
    gcloud sql users create gitpod \
        --instance="${MYSQL_INSTANCE_NAME}" --password="${MYSQL_GITPOD_PASSWORD}"
}

function create_service_account() {
    local SA=$1;shift
    local EMAIL=$1;shift
    local ROLES=( "$@" )
    if [ "$(gcloud iam service-accounts list --filter="displayName:${SA}" --format="value(displayName)" | grep "${SA}" || echo "empty")" == "${SA}" ]; then
        echo "IAM service account ${SA} already exists."
        return
    fi

    gcloud iam service-accounts create "${SA}" --display-name "${SA}"
    for ROLE in ${ROLES[*]}; do
        gcloud projects add-iam-policy-binding "${PROJECT_NAME}" \
            --member serviceAccount:"${EMAIL}" --role="${ROLE}"
    done
}

function create_namespace() {
    local NAMESPACE=$1
    if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1;then
        kubectl create namespace "${NAMESPACE}"
    fi
}

function install_jaeger_operator(){
    echo "Installing Jaeger operator..."
    create_namespace jaeger-operator
    kubectl apply -f https://raw.githubusercontent.com/jaegertracing/helm-charts/main/charts/jaeger-operator/crds/crd.yaml
    helm upgrade --install --namespace jaeger-operator \
        jaegeroperator jaegertracing/jaeger-operator \
        --set crd.install=false \
        -f "${DIR}/charts/assets/jaeger-values.yaml"

    kubectl wait --for=condition=available --timeout=300s \
        deployment/jaegeroperator-jaeger-operator -n jaeger-operator
    kubectl apply -f "${DIR}/charts/assets/jaeger-gitpod.yaml"
}

function setup_managed_dns() {
    if [ -n "${SETUP_MANAGED_DNS}" ] && [ "${SETUP_MANAGED_DNS}" == "true" ]; then
        if [ "$(gcloud iam service-accounts list --filter="displayName:${DNS_SA}" --format="value(displayName)" | grep "${DNS_SA}" || echo "empty")" == "${DNS_SA}" ]; then
            echo "IAM service account ${DNS_SA} already exists."
        else
            local DNS_ROLES=( "roles/dns.admin" )
            create_service_account "${DNS_SA}" "${DNS_SA_EMAIL}" "${DNS_ROLES[@]}"
        fi
        if [ ! -f "$DIR/dns-credentials.json" ]; then
            gcloud iam service-accounts keys create --iam-account "${DNS_SA_EMAIL}" "$DIR"/dns-credentials.json
        fi

        if [ "$(gcloud dns managed-zones list --filter="name=${CLUSTER_NAME}" --format="value(name)" | grep "${CLUSTER_NAME}" || echo "empty")" == "${CLUSTER_NAME}" ]; then
            echo "Using existing managed DNS zone ${CLUSTER_NAME}"
        else
            echo "Creating managed DNS zone ${CLUSTER_NAME} for domain ${DOMAIN}..."
            gcloud dns managed-zones create "${CLUSTER_NAME}" \
                --dns-name "${DOMAIN}" \
                --description "Automatically managed zone by kubernetes.io/external-dns"
        fi

        echo "Installing external-dns..."
        create_namespace external-dns
        helm upgrade --install external-dns \
            --namespace external-dns \
            bitnami/external-dns \
            --set provider=google \
            --set google.project="${PROJECT_NAME}" \
            --set logFormat=json \
            --set google.serviceAccountSecretKey=dns-credentials.json

        if ! kubectl get secret --namespace cert-manager clouddns-dns01-solver-svc-acct; then
            echo "Creating secret for Cloud DNS Issuer..."
            kubectl create secret generic clouddns-dns01-solver-svc-acct \
                --namespace cert-manager --from-file=key.json="${DIR}/dns-credentials.json"
        fi

        echo "Installing cert-manager certificate issuer..."
        envsubst < "${DIR}/charts/assets/issuer.yaml" | kubectl apply -f -
    fi
}

function install_cert_manager() {
    echo "Installing cert-manager..."
    helm upgrade cert-manager jetstack/cert-manager \
        --namespace='cert-manager' \
        --install \
        --create-namespace \
        --set installCRDs=true \
        --set 'extraArgs={--dns01-recursive-nameservers-only=true,--dns01-recursive-nameservers=8.8.8.8:53\,1.1.1.1:53}' \
        --atomic

    # ensure cert-manager and CRDs are installed and running
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager -n cert-manager
}

function install_gitpod() {
    echo "Installing Gitpod..."
    if ! kubectl get secret gcloud-sql-token >/dev/null 2>&1;then
        kubectl create secret generic gcloud-sql-token --from-file=credentials.json="${DIR}/mysql-credentials.json"
    fi

    if ! kubectl get secret remote-storage-gcloud >/dev/null 2>&1;then
        kubectl create secret generic remote-storage-gcloud --from-file=key.json="${DIR}/gs-credentials.json"
    fi

    CONTAINER_REGISTRY_BUCKET="container-registry-${CLUSTER_NAME}-${PROJECT_ID}"
    export CONTAINER_REGISTRY_BUCKET
    # the bucket must exists before installing the docker-registry.
    if ! gsutil acl get "gs://${CONTAINER_REGISTRY_BUCKET}" >/dev/null 2>&1;then
        gsutil mb "gs://${CONTAINER_REGISTRY_BUCKET}"
    fi

    envsubst < "${DIR}/charts/assets/gitpod-values.yaml" | helm upgrade --install gitpod gitpod/gitpod -f -
}

function service_account_exits() {
    local SA=$1
    if [ "$(gcloud iam service-accounts list --filter="displayName:${SA}" --format="value(displayName)" | grep "${SA}" || echo "empty")" == "${SA}" ]; then
        return 0
    else
        return 1
    fi
}

function wait_for_load_balancer() {
    sleep 10

    COUNT=0
    LB_IP_ADDRESS=""
    while [ "${LB_IP_ADDRESS}" == "" ] && [ "${COUNT}" -lt 5 ];do
        printf "."
        LB_IP_ADDRESS=$(kubectl get service proxy -o=jsonpath='{.status.loadBalancer.ingress[0].ip}')
        ((COUNT+=1))
        sleep 5
    done

    if [ -n "${LB_IP_ADDRESS}" ];then
        printf '\nLoad balancer IP address: %s\n' "${LB_IP_ADDRESS}"
    else
        printf '\n The load balancer is still being provisioned. Wait a couple of minutes.'
    fi
}

function install() {
    check_prerequisites

    echo "Updating helm repositories..."
    helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm repo add jetstack https://charts.jetstack.io
    helm repo add gitpod https://aledbf.github.io/gitpod-chart-cleanup/
    helm repo update

    gcloud config set project "${PROJECT_NAME}"
    if ! gcloud projects describe "${PROJECT_NAME}" >/dev/null 2>&1; then
        echo "Project ${PROJECT_NAME} does not exist. Creating."
        gcloud projects create "${PROJECT_NAME}"
    fi

    PROJECT_ID="$(gcloud projects describe "${PROJECT_NAME}" --format='get(projectNumber)')"
    export PROJECT_ID

    # Enable billing (required by container.googleapis.com)
    gcloud alpha billing projects link "${PROJECT_NAME}" --billing-account "${BILLING_ACCOUNT}"
    # Enable required services
    gcloud services enable cloudbilling.googleapis.com
    gcloud services enable containerregistry.googleapis.com
    gcloud services enable iam.googleapis.com
    gcloud services enable compute.googleapis.com
    gcloud services enable container.googleapis.com
    gcloud services enable dns.googleapis.com
    gcloud services enable sqladmin.googleapis.com

    # Create service accounts
    if service_account_exits "${GKE_SA}"; then
        echo "IAM service account ${GKE_SA} already exists."
    else
        local GKE_ROLES=( "roles/storage.admin" "roles/logging.logWriter" "roles/monitoring.metricWriter" "roles/container.admin")
        create_service_account "${GKE_SA}" "${GKE_SA_EMAIL}" "${GKE_ROLES[@]}"
    fi

    local MYSQL_ROLES=( "roles/cloudsql.client" )
    create_service_account "${MYSQL_SA}" "${MYSQL_SA_EMAIL}" "${MYSQL_ROLES[@]}"
    if [ ! -f "$DIR/mysql-credentials.json" ]; then
        gcloud iam service-accounts keys create \
            --iam-account "${MYSQL_SA_EMAIL}" "$DIR/mysql-credentials.json"
    fi

    if service_account_exits "${OBJECT_STORAGE_SA}"; then
        echo "IAM service account ${OBJECT_STORAGE_SA} already exists."
    else
        local OBJECT_STORAGE_ROLES=( "roles/storage.admin" "roles/storage.objectAdmin" )
        create_service_account "${OBJECT_STORAGE_SA}" "${OBJECT_STORAGE_SA_EMAIL}" "${OBJECT_STORAGE_ROLES[@]}"
    fi
    if [ ! -f "$DIR/gs-credentials.json" ]; then
        gcloud iam service-accounts keys create \
            --iam-account "${OBJECT_STORAGE_SA_EMAIL}" "$DIR/gs-credentials.json"
    fi

    if [ "$(gcloud container clusters list --filter="name=${CLUSTER_NAME}" --format="value(name)" | grep "${CLUSTER_NAME}" || echo "empty")" == "${CLUSTER_NAME}" ]; then
        echo "Cluster with name ${CLUSTER_NAME} already exists. Skip cluster creation.";
        gcloud container clusters get-credentials --region="${REGION}" "${CLUSTER_NAME}"
    else
        # shellcheck disable=SC2086
        gcloud container clusters \
            create "${CLUSTER_NAME}" \
            --disk-type="pd-ssd" --disk-size="50GB" \
            --image-type="UBUNTU_CONTAINERD" \
            --machine-type="e2-standard-2" \
            --cluster-version="${GKE_VERSION}" \
            --region="${REGION}" \
            --service-account "$GKE_SA_EMAIL" \
            --num-nodes=1 \
            --no-enable-basic-auth \
            --enable-autoscaling \
            --enable-autorepair --no-enable-autoupgrade \
            --enable-ip-alias --enable-network-policy \
            --create-subnetwork name="gitpod-${CLUSTER_NAME}" \
            --metadata=disable-legacy-endpoints=true \
            --max-pods-per-node=110 --default-max-pods-per-node=110 \
            --min-nodes=0 --max-nodes=1 \
            --addons=HorizontalPodAutoscaling,NodeLocalDNS,NetworkPolicy \
            ${NODES_LOCATIONS} ${PREEMPTIBLE}

        # delete default node pool (is not possible to create a cluster without nodes)
        gcloud --quiet container node-pools delete default-pool --cluster="${CLUSTER_NAME}" --region="${REGION}"
    fi

    if [ "$(gcloud container node-pools list --cluster="${CLUSTER_NAME}" --region="${REGION}" --filter="name=${SERVICES_POOL}" --format="value(name)" | grep "${SERVICES_POOL}" || echo "empty")" == "${SERVICES_POOL}" ]; then
        echo "Node pool with name ${SERVICES_POOL} already exists in cluster ${CLUSTER_NAME}. Skip node-pool creation step.";
    else
        create_node_pool "${SERVICES_POOL}" "gitpod.io/workload_services=true"
    fi

    if [ "$(gcloud container node-pools list --cluster="${CLUSTER_NAME}" --region="${REGION}" --filter="name=${WORKSPACES_POOL}" --format="value(name)" | grep "${WORKSPACES_POOL}" || echo "empty")" == "${WORKSPACES_POOL}" ]; then
        echo "Node pool with name ${WORKSPACES_POOL} already exists in cluster ${CLUSTER_NAME}. Skip node-pool creation step.";
    else
        create_node_pool "${WORKSPACES_POOL}" "gitpod.io/workload_workspaces=true"
    fi

    if ! kubectl get clusterrolebinding cluster-admin-binding >/dev/null 2>&1; then
        # create the cluster role binding to allow the current user to create new rbac rules.
        # Needed for installing addons, istio, etc.
        kubectl create clusterrolebinding cluster-admin-binding \
            --clusterrole=cluster-admin --user="$(gcloud config get-value core/account)"
    fi

    # Create secret with container registry credentials
    if [ -n "${IMAGE_PULL_SECRET_FILE}" ] && [ -f "${IMAGE_PULL_SECRET_FILE}" ]; then
        if ! kubectl get secret gitpod-image-pull-secret; then
            kubectl create secret generic gitpod-image-pull-secret \
                --from-file=.dockerconfigjson="${IMAGE_PULL_SECRET_FILE}" \
                --type=kubernetes.io/dockerconfigjson  >/dev/null 2>&1 || true
        fi
    fi

    install_cert_manager
    setup_managed_dns
    setup_mysql_database
    install_jaeger_operator
    install_gitpod

    wait_for_load_balancer
}

function setup_kubectl() {
    gcloud config set project "${PROJECT_NAME}"
    gcloud container clusters get-credentials --region="${REGION}" "${CLUSTER_NAME}"
}

function uninstall() {
    check_prerequisites

    read -p "Are you sure you want to delete: Gitpod (y/n)? " -n 1 -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        set +e
        setup_kubectl
        echo "Deleting IAM service accounts credential files..."
        rm -rf dns-credentials.json gs-credentials.json mysql-credentials.json
        kubectl delete secret clouddns-dns01-solver-svc-acct gcloud-sql-token remote-storage-gcloud gitpod-image-pull-secret
        # ensure we remove the GCP Load Balancer.
        kubectl delete service proxy
        echo "Deleting node-pools..."
        gcloud container node-pools delete workload-services   --region "${REGION}" --cluster "${CLUSTER_NAME}" --quiet
        gcloud container node-pools delete workload-workspaces --region "${REGION}" --cluster "${CLUSTER_NAME}" --quiet
        echo "Deleting GKE cluster..."
        gcloud container clusters   delete "${CLUSTER_NAME}"   --region "${REGION}" --quiet
        echo "Deleting IAM service accounts..."
        gcloud iam service-accounts delete "${GKE_SA_EMAIL}"            --quiet
        gcloud iam service-accounts delete "${DNS_SA_EMAIL}"            --quiet
        gcloud iam service-accounts delete "${OBJECT_STORAGE_SA_EMAIL}" --quiet
        gcloud iam service-accounts delete "${MYSQL_SA_EMAIL}"          --quiet

        printf "\n%s\n" "Please make sure to delete the project ${PROJECT_NAME} and services:"
        printf "%s\n" "- https://console.cloud.google.com/sql/instances?project=${PROJECT_NAME}"
        printf "%s\n" "- https://console.cloud.google.com/storage/browser?project=${PROJECT_NAME}"
        printf "%s\n" "- https://console.cloud.google.com/net-services/dns/zones?project=${PROJECT_NAME}"
    fi
}

function auth() {
    AUTHPROVIDERS_CONFIG=${1:="auth-providers-patch.yaml"}
    if [ ! -f "${AUTHPROVIDERS_CONFIG}" ]; then
        echo "The auth provider configuration file ${AUTHPROVIDERS_CONFIG} does not exist."
        exit 1
    fi

    setup_kubectl

    echo "Using the auth providers configuration file: ${AUTHPROVIDERS_CONFIG}"
    # Patching the configuration with the user auth provider/s
    kubectl patch configmap auth-providers-config --type merge --patch "$(cat ${AUTHPROVIDERS_CONFIG})"
    # Restart the server component
    kubectl rollout restart deployment/server
}

function main() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: $0 [--install|--uninstall]"
        exit
    fi

    case $1 in
        '--install')
            install
        ;;
        '--uninstall')
            uninstall
        ;;
        '--auth')
            auth "auth-providers-patch.yaml"
        ;;
        *)
            echo "Unknown command: $1"
            echo "Usage: $0 [--install|--uninstall|--auth]"
        ;;
    esac
    echo "done"
}

main "$@"
