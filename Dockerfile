# syntax=docker/dockerfile:1.7
ARG GO_VERSION=1.24.2
ARG ALPINE_VERSION=3.21
ARG TAILSCALE_VERSION=v1.96.4
ARG LEGO_VERSION=v4.33.0

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS derper-builder
ARG TAILSCALE_VERSION
ARG TARGETOS
ARG TARGETARCH
RUN mkdir -p /out && \
    GOBIN=/out GOOS=${TARGETOS} GOARCH=${TARGETARCH} CGO_ENABLED=0 \
    go install tailscale.com/cmd/derper@${TAILSCALE_VERSION}

FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS lego-builder
ARG LEGO_VERSION
ARG TARGETOS
ARG TARGETARCH
RUN apk add --no-cache curl tar
WORKDIR /tmp
RUN case "${TARGETARCH}" in amd64|arm64) ;; *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; esac && \
    mkdir -p /out && \
    curl -fsSL "https://github.com/go-acme/lego/releases/download/${LEGO_VERSION}/lego_${LEGO_VERSION#v}_${TARGETOS}_${TARGETARCH}.tar.gz" \
    | tar -xz lego && \
    install -m 0755 lego /out/lego

FROM alpine:${ALPINE_VERSION}
ARG TAILSCALE_VERSION
ARG LEGO_VERSION
ENV TZ=UTC \
    DERPER_CONFIG_FILE=/data/config/derper.toml
WORKDIR /app
RUN apk add --no-cache ca-certificates openssl libcap && \
    mkdir -p /data/config /var/lib/derper/certs /var/lib/derper/acme
COPY --from=derper-builder /out/derper /usr/local/bin/derper
COPY --from=lego-builder /out/lego /usr/local/bin/lego
COPY docker/entrypoint.sh /app/entrypoint.sh
RUN chmod 0755 /app/entrypoint.sh && \
    addgroup -g 10000 derper && \
    adduser -D -u 10000 -G derper -h /var/lib/derper derper && \
    setcap cap_net_bind_service=+ep /usr/local/bin/derper && \
    chown -R derper:derper /data /var/lib/derper /app
EXPOSE 443 3478/udp
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -q --spider --no-check-certificate "https://localhost${DERP_ADDR:-:443}/" || exit 1
LABEL org.opencontainers.image.title="derper" \
      org.opencontainers.image.version="${TAILSCALE_VERSION}" \
      org.opencontainers.image.description="Dual-mode Tailscale DERP image with IP and DNS-01 support"
USER derper
ENTRYPOINT ["/app/entrypoint.sh"]
