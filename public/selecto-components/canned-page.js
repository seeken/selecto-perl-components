(() => {
  "use strict";

  // The link remains a normal local URL when JavaScript is unavailable or the
  // user explicitly asks to open it in another tab.
  document.addEventListener("click", (event) => {
    const link = event.target.closest?.("a[data-sc-canned-modal-link]");
    if (!link || !link.closest(".selecto-canned-page") || event.button !== 0
      || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey
      || typeof HTMLDialogElement === "undefined"
      || typeof HTMLDialogElement.prototype.showModal !== "function") return;
    event.preventDefault();

    const title = link.dataset.scCannedModalTitle || "Record details";
    const dialog = document.createElement("dialog");
    dialog.className = "sc-canned-record-dialog";
    dialog.setAttribute("aria-label", title);
    const header = document.createElement("header");
    const heading = document.createElement("h2");
    heading.textContent = title;
    const close = document.createElement("button");
    close.type = "button";
    close.className = "sc-button sc-secondary";
    close.textContent = "Close";
    close.addEventListener("click", () => dialog.close());
    header.append(heading, close);
    const frame = document.createElement("iframe");
    frame.title = title;
    frame.referrerPolicy = "same-origin";
    dialog.append(header, frame);
    const host = embeddingHost();
    const place = () => placeInVisibleBand(dialog, host);
    dialog.addEventListener("close", () => {
      if (host) {
        host.window.removeEventListener("scroll", place, true);
        host.window.removeEventListener("resize", place);
      }
      frame.removeAttribute("src");
      dialog.remove();
      if (link.isConnected) link.focus({ preventScroll: true });
    }, { once: true });
    document.body.append(dialog);
    place();
    if (host) {
      host.window.addEventListener("scroll", place, { capture: true, passive: true });
      host.window.addEventListener("resize", place);
    }
    dialog.showModal();
    frame.src = link.href;
    close.focus({ preventScroll: true });
  });

  // A host page may grow this document's frame to its full content height, so
  // centering in this viewport can put the dialog below the fold. When the host
  // is same-origin, center the dialog in the part of the frame the user sees.
  function embeddingHost() {
    try {
      const element = window.frameElement;
      if (!element || !window.parent) return null;
      return { element, window: window.parent };
    } catch (_error) {
      return null;
    }
  }

  function placeInVisibleBand(dialog, host) {
    if (!host) return;
    const rect = host.element.getBoundingClientRect();
    const top = Math.max(0, -rect.top);
    const bottom = Math.min(window.innerHeight, host.window.innerHeight - rect.top);
    const visible = bottom - top;
    if (visible <= 0) return;
    const height = Math.min(540, visible - 24);
    dialog.style.boxSizing = "border-box";
    dialog.style.height = `${Math.max(height, 240)}px`;
    dialog.style.margin = "0 auto";
    dialog.style.top = `${top + Math.max((visible - height) / 2, 12)}px`;
    dialog.style.bottom = "auto";
  }

  document.addEventListener("submit", (event) => {
    const form = event.target;
    if (!(form instanceof HTMLFormElement) || !form.closest(".selecto-canned-page")) return;
    const channel = form.closest('[hx-ws\\:connect]');
    const socket = channel && channel._htmx && channel._htmx.ws
      && channel._htmx.ws.connection && channel._htmx.ws.connection.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      // Keep the form's ordinary GET or POST behavior when the channel is down.
      event.stopImmediatePropagation();
      return;
    }
    const id = String((Number(channel.dataset.latestCannedRequest || "0") + 1));
    channel.dataset.latestCannedRequest = id;
    let input = form.querySelector('input[name="selecto_request_id"]');
    if (!input) {
      input = document.createElement("input");
      input.type = "hidden";
      input.name = "selecto_request_id";
      form.appendChild(input);
    }
    input.value = id;
    if (form.method.toLowerCase() === "get") {
      const target = new URL(form.action, window.location.href);
      const pairs = new FormData(form, event.submitter || undefined);
      pairs.delete("selecto_request_id");
      target.search = new URLSearchParams(pairs).toString();
      channel.dataset.latestCannedUrl = target.pathname + target.search;
    }
  }, true);

  document.addEventListener("htmx:ws:before:message:incoming", (event) => {
    const channel = event.target;
    if (!(channel instanceof Element) || !channel.id.startsWith("selecto-page-channel-")) return;
    const detail = event.detail;
    detail.waitUntil(detail.message.json().then((message) => {
      const incoming = message && message.selecto && message.selecto.request_id;
      if (!incoming || incoming !== channel.dataset.latestCannedRequest) {
        detail.cancelled = true;
      } else if (channel.dataset.latestCannedUrl) {
        history.replaceState(history.state, "", channel.dataset.latestCannedUrl);
      }
    }).catch(() => { detail.cancelled = true; }));
  });
})();
