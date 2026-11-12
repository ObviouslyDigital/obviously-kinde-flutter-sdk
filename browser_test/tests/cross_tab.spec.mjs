import { expect, test } from '@playwright/test';

const kinde = 'https://localhost:47443';
const appOrigin = 'http://localhost:47080';

async function resetKinde(request, refreshDelayMs = 0) {
  await request.post(`${kinde}/__reset?refreshDelayMs=${refreshDelayMs}`);
}

async function kindeStats(request) {
  return (await request.get(`${kinde}/__stats`)).json();
}

async function waitForApp(page) {
  await page.waitForURL((url) => url.origin === appOrigin);
  await page.waitForFunction(() => window.kindeReady === true);
}

async function openApp(page) {
  await page.goto('/');
  await waitForApp(page);
}

async function appState(page) {
  return JSON.parse(await page.evaluate(() => window.kindeState()));
}

async function startLogin(page, orgCode) {
  await page.evaluate((org) => { window.kindeLogin(org); }, orgCode);
  await page.waitForURL(`${kinde}/oauth2/auth**`);
}

async function approveLogin(page) {
  await page.click('#approve');
  await waitForApp(page);
  expect(await page.evaluate(() => window.kindeCallbackError ?? null)).toBeNull();
}

async function signIn(page, orgCode) {
  await startLogin(page, orgCode);
  await approveLogin(page);
}

const getToken = (page, forceRefresh) =>
  page.evaluate((force) => window.kindeGetToken(force), forceRefresh).then(JSON.parse);

test('(a) two tabs refreshing at once send one refresh request and share the new tokens', async ({ context, request }) => {
  const [tab1, tab2] = [await context.newPage(), await context.newPage()];
  await resetKinde(request);
  await openApp(tab1);
  await signIn(tab1, 'org_pool');
  await openApp(tab2);
  expect((await appState(tab2)).signedIn).toBe(true);
  await resetKinde(request, 1000);

  const [first, second] = await Promise.all([getToken(tab1, true), getToken(tab2, true)]);

  const stats = await kindeStats(request);
  console.log('(a) results', JSON.stringify({ first, second, stats }));
  expect(stats.refreshRequests).toBe(1);
  expect(stats.rejectedRefreshes).toBe(0);
  expect(first.error).toBeUndefined();
  expect(second.error).toBeUndefined();
  expect(second.token).toBe(first.token);
  expect((await appState(tab1)).refreshToken).toBe((await appState(tab2)).refreshToken);
  expect((await appState(tab1)).signedIn).toBe(true);
  expect((await appState(tab2)).signedIn).toBe(true);
});

test('(b) an organisation switch in one tab reaches the other on its next getToken', async ({ context, request }) => {
  const [tab1, tab2] = [await context.newPage(), await context.newPage()];
  await resetKinde(request);
  await openApp(tab1);
  await signIn(tab1, 'org_pool');
  await openApp(tab2);
  expect((await appState(tab2)).org).toBe('org_pool');

  await signIn(tab1, 'org_meridian');
  const tab1State = await appState(tab1);
  const tab2Token = await getToken(tab2, false);

  console.log('(b) results', JSON.stringify({ tab1State, tab2Token }));
  expect(tab1State.org).toBe('org_meridian');
  expect(tab1State.url).not.toContain('code=');
  expect(tab1State.historyState).toEqual({ kindeTestMarker: true });
  expect(tab2Token.error).toBeUndefined();
  expect(tab2Token.org).toBe('org_meridian');
});

test('(c) a logout in one tab while the other refreshes signs both out', async ({ context, request }) => {
  const [tab1, tab2] = [await context.newPage(), await context.newPage()];
  await resetKinde(request);
  await openApp(tab1);
  await signIn(tab1, 'org_pool');
  await openApp(tab2);
  await resetKinde(request, 1500);

  const refreshing = getToken(tab2, true);
  await expect.poll(async () => (await kindeStats(request)).refreshRequests).toBe(1);
  await tab1.evaluate(() => { window.kindeLeaving = true; window.kindeLogout(); });
  await tab1.waitForFunction(() => window.kindeReady === true && window.kindeLeaving === undefined);
  const refreshed = await refreshing;
  const tab1State = await appState(tab1);
  const tab2Next = await getToken(tab2, false);
  const stats = await kindeStats(request);

  console.log('(c) results', JSON.stringify({ refreshed, tab1State, tab2Next, stats }));
  expect(stats.rejectedRefreshes).toBe(0);
  expect(refreshed.error).toBeUndefined();
  expect(tab1State.signedIn).toBe(false);
  expect(tab2Next.error).toBe('session-expired-or-invalid');
  expect(tab2Next.signedIn).toBe(false);
  await tab2.reload();
  await waitForApp(tab2);
  expect((await appState(tab2)).signedIn).toBe(false);
});

test('(d) logins started in two tabs both complete', async ({ context, request }) => {
  const [tab1, tab2] = [await context.newPage(), await context.newPage()];
  await resetKinde(request);
  await openApp(tab1);
  await openApp(tab2);

  await startLogin(tab1, 'org_pool');
  await startLogin(tab2, 'org_meridian');
  await approveLogin(tab2);
  const tab2State = await appState(tab2);
  await approveLogin(tab1);
  const tab1State = await appState(tab1);
  const stats = await kindeStats(request);

  console.log('(d) results', JSON.stringify({ tab1State, tab2State, stats }));
  expect(tab2State.org).toBe('org_meridian');
  expect(tab1State.org).toBe('org_pool');
  expect(stats.codeExchanges).toBe(2);
});

test('(e) a tab shown again from the back/forward cache can start a new login', async ({ page, request }) => {
  await resetKinde(request);
  await openApp(page);
  const authorizeRequests = [];
  await page.route(`${kinde}/oauth2/auth**`, (route) => {
    authorizeRequests.push(route.request().url());
    return route.abort('aborted');
  });

  const first = JSON.parse(await page.evaluate(() => window.kindeLogin('org_pool')));
  await expect.poll(() => authorizeRequests.length).toBe(1);
  const whileLeaving = JSON.parse(await page.evaluate(() => window.kindeLogin('org_pool')));
  await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true })));
  await page.unroute(`${kinde}/oauth2/auth**`);
  await startLogin(page, 'org_pool');
  await approveLogin(page);
  const state = await appState(page);
  const stats = await kindeStats(request);

  console.log('(e) results', JSON.stringify({ first, whileLeaving, state, stats }));
  expect(first.error).toBeUndefined();
  expect(whileLeaving.error).toBe('login-in-process');
  expect(state.signedIn).toBe(true);
  expect(state.org).toBe('org_pool');
  expect(stats.codeExchanges).toBe(1);
});
