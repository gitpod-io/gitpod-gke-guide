# Running Gitpod in [Google Kubernetes Engine](https://cloud.google.com/kubernetes-engine)

> **IMPORTANT** This guide exists as a simple and reliable way of creating an environment in GKE that can run Gitpod. It
> is not designed to cater for every situation. If you find that it does not meet your exact needs,
> please fork this guide and amend it to your own needs.

## Provision a GKE cluster

Before starting the installation process, you need:

- A GCP account with Administrator access
  - [Create one now by clicking here](https://console.cloud.google.com/freetrial)
- GCP credentials set up. Install [gcloud](https://cloud.google.com/sdk/docs/install)
- A `.env` file with basic details about the environment.
  - We provide an example of such file [here](.env.example).
- [Docker](https://docs.docker.com/engine/install/) installed on your machine, or better, a Gitpod workspace :)

**To start the installation, execute:**

```shell
make install
```

The whole process takes around twenty minutes. In the end, the following resources are created. These are the GCP versions of the [components Gitpod requires](https://www.gitpod.io/docs/self-hosted/latest/required-components):

- a GKE cluster running Kubernetes v1.21 ([rapid channel](https://cloud.google.com/kubernetes-engine/docs/release-notes-rapid)).
- GCP L4 load balancer.
- Cloud SQL - Mysql database.
- Cloud DNS zone.
- In-cluster docker registry using [Cloud Storage](https://cloud.google.com/storage) as storage backend.
- [calico](https://docs.projectcalico.org) as CNI and NetworkPolicy implementation.
- [cert-manager](https://cert-manager.io/) for self-signed SSL certificates.

Upon completion, it will print the config for the resources created (including passwords) and instructions on what
to do next. **IMPORTANT** - running the `make install` command after the initial install will change
your database password which will require you to update your KOTS configuration.

### Common errors running make install

- Insufficient regional quota to satisfy request

  Depending on the size of the configured `disks size` and `machine-type`,
  it may be necessary to request an [increase in the service quota](https://console.cloud.google.com/iam-admin/quotas?usage=USED)

  [!["GCP project Quota"](./images/quota.png)](https://console.cloud.google.com/iam-admin/quotas?usage=USED)

  *After increasing the quota, retry the installation running `make install`*

- Some pods never start (`Init` state)

  ```shell
  ❯ kubectl get pods -l component=proxy
  NAME                     READY   STATUS    RESTARTS   AGE
  proxy-5998488f4c-t8vkh   0/1     Init 0/1  0          5m
  ```
  
  The most likely reason is that the [DNS01 challenge](https://cert-manager.io/docs/configuration/acme/dns01/) has yet to resolve. If using `SETUP_MANAGED_DNS`, you will need to update your DNS records to point to the GCP Cloud DNS nameserver.

  Once the DNS record has been updated, you will need to delete all cert-manager pods to retrigger the certificate request

  ```shell
  ❯ kubectl delete pods -n cert-manager --all
  ```
  
  After a few minutes, you should see the `https-certificate` become ready.   

  ```shell
  ❯ kubectl get certificate
  NAME                        READY   SECRET                      AGE
  https-certificates          True    https-certificates          5m
  ```

## Destroy the cluster and GCP resources

Remove the GCP cluster running:

```shell
make uninstall
```

> The command asks for a confirmation:
> `Are you sure you want to delete: Gitpod (y/n)?`

> Please make sure you delete the GCP buckets used to store the docker registry images and Cloud SQL database!
