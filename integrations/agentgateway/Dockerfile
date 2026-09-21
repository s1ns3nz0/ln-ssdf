FROM node:22-alpine@sha256:b6f26b36c8ff49624cfdac716b8ea1138d606df02586a77d364bb5536a634f85

WORKDIR /app
COPY phase10-l402-proxy.mjs ./
USER node
EXPOSE 8080
CMD ["node", "phase10-l402-proxy.mjs"]
