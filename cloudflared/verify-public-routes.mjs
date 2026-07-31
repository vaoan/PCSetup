import { chromium } from 'playwright';
import fs from 'fs/promises';
import path from 'path';

const defaultReportDir = path.join(process.env.USERPROFILE ?? process.env.HOME ?? '.', '.cloudflared', 'reports');
const args = process.argv.slice(2);
const reportDir = args[0] && !args[0].startsWith('--') ? args[0] : defaultReportDir;
const headed = args.includes('--headed');

const urls = [
  ['www.ffxiv.be', 'https://www.ffxiv.be/'],
  ['chat.ffxiv.be', 'https://chat.ffxiv.be/'],
  ['console.ffxiv.be', 'https://console.ffxiv.be/'],
  ['code.ffxiv.be', 'https://code.ffxiv.be/'],
  ['ttyd.ffxiv.be', 'https://ttyd.ffxiv.be/'],
  ['tools.ffxiv.be', 'https://tools.ffxiv.be/'],
  ['git.ffxiv.be', 'https://git.ffxiv.be/'],
];

const codeFolderChecks = [
  {
    name: 'code.ffxiv.be folder switch PCSetup',
    url: 'https://code.ffxiv.be/?folder=/mnt/z/Users/Heiner/Documents/PCSetup',
    expectedText: /PCSetup|PCSETUP/,
    failOnSubresourceErrors: true,
  },
];

await fs.mkdir(reportDir, { recursive: true });

const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
const jsonPath = path.join(reportDir, `public-routes-${timestamp}.json`);
const mdPath = path.join(reportDir, `public-routes-${timestamp}.md`);
const latestJson = path.join(reportDir, 'public-routes-latest.json');
const latestMd = path.join(reportDir, 'public-routes-latest.md');

const results = [];
const browser = await chromium.launch({
  headless: !headed,
  args: ['--no-proxy-server', '--proxy-server=direct://', '--proxy-bypass-list=*', '--disable-ipv6'],
});

function isCloudflareAccessLoginUrl(url) {
  try {
    const parsed = new URL(url);
    return parsed.hostname.endsWith('cloudflareaccess.com') && parsed.pathname.includes('/cdn-cgi/access/login/');
  } catch {
    return false;
  }
}

async function looksLikeCloudflareError(page, status) {
  if (status >= 500) {
    return true;
  }

  const title = await page.title().catch(() => '');
  if (/502|504|bad gateway|cloudflare/i.test(title)) {
    return true;
  }

  const bodyText = await page.locator('body').innerText({ timeout: 5000 }).catch(() => '');
  return /502|504|bad gateway|cloudflare/i.test(bodyText);
}

async function looksLikeFallbackPage(page) {
  const bodyText = await page.locator('body').innerText({ timeout: 5000 }).catch(() => '');
  return /Route online|WSL setup is pending|will start after WSL is ready|fallback route/i.test(bodyText);
}

function safeFileName(name) {
  return name.replace(/[^a-z0-9.-]+/gi, '_');
}

async function probePage(context, name, url, options = {}) {
  let lastResult = null;
  for (let attempt = 1; attempt <= 8; attempt++) {
    const page = await context.newPage();
    const responseFailures = [];
    page.on('response', response => {
      if (response.status() >= 500) {
        responseFailures.push(`${response.status()} ${response.url()}`);
      }
    });
    try {
      const response = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 });
      const status = response?.status() ?? 0;
      const finalUrl = page.url();
      const request = response?.request();
      let redirected = false;
      let redirectCount = 0;
      let redirectChain = [];

      let current = request?.redirectedFrom?.();
      while (current) {
        redirected = true;
        redirectCount += 1;
        redirectChain.unshift(current.url());
        current = current.redirectedFrom?.();
      }

      const hitAccessLogin = isCloudflareAccessLoginUrl(finalUrl);
      const hitCloudflareError = await looksLikeCloudflareError(page, status);
      const hitFallbackPage = await looksLikeFallbackPage(page);
      if (options.expectedText) {
        await page.waitForFunction(
          ({ source, flags }) => new RegExp(source, flags).test(document.body?.innerText ?? ''),
          { source: options.expectedText.source, flags: options.expectedText.flags },
          { timeout: 30000 }
        ).catch(() => {});
      }
      const bodyText = await page.locator('body').innerText({ timeout: 10000 }).catch(() => '');
      const hitExpectedText = options.expectedText ? options.expectedText.test(bodyText) : true;
      const hitSubresourceError = Boolean(options.failOnSubresourceErrors && responseFailures.length);
      const passed = !hitAccessLogin && !hitCloudflareError && !hitFallbackPage && !hitSubresourceError && hitExpectedText && (status === 200 || redirected || (status >= 300 && status < 400));

      lastResult = {
        Name: name,
        Url: url,
        Status: status,
        FinalUrl: finalUrl,
        Redirected: redirected,
        RedirectCount: redirectCount,
        RedirectChain: redirectChain,
        Passed: passed,
        Detail: `HTTP ${status} -> ${finalUrl}${redirected ? ` (redirected ${redirectCount}x)` : ''}${hitAccessLogin ? ' (Cloudflare Access login page)' : ''}${hitCloudflareError ? ' (Cloudflare error page)' : ''}${hitFallbackPage ? ' (placeholder fallback page)' : ''}${hitSubresourceError ? ` (subresource 5xx: ${responseFailures.slice(0, 3).join('; ')})` : ''}${!hitExpectedText ? ' (expected folder content missing)' : ''}`,
      };

      if (passed || attempt === 8) {
        if (!passed) {
          const screenshotPath = path.join(reportDir, `public-routes-${timestamp}-${safeFileName(name)}.png`);
          await page.screenshot({ path: screenshotPath, fullPage: true }).catch(() => {});
          lastResult.Screenshot = screenshotPath;
        }
        await page.close().catch(() => {});
        break;
      }
    } catch (error) {
      lastResult = {
        Name: name,
        Url: url,
        Status: 0,
        FinalUrl: '',
        Redirected: false,
        RedirectCount: 0,
        RedirectChain: [],
        Passed: false,
        Detail: error?.message ?? String(error),
      };
    } finally {
      await page.close().catch(() => {});
    }

    if (attempt < 8) {
      await new Promise(resolve => setTimeout(resolve, 5000));
    }
  }

  return lastResult;
}

try {
  const context = await browser.newContext({ ignoreHTTPSErrors: true });

  for (const [name, url] of urls) {
    try {
      const lastResult = await probePage(context, name, url);
      results.push(lastResult);

      if (name === 'code.ffxiv.be' && lastResult.Passed) {
        for (const folderCheck of codeFolderChecks) {
          results.push(await probePage(context, folderCheck.name, folderCheck.url, {
            expectedText: folderCheck.expectedText,
            failOnSubresourceErrors: folderCheck.failOnSubresourceErrors,
          }));
        }
      }
    } catch (error) {
      results.push({
        Name: name,
        Url: url,
        Status: 0,
        FinalUrl: '',
        Redirected: false,
        RedirectCount: 0,
        RedirectChain: [],
        Passed: false,
        Detail: error?.message ?? String(error),
      });
    }
  }
} finally {
  await browser.close().catch(() => {});
}

const summary = {
  Timestamp: new Date().toISOString(),
  ReportDir: reportDir,
  Passed: results.filter(r => r.Passed).length,
  Failed: results.filter(r => !r.Passed).length,
  Results: results,
};

const lines = [];
lines.push('# PCSetup Public Route Verification');
lines.push('');
lines.push(`- Timestamp: ${summary.Timestamp}`);
lines.push(`- Passed: ${summary.Passed}`);
lines.push(`- Failed: ${summary.Failed}`);
lines.push('');
lines.push('| Hostname | Expected | Actual | Result |');
lines.push('| --- | --- | --- | --- |');
for (const result of results) {
  lines.push(`| ${result.Name} | 200 or redirect | ${result.Detail.replace(/\|/g, '\\|')} | ${result.Passed ? 'PASS' : 'FAIL'} |`);
}

await fs.writeFile(jsonPath, JSON.stringify(summary, null, 2), 'utf8');
await fs.writeFile(mdPath, lines.join('\n'), 'utf8');
await fs.copyFile(jsonPath, latestJson);
await fs.copyFile(mdPath, latestMd);

console.log(JSON.stringify(summary, null, 2));
process.exit(summary.Failed === 0 ? 0 : 1);
