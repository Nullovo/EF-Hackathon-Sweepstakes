import path from 'node:path'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

const local = (target) => path.resolve(__dirname, target)

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: [
      {
        find: /^@mysten\/dapp-kit-core\/web$/,
        replacement: local('node_modules/@mysten/dapp-kit-core/dist/web/index.mjs'),
      },
      {
        find: /^@mysten\/dapp-kit-core$/,
        replacement: local('node_modules/@mysten/dapp-kit-core/dist/index.mjs'),
      },
      {
        find: /^@mysten\/dapp-kit-react$/,
        replacement: local('node_modules/@mysten/dapp-kit-react/dist/index.mjs'),
      },
      {
        find: /^@evefrontier\/dapp-kit$/,
        replacement: local('node_modules/@evefrontier/dapp-kit/index.ts'),
      },
      {
        find: /^@mysten\/sui\/bcs$/,
        replacement: local('node_modules/@mysten/sui/dist/bcs/index.mjs'),
      },
      {
        find: /^@mysten\/sui\/client$/,
        replacement: local('node_modules/@mysten/sui/dist/client/index.mjs'),
      },
      {
        find: /^@mysten\/sui\/cryptography$/,
        replacement: local('node_modules/@mysten/sui/dist/cryptography/index.mjs'),
      },
      {
        find: /^@mysten\/sui\/grpc$/,
        replacement: local('node_modules/@mysten/sui/dist/grpc/index.mjs'),
      },
      {
        find: /^@mysten\/sui\/keypairs\/ed25519$/,
        replacement: local('node_modules/@mysten/sui/dist/keypairs/ed25519/index.mjs'),
      },
      {
        find: /^@mysten\/sui\/transactions$/,
        replacement: local('node_modules/@mysten/sui/dist/transactions/index.mjs'),
      },
      {
        find: /^@mysten\/sui\/utils$/,
        replacement: local('node_modules/@mysten/sui/dist/utils/index.mjs'),
      },
      {
        find: /^@mysten\/sui\/verify$/,
        replacement: local('node_modules/@mysten/sui/dist/verify/index.mjs'),
      },
    ],
    dedupe: ['react', 'react-dom', '@tanstack/react-query'],
  },
})