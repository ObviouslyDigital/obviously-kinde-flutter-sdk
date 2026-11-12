import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  workers: 1,
  fullyParallel: false,
  timeout: 60_000,
  reporter: [['list']],
  use: {
    browserName: 'chromium',
    baseURL: 'http://localhost:47080',
    ignoreHTTPSErrors: true,
  },
  webServer: {
    command: 'node mock_kinde.mjs',
    url: 'http://localhost:47080/index.html',
    reuseExistingServer: false,
    stdout: 'pipe',
  },
});
