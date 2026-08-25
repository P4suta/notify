# SPDX-License-Identifier: Apache-2.0

FROM alpine:3.23.5@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40

RUN apk add --no-cache \
      bsd-compat-headers=0.7.2-r6 \
      build-base=0.5-r3

COPY packaging/native/compile_linux_nifs.sh /usr/local/bin/compile-linux-nifs

USER 65532:65532

ENTRYPOINT ["/usr/local/bin/compile-linux-nifs"]
