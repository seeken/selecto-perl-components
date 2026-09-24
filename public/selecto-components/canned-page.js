(() => {
  "use strict";

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
