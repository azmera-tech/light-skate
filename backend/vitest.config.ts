import { defineConfig } from 'vitest/config';
export default defineConfig({
  test: {
    globalSetup: ['./test/globalSetup.ts'],
    fileParallelism: false,
    testTimeout: 30000,
    hookTimeout: 60000,
    env: {
      NODE_ENV: 'test',
      DATABASE_URL: 'postgres://lightskate:lightskate@localhost:5432/lightskate_test',
      STORAGE_DIR: '/tmp/light-skate-test-storage',
      RATE_LIMIT_ENABLED: 'false',
      LOG_LEVEL: 'silent',
    },
  },
});
