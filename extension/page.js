// Runs in the page's own JS world, in every frame. Replaces the fullscreen API
// so the player fills the window instead of opening a new macOS Space.
(() => {
  if (window.__videoCurtainInstalled) return;
  window.__videoCurtainInstalled = true;

  const MESSAGE = "video-curtain";
  const isTop = window === window.top;
  let active = null;

  // Safari in native fullscreen fills the display's width and reaches its bottom
  // edge; only the camera housing (under 40pt) is left out. An ordinary window is
  // shorter, so its video keeps Safari's normal fullscreen and its own desktop.
  const safariIsFullscreen = () =>
    window.outerWidth >= window.screen.width && window.outerHeight >= window.screen.height - 40;

  const notifyPage = (element) => {
    for (const type of ["fullscreenchange", "webkitfullscreenchange"]) {
      element.dispatchEvent(new Event(type, { bubbles: true, composed: true }));
    }
    // Players re-measure themselves on resize; the window size itself may not change.
    window.dispatchEvent(new Event("resize"));
  };

  const notifyHelper = (state) => {
    // bridge.js (top frame only) forwards this to the background script.
    window.postMessage({ source: MESSAGE, kind: "helper", state }, "*");
  };

  const place = (element) => {
    element.setAttribute("data-video-curtain", "");
    document.documentElement.setAttribute("data-video-curtain-page", "");
    // The top layer escapes ancestors' transforms and stacking contexts, which
    // would otherwise trap a position:fixed player inside its column.
    if (element.showPopover && !element.hasAttribute("popover")) {
      try {
        element.setAttribute("popover", "manual");
        element.showPopover();
        element.dataset.videoCurtainPopover = "1";
      } catch {
        element.removeAttribute("popover");
      }
    }
  };

  const unplace = (element) => {
    if (element.dataset.videoCurtainPopover) {
      try {
        element.hidePopover();
      } catch {}
      element.removeAttribute("popover");
      delete element.dataset.videoCurtainPopover;
    }
    element.removeAttribute("data-video-curtain");
    document.documentElement.removeAttribute("data-video-curtain-page");
  };

  const enter = (element) => {
    if (active === element) return;
    if (active) leave("switch");
    active = element;
    place(element);
    if (isTop) notifyHelper("enter");
    else window.parent.postMessage({ source: MESSAGE, kind: "child-enter" }, "*");
    notifyPage(element);
  };

  // `from` says who already knows: "parent", "child", or "switch" (staying fullscreen).
  const leave = (from) => {
    if (!active) return;
    const element = active;
    active = null;
    unplace(element);
    if (from !== "switch") {
      if (isTop) notifyHelper("exit");
      else if (from !== "parent") window.parent.postMessage({ source: MESSAGE, kind: "child-exit" }, "*");
      if (from !== "child" && element.tagName === "IFRAME" && element.contentWindow) {
        element.contentWindow.postMessage({ source: MESSAGE, kind: "parent-exit" }, "*");
      }
    }
    notifyPage(element);
  };

  const makeRequest = (original) =>
    function (...args) {
      if (!safariIsFullscreen()) return original ? original.apply(this, args) : undefined;
      // Same rule as the real API: only a user gesture may go fullscreen.
      if (navigator.userActivation && !navigator.userActivation.isActive) {
        return Promise.reject(new TypeError("Fullscreen request requires a user gesture"));
      }
      enter(this);
      return Promise.resolve();
    };

  const makeExit = (original) =>
    function (...args) {
      if (!active) return original ? original.apply(this, args) : undefined;
      leave("page");
      return Promise.resolve();
    };

  const wrapMethods = (target, names, wrap) => {
    if (!target) return;
    for (const name of names) {
      const value = wrap(target[name]);
      Object.defineProperty(target, name, { value, configurable: true, writable: true });
    }
  };

  // `read` receives the original getter's value, so real fullscreen still reports correctly.
  const wrapGetters = (target, names, read) => {
    if (!target) return;
    for (const name of names) {
      const original = Object.getOwnPropertyDescriptor(target, name)?.get;
      Object.defineProperty(target, name, {
        configurable: true,
        get() {
          return read.call(this, original ? original.call(this) : undefined);
        },
      });
    }
  };

  wrapMethods(Element.prototype, ["requestFullscreen", "webkitRequestFullscreen", "webkitRequestFullScreen"], makeRequest);
  wrapMethods(Document.prototype, ["exitFullscreen", "webkitExitFullscreen", "webkitCancelFullScreen"], makeExit);
  wrapGetters(Document.prototype, ["fullscreenElement", "webkitFullscreenElement", "webkitCurrentFullScreenElement"], (real) => active || real || null);
  wrapGetters(Document.prototype, ["fullscreen", "webkitIsFullScreen"], (real) => active !== null || Boolean(real));
  wrapGetters(Document.prototype, ["fullscreenEnabled", "webkitFullscreenEnabled"], (real) => safariIsFullscreen() || Boolean(real));

  // Video-only legacy API, used by some players in Safari.
  const video = window.HTMLVideoElement && HTMLVideoElement.prototype;
  wrapMethods(video, ["webkitEnterFullscreen", "webkitEnterFullScreen"], makeRequest);
  wrapMethods(video, ["webkitExitFullscreen", "webkitExitFullScreen"], makeExit);
  wrapGetters(video, ["webkitDisplayingFullscreen"], function (real) {
    return active === this || Boolean(real);
  });

  window.addEventListener("message", (event) => {
    const data = event.data;
    if (!data || data.source !== MESSAGE) return;

    if (data.kind === "parent-exit") {
      if (event.source === window.parent) leave("parent");
      return;
    }
    if (data.kind === "tab-exit") {
      if (event.source === window) leave("page");
      return;
    }
    const frame = [...document.querySelectorAll("iframe")].find(
      (candidate) => candidate.contentWindow === event.source
    );
    if (!frame) return;
    if (data.kind === "child-enter") enter(frame);
    else if (data.kind === "child-exit" && active === frame) leave("child");
  });

  // The focus may be in any frame, so each one watches for Esc while it is involved.
  window.addEventListener(
    "keydown",
    (event) => {
      if (event.key === "Escape" && active) {
        event.preventDefault();
        event.stopPropagation();
        leave("page");
      }
    },
    true
  );

  // Leaving the page must take the curtain down too.
  window.addEventListener("pagehide", () => {
    if (active) leave("page");
  });
})();
