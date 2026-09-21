ARG BASE_IMAGE=node:22.14.0-alpine3.21@sha256:9bef0ef1e268f60627da9ba7d7605e8831d5b56ad07487d24d1aa386336d1944
FROM ${BASE_IMAGE}
WORKDIR /app
COPY --chown=node:node lib.mjs kube.mjs server.mjs ./
USER node
ENV NODE_ENV=production
ENV NODE_EXTRA_CA_CERTS=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
EXPOSE 8080
CMD ["node", "server.mjs"]
