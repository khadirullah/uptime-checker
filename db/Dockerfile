# migrations ship as an image so they are versioned, scanned and deployed like the services.
# only psql and pg_isready are needed, so this is alpine plus the client package (about 20MB)
# rather than the full postgres image (over 400MB, and it carries gosu, a Go binary that
# picks up every Go stdlib CVE).
FROM alpine:3.23
# the client package version is not pinned on purpose: alpine keeps only the newest build of
# a package in its repository, so a pin breaks the build a few weeks after it is written.
# apk upgrade pulls fixes the base image has not been rebuilt with yet.
# hadolint ignore=DL3018
RUN apk upgrade --no-cache \
    && apk add --no-cache postgresql18-client \
    && adduser -D -u 10002 migrate
COPY migrations /migrations
COPY migrate.sh /migrate.sh
USER 10002
ENTRYPOINT ["/migrate.sh"]
