// Isolated world, every frame. Safari has no MAIN-world content scripts, so
// page.js is loaded as a page script; it can't use extension APIs, so the top
// frame's copy of this file relays between it and the background script.
const script = document.createElement("script");
script.src = browser.runtime.getURL("page.js");
script.onload = () => script.remove();
script.onerror = () => script.remove();
(document.head || document.documentElement).appendChild(script);

if (window === window.top) {
  window.addEventListener("message", (event) => {
    const data = event.data;
    if (event.source !== window || !data || data.source !== "video-curtain" || data.kind !== "helper") return;
    browser.runtime.sendMessage({ state: data.state });
  });

  browser.runtime.onMessage.addListener((message) => {
    if (message.exit) {
      window.postMessage({ source: "video-curtain", kind: "tab-exit" }, "*");
    }
  });
}
