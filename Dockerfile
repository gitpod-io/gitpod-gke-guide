FROM alpine:3.14

RUN apk add --no-cache \
    bash \
    curl \
    python3 \
    py3-pip \
    jq \
    gettext \
    openssl

ARG CLOUD_SDK_VERSION=351.0.0
ARG HELM_VERSION=v3.6.3

RUN curl -fsSL "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl \
  && chmod +x /usr/local/bin/kubectl

RUN curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-${CLOUD_SDK_VERSION}-linux-x86_64.tar.gz \
  && tar xzf google-cloud-sdk-${CLOUD_SDK_VERSION}-linux-x86_64.tar.gz \
  && rm google-cloud-sdk-${CLOUD_SDK_VERSION}-linux-x86_64.tar.gz

RUN mkdir -p /tmp/helm/ \
  && curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz | tar -xzvC /tmp/helm/ --strip-components=1 \
  && cp /tmp/helm/helm /usr/local/bin/helm \
  && rm -rf /tmp/helm

ENV PATH /google-cloud-sdk/bin:$PATH

RUN gcloud components install beta
RUN gcloud components install alpha

RUN curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.24.2/yq_linux_amd64 -o /usr/local/bin/yq \
  && chmod +x /usr/local/bin/yq

WORKDIR /gitpod

COPY . /gitpod

ENTRYPOINT ["/gitpod/setup.sh"]
