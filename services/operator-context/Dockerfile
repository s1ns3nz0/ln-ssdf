ARG BASE_IMAGE=node:22-alpine@sha256:b6f26b36c8ff49624cfdac716b8ea1138d606df02586a77d364bb5536a634f85
FROM ${BASE_IMAGE}
WORKDIR /app
COPY server.mjs .
USER node
EXPOSE 8080
CMD ["node", "server.mjs"]
