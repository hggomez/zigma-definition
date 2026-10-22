# The backend service of docker-compose.yml: Node + pg + the code generated
# from the SSOT. The generated files (src/dml.ts, ...) are written into this
# directory on the host by `zig build` before the image is built: there is no
# Zig inside the image. Node 22.18+ runs .ts directly (type stripping).
FROM node:22.19.0-alpine

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

COPY src ./src
