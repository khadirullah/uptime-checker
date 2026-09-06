FROM nginxinc/nginx-unprivileged:1.29-alpine
# the base image lags alpine's package fixes by days to weeks. upgrading at build time keeps
# the image scan clean instead of waiting for the next upstream rebuild.
USER 0
RUN apk upgrade --no-cache
USER 101
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html app.js style.css /usr/share/nginx/html/
EXPOSE 8080
