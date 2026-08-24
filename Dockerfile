# syntax=docker/dockerfile:1.7

FROM ghcr.io/gleam-lang/gleam:v1.18.1-erlang-alpine@sha256:7c82e4a284b7c05c26eac34db497ea0e63ce7cb04bd019d966d70338eb172b68 AS gleam

FROM erlang:29-alpine@sha256:77074ad338ad7303c2f127eb686759721dffbff952f7c8db162bb4adac1e1e1c AS build
COPY --from=gleam /bin/gleam /bin/gleam
RUN apk add --no-cache \
      bsd-compat-headers=0.7.2-r6 \
      build-base=0.5-r3 \
      git=2.52.0-r0
WORKDIR /source
COPY . .
WORKDIR /source/web
RUN gleam run -m lustre/dev build \
      --minify=true --no-html=true --no-tailwind=true \
      --outdir=../priv/public
WORKDIR /source
RUN gleam export erlang-shipment

FROM erlang:29-alpine@sha256:77074ad338ad7303c2f127eb686759721dffbff952f7c8db162bb4adac1e1e1c AS runtime
RUN apk add --no-cache \
      ca-certificates=20260611-r0 \
      libgcc=15.2.0-r2 \
      libstdc++=15.2.0-r2 \
  && addgroup -S -g 10001 notify \
  && adduser -S -u 10001 -G notify -h /app notify \
  && mkdir -p /data \
  && chown notify:notify /data
COPY --from=build --chown=notify:notify /source/build/erlang-shipment /app
USER 10001:10001
WORKDIR /app
VOLUME ["/data"]
EXPOSE 8080
ENV NOTIFY_DATABASE_PATH=/data/notify.db \
    NOTIFY_ATTACHMENT_DIRECTORY=/data/attachments \
    NOTIFY_LOG_FORMAT=json
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]
ENTRYPOINT ["/bin/sh", "/app/entrypoint.sh"]
CMD ["run", "serve"]
