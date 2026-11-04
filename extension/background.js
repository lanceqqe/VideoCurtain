// Tells the native side to raise or lower the curtain, and ends fullscreen when
// the user moves to another tab, since the curtain would cover that tab's toolbar.
const send = (state) => browser.runtime.sendNativeMessage("application.id", { state });

// Page-world injection without a <script> tag, which a site's CSP can block.
const registerPageScript = async () => {
  try {
    const existing = await browser.scripting.getRegisteredContentScripts({ ids: ["video-curtain-page"] });
    if (existing.length === 0) {
      await browser.scripting.registerContentScripts([
        {
          id: "video-curtain-page",
          js: ["page.js"],
          matches: ["<all_urls>"],
          allFrames: true,
          runAt: "document_start",
          world: "MAIN",
        },
      ]);
    }
  } catch (error) {
    console.warn("Video Curtain: main-world registration failed", error);
  }
};
registerPageScript();

browser.runtime.onMessage.addListener(async (message, sender) => {
  if (message.state === "enter") {
    await browser.storage.local.set({ curtainTab: sender.tab.id });
  } else {
    await browser.storage.local.remove("curtainTab");
  }
  await send(message.state);
});

const clear = async () => {
  await browser.storage.local.remove("curtainTab");
  await send("exit");
};

browser.tabs.onActivated.addListener(async ({ tabId }) => {
  const { curtainTab } = await browser.storage.local.get("curtainTab");
  if (curtainTab === undefined || curtainTab === tabId) return;
  await browser.tabs.sendMessage(curtainTab, { exit: true }).catch(clear);
});

browser.tabs.onRemoved.addListener(async (tabId) => {
  const { curtainTab } = await browser.storage.local.get("curtainTab");
  if (curtainTab === tabId) await clear();
});
