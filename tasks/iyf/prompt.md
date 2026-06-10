Your job is to complete TWO daily quests on iyf.tv: SIGN-IN (+4 coins) and SHARE (+10 coins). Both phases must be attempted; do not stop after Phase A. Use the claude-in-chrome browser tools to control Brave Browser. Complete this task fully and autonomously — do not ask for confirmation at any step.

## Phase A: SIGN-IN

1. Use browser and navigate to https://www.iyf.tv/ and wait for it to load.

2. Check login status using JavaScript: `!!document.querySelector('img.avatar, .avatar, app-user-avatar')`. If NOT logged in:
   a. Click the login area in the nav
   b. Wait for the DNA login iframe (#Dna_Login_Iframe) to appear
   c. Make sure the '其他方式登录' (email) tab is active — click it if not
   d. Fill the email field with: ${IYF_EMAIL}
   e. Fill the password field with: ${IYF_PASSWORD}
   f. Slider captcha: take a screenshot, find the slider handle, then use the computer tool to click-and-drag it all the way to the right
   g. Click the 登录 (login) button and wait for login to complete

3. Open the daily sign-in dialog:
   a. Hover over app-daily-sign-in-button so the panel expands
   b. Click the '每日签到' button (.button-block whose text is 每日签到)
   c. Wait for dn-dialog to appear (`document.querySelector('dn-dialog')`)

4. PRE-CHECK sign-in state. Run this JS and log as line `DETAILS_PRE: <json>`:
   ```
   ({
     hasInvalidDay: !!document.querySelector('.signInDays.invalid'),
     invalidDayText: document.querySelector('.signInDays.invalid')?.innerText?.trim() || null
   })
   ```
   - If `hasInvalidDay` is true → remember SIGNIN_RESULT = ALREADY_COLLECTED. SKIP step 5 and step 6 and continue at Phase B (step 7). (.signInDays.invalid with text '已签到' is the persistent post-collection marker on the streak display.)
   - Otherwise → proceed to step 5.

5. CLICK the 即刻签到 button:
   a. Click `.sign-in-submit .button`
   b. Wait 2 seconds.

   IMPORTANT: do NOT rely on `.already-signed` or `.signed-sucss` opacity to detect success — both elements always exist in the DOM toggled by CSS opacity, and the success animation fades back to opacity 0 within ~2-3 seconds, so polling the opacity is unreliable.

6. POST-CHECK sign-in: re-run the JS from step 4 and log as line `DETAILS_POST: <json>`.
   - If `hasInvalidDay` is true → remember SIGNIN_RESULT = COIN_COLLECTED.
   - Else → remember SIGNIN_RESULT = FAILED — .signInDays.invalid did not appear after click.

   Regardless of SIGNIN_RESULT, continue to Phase B.

## Phase B: SHARE

After Phase A you should be on https://www.iyf.tv/user/index (the user center page). The 每日任务 panel is on this page. REMEMBER the current main tab's tabId — you will need it in steps 10 and 11 to distinguish the main tab from the popup tab you create in step 10.

7. PRE-CHECK share quest state. Run this JS on the main tab and log as line `SHARE_PRE: <json>`:
   ```
   (() => {
     const cards = document.querySelectorAll('.quest-ctn');
     for (const c of cards) {
       const t = c.querySelector('.quest-title');
       if (t && t.innerText.trim() === '分享视频给好友') {
         const btn = c.querySelector('.quest-btn');
         return {
           cardFound: true,
           btnText: btn ? btn.innerText.trim() : null,
           isInvalid: !!(btn && btn.classList.contains('invalid'))
         };
       }
     }
     return { cardFound: false };
   })()
   ```
   - If `isInvalid` is true → remember SHARE_RESULT = ALREADY_COMPLETED. SKIP steps 8–11 and go to the Output Format step.
   - If `cardFound` is false → remember SHARE_RESULT = FAILED — share quest card not found on /user/index. SKIP steps 8–11.
   - Otherwise → proceed to step 8.

8. Navigate to a video page (use the main tab — do NOT create a new tab here):
   a. Navigate the main tab to https://www.iyf.tv/ and wait for the homepage to render (about 2 seconds).
   b. Read the first /play/<id> href from the page: `document.querySelector('a[href^="/play/"]')?.getAttribute('href')`. Remember this value as PLAY_HREF.
      If PLAY_HREF is empty or null → remember SHARE_RESULT = FAILED — could not find a video link on homepage. SKIP the rest of step 8 and SKIP steps 9–11.
   c. Navigate the main tab to the URL formed by https://www.iyf.tv concatenated with PLAY_HREF (for example, if PLAY_HREF is /play/abc123 then navigate to https://www.iyf.tv/play/abc123).
   d. Wait about 3 seconds for the video page action bar to render.

9. Open the share modal on the video page and locate the X share button:
   a. Note the current (main) tabId as MAIN_TAB — you will need it in step 10.
   b. Click the share button by running this JS: `document.querySelector('.iconfont.iconfenxiang')?.closest('.icon-container')?.click()`
   c. Wait 1 second for the share modal `.hovered-share-box` to appear.
   d. Use the `find` browser tool with the query: X (Twitter) share button in the share modal, title is 分享到𝕏. (The title attribute uses the stylized 𝕏 mathematical bold character, NOT ASCII X.) Remember the returned element ref as X_REF.
   e. If `find` returns no matching element → remember SHARE_RESULT = FAILED — could not find X share button in modal. SKIP steps 10–11.

10. Trigger the share completion via a TRUSTED click event (this is what the iyf.tv frontend handler listens for; JS .click() and direct anybound.vip navigation both fail to fire it):
    a. Use the `computer` browser tool with action `left_click`, tabId MAIN_TAB, and `ref` set to X_REF. The click is a trusted user-gesture event so it WILL spawn a popup tab to the anybound.vip redirector — that is expected and required for the completion to register.
    b. Wait 2 seconds for the iyf.tv frontend XHR to mark the quest complete server-side.
    c. Call `tabs_context_mcp` to list current tabs. Identify any tab whose tabId is NOT MAIN_TAB — that is POPUP_TAB.
    d. Use `tabs_close_mcp` to close POPUP_TAB. Do this even if any prior step errored — leaving an orphan tab open would pollute the next scheduled run.

11. POST-CHECK share quest state (use the main tab):
    a. Navigate the main tab to https://www.iyf.tv/user/index.
    b. Wait about 2 seconds for the user center page to render.
    c. Re-run the JS from step 7 and log as line `SHARE_POST: <json>`.
    d. If `isInvalid` is true → remember SHARE_RESULT = COIN_COLLECTED.
    e. Else → remember SHARE_RESULT = FAILED — .quest-btn.invalid did not appear after share.

## Output Format

Print these log lines as you go through the steps:
- `DETAILS_PRE: <json>` (always, after step 4)
- `DETAILS_POST: <json>` (only if step 6 was reached)
- `SHARE_PRE: <json>` (always, after step 7)
- `SHARE_POST: <json>` (only if step 11c was reached)

Then end your response with EXACTLY these two lines, in this order, each on its own line:
- One of: `SIGNIN: COIN_COLLECTED` / `SIGNIN: ALREADY_COLLECTED` / `SIGNIN: FAILED — <brief reason>`
- One of: `SHARE: COIN_COLLECTED` / `SHARE: ALREADY_COMPLETED` / `SHARE: FAILED — <brief reason>`
