# Multi-stage build: web assets + compiled backend in one runtime image.
# NOTE: written for deployment convenience; it has not been built in the authoring environment (no Docker daemon there).
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
COPY backend/package.json backend/
COPY web/package.json web/
RUN npm ci
COPY backend backend
COPY web web
RUN npm run build

FROM node:22-alpine
ENV NODE_ENV=production WEB_DIR=/app/web/dist STORAGE_DIR=/var/lib/light-skate/storage
WORKDIR /app
COPY package.json package-lock.json ./
COPY backend/package.json backend/
COPY web/package.json web/
RUN npm ci --omit=dev -w backend && npm cache clean --force
COPY --from=build /app/backend/dist backend/dist
COPY backend/migrations backend/migrations
COPY --from=build /app/web/dist web/dist
RUN mkdir -p /var/lib/light-skate/storage && chown -R node:node /var/lib/light-skate /app
USER node
WORKDIR /app/backend
EXPOSE 8080
VOLUME ["/var/lib/light-skate/storage"]
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://localhost:8080/api/v1/health || exit 1
CMD ["node", "dist/server.js"]
