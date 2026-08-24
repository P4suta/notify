# syntax=docker/dockerfile:1.7
ARG ERLANG_IMAGE=erlang:29-alpine
ARG GLEAM_VERSION=1.18.1

FROM ghcr.io/gleam-lang/gleam:v${GLEAM_VERSION}-erlang-alpine AS gleam

FROM ${ERLANG_IMAGE} AS build
COPY --from=gleam /bin/gleam /bin/gleam
RUN apk add --no-cache bsd-compat-headers build-base git
WORKDIR /source
COPY . .
RUN cd web && gleam run -m lustre/dev build \
      --minify=true --no-html=true --no-tailwind=true \
      --outdir=../priv/public
RUN gleam export erlang-shipment

FROM ${ERLANG_IMAGE} AS runtime
RUN apk add --no-cache ca-certificates libgcc libstdc++ \
  && addgroup -S notify \
  && adduser -S -G notify -h /app notify \
  && mkdir -p /data \
  && chown notify:notify /data
COPY --from=build --chown=notify:notify /source/build/erlang-shipment /app
USER notify
WORKDIR /app
VOLUME ["/data"]
EXPOSE 8080
ENV NOTIFY_DATABASE_PATH=/data/notify.db \
    NOTIFY_ATTACHMENT_DIRECTORY=/data/attachments \
    NOTIFY_LOG_FORMAT=json
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["/bin/sh", "/app/entrypoint.sh"]
CMD ["run", "serve"]
