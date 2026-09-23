FROM node:24.21.0-bookworm-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
COPY test ./test
RUN npm run build && npm prune --omit=dev
FROM node:24.21.0-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
COPY db ./db
RUN mkdir -p /var/lib/livedash/blobs && chown node:node /var/lib/livedash/blobs && chmod 700 /var/lib/livedash/blobs
USER node
EXPOSE 3000
CMD ["node", "dist/src/main.js"]
