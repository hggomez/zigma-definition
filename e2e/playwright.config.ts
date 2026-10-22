import { defineConfig } from "@playwright/test";

// Run inside the e2e service of docker-compose.yml: the frontend is reached
// by its service name on the compose network.
export default defineConfig({
  testDir: "./tests",
  reporter: "list",
  use: {
    baseURL: process.env.BASE_URL ?? "http://frontend",
  },
});
