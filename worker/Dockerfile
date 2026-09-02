# build stage: static binary, no cgo
FROM golang:1.24-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /uptime-worker .

# runtime stage: distroless, no shell, non-root
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /uptime-worker /uptime-worker
USER nonroot
ENTRYPOINT ["/uptime-worker"]
