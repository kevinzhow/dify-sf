# Agent v2 agent service: one AOT binary (see README.md).
# Build from this directory: docker build -t dify-sf-agent-service .

FROM dart:3.13 AS build
WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get --enforce-lockfile
COPY . .
RUN dart pub get --offline --enforce-lockfile \
 && dart compile exe bin/agent_service.dart -o /out/agent_service

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /nonexistent --shell /usr/sbin/nologin agent \
 && mkdir -p /data \
 && chown agent:agent /data
COPY --from=build /out/agent_service /usr/local/bin/agent_service
USER 10001:10001
ENV AGENT_SERVICE_PORT=5050 \
    AGENT_DATA_DIR=/data
VOLUME ["/data"]
EXPOSE 5050
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/agent_service"]
