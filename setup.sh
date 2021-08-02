#!/usr/bin/env bash

set -eo pipefail
set -x

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

if [ ! -f .env ]; then
    echo "Missing .env configuration file."
    exit 1;
fi

set -a
# shellcheck disable=SC1091
source "$DIR/.env"
set -a

# Required service accounts
GKE_SA=gitpod-gke
GKE_SA_EMAIL="${GKE_SA}"@"${PROJECT_NAME}".iam.gserviceaccount.com
GCR_SA=gitpod-gcr
GCR_SA_EMAIL="${GCR_SA}"@"${PROJECT_NAME}".iam.gserviceaccount.com
MYSQL_SA=gitpod-mysql
MYSQL_SA_EMAIL="${MYSQL_SA}"@"${PROJECT_NAME}".iam.gserviceaccount.com
OBJECT_STORAGE_SA=gitpod-storage
OBJECT_STORAGE_SA_EMAIL="${MYSQL_SA}"@"${PROJECT_NAME}".iam.gserviceaccount.com
DNS_SA=gitpod-dns01-solver
DNS_SA_EMAIL="${DNS_SA}"@"${PROJECT_NAME}".iam.gserviceaccount.com

function variables_from_context() {
    SERVICES_POOL="workload-services"
    WORKSPACES_POOL="workload-workspaces"

    export SERVICES_POOL
    export WORKSPACES_POOL
}

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

    if [ -z "${PREEMPTIBLE}" ]; then
        echo "Missing PREEMPTIBLE environment variable. Using regular nodes."
    else
        if [ "${PREEMPTIBLE}" == "true" ]; then
            PREEMPTIBLE="--preemptible"
            export PREEMPTIBLE
        fi
    fi

    RELEASE_CHANNEL=${RELEASE_CHANNEL:="rapid"}
    export RELEASE_CHANNEL
}

function create_node_pool() {
    POOL_NAME=$1
    NODES_LABEL=$2
    gcloud container node-pools --project "${PROJECT_NAME}" \
        create "${POOL_NAME}" \
        --cluster="${CLUSTER_NAME}" \
        --disk-type="pd-ssd" --disk-size="50GB" \
        --image-type="UBUNTU_CONTAINERD" \
        --machine-type="e2-standard-4" \
        --num-nodes=1 \
        --enable-autoupgrade \
        --enable-autorepair \
        --enable-autoscaling \
        --metadata disable-legacy-endpoints=true \
        --scopes "https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append" \
        --node-labels="${NODES_LABEL}" \
        --max-pods-per-node=110 \
        --region="${REGION}" \
        --min-nodes=1 --max-nodes=50 \
        "${PREEMPTIBLE}"
}

function create_mysql_database() {
    if [ "$(gcloud sql instances list --filter="name:gitpod" --format="value(name)" | grep "gitpod" || echo "empty")" == "gitpod" ]; then
        echo "Cloud SQL (MySQL) Instance already exists."
    else
        # https://cloud.google.com/sql/docs/mysql/create-instance
        gcloud sql instances create gitpod \
            --database-version=MYSQL_5_7 \
            --storage-size=100 \
            --storage-auto-increase \
            --tier=db-n1-standard-4 \
            --region="${REGION}" \
            --replica-type=FAILOVER \
            --enable-bin-log

        MYSQL_ROOT_PASSWORD=$(openssl rand -base64 20)
        export MYSQL_ROOT_PASSWORD
        gcloud sql users set-password root --instance gitpod --password "${MYSQL_ROOT_PASSWORD}"
        gcloud sql databases create gitpod          --instance=gitpod
        gcloud sql databases create gitpod-sessions --instance=gitpod
    fi
}

function create_service_account() {
    local SA=$1
    local EMAIL=$2
    local ROLE=$3
    if [ "$(gcloud iam service-accounts list --filter="displayName:${SA}" --format="value(displayName)" | grep "${SA}" || echo "empty")" == "${SA}" ]; then
        echo "IAM service account ${SA} already exists."
    else
        gcloud iam service-accounts create "${SA}" --display-name "${SA}"
        gcloud projects add-iam-policy-binding "${PROJECT_NAME}" \
            --member serviceAccount:"${EMAIL}" \
            --role="${ROLE}"
    fi
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

    kubectl wait --for=condition=available --timeout=300s deployment/jaegeroperator-jaeger-operator -n jaeger-operator
    kubectl apply -f "${DIR}/charts/assets/jaeger-gitpod.yaml"
}

function setup_managed_dns() {
    if [ -n "${SETUP_MANAGED_DNS}" ] && [ "${SETUP_MANAGED_DNS}" == "true" ]; then
        if [ "$(gcloud iam service-accounts list --filter="displayName:${DNS_SA}" --format="value(displayName)" | grep "${DNS_SA}" || echo "empty")" == "${DNS_SA}" ]; then
            echo "IAM service account ${DNS_SA} already exists."
        else
            gcloud iam service-accounts create "${DNS_SA}" --display-name "${DNS_SA}"
            gcloud projects add-iam-policy-binding "${PROJECT_NAME}" \
                --member serviceAccount:"${DNS_SA_EMAIL}" \
                --role roles/dns.admin
        fi
        gcloud --project "${PROJECT_NAME}" iam service-accounts keys create --iam-account "${DNS_SA_EMAIL}" "$DIR"/dns-credentials.json

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
            --set google.serviceAccountSecretKey=dns-credentials.json

        if ! kubectl get secret --namespace=cert-manager clouddns-dns01-solver-svc-acct; then
            echo "Creating secret for Cloud DNS Issuer..."
            kubectl create secret generic clouddns-dns01-solver-svc-acct \
                --namespace=cert-manager \
                --from-file=dns-credentials.json
        fi

        echo "Installing cert-manager certificate issuer..."
        envsubst < "${DIR}/charts/assets/issuer.yaml" | kubectl apply --namespace cert-manager -f -
    fi
}

function install_cert_manager() {
    echo "Installing cert-manager..."
    helm upgrade cert-manager jetstack/cert-manager \
        --namespace='cert-manager' \
        --install \
        --create-namespace \
        --set installCRDs=true \
        --set 'extraArgs={--dns01-recursive-nameservers-only=true,--dns01-recursive-nameservers=8.8.8.8:53,1.1.1.1:53}' \
        --atomic

    # ensure cert-manager and CRDs are installed and running
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager -n cert-manager
}

function install_gitpod() {
    echo "Installing Gitpod..."
    GCP_MYSQL_CREDENTIALS="${DIR}/mysql-credentials.json"
    export GCP_MYSQL_CREDENTIALS
    GCP_MYSQL_INSTANCE=$(gcloud sql instances list --filter=name:gitpod --format="value(PRIMARY_ADDRESS)")
    export GCP_MYSQL_INSTANCE

    if ! kubectl get secret gcloud-sql-token >/dev/null 2>&1;then
        kubectl create secret generic gcloud-sql-token --from-file=credentials.json="${DIR}/mysql-credentials.json"
    fi
    envsubst < "${DIR}/charts/assets/gitpod-values.yaml" | helm upgrade --install gitpod gitpod/gitpod --debug -f -
}

function service_account_exits() {
    local SA=$1
    if [ "$(gcloud iam service-accounts list --filter="displayName:${SA}" --format="value(displayName)" | grep "${SA}" || echo "empty")" == "${SA}" ]; then
        return 1
    else
        return 0
    fi
}

function install() {
    check_prerequisites
    variables_from_context

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
        gcloud iam service-accounts create "$GKE_SA" --project "$PROJECT_NAME" --display-name "$GKE_SA"
        gcloud projects add-iam-policy-binding "$PROJECT_NAME" --member serviceAccount:"${GKE_SA_EMAIL}" --role roles/storage.admin
        gcloud projects add-iam-policy-binding "$PROJECT_NAME" --member serviceAccount:"${GKE_SA_EMAIL}" --role roles/logging.logWriter
        gcloud projects add-iam-policy-binding "$PROJECT_NAME" --member serviceAccount:"${GKE_SA_EMAIL}" --role roles/monitoring.metricWriter
        gcloud projects add-iam-policy-binding "$PROJECT_NAME" --member serviceAccount:"${GKE_SA_EMAIL}" --role roles/container.admin
    fi

    create_service_account "${GCR_SA}" "${GCR_SA_EMAIL}" "roles/storage.admin"
    if [ ! -f "$DIR/registry-credentials.json" ]; then
        gcloud --project "${PROJECT_NAME}" iam service-accounts keys create \
            --iam-account "${GCR_SA_EMAIL}" "$DIR/registry-credentials.json"
    fi

    create_service_account "${MYSQL_SA}" "${MYSQL_SA_EMAIL}" "roles/cloudsql.client"
    if [ ! -f "$DIR/mysql-credentials.json" ]; then
        gcloud --project "${PROJECT_NAME}" iam service-accounts keys create \
            --iam-account "${MYSQL_SA_EMAIL}" "$DIR/mysql-credentials.json"
    fi

    if service_account_exits "${OBJECT_STORAGE_SA}"; then
        echo "IAM service account ${OBJECT_STORAGE_SA} already exists."
    else
        gcloud iam service-accounts create "${OBJECT_STORAGE_SA}" --display-name "${OBJECT_STORAGE_SA}"
        gcloud projects add-iam-policy-binding "${PROJECT_NAME}" \
            --member=serviceAccount:"${OBJECT_STORAGE_SA_EMAIL}" \
            --role="roles/storage.admin"
        gcloud projects add-iam-policy-binding "${PROJECT_NAME}" \
            --member=serviceAccount:"${OBJECT_STORAGE_SA_EMAIL}" \
            --role="roles/storage.objectAdmin"
    fi
    if [ ! -f "$DIR/gs-credentials.json" ]; then
        gcloud --project "${PROJECT_NAME}" iam service-accounts keys create \
            --iam-account "${OBJECT_STORAGE_SA_EMAIL}" "$DIR/gs-credentials.json"
    fi

    if [ "$(gcloud container clusters list --filter="name=${CLUSTER_NAME}" --format="value(name)" | grep "${CLUSTER_NAME}" || echo "empty")" == "${CLUSTER_NAME}" ]; then
        echo "Cluster with name ${CLUSTER_NAME} already exists. Skip cluster creation.";
        gcloud container clusters get-credentials --region="${REGION}" "${CLUSTER_NAME}"
    else
        gcloud container clusters --project "${PROJECT_NAME}" \
            create "${CLUSTER_NAME}" \
            --disk-type="pd-ssd" --disk-size="50GB" \
            --image-type="UBUNTU_CONTAINERD" \
            --machine-type="e2-standard-4" \
            --region="${REGION}" \
            --service-account "$GKE_SA_EMAIL" \
            --num-nodes=1 \
            --no-enable-basic-auth \
            --release-channel="${RELEASE_CHANNEL}" \
            --enable-autoscaling \
            --metadata=disable-legacy-endpoints=true \
            --enable-ip-alias \
            --max-pods-per-node=110 \
            --default-max-pods-per-node=110 \
            --min-nodes=0 --max-nodes=1 \
            --enable-network-policy \
            --addons=HorizontalPodAutoscaling,NodeLocalDNS,NetworkPolicy \
            "${PREEMPTIBLE}"

        # delete default node pool.
        gcloud --quiet container node-pools delete default-pool --cluster="${CLUSTER_NAME}" --region="${REGION}" --async
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
            --clusterrole=cluster-admin \
            --user="$(gcloud config get-value core/account)"
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
    create_mysql_database
    install_jaeger_operator
    install_gitpod
}

function uninstall() {
    check_prerequisites "$1"
    variables_from_context

    read -p "Are you sure you want to delete: Gitpod (y/n)? " -n 1 -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        gcloud container node-pools delete workload-services   --region "${REGION}" --cluster "${CLUSTER_NAME}" --quiet
        gcloud container node-pools delete workload-workspaces --region "${REGION}" --cluster "${CLUSTER_NAME}" --quiet
        gcloud container clusters   delete "${CLUSTER_NAME}"   --region "${REGION}" --quiet

        gcloud iam service-accounts delete "${GKE_SA_EMAIL}" --quiet || true
        gcloud iam service-accounts delete "${GCR_SA_EMAIL}" --quiet || true
        gcloud iam service-accounts delete "${DNS_SA_EMAIL}" --quiet || true
        gcloud iam service-accounts delete "${OBJECT_STORAGE_SA_EMAIL}" --quiet || true

        gcloud sql instances delete gitpod  --quiet || true
        gcloud iam service-accounts delete "${MYSQL_SA_EMAIL}" --quiet || true

        printf "\n%s" "Please make sure to delete the project ${PROJECT_NAME}"
    fi
}

function main() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: $0 [--install|--uninstall]"
        exit
    fi

    case $1 in
        '--install')
            install ".env"
        ;;
        '--uninstall')
            uninstall ".env"
        ;;
        *)
            echo "Unknown command: $1"
            echo "Usage: $0 [--install|--uninstall]"
        ;;
    esac
    echo "done"
}

main "$@"
