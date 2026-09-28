  // Horizontal table scrolling establishes a sticky containing block even
  // when the document owns vertical scrolling. Move the native header within
  // that block, below any host toolbar, without cloning interactive controls.
  var stickyResultTables = [];
  var stickyResultFrame = null;
  var stickyResultResize = typeof ResizeObserver === "function"
    ? new ResizeObserver(scheduleResultTableHeaders) : null;

  function scheduleResultTableHeaders() {
    if (stickyResultFrame !== null) return;
    stickyResultFrame = window.requestAnimationFrame(positionResultTableHeaders);
  }

  function positionResultTableHeaders() {
    stickyResultFrame = null;
    // Read before writing, and do not traverse table cells on scroll.
    var positions = stickyResultTables.filter(function (entry) {
      return entry.wrap.isConnected && entry.head.isConnected;
    }).map(function (entry) {
      var bounds = entry.wrap.getBoundingClientRect();
      var hostTop = parseFloat(window.getComputedStyle(entry.wrap).getPropertyValue("--sc-sticky-top")) || 0;
      var limit = Math.max(0, entry.wrap.clientHeight - entry.head.offsetHeight);
      return {entry: entry, offset: Math.max(0, Math.min(limit, hostTop - bounds.top - entry.wrap.clientTop))};
    });
    positions.forEach(function (position) {
      var value = position.offset + "px";
      if (position.entry.offset === value) return;
      position.entry.offset = value;
      position.entry.wrap.style.setProperty("--sc-table-header-offset", value);
    });
  }

  function restoreResultTableHeaders() {
    if (stickyResultResize) stickyResultResize.disconnect();
    stickyResultTables = Array.from(document.querySelectorAll(".sc-table-wrap > table > thead"))
      .filter(function (head) { return !head.closest("dialog, [role=dialog]"); })
      .map(function (head) {
        var wrap = head.parentElement.parentElement;
        if (stickyResultResize) {
          stickyResultResize.observe(wrap);
          stickyResultResize.observe(head);
        }
        return {head: head, wrap: wrap};
      });
    if (stickyResultResize && document.body) stickyResultResize.observe(document.body);
    scheduleResultTableHeaders();
  }

  function initResultTableHeaders() {
    restoreResultTableHeaders();
    // Toolbar sizes and host menu classes can change without a window resize.
    if (document.body && typeof MutationObserver === "function") {
      new MutationObserver(scheduleResultTableHeaders).observe(document.body, {
        attributes: true, attributeFilter: ["style", "class"],
      });
    }
  }

  document.addEventListener("scroll", scheduleResultTableHeaders, {capture: true, passive: true});
  window.addEventListener("resize", scheduleResultTableHeaders);
  window.addEventListener("pageshow", restoreResultTableHeaders);
  document.addEventListener("htmx:after:swap", restoreResultTableHeaders);
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initResultTableHeaders);
  } else {
    initResultTableHeaders();
  }
