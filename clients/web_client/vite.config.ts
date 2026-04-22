import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const srcDir = resolve(__dirname, "src");

export default defineConfig({
  resolve: {
    alias: {
      "@app": resolve(srcDir, "app"),
      "@domain": resolve(srcDir, "domain"),
      "@infra": resolve(srcDir, "infrastructure"),
      "@presentation": resolve(srcDir, "presentation"),
      "@shared": resolve(srcDir, "shared"),
    },
  },
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
    proxy: {
      "/ingame": {
        target: "http://127.0.0.1:4000",
        changeOrigin: true,
        ws: true,
      },
    },
  },
  build: {
    target: "es2022",
    sourcemap: true,
  },
  test: {
    globals: true,
    environment: "node",
    include: ["src/**/*.test.ts"],
  },
});
