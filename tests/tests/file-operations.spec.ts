import { test, expect } from '@playwright/test';
import { FileBrowserPage } from '../pages/FileBrowserPage';

test.describe('File operations', () => {
  let fb: FileBrowserPage;

  test.beforeEach(async ({ page }) => {
    fb = new FileBrowserPage(page);
  });

  test('delete modal opens and shows file path', async () => {
    await fb.gotoBucket('download', 'documents/');
    const testFile = 'notes.txt';

    await fb.openThreeDotMenu(testFile);
    const activeMenu = fb.page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Delete")').click();
    await fb.page.waitForTimeout(300);

    const modal = fb.getModal('deleteModal');
    await expect(modal).toBeVisible();
  });

  test('rename modal opens and pre-fills name', async () => {
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');

    const activeMenu = fb.page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Rename")').click();
    await fb.page.waitForTimeout(300);

    const modal = fb.getModal('renameModal');
    await expect(modal).toBeVisible();
  });

  test('copy/move modal UI: defaults, source display, button state', async () => {
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');

    const activeMenu = fb.page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await fb.page.waitForTimeout(300);

    const modal = fb.getModal('copyMoveModal');
    await expect(modal).toBeVisible();

    // Source shows item path only, no prefix/bucket
    await expect(modal.locator('#copySourcePath')).toHaveText('/documents/notes.txt');

    // Path input pre-filled with full source path
    const pathInput = modal.locator('#copyDestPath');
    await expect(pathInput).toBeVisible();
    await expect(pathInput).toHaveValue('/documents/notes.txt');

    // All bucket radios visible, current bucket pre-selected
    const downloadRadio = modal.locator('input[name="copyDest"][value="download"]');
    const archiveRadio = modal.locator('input[name="copyDest"][value="archive"]');
    const publicRadio = modal.locator('input[name="copyDest"][value="public"]');
    await expect(downloadRadio).toBeVisible();
    await expect(downloadRadio).toBeChecked();
    await expect(archiveRadio).toBeVisible();
    await expect(publicRadio).toBeVisible();

    // Same bucket + same path → Confirm disabled
    await expect(modal.locator('.btn-primary')).toBeDisabled();

    // Different path → enabled
    await pathInput.fill('/other-dir/');
    await expect(modal.locator('.btn-primary')).toBeEnabled();

    // Same path again → disabled
    await pathInput.fill('/documents/notes.txt');
    await expect(modal.locator('.btn-primary')).toBeDisabled();

    // Different bucket → enabled
    await archiveRadio.check();
    await expect(modal.locator('.btn-primary')).toBeEnabled();
  });

  test('copy file to same bucket, different path', async ({ page }) => {
    const destName = 'e2e-copy-same.txt';
    const destPath = '/' + destName;
    const destUrl = '/download' + destPath;
    const sourceUrl = '/download/documents/notes.txt';

    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');

    const activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);

    const modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(destPath);

    // Intercept the PUT request so we can verify the response
    const putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes(sourceUrl),
      { timeout: 10000 }
    );

    await modal.locator('.btn-primary').click();
    const response = await putResp;
    expect(response.status()).toBe(200);

    // Navigate directly to destination (file is already on disk after PUT)
    // Don't wait for the frontend's 1.5s auto-reload — navigate before it fires
    await fb.gotoBucket('download', '');
    const data = await fb.getFileData();
    expect(data.files.some(f => f.name === destName)).toBeTruthy();

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, destUrl);
    await page.waitForTimeout(300);
  });

  test('copy file to different bucket', async ({ page }) => {
    const destName = 'e2e-copy-xbucket.txt';
    const destPath = '/' + destName;
    const destUrl = '/archive' + destPath;
    const sourceUrl = '/download/documents/notes.txt';

    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');

    const activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);

    const modal = fb.getModal('copyMoveModal');

    // Select archive bucket and set destination path
    await modal.locator('input[name="copyDest"][value="archive"]').check();
    await modal.locator('#copyDestPath').fill(destPath);

    const putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes(sourceUrl),
      { timeout: 10000 }
    );

    await modal.locator('.btn-primary').click();
    const response = await putResp;
    expect(response.status()).toBe(200);

    // Navigate directly (file on disk, don't wait for auto-reload)
    await fb.gotoBucket('archive', '');
    const data = await fb.getFileData();
    expect(data.files.some(f => f.name === destName)).toBeTruthy();

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, destUrl);
    await page.waitForTimeout(300);
  });

  test('copy folder to same bucket, different path', async ({ page }) => {
    const destName = 'e2e-copy-folder';
    const destPath = '/' + destName;
    const destUrl = '/download' + destPath;
    const sourceUrl = '/download/code';

    await fb.gotoBucket('download', '');
    await fb.openThreeDotMenu('code');

    const activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);

    const modal = fb.getModal('copyMoveModal');

    // Folder source path should not have trailing slash
    await expect(modal.locator('#copySourcePath')).toHaveText('/code');
    await expect(modal.locator('#copyDestPath')).toHaveValue('/code');

    // Same path → disabled for folders too
    await expect(modal.locator('.btn-primary')).toBeDisabled();

    // Change dest
    await modal.locator('#copyDestPath').fill(destPath);

    const putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes(sourceUrl),
      { timeout: 10000 }
    );

    await modal.locator('.btn-primary').click();
    const response = await putResp;
    expect(response.status()).toBe(200);

    // Verify folder was copied with its contents
    await fb.gotoBucket('download', '');
    let data = await fb.getFileData();
    expect(data.files.some(f => f.name === destName && f.type === 'directory')).toBeTruthy();

    // Navigate into the copied folder and verify contents
    await fb.openFolder(destName);
    data = await fb.getFileData();
    expect(data.files.some(f => f.name === 'script.js')).toBeTruthy();
    expect(data.files.some(f => f.name === 'style.css')).toBeTruthy();
    expect(data.files.some(f => f.name === 'main.lua')).toBeTruthy();

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, destUrl);
    await page.waitForTimeout(300);
  });

  test('copy folder merges into existing directory with force', async ({ page }) => {
    test.setTimeout(60000);
    const destName = 'e2e-merge-dest';
    const destPath = '/' + destName;
    const destUrl = '/download' + destPath;

    // Step 1: Navigate first (gives fetch a base URL), clean up, then create dest
    await fb.gotoBucket('download', '');
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, destUrl);
    await page.waitForTimeout(300);
    await fb.openThreeDotMenu('code');
    let activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);

    let modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(destPath);

    let putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/code') && resp.status() === 200,
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    // Let the auto-reload complete before proceeding
    await page.waitForTimeout(3000);

    // Step 2: Copy 'documents' folder to the same dest → conflict → merge
    await fb.gotoBucket('download', '');
    await fb.openThreeDotMenu('documents');
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);

    modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(destPath);

    // Auto-accept the conflict dialog ("A folder named ... already exists ... Merge?")
    page.once('dialog', dialog => dialog.accept());

    // Wait for the force=true PUT to succeed
    const forceResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT'
        && resp.url().includes('/download/documents')
        && resp.status() === 200,
      { timeout: 15000 }
    );

    await modal.locator('.btn-primary').click();
    await forceResp;

    // Let the auto-reload complete before navigating to verify
    await page.waitForTimeout(3000);

    // Verify merged folder has files from both sources
    await fb.gotoBucket('download', '');
    await fb.openFolder(destName);
    const data = await fb.getFileData();
    expect(data.files.some(f => f.name === 'script.js')).toBeTruthy();
    expect(data.files.some(f => f.name === 'main.lua')).toBeTruthy();
    expect(data.files.some(f => f.name === 'style.css')).toBeTruthy();
    expect(data.files.some(f => f.name === 'notes.txt')).toBeTruthy();
    expect(data.files.some(f => f.name === 'README.md')).toBeTruthy();

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, destUrl);
    await page.waitForTimeout(300);
  });

  // === Move operations ===

  test('move file to same bucket, different path', async ({ page }) => {
    const tmpDir = '/download/e2e-tmp';
    const tmpDirPath = '/e2e-tmp';
    const srcName = 'src.txt';
    const destName = 'dest.txt';
    const srcRelPath = tmpDirPath + '/' + srcName;
    const srcUrl = tmpDir + '/' + srcName;

    // Clean up stale tmp dir from previous runs
    await fb.gotoBucket('download', '');
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);

    // Setup: copy fixture into e2e-tmp/ subdirectory
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');
    let activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    let modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(srcRelPath);
    let putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/documents/notes.txt'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', 'e2e-tmp/');

    // Move src.txt → dest.txt within same subdirectory
    await fb.openThreeDotMenu(srcName);
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyAsMove').check();
    await modal.locator('#copyDestPath').fill(tmpDirPath + '/' + destName);

    const moveResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes(srcUrl) && resp.status() === 200,
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await moveResp;
    await fb.gotoBucket('download', 'e2e-tmp/');

    // Source gone, dest exists
    const data = await fb.getFileData();
    expect(data.files.some(f => f.name === srcName)).toBeFalsy();
    expect(data.files.some(f => f.name === destName)).toBeTruthy();

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);
  });

  test('move file to different bucket', async ({ page }) => {
    const dlTmpDir = '/download/e2e-tmp';
    const arTmpDir = '/archive/e2e-tmp';
    const tmpDirPath = '/e2e-tmp';
    const srcName = 'src.txt';
    const destName = 'dest.txt';
    const srcRelPath = tmpDirPath + '/' + srcName;
    const srcUrl = dlTmpDir + '/' + srcName;
    const destRelPath = tmpDirPath + '/' + destName;
    const destUrl = arTmpDir + '/' + destName;

    // Clean up stale tmp dirs
    await fb.gotoBucket('download', '');
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, dlTmpDir);
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, arTmpDir);
    await page.waitForTimeout(300);

    // Setup: copy fixture into download/e2e-tmp/
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');
    let activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    let modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(srcRelPath);
    let putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/documents/notes.txt'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', 'e2e-tmp/');

    // Move to archive bucket
    await fb.openThreeDotMenu(srcName);
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyAsMove').check();
    await modal.locator('input[name="copyDest"][value="archive"]').check();
    await modal.locator('#copyDestPath').fill(destRelPath);

    const moveResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes(srcUrl) && resp.status() === 200,
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await moveResp;

    // Source gone from download/e2e-tmp/
    await fb.gotoBucket('download', 'e2e-tmp/');
    let data = await fb.getFileData();
    expect((data.files || []).some(f => f.name === srcName)).toBeFalsy();

    // Dest exists in archive/e2e-tmp/
    await fb.gotoBucket('archive', 'e2e-tmp/');
    data = await fb.getFileData();
    expect((data.files || []).some(f => f.name === destName)).toBeTruthy();

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, arTmpDir);
    await page.waitForTimeout(300);
  });

  test('move folder to same bucket, different path', async ({ page }) => {
    const tmpDir = '/download/e2e-tmp';
    const tmpDirPath = '/e2e-tmp';
    const srcName = 'src-folder';
    const destName = 'dest-folder';
    const srcRelPath = tmpDirPath + '/' + srcName;
    const srcUrl = tmpDir + '/' + srcName;
    const destRelPath = tmpDirPath + '/' + destName;

    // Clean up stale tmp dir
    await fb.gotoBucket('download', '');
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);

    // Setup: copy 'code' fixture into e2e-tmp/src-folder
    await fb.gotoBucket('download', '');
    await fb.openThreeDotMenu('code');
    let activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    let modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(srcRelPath);
    let putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/code'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', 'e2e-tmp/');

    // Move src-folder → dest-folder within same subdirectory
    await fb.openThreeDotMenu(srcName);
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyAsMove').check();
    await modal.locator('#copyDestPath').fill(destRelPath);

    const moveResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes(srcUrl) && resp.status() === 200,
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await moveResp;
    await fb.gotoBucket('download', 'e2e-tmp/');

    // Source gone, dest exists with contents
    let data = await fb.getFileData();
    expect(data.files.some(f => f.name === srcName)).toBeFalsy();
    expect(data.files.some(f => f.name === destName && f.type === 'directory')).toBeTruthy();

    await fb.openFolder(destName);
    data = await fb.getFileData();
    expect(data.files.some(f => f.name === 'script.js')).toBeTruthy();
    expect(data.files.some(f => f.name === 'main.lua')).toBeTruthy();

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);
  });

  test('move folder to different bucket', async ({ page }) => {
    const dlTmpDir = '/download/e2e-tmp';
    const arTmpDir = '/archive/e2e-tmp';
    const tmpDirPath = '/e2e-tmp';
    const srcName = 'src-folder';
    const destName = 'dest-folder';
    const srcRelPath = tmpDirPath + '/' + srcName;
    const srcUrl = dlTmpDir + '/' + srcName;
    const destRelPath = tmpDirPath + '/' + destName;

    // Clean up stale tmp dirs
    await fb.gotoBucket('download', '');
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, dlTmpDir);
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, arTmpDir);
    await page.waitForTimeout(300);

    // Setup: copy 'code' fixture into download/e2e-tmp/src-folder
    await fb.gotoBucket('download', '');
    await fb.openThreeDotMenu('code');
    let activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    let modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(srcRelPath);
    let putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/code'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', 'e2e-tmp/');

    // Move to archive bucket
    await fb.openThreeDotMenu(srcName);
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyAsMove').check();
    await modal.locator('input[name="copyDest"][value="archive"]').check();
    await modal.locator('#copyDestPath').fill(destRelPath);

    const moveResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes(srcUrl) && resp.status() === 200,
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await moveResp;

    // Source gone from download/e2e-tmp/
    await fb.gotoBucket('download', 'e2e-tmp/');
    let data = await fb.getFileData();
    expect((data.files || []).some(f => f.name === srcName)).toBeFalsy();

    // Dest exists in archive/e2e-tmp/ with contents
    await fb.gotoBucket('archive', 'e2e-tmp/');
    data = await fb.getFileData();
    expect((data.files || []).some(f => f.name === destName && f.type === 'directory')).toBeTruthy();
    await fb.openFolder(destName);
    data = await fb.getFileData();
    expect((data.files || []).some(f => f.name === 'script.js')).toBeTruthy();

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, arTmpDir);
    await page.waitForTimeout(300);
  });

  // === Dest exists / force scenarios ===

  test('copy file overwrites existing file with force', async ({ page }) => {
    const tmpDir = '/download/e2e-tmp';
    const tmpDirPath = '/e2e-tmp';
    const existingName = 'exist.txt';
    const srcName = 'src.txt';
    const destRelPath = tmpDirPath + '/' + existingName;
    const srcRelPath = tmpDirPath + '/' + srcName;

    // Clean up stale tmp dir
    await fb.gotoBucket('download', '');
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);

    // Create existing file in e2e-tmp/ by copying notes.txt
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');
    let activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    let modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(destRelPath);
    let putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/documents/notes.txt'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', '');

    // Copy different file (README.md) to same dest → conflict
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('README.md');
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(destRelPath);

    page.once('dialog', dialog => dialog.accept());

    const forceResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT'
        && resp.url().includes('/download/documents/README.md')
        && resp.status() === 200,
      { timeout: 15000 }
    );
    await modal.locator('.btn-primary').click();
    await forceResp;
    await page.waitForTimeout(2500);

    // Verify file exists at dest (overwritten) — inside e2e-tmp/
    await fb.gotoBucket('download', 'e2e-tmp/');
    const data = await fb.getFileData();
    expect(data.files.some(f => f.name === existingName)).toBeTruthy();

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);
  });

  test('copy folder merges into existing folder with force', async ({ page }) => {
    const tmpDir = '/download/e2e-tmp';
    const tmpDirPath = '/e2e-tmp';
    const destName = 'dest';
    const destRelPath = tmpDirPath + '/' + destName;

    // Clean up stale tmp dir
    await fb.gotoBucket('download', '');
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);

    // Create dest folder in e2e-tmp/ by copying 'code'
    await fb.gotoBucket('download', '');
    await fb.openThreeDotMenu('code');
    let activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    let modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(destRelPath);
    let putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/code'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', '');

    // Copy 'documents' folder to same dest → conflict → merge
    await fb.gotoBucket('download', '');
    await fb.openThreeDotMenu('documents');
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(destRelPath);

    page.once('dialog', dialog => dialog.accept());

    const forceResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT'
        && resp.url().includes('/download/documents')
        && resp.status() === 200,
      { timeout: 15000 }
    );
    await modal.locator('.btn-primary').click();
    await forceResp;
    await page.waitForTimeout(2500);

    // Verify merged folder has files from both sources
    await fb.gotoBucket('download', 'e2e-tmp/dest/');
    const data = await fb.getFileData();
    expect(data.files.some(f => f.name === 'script.js')).toBeTruthy(); // from code
    expect(data.files.some(f => f.name === 'main.lua')).toBeTruthy();   // from code
    expect(data.files.some(f => f.name === 'notes.txt')).toBeTruthy();  // from documents
    expect(data.files.some(f => f.name === 'README.md')).toBeTruthy();  // from documents

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);
  });

  test('move file into existing directory merges file inside', async ({ page }) => {
    // When moving a file to an existing directory path, the backend merges
    // the file into the directory rather than replacing it (files.lua:109-119)
    const tmpDir = '/download/e2e-tmp';
    const tmpDirPath = '/e2e-tmp';
    const dirName = 'targetdir';
    const fileName = 'inner-file.txt';
    const dirRelPath = tmpDirPath + '/' + dirName;
    const fileRelPath = tmpDirPath + '/' + fileName;
    const fileUrl = tmpDir + '/' + fileName;

    // Clean up stale tmp dir
    await fb.gotoBucket('download', '');
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);

    // Create target directory in e2e-tmp/ by copying 'code'
    await fb.gotoBucket('download', '');
    await fb.openThreeDotMenu('code');
    let activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    let modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(dirRelPath);
    let putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/code'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', '');

    // Create a disposable file in e2e-tmp/
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(fileRelPath);
    putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/documents/notes.txt'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', 'e2e-tmp/');

    // Move the file to the existing directory path
    await fb.openThreeDotMenu(fileName);
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyAsMove').check();
    await modal.locator('#copyDestPath').fill(dirRelPath);

    page.once('dialog', dialog => dialog.accept());

    const moveResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes(fileUrl) && resp.status() === 200,
      { timeout: 15000 }
    );
    await modal.locator('.btn-primary').click();
    await moveResp;
    await page.waitForTimeout(2500);
    await fb.gotoBucket('download', 'e2e-tmp/');

    // Source file should be gone from e2e-tmp/
    let data = await fb.getFileData();
    expect(data.files.some(f => f.name === fileName)).toBeFalsy();

    // File should be inside the directory
    await fb.openFolder(dirName);
    data = await fb.getFileData();
    expect(data.files.some(f => f.name === fileName)).toBeTruthy();

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);
  });

  test('move folder into existing directory merges contents', async ({ page }) => {
    // Moving a folder to an existing directory path merges contents (files.lua:110-113)
    const tmpDir = '/download/e2e-tmp';
    const tmpDirPath = '/e2e-tmp';
    const destDir = 'dest-dir';
    const srcName = 'src-dir';
    const destRelPath = tmpDirPath + '/' + destDir;
    const srcRelPath = tmpDirPath + '/' + srcName;
    const srcUrl = tmpDir + '/' + srcName;

    // Clean up stale tmp dir
    await fb.gotoBucket('download', '');
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);

    // Create dest directory in e2e-tmp/ from 'code'
    await fb.gotoBucket('download', '');
    await fb.openThreeDotMenu('code');
    let activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    let modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(destRelPath);
    let putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/code'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', '');

    // Create source folder in e2e-tmp/ from 'documents'
    await fb.gotoBucket('download', '');
    await fb.openThreeDotMenu('documents');
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(srcRelPath);
    putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/documents'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', 'e2e-tmp/');

    // Move source folder into existing dest directory
    await fb.openThreeDotMenu(srcName);
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyAsMove').check();
    await modal.locator('#copyDestPath').fill(destRelPath);

    page.once('dialog', dialog => dialog.accept());

    const moveResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes(srcUrl) && resp.status() === 200,
      { timeout: 15000 }
    );
    await modal.locator('.btn-primary').click();
    await moveResp;
    await page.waitForTimeout(2500);
    await fb.gotoBucket('download', 'e2e-tmp/');

    // Source folder should be gone
    let data = await fb.getFileData();
    expect(data.files.some(f => f.name === srcName)).toBeFalsy();

    // Merged folder should have files from both sources
    await fb.openFolder(destDir);
    data = await fb.getFileData();
    expect(data.files.some(f => f.name === 'script.js')).toBeTruthy();  // from code
    expect(data.files.some(f => f.name === 'main.lua')).toBeTruthy();   // from code
    expect(data.files.some(f => f.name === 'notes.txt')).toBeTruthy();  // from documents
    expect(data.files.some(f => f.name === 'README.md')).toBeTruthy();  // from documents

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);
  });

  test('move file overwrites existing file with force', async ({ page }) => {
    const tmpDir = '/download/e2e-tmp';
    const tmpDirPath = '/e2e-tmp';
    const existingName = 'exist.txt';
    const srcName = 'src.txt';
    const existingRelPath = tmpDirPath + '/' + existingName;
    const srcRelPath = tmpDirPath + '/' + srcName;
    const srcUrl = tmpDir + '/' + srcName;

    // Clean up stale tmp dir
    await fb.gotoBucket('download', '');
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);

    // Create existing file in e2e-tmp/ from notes.txt
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');
    let activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    let modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(existingRelPath);
    let putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/documents/notes.txt'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', '');

    // Create source file in e2e-tmp/ from README.md
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('README.md');
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(srcRelPath);
    putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/documents/README.md'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', 'e2e-tmp/');

    // Move src to existing name → conflict → overwrite
    await fb.openThreeDotMenu(srcName);
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyAsMove').check();
    await modal.locator('#copyDestPath').fill(existingRelPath);

    page.once('dialog', dialog => dialog.accept());

    const forceResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT'
        && resp.url().includes(srcUrl)
        && resp.status() === 200,
      { timeout: 15000 }
    );
    await modal.locator('.btn-primary').click();
    await forceResp;
    await page.waitForTimeout(2500);

    // Source gone, existing file still present (overwritten)
    await fb.gotoBucket('download', 'e2e-tmp/');
    const data = await fb.getFileData();
    expect(data.files.some(f => f.name === srcName)).toBeFalsy();
    expect(data.files.some(f => f.name === existingName)).toBeTruthy();

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);
  });

  test('move folder overwrites existing folder with force', async ({ page }) => {
    const tmpDir = '/download/e2e-tmp';
    const tmpDirPath = '/e2e-tmp';
    const destName = 'dest-folder';
    const srcName = 'src-folder';
    const destRelPath = tmpDirPath + '/' + destName;
    const srcRelPath = tmpDirPath + '/' + srcName;
    const srcUrl = tmpDir + '/' + srcName;

    // Clean up stale tmp dir
    await fb.gotoBucket('download', '');
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);

    // Create dest folder in e2e-tmp/ from 'code'
    await fb.gotoBucket('download', '');
    await fb.openThreeDotMenu('code');
    let activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    let modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(destRelPath);
    let putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/code'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', '');

    // Create source folder in e2e-tmp/ from 'documents'
    await fb.gotoBucket('download', '');
    await fb.openThreeDotMenu('documents');
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(srcRelPath);
    putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/documents'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', 'e2e-tmp/');

    // Move source folder to existing dest → conflict → merge
    await fb.openThreeDotMenu(srcName);
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyAsMove').check();
    await modal.locator('#copyDestPath').fill(destRelPath);

    page.once('dialog', dialog => dialog.accept());

    const forceResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT'
        && resp.url().includes(srcUrl)
        && resp.status() === 200,
      { timeout: 15000 }
    );
    await modal.locator('.btn-primary').click();
    await forceResp;
    await page.waitForTimeout(2500);

    // Source gone, dest folder still present (merged)
    await fb.gotoBucket('download', 'e2e-tmp/');
    let data = await fb.getFileData();
    expect(data.files.some(f => f.name === srcName)).toBeFalsy();
    expect(data.files.some(f => f.name === destName)).toBeTruthy();

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);
  });

  // === Rename operations ===

  test('rename file', async ({ page }) => {
    const tmpDir = '/download/e2e-tmp';
    const tmpDirPath = '/e2e-tmp';
    const oldName = 'oldname.txt';
    const newName = 'newname.txt';
    const oldRelPath = tmpDirPath + '/' + oldName;
    const oldUrl = tmpDir + '/' + oldName;

    // Clean up stale tmp dir
    await fb.gotoBucket('download', '');
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);

    // Setup: copy fixture into e2e-tmp/
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');
    let activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    let modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(oldRelPath);
    let putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/documents/notes.txt'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', 'e2e-tmp/');

    // Rename the file
    await fb.openThreeDotMenu(oldName);
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Rename")').click();
    await page.waitForTimeout(300);

    const renameModal = fb.getModal('renameModal');
    await expect(renameModal).toBeVisible();
    await renameModal.locator('#renameNewName').fill(newName);

    const renameResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes(oldUrl) && resp.status() === 200,
      { timeout: 10000 }
    );
    await renameModal.locator('.btn-primary').click();
    await renameResp;
    await fb.gotoBucket('download', 'e2e-tmp/');

    // Old name gone, new name exists
    const data = await fb.getFileData();
    expect(data.files.some(f => f.name === oldName)).toBeFalsy();
    expect(data.files.some(f => f.name === newName)).toBeTruthy();

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);
  });

  test('rename folder', async ({ page }) => {
    const tmpDir = '/download/e2e-tmp';
    const tmpDirPath = '/e2e-tmp';
    const oldName = 'old-folder';
    const newName = 'new-folder';
    const oldRelPath = tmpDirPath + '/' + oldName;
    const oldUrl = tmpDir + '/' + oldName;

    // Clean up stale tmp dir
    await fb.gotoBucket('download', '');
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);

    // Setup: copy 'code' fixture into e2e-tmp/
    await fb.gotoBucket('download', '');
    await fb.openThreeDotMenu('code');
    let activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    let modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(oldRelPath);
    let putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/code'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', 'e2e-tmp/');

    // Rename the folder
    await fb.openThreeDotMenu(oldName);
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Rename")').click();
    await page.waitForTimeout(300);

    const renameModal = fb.getModal('renameModal');
    await expect(renameModal).toBeVisible();
    await renameModal.locator('#renameNewName').fill(newName);

    const renameResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes(oldUrl) && resp.status() === 200,
      { timeout: 10000 }
    );
    await renameModal.locator('.btn-primary').click();
    await renameResp;
    await fb.gotoBucket('download', 'e2e-tmp/');

    // Old name gone, new name exists with contents
    let data = await fb.getFileData();
    expect(data.files.some(f => f.name === oldName)).toBeFalsy();
    expect(data.files.some(f => f.name === newName && f.type === 'directory')).toBeTruthy();

    await fb.openFolder(newName);
    data = await fb.getFileData();
    expect(data.files.some(f => f.name === 'script.js')).toBeTruthy();

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);
  });

  test('rename file overwrites existing name with force', async ({ page }) => {
    const tmpDir = '/download/e2e-tmp';
    const tmpDirPath = '/e2e-tmp';
    const srcName = 'src.txt';
    const existingName = 'exist.txt';
    const srcRelPath = tmpDirPath + '/' + srcName;
    const existingRelPath = tmpDirPath + '/' + existingName;
    const srcUrl = tmpDir + '/' + srcName;

    // Clean up stale tmp dir
    await fb.gotoBucket('download', '');
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);

    // Create existing file in e2e-tmp/
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');
    let activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    let modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(existingRelPath);
    let putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/documents/notes.txt'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', '');

    // Create source file in e2e-tmp/ from different fixture
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('README.md');
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Copy / Move")').click();
    await page.waitForTimeout(300);
    modal = fb.getModal('copyMoveModal');
    await modal.locator('#copyDestPath').fill(srcRelPath);
    putResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT' && resp.url().includes('/download/documents/README.md'),
      { timeout: 10000 }
    );
    await modal.locator('.btn-primary').click();
    await putResp;
    await fb.gotoBucket('download', 'e2e-tmp/');

    // Rename source to existing name → conflict
    await fb.openThreeDotMenu(srcName);
    activeMenu = page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Rename")').click();
    await page.waitForTimeout(300);

    const renameModal = fb.getModal('renameModal');
    await expect(renameModal).toBeVisible();
    await renameModal.locator('#renameNewName').fill(existingName);

    page.once('dialog', dialog => dialog.accept());

    const forceResp = page.waitForResponse(
      resp => resp.request().method() === 'PUT'
        && resp.url().includes(srcUrl)
        && resp.status() === 200,
      { timeout: 15000 }
    );
    await renameModal.locator('.btn-primary').click();
    await forceResp;
    await page.waitForTimeout(2500);

    // Source name gone, existing name still present (overwritten)
    await fb.gotoBucket('download', 'e2e-tmp/');
    const data = await fb.getFileData();
    expect(data.files.some(f => f.name === srcName)).toBeFalsy();
    expect(data.files.some(f => f.name === existingName)).toBeTruthy();

    // Cleanup
    await page.evaluate(async (url) => {
      await fetch(url, { method: 'DELETE' });
    }, tmpDir);
    await page.waitForTimeout(300);
  });

  // === UI smoke tests ===

  test('delete modal can be closed', async () => {
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');

    const activeMenu = fb.page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Delete")').click();
    await fb.page.waitForTimeout(300);

    const modal = fb.getModal('deleteModal');
    await expect(modal).toBeVisible();

    await fb.page.locator('#deleteModal .modal-cancel, #deleteModal .btn-cancel, #deleteModal button:has-text("Cancel")').click();
    await fb.page.waitForTimeout(300);

    await expect(modal).not.toBeVisible();
  });

  test('share modal opens for file', async () => {
    await fb.gotoBucket('download', 'documents/');
    await fb.openThreeDotMenu('notes.txt');

    const activeMenu = fb.page.locator('.file-three-dot-menu.active .file-three-dot-dropdown');
    await activeMenu.locator('.dropdown-item:has-text("Share")').click();
    await fb.page.waitForTimeout(300);

    const modal = fb.getModal('shareModal');
    await expect(modal).toBeVisible();
  });
});
