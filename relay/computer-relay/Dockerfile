FROM node:22-alpine

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts
COPY server.mjs ./

ENV RELAY_HOST=0.0.0.0
ENV RELAY_PORT=8787
ENV RELAY_DATA_DIR=/data
EXPOSE 8787
VOLUME ["/data"]

USER node
CMD ["node", "server.mjs"]
