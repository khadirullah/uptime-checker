# build stage: static binary, no cgo
FROM golang:1.26-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /uptime-worker .

# runtime stage: distroless, no shell, non-root
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /uptime-worker /uptime-worker
# "nonroot" in distroless, written numerically so kubernetes can verify runAsNonRoot.
# (a comment must not share a line with USER: docker would treat it as part of the value)
USER 65532:65532
ENTRYPOINT ["/uptime-worker"]
