# SPDX-License-Identifier: Apache-2.0

FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

RUN apk add --no-cache \
      bsd-compat-headers=0.7.2-r6 \
      build-base=0.5-r3

COPY packaging/native/compile_linux_nifs.sh /usr/local/bin/compile-linux-nifs

USER 65532:65532

ENTRYPOINT ["/usr/local/bin/compile-linux-nifs"]
