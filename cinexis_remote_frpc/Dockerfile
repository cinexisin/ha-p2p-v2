ARG BUILD_FROM
FROM ${BUILD_FROM}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apk add --no-cache bash jq curl ca-certificates

ARG TARGETARCH
RUN set -eux; \
    FRP_VER="0.54.0"; \
    case "${TARGETARCH}" in \
      "amd64")  FRP_ARCH="amd64" ;; \
      "arm64")  FRP_ARCH="arm64" ;; \
      "arm")    FRP_ARCH="arm" ;; \
      *) echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/frp.tgz "https://github.com/fatedier/frp/releases/download/v${FRP_VER}/frp_${FRP_VER}_linux_${FRP_ARCH}.tar.gz"; \
    tar -xzf /tmp/frp.tgz -C /tmp; \
    cp "/tmp/frp_${FRP_VER}_linux_${FRP_ARCH}/frpc" /usr/bin/frpc; \
    chmod +x /usr/bin/frpc; \
    rm -rf /tmp/frp*;

COPY run.sh /usr/bin/run.sh
RUN chmod +x /usr/bin/run.sh

CMD ["/usr/bin/run.sh"]
