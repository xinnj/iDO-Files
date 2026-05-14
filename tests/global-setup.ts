import { test as setup } from '@playwright/test';

async function globalSetup(_config: any) {
  const baseUrl = process.env.TEST_BASE_URL || 'http://localhost:8080';

  try {
    const response = await fetch(`${baseUrl}/health`);
    if (!response.ok) {
      throw new Error(`Health check returned HTTP ${response.status}`);
    }
    const body = await response.text();
    if (!body.includes('healthy')) {
      throw new Error(`Unexpected health response: ${body}`);
    }
    console.log(`[global-setup] Server healthy at ${baseUrl}`);
  } catch (e) {
    console.error(`[global-setup] Health check failed at ${baseUrl}. Is the server running?`);
    console.error(e);
    process.exit(1);
  }
}

export default globalSetup;
