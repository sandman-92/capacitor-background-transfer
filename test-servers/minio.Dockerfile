# MinIO built from its own repository at a pinned release: it no longer publishes binaries or
# images. CI's macOS job builds the same release the same way (.github/workflows/ci.yml).
FROM golang:1.25-alpine AS build
ARG MINIO_RELEASE=RELEASE.2025-10-15T17-29-55Z
RUN apk add --no-cache git \
  && git clone --depth 1 --branch "$MINIO_RELEASE" https://github.com/minio/minio /src \
  && cd /src && CGO_ENABLED=0 go build -trimpath -o /minio .

FROM alpine:3.22
COPY --from=build /minio /usr/bin/minio
ENTRYPOINT ["/usr/bin/minio"]
