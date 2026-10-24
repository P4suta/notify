# syntax=docker/dockerfile:1.7

ARG BUN_VERSION=1.4.3-alpine

FROM ghcr.io/gleam-lang/gleam:v1.18.1-erlang-alpine@sha256:7c82e4a284b7c05c26eac34db497ea0e63ce7cb04bd019d966d70338eb172b68 AS gleam

FROM oven/bun:${BUN_VERSION}@sha256:629e17411f1f129dbec3af78d5af9c9f2a937435c80349437206c6b0b7422373 AS bun

FROM erlang:29.1.1.0-alpine@sha256:e7a27e743d17abf139518a69ba3861b43a88ad8396296f0a859d7f37031dbde0 AS build
ARG BUN_VERSION
COPY --from=gleam /bin/gleam /bin/gleam
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
RUN apk add --no-cache \
      bsd-compat-headers=0.7.2-r6 \
      build-base=0.5-r4 \
      git=2.54.0-r0 \
      libgcc=15.2.0-r5 \
      libstdc++=15.2.0-r5
WORKDIR /source
COPY . .
WORKDIR /source/web
RUN bun_version=$(/usr/local/bin/bun --version) \
  && test "$bun_version" = "${BUN_VERSION%-alpine}" \
  && printf '\n[tools.lustre.bin]\nbun = "/usr/local/bin/bun"\n' >> gleam.toml
RUN gleam run -m lustre/dev build \
      --minify=true --no-html=true --no-tailwind=true \
      --outdir=../priv/public
WORKDIR /source
RUN gleam export erlang-shipment \
  && escript packaging/erlang_shipment/finalize.escript build/erlang-shipment

FROM erlang:29.1.1.0-alpine@sha256:e7a27e743d17abf139518a69ba3861b43a88ad8396296f0a859d7f37031dbde0 AS runtime
RUN apk add --no-cache \
      ca-certificates=20260909-r0 \
      libcrypto3=3.5.8-r0 \
      libgcc=15.2.0-r5 \
      libssl3=3.5.8-r0 \
      libstdc++=15.2.0-r5 \
  && addgroup -S -g 10001 notify \
  && adduser -S -u 10001 -G notify -h /app notify \
  && mkdir -p /data \
  && chown notify:notify /data
COPY --from=build --chown=notify:notify /source/build/erlang-shipment /app
USER 10001:10001
WORKDIR /app
VOLUME ["/data"]
EXPOSE 8080/tcp 8080/udp
ENV NOTIFY_DATABASE_PATH=/data/notify.db \
    NOTIFY_ATTACHMENT_DIRECTORY=/data/attachments \
    NOTIFY_LOG_FORMAT=json
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]
ENTRYPOINT ["/bin/sh", "/app/entrypoint.sh"]
CMD ["run", "serve"]
