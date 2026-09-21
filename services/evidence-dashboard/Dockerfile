FROM postgres:16-alpine@sha256:cf78e76683b9ca8c5733cbbdce6c9262b45b6767934dd0a95e671f9a0fc20685

RUN apk add --no-cache nodejs \
  && addgroup -S dashboard \
  && adduser -S -G dashboard -h /app dashboard
WORKDIR /app
COPY --chown=dashboard:dashboard . .
USER dashboard
ENV PORT=8080 BASE_PATH=/lnd DASHBOARD_MODE=fixture
EXPOSE 8080
CMD ["node", "server.mjs"]
