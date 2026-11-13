  // A Detail page that returned before its count (Explorer defer_count) names
  // its count URL on the matched-rows text. Its total and pagination replace
  // the placeholders when the count returns; a page replaced meanwhile by
  // another query keeps what it has.
  function loadDeferredCounts(root) {
    var scope = root && root.querySelectorAll ? root : document;
    var pending = scope.matches && scope.matches("[data-sc-deferred-count]")
      ? [scope] : Array.prototype.slice.call(scope.querySelectorAll("[data-sc-deferred-count]"));
    pending.forEach(function (matched) {
      if (matched.hasAttribute("data-sc-count-started")) return;
      matched.setAttribute("data-sc-count-started", "");
      var url = matched.getAttribute("data-sc-deferred-count");
      if (!url || url.charAt(0) !== "/" || url.charAt(1) === "/") return;
      var results = matched.closest('[id^="selecto-results-"]');
      fetch(url, {credentials: "same-origin", headers: {Accept: "application/json"}})
        .then(function (response) {
          return response.json().then(function (data) {
            if (!response.ok || typeof data.matched !== "string") throw new Error(data.error || "not counted");
            return data;
          });
        })
        .then(function (data) {
          if (!matched.isConnected) return;
          replaceWithHtml(matched, data.matched);
          if (results && data.pagination) {
            ["top", "bottom"].forEach(function (position) {
              var nav = results.querySelector('nav.sc-pagination[data-sc-pagination-position="' + position + '"]');
              if (nav && typeof data.pagination[position] === "string") {
                var replacement = replaceWithHtml(nav, data.pagination[position]);
                if (replacement && window.htmx && typeof window.htmx.process === "function") {
                  window.htmx.process(replacement);
                }
              }
            });
          }
          var card = results && results.querySelector("[data-sc-debug-count] strong");
          if (card && data.count_ms !== undefined && data.count_ms !== null) {
            card.textContent = data.count_ms + " ms, after the page";
          }
          var matchedCard = results && results.querySelector("[data-sc-debug-matched] strong");
          if (matchedCard && typeof data.total_count === "number") {
            matchedCard.textContent = data.total_count.toLocaleString("en-US");
          }
          var trips = results && results.querySelector("[data-sc-debug-count-trips]");
          if (trips && typeof data.count_round_trips === "string" && data.count_round_trips) {
            replaceWithHtml(trips, data.count_round_trips);
          }
          document.dispatchEvent(new CustomEvent("selecto:count", {detail: {
            total_count: data.total_count, total_pages: data.total_pages
          }}));
        })
        .catch(function () {
          if (!matched.isConnected) return;
          var status = matched.querySelector("[data-sc-count-status]");
          if (status) status.textContent = "more on the next";
        });
    });
  }

  function replaceWithHtml(element, html) {
    var template = document.createElement("template");
    template.innerHTML = html.trim();
    var replacement = template.content.firstElementChild;
    if (!replacement) return null;
    element.replaceWith(replacement);
    return replacement;
  }

  document.addEventListener("DOMContentLoaded", function () { loadDeferredCounts(document); });
  if (document.readyState !== "loading") loadDeferredCounts(document);
  document.addEventListener("htmx:after:swap", function (event) {
    var target = event.detail && event.detail.ctx && event.detail.ctx.target;
    loadDeferredCounts(target && target.isConnected ? target : document);
  });
