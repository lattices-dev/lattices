import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { staticPreview } from "./scripts/static-preview";

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));

export default defineConfig({
  plugins: [react(), staticPreview()],
  base: "/",
  server: {
    fs: {
      allow: [repoRoot],
    },
  },
});
