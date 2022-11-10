FROM golang:latest as base

RUN update-ca-certificates

# download the builder utility
RUN GO111MODULE=on go install go.opentelemetry.io/collector/cmd/builder@v0.63.1

COPY builder-config.yaml /

# build our custom collector using our provided builder-config
RUN export CGO_ENABLED=0 && \
    builder --config=/builder-config.yaml \
    --name /otelcol-custom

FROM alpine
USER 10001

COPY --from=base /otelcol-custom /

ENTRYPOINT ["/otelcol-custom"]
CMD ["--config", "/etc/otelcol/config.yaml"]
EXPOSE 4317 4318 13333