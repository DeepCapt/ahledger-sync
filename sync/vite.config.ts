import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';

// Tauri sets TAURI_DEV_HOST when the dev server must be reachable from a device/VM.
const host = process.env.TAURI_DEV_HOST;

export default defineConfig({
  // The shared parsing code lives next door in this repository.
  resolve: {
    alias: {
      '@ahledger/shared': fileURLToPath(new URL('../shared/index.ts', import.meta.url)),
    },
  },
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    host: host || false,
    hmr: host ? { protocol: 'ws', host, port: 1421 } : undefined,
    watch: { ignored: ['**/src-tauri/**'] },
  },
  build: {
    target: 'es2022',
    outDir: 'dist',
    emptyOutDir: true,
    sourcemap: false,
  },
});
