FROM dart:stable AS build
WORKDIR /src
COPY packages/remote_protocol packages/remote_protocol
COPY relay_server relay_server
WORKDIR /src/relay_server
RUN mkdir -p /out \
    && dart pub get \
    && dart compile exe bin/mengren_relay.dart -o /out/mengren-relay

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/mengren-relay /usr/local/bin/mengren-relay
ENV MQT_RELAY_BIND=0.0.0.0
ENV MQT_RELAY_PORT=8080
EXPOSE 8080
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/mengren-relay"]
