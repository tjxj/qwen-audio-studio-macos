const { defineConfig } = require("@playwright/test");
module.exports = defineConfig({
  testDir: "./tests",
  testMatch: "desktop.spec.cjs",
  workers: 1,
  fullyParallel: false,
  timeout: 45000,
  reporter: "list",
  use: { screenshot: "only-on-failure", trace: "retain-on-failure" },
});
