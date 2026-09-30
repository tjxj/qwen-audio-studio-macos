const fs = require('node:fs');
const { defineConfig } = require('@playwright/test');
module.exports = defineConfig({
  testDir: './tests', testMatch: 'ui.spec.cjs', timeout: 20000,
  fullyParallel: true, workers: 2, reporter: 'list',
  use: { baseURL: 'http://127.0.0.1:4177', viewport: {width: 1360, height: 900}, headless: true,
    launchOptions: { ...((process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || (process.platform === 'linux' && fs.existsSync('/usr/bin/chromium') ? '/usr/bin/chromium' : null)) ? {executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || '/usr/bin/chromium'} : {}), args: ['--no-sandbox'] },
    screenshot: 'only-on-failure', trace: 'retain-on-failure' },
  webServer: {command:'node tests/ui-server.cjs', url:'http://127.0.0.1:4177', reuseExistingServer: false}
});
