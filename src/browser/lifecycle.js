  document.addEventListener("DOMContentLoaded", function () {
    restoreHostMenuLayout();
    rememberSelectoHistory(window.location.pathname + window.location.search + window.location.hash, false);
    renderConnectionStatus();
    restoreBuilderTabs();
    restoreBuilderTrays();
    restoreResultViews();
    restoreCharts();
    restoreGridSelections();
    scheduleSelectoWebSocketRecovery(750);
  });

  window.addEventListener("pageshow", function (event) {
    if (!event.persisted) {
      // A hosted Explorer can be reactivated with a closed htmx channel even
      // when the browser does not label the pageshow as a bfcache restore.
      // Verify the channel after htmx has had a chance to process the page.
      scheduleSelectoWebSocketRecovery(750);
      return;
    }
    // Chrome can restore the Explorer document from bfcache while leaving the
    // host toolbar custom element disconnected from its internal menu state.
    // Rebuilding only the Selecto channel cannot repair an element outside
    // that channel, and Chart.js can retain a similarly stale canvas backing
    // store. Reload the exact history URL so both host chrome and results are
    // constructed from a clean document. A reload is not itself a persisted
    // pageshow, so this cannot loop.
    if (usesSelectoHostMenu()) {
      window.location.reload();
      return;
    }
    recoverClosedWebSocketChannels();
    restoreCharts(true);
  });

  window.addEventListener("pagehide", function () {
    rememberSelectoHistory(window.location.pathname + window.location.search + window.location.hash, false);
  });

  window.addEventListener("popstate", function (event) {
    // Selecto's surface snapshot deliberately excludes the host navigation.
    // A toolbar or legacy dynamic menu can still mutate its own body classes
    // while the detail entry is active, so restoring only the surface leaves
    // the graph beneath an absent/overlapping menu. Re-render the exact joint
    // history entry as a complete document for hosted pages.
    if (usesSelectoHostMenu()) {
      window.location.reload();
      return;
    }
    activeSelectoRequestId = event.state && event.state.selectoPendingNavigation
      ? event.state.selectoRequestId || null : null;
    restoreSelectoHistory(event.state);
  });

  function usesSelectoHostMenu() {
    return !!(document.body && document.body.matches(
      ".sc-host-menu-toolbar, .cgt-host-menu-toolbar, " +
      ".sc-host-menu-dynamic, .cgt-host-menu-dynamic"
    ));
  }

  function restoreHostMenuLayout() {
    if (!document.body || !document.querySelector("toolbar-menu[sidebar-always-open]")) return;
    // The toolbar component normally owns this class. Chrome history can
    // retain the element while restoring an older body class list, placing
    // application content underneath the visible sidebar.
    document.body.classList.add("toolbar-left-menu-open");
  }

  function rememberSelectoHistory(url, push, pendingNavigation, requestId) {
    var surface = document.querySelector('[id^="selecto-surface-"]');
    if (!surface || !window.history) return;
    var state = window.history.state && typeof window.history.state === "object"
      ? Object.assign({}, window.history.state) : {};
    var key = push ? null : state.selectoSnapshot;
    if (!key) key = "selecto-" + Date.now() + "-" + (++selectoHistoryCounter);
    var snapshot = surface.cloneNode(true);
    prepareChartsForSnapshot(snapshot);
    snapshot.querySelectorAll('input[name="selecto_request_id"]').forEach(function (input) {
      input.remove();
    });
    storeSelectoHistorySnapshot(key, snapshot.outerHTML);
    while (selectoHistorySnapshots.size > 24) {
      removeSelectoHistorySnapshot(selectoHistorySnapshots.keys().next().value);
    }
    state.selecto = true;
    state.selectoSnapshot = key;
    if (pendingNavigation) {
      state.selectoPendingNavigation = true;
      state.selectoRequestId = requestId;
    } else {
      delete state.selectoPendingNavigation;
      delete state.selectoRequestId;
    }
    try {
      if (push) window.history.pushState(state, "", url);
      else window.history.replaceState(state, "", url);
    } catch (_error) {}
  }

  function selectoHistoryStorageKey(key) {
    return "selecto-history:" + key;
  }

  function removeSelectoHistorySnapshot(key) {
    selectoHistorySnapshots.delete(key);
    try { window.sessionStorage.removeItem(selectoHistoryStorageKey(key)); } catch (_error) {}
  }

  function storeSelectoHistorySnapshot(key, html) {
    selectoHistorySnapshots.delete(key);
    selectoHistorySnapshots.set(key, html);
    try {
      window.sessionStorage.setItem(selectoHistoryStorageKey(key), html);
    } catch (_error) {
      // A result set can exceed the browser's storage quota. Keep the current
      // in-memory copy, discard older Selecto snapshots, and retry once so a
      // document/frame restoration still has the best available snapshot.
      try {
        var prefix = "selecto-history:";
        var storedKeys = [];
        for (var index = 0; index < window.sessionStorage.length; index += 1) {
          var storedKey = window.sessionStorage.key(index);
          if (storedKey && storedKey.indexOf(prefix) === 0
              && storedKey !== selectoHistoryStorageKey(key)) storedKeys.push(storedKey);
        }
        storedKeys.forEach(function (storedKey) { window.sessionStorage.removeItem(storedKey); });
        window.sessionStorage.setItem(selectoHistoryStorageKey(key), html);
      } catch (_retryError) {}
    }
  }

  function loadSelectoHistorySnapshot(key) {
    var snapshot = selectoHistorySnapshots.get(key);
    if (snapshot) return snapshot;
    try { snapshot = window.sessionStorage.getItem(selectoHistoryStorageKey(key)); }
    catch (_error) { snapshot = null; }
    if (snapshot) selectoHistorySnapshots.set(key, snapshot);
    return snapshot;
  }

  function formNavigationUrl(form) {
    if (!form) return null;
    try {
      var target = new URL(form.getAttribute("action") || window.location.href, window.location.href);
      if (target.origin !== window.location.origin) return null;
      if ((form.getAttribute("method") || "get").toLowerCase() === "get") {
        var query = new URLSearchParams();
        new FormData(form).forEach(function (value, name) {
          if (typeof File !== "undefined" && value instanceof File) return;
          if (name === "selecto_request_id") return;
          query.append(name, value);
        });
        target.search = query.toString();
      }
      return target.pathname + target.search + target.hash;
    } catch (_error) {
      return null;
    }
  }

  function beginSelectoNavigation(form) {
    var url = formNavigationUrl(form);
    if (!url) return;
    var requestId = "selecto-" + Date.now() + "-" + (++selectoRequestCounter);
    // Create the joint-history entry while the submit event is still in
    // progress. Waiting for the asynchronous WebSocket response leaves a
    // short window in which browser Back exits the Explorer (and, in a
    // framed host, can also leave the surrounding application shell).
    rememberSelectoHistory(url, true, true, requestId);
    activeSelectoRequestId = requestId;
    var input = form.querySelector('input[name="selecto_request_id"]');
    if (!input) {
      input = document.createElement("input");
      input.type = "hidden";
      input.name = "selecto_request_id";
      form.appendChild(input);
    }
    input.value = requestId;
  }

  function usesSelectoWebSocket(form) {
    return !!(form && form.hasAttribute("hx-ws:send")
      && form.closest('[hx-ws\\:connect]'));
  }

  function restoreSelectoHistory(state) {
    var key = state && state.selectoSnapshot;
    var snapshot = key && loadSelectoHistorySnapshot(key);
    if (!snapshot) return;
    var current = document.querySelector('[id^="selecto-surface-"]');
    if (!current) return;
    var template = document.createElement("template");
    template.innerHTML = snapshot.trim();
    var restored = template.content.firstElementChild;
    if (!restored) return;
    prepareChartsForSnapshot(restored);
    destroyChartsWithin(current);
    current.replaceWith(restored);
    selectoPerformance = null;
    selectoSwapStarted = 0;
    if (window.htmx && typeof window.htmx.process === "function") {
      window.htmx.process(restored);
    }
    renderConnectionStatus();
    restoreBuilderTabs();
    restoreBuilderTrays();
    restoreResultViews();
    restoreCharts();
    restoreGridSelections();
    restoreBulkActions();
  }

  function recoverClosedWebSocketChannels() {
    selectoWebSocketRecoveryTimer = null;
    if (!window.htmx || typeof window.htmx.process !== "function") return;
    var recovering = false;
    document.querySelectorAll('[id^="selecto-channel-"][hx-ws\\:connect]').forEach(function (channel) {
      var connection = channel._htmx && channel._htmx.ws && channel._htmx.ws.connection;
      var socket = connection && connection.socket;
      if (socket && (socket.readyState === WebSocket.OPEN
          || socket.readyState === WebSocket.CONNECTING)) return;
      recovering = true;
      var replacement = channel.cloneNode(false);
      while (channel.firstChild) replacement.appendChild(channel.firstChild);
      channel.replaceWith(replacement);
      window.htmx.process(replacement);
    });
    if (recovering) connectionStatus = "Connecting";
    renderConnectionStatus();
  }

  function scheduleSelectoWebSocketRecovery(delay) {
    if (selectoWebSocketRecoveryTimer !== null) {
      window.clearTimeout(selectoWebSocketRecoveryTimer);
    }
    selectoWebSocketRecoveryTimer = window.setTimeout(
      recoverClosedWebSocketChannels,
      delay === undefined ? 750 : delay
    );
  }

  document.addEventListener("htmx:ws:after:connection", function () {
    if (selectoWebSocketRecoveryTimer !== null) {
      window.clearTimeout(selectoWebSocketRecoveryTimer);
      selectoWebSocketRecoveryTimer = null;
    }
    connectionStatus = "Live";
    renderConnectionStatus();
  });

  document.addEventListener("htmx:ws:close", function () {
    connectionStatus = "Reconnecting";
    renderConnectionStatus();
    scheduleSelectoWebSocketRecovery(750);
  });

  document.addEventListener("htmx:ws:error", function (event) {
    var detail = event.detail || {};
    var socket = detail.connection && detail.connection.socket;
    connectionStatus = socket && socket.readyState === WebSocket.OPEN
      ? "Live" : "Reconnecting";
    renderConnectionStatus();
    if (connectionStatus === "Live") return;
    scheduleSelectoWebSocketRecovery(750);
    var target = event.target instanceof Element ? event.target : null;
    var form = target && (target.matches("form") ? target : target.closest("form"));
    if (!form || !form.hasAttribute("hx-ws:send")) return;
    // A channel can be present in the DOM while its HTMX connection object is
    // absent (for example after browser restoration or a reconnect race).
    // Explorer queries are ordinary GET/POST forms, so preserve the user's
    // submitted state and finish through the equivalent HTTP route.
    submitWithoutWebSocket(
      form,
      form.matches("[data-sc-builder]") ? "Running…" : "Opening…"
    );
  });

  document.addEventListener("htmx:after:swap", renderConnectionStatus);

  window.addEventListener("submit", function (event) {
    var gridForm = event.target.closest("[data-sc-grid-selection]");
    if (gridForm) {
      var selected = gridCells(gridForm, function (cell) { return cell.checked; });
      if (!selected.length) {
        event.preventDefault();
        return;
      }
      rememberSelectoHistory(window.location.pathname + window.location.search + window.location.hash, false);
      var workspace = gridForm.closest("[data-sc-workspace]");
      var shell = workspace && workspace.querySelector("[data-sc-builder-shell]");
      if (shell) {
        setBuilderTrayCollapsed(shell, true);
      }
      var connection = document.querySelector("[data-selecto-connection]");
      if (usesSelectoWebSocket(gridForm)) {
        // Do not depend on the WebSocket extension's form listener to cancel
        // native navigation. Freshly swapped forms can be submitted before
        // HTMX has initialized them; the event must still bubble so an
        // initialized/queued WebSocket transport can send it.
        event.preventDefault();
        beginSelectoNavigation(gridForm);
        window.setTimeout(function () { showWorkspaceResultsLoading(workspace); }, 0);
        return;
      }
      if (connection && connection.classList.contains("is-live")) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      showWorkspaceResultsLoading(workspace);
      submitWithoutWebSocket(gridForm, "Opening details…");
      return;
    }
    var form = event.target.closest("[data-sc-builder]");
    if (!form) {
      var websocketForm = event.target.closest("form");
      if (!websocketForm || !websocketForm.hasAttribute("hx-ws:send")) return;
      rememberSelectoHistory(window.location.pathname + window.location.search + window.location.hash, false);
      var websocketConnection = document.querySelector("[data-selecto-connection]");
      if (usesSelectoWebSocket(websocketForm)) {
        event.preventDefault();
        beginSelectoNavigation(websocketForm);
        return;
      }
      if (websocketConnection && websocketConnection.classList.contains("is-live")) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      submitWithoutWebSocket(websocketForm);
      return;
    }
    rememberSelectoHistory(window.location.pathname + window.location.search + window.location.hash, false);
    var pageInput = form.querySelector('[name="page"]');
    if (form.classList.contains("is-dirty") && pageInput) pageInput.value = "1";
    var activeLibraryView = form.querySelector(
      '[name="query_library_view"]:checked, select[name="query_library_view"]'
    );
    if (!activeLibraryView || !activeLibraryView.value) {
      var renderScope = form.querySelector('[name="render_scope"]');
      if (!renderScope) {
        renderScope = document.createElement("input");
        renderScope.type = "hidden";
        renderScope.name = "render_scope";
        form.appendChild(renderScope);
      }
      renderScope.value = "results";
    }
    showResultsLoading(form);
    setBuilderTrayCollapsed(form.closest("[data-sc-builder-shell]"), true);
    var connection = document.querySelector("[data-selecto-connection]");
    if (usesSelectoWebSocket(form)) {
      event.preventDefault();
      beginSelectoNavigation(form);
      return;
    }
    if (connection && connection.classList.contains("is-live")) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    submitWithoutWebSocket(form, "Running…");
  }, true);

  function submitWithoutWebSocket(form, buttonLabel) {
    if (!form || form.dataset.scHttpSubmitting === "true") return;
    form.dataset.scHttpSubmitting = "true";
    var requestId = form.querySelector('input[name="selecto_request_id"]');
    if (requestId) requestId.disabled = true;
    var button = form.querySelector('button[type="submit"]');
    if (button) {
      button.disabled = true;
      if (buttonLabel) button.textContent = buttonLabel;
    }
    HTMLFormElement.prototype.submit.call(form);
  }

  function exportUrlFromBuilder(form, format) {
    var target = new URL(form.getAttribute("action") || window.location.href, window.location.href);
    var query = new URLSearchParams();
    new FormData(form).forEach(function (value, name) {
      // The Explorer builder has no file controls, but do not turn one into
      // a misleading URL if a host adds one around the surface.
      if (typeof File !== "undefined" && value instanceof File) return;
      query.append(name, value);
    });
    query.set("format", format);
    target.search = query.toString();
    return target.pathname + target.search + target.hash;
  }

  function replaceApiConsoleControl(html) {
    if (typeof html !== "string") return;
    document.querySelectorAll("[data-sc-api-console]").forEach(function (current) {
      if (!html.length) {
        current.remove();
        return;
      }
      var template = document.createElement("template");
      template.innerHTML = html.trim();
      var replacement = template.content.firstElementChild;
      if (replacement) current.replaceWith(replacement.cloneNode(true));
    });
  }

  // Export links are rendered from the last completed query.  The picker can
  // be edited locally immediately before a download, so rebuild the link from
  // the live form as it is clicked. This keeps the export projection, filters,
  // and ordering aligned with what the user currently selected.
  document.addEventListener("click", function (event) {
    var link = event.target.closest("[data-sc-export-format]");
    if (!link) return;
    var surface = link.closest('[id^="selecto-surface-"]');
    var form = surface && surface.querySelector("form[data-sc-builder]");
    var format = link.dataset.scExportFormat;
    if (!form || !format) return;
    try {
      link.href = exportUrlFromBuilder(form, format);
    } catch (_error) {}
  });

  document.addEventListener("htmx:ws:before:message:incoming", function (event) {
    var detail = event.detail;
    var incoming = detail && detail.message;
    if (!incoming || typeof incoming.json !== "function"
        || typeof detail.waitUntil !== "function") return;
    // A request queued during reconnect can finish after Back has restored an
    // older snapshot. Reject it before hx-ws swaps that stale surface into the
    // current history entry.
    detail.waitUntil(incoming.json().then(function (message) {
      var requestId = message && message.selecto && message.selecto.request_id;
      if (requestId && requestId !== activeSelectoRequestId) detail.cancelled = true;
    }).catch(function () {}));
  });

  document.addEventListener("htmx:ws:after:message:incoming", function (event) {
    var incoming = event.detail && event.detail.message;
    if (incoming && typeof incoming.json === "function") {
      incoming.json().then(function (message) {
        var requestId = message && message.selecto && message.selecto.request_id;
        if (requestId && requestId === activeSelectoRequestId) activeSelectoRequestId = null;
        var nextUrl = message && message.selecto && message.selecto.url;
        if (message && message.selecto
            && typeof message.selecto.api_console_control === "string") {
          replaceApiConsoleControl(message.selecto.api_console_control);
        }
        if (message && message.selecto && message.selecto.performance) {
          selectoPerformance = message.selecto.performance;
          if (typeof message.selecto.query_summary === "string") {
            document.querySelectorAll("[data-sc-query-summary]").forEach(function (summary) {
              summary.outerHTML = message.selecto.query_summary;
            });
          }
          renderSelectoPerformance();
        }
        if (typeof nextUrl === "string" && nextUrl.charAt(0) === "/") {
          var currentUrl = window.location.pathname + window.location.search + window.location.hash;
          var pendingNavigation = window.history && window.history.state
            && window.history.state.selectoPendingNavigation;
          rememberSelectoHistory(nextUrl, !pendingNavigation && nextUrl !== currentUrl);
        }
      }).catch(function () {});
    }
    // htmx:after:swap below owns DOM initialization. Running it here as well
    // traversed the freshly inserted surface twice for every WebSocket reply.
  });

  document.addEventListener("htmx:after:swap", function () {
    restoreBuilderTabs();
    restoreBuilderTrays();
    restoreResultViews();
    restoreCharts();
    restoreGridSelections();
    if (selectoPerformance && selectoSwapStarted) {
      selectoPerformance.swap_ms = Math.round(performance.now() - selectoSwapStarted);
      selectoSwapStarted = 0;
    }
    renderSelectoPerformance();
  });

  document.addEventListener("htmx:before:swap", function (event) {
    selectoSwapStarted = performance.now();
    destroyChartsWithin(event.detail && event.detail.target);
  });

  function renderSelectoPerformance() {
    if (!selectoPerformance) return;
    var parts = [
      "HTML render: " + selectoPerformance.render_ms + " ms",
      "response: " + Number(selectoPerformance.response_chars || 0).toLocaleString() + " characters"
    ];
    if (selectoPerformance.swap_ms !== undefined) {
      parts.push("browser swap: " + selectoPerformance.swap_ms + " ms");
    }
    if (selectoPerformance.results_only) parts.push("results-only update");
    if (selectoPerformance.results_only) {
      document.querySelectorAll("[data-sc-builder]").forEach(function (builder) {
        builder.classList.remove("is-dirty");
        var pending = builder.querySelector("[data-sc-builder-pending]");
        if (pending) pending.textContent = "";
        var signature = builder.querySelector('[name="query_signature"]');
        if (signature && selectoPerformance.query_signature) {
          signature.value = selectoPerformance.query_signature;
        }
        var page = builder.querySelector('[name="page"]');
        if (page && selectoPerformance.page) page.value = selectoPerformance.page;
      });
    }
    document.querySelectorAll("[data-sc-client-performance]").forEach(function (node) {
      node.textContent = parts.join(" · ");
    });
    document.dispatchEvent(new CustomEvent("selecto:performance", {
      detail: Object.assign({}, selectoPerformance)
    }));
  }

  document.addEventListener("click", function (event) {
    var rowDialogClose = event.target.closest("[data-sc-row-dialog-close]");
    if (rowDialogClose) {
      var closingDialog = rowDialogClose.closest("[data-sc-row-dialog]");
      if (confirmEditorDiscard(closingDialog)) closeRowDialog(closingDialog);
      return;
    }
    var refreshResults = event.target.closest("[data-sc-refresh-results]");
    if (refreshResults) {
      window.location.reload();
      return;
    }
    var rowDialogNav = event.target.closest("[data-sc-row-dialog-nav]");
    if (rowDialogNav && !rowDialogNav.disabled) {
      moveRowDialog(
        rowDialogNav.closest("[data-sc-row-dialog]"),
        rowDialogNav.dataset.scRowDialogNav === "previous" ? -1 : 1
      );
      return;
    }
    var rowDialogBackdrop = event.target.closest("[data-sc-row-dialog]");
    if (rowDialogBackdrop && event.target === rowDialogBackdrop) {
      if (confirmEditorDiscard(rowDialogBackdrop)) closeRowDialog(rowDialogBackdrop);
      return;
    }
    var resultRow = event.target.closest("[data-sc-row-click]");
    if (resultRow && event.button === 0 && !event.defaultPrevented
        && !rowClickIsInteractive(event.target)) {
      var selection = window.getSelection && window.getSelection();
      if (!selection || selection.isCollapsed || !String(selection).length) openResultRow(resultRow);
      return;
    }
    var debugCopy = event.target.closest("[data-sc-debug-copy]");
    if (debugCopy) {
      copyDebugSql(debugCopy);
      return;
    }
    var gridClear = event.target.closest("[data-sc-grid-clear]");
    if (gridClear) {
      var gridRoot = gridClear.closest("[data-sc-grid-selection]");
      setGridCells(gridRoot, gridCells(gridRoot), false);
      updateGridSelection(gridRoot);
      return;
    }
    var toggle = event.target.closest("[data-sc-builder-toggle]");
    if (toggle) {
      var tray = builderTrayForToggle(toggle);
      if (tray) setBuilderTrayCollapsed(tray, !tray.classList.contains("is-collapsed"));
      return;
    }
    var tab = event.target.closest("[data-sc-builder-tab]");
    if (!tab) return;
    activateBuilderTab(tab.closest("[data-sc-builder-shell]"), tab.dataset.scBuilderTab);
  });

  document.addEventListener("keydown", function (event) {
    var rowDialog = event.target.closest && event.target.closest("[data-sc-row-dialog]");
    if (rowDialog && rowDialog.open && (event.key === "ArrowLeft" || event.key === "ArrowRight")) {
      event.preventDefault();
      moveRowDialog(rowDialog, event.key === "ArrowLeft" ? -1 : 1);
      return;
    }
    var resultRow = event.target.closest("[data-sc-row-click]");
    if (resultRow && event.target === resultRow && event.key === "Enter") {
      event.preventDefault();
      openResultRow(resultRow);
      return;
    }
    var tab = event.target.closest("[data-sc-builder-tab]");
    if (!tab || (event.key !== "ArrowLeft" && event.key !== "ArrowRight")) return;
    var root = tab.closest("[data-sc-builder-shell]");
    var tabs = Array.from(root.querySelectorAll("[data-sc-builder-tab]"));
    var offset = event.key === "ArrowRight" ? 1 : -1;
    var next = tabs[(tabs.indexOf(tab) + offset + tabs.length) % tabs.length];
    event.preventDefault();
    activateBuilderTab(root, next.dataset.scBuilderTab);
    next.focus();
  });

  document.addEventListener("load", function (event) {
    var frame = event.target;
    if (!frame.matches || !frame.matches("[data-sc-row-dialog-frame]")) return;
    frame.classList.remove("is-loading");
    var dialog = frame.closest("[data-sc-row-dialog]");
    var loading = dialog && dialog.querySelector("[data-sc-row-dialog-loading]");
    if (loading) loading.hidden = true;
    restoreRowDialogHostTitle(dialog, false);
  }, true);

  document.addEventListener("cancel", function (event) {
    if (event.target.matches && event.target.matches("[data-sc-row-dialog]")) {
      if (!confirmEditorDiscard(event.target)) {
        event.preventDefault();
        return;
      }
      clearRowDialog(event.target);
    }
  }, true);

  document.addEventListener("close", function (event) {
    if (event.target.matches && event.target.matches("[data-sc-row-dialog]")) {
      clearRowDialog(event.target);
    }
  }, true);
