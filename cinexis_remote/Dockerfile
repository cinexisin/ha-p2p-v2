ARG BUILD_FROM
FROM ${BUILD_FROM}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install tools needed to fetch frpc
RUN apk add --no-cache curl tar ca-certificates

# Home Assistant add-on conventions
WORKDIR /

# ---- Install frpc (FRP client) ----
# Pick FRP version (match your server/client version family)
ARG FRP_VERSION="0.54.0"

# TARGETARCH is provided by HA build system for multi-arch builds
# Values: amd64, aarch64, armv7
ARG TARGETARCH

RUN set -eux; \
  case "${TARGETARCH}" in \
    "amd64")   FRP_ARCH="amd64" ;; \
    "aarch64") FRP_ARCH="arm64" ;; \
    "armv7")   FRP_ARCH="armv7" ;; \
    *) echo "Unsupported TARGETARCH: ${TARGETARCH}"; exit 1 ;; \
  esac; \
  echo "Downloading FRP ${FRP_VERSION} for ${FRP_ARCH}"; \
  curl -fsSL "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz" -o /tmp/frp.tgz; \
  tar -xzf /tmp/frp.tgz -C /tmp; \
  cp "/tmp/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frpc" /frpc; \
  chmod +x /frpc; \
  rm -rf /tmp/frp* /tmp/frp.tgz

# Copy rootfs (s6/cont-init.d etc if you use it)
COPY rootfs /

# Copy run script
COPY run.sh /usr/bin/run.sh
RUN chmod +x /usr/bin/run.sh

CMD ["/usr/bin/run.sh"]
