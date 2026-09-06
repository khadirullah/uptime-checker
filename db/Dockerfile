# migrations ship as an image so they are versioned, scanned and deployed like the services.
FROM postgres:18-alpine
COPY migrations /migrations
COPY migrate.sh /migrate.sh
USER postgres
ENTRYPOINT ["/migrate.sh"]
