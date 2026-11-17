import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { staticPreview } from "./scripts/static-preview";

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));

export default defineConfig({
  plugins: [react(), staticPreview()],
  base: "/",
  build: { manifest: true },
  server: {
    fs: {
      allow: [repoRoot],
    },
  },
});
