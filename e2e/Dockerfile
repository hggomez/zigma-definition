# The e2e service of docker-compose.yml: Playwright with its browsers, at the
# same version as @playwright/test in package.json (they must match).
FROM mcr.microsoft.com/playwright:v1.63.0-noble

WORKDIR /e2e

COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY playwright.config.ts ./
COPY tests ./tests

CMD ["npx", "playwright", "test"]
