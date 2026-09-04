  document.addEventListener("DOMContentLoaded", function () {
    rememberSelectoHistory(window.location.pathname + window.location.search + window.location.hash, false);
    renderConnectionStatus();
    restoreBuilderTabs();
    restoreBuilderTrays();
    restoreResultViews();
    restoreCharts();
    restoreGridSelections();
  });

  window.addEventListener("pageshow", function (event) {
    if (!event.persisted) return;
    reconnectRestoredWebSocketChannels();
  });

  window.addEventListener("pagehide", function () {
    rememberSelectoHistory(window.location.pathname + window.location.search + window.location.hash, false);
  });

  window.addEventListener("popstate", function (event) {
    restoreSelectoHistory(event.state);
  });

  function rememberSelectoHistory(url, push) {
    var surface = document.querySelector('[id^="selecto-surface-"]');
    if (!surface || !window.history) return;
    var state = window.history.state && typeof window.history.state === "object"
      ? Object.assign({}, window.history.state) : {};
    var key = push ? null : state.selectoSnapshot;
    if (!key) key = "selecto-" + Date.now() + "-" + (++selectoHistoryCounter);
    selectoHistorySnapshots.delete(key);
    selectoHistorySnapshots.set(key, surface.outerHTML);
    while (selectoHistorySnapshots.size > 24) {
      selectoHistorySnapshots.delete(selectoHistorySnapshots.keys().next().value);
    }
    state.selecto = true;
    state.selectoSnapshot = key;
    try {
      if (push) window.history.pushState(state, "", url);
      else window.history.replaceState(state, "", url);
    } catch (_error) {}
  }

  function restoreSelectoHistory(state) {
    var key = state && state.selectoSnapshot;
    var snapshot = key && selectoHistorySnapshots.get(key);
    if (!snapshot) return;
    var current = document.querySelector('[id^="selecto-surface-"]');
    if (!current) return;
    var template = document.createElement("template");
    template.innerHTML = snapshot.trim();
    var restored = template.content.firstElementChild;
    if (!restored) return;
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

  function reconnectRestoredWebSocketChannels() {
    connectionStatus = "Connecting";
    document.querySelectorAll('[id^="selecto-channel-"][hx-ws\\:connect]').forEach(function (channel) {
      var replacement = channel.cloneNode(false);
      while (channel.firstChild) replacement.appendChild(channel.firstChild);
      channel.replaceWith(replacement);
      if (window.htmx && typeof window.htmx.process === "function") {
        window.htmx.process(replacement);
      }
    });
    renderConnectionStatus();
  }

  document.addEventListener("htmx:ws:after:connection", function () {
    connectionStatus = "Live";
    renderConnectionStatus();
  });

  document.addEventListener("htmx:ws:close", function () {
    connectionStatus = "Reconnecting";
    renderConnectionStatus();
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
      if (connection && connection.classList.contains("is-live")) {
        window.setTimeout(function () { showWorkspaceResultsLoading(workspace); }, 0);
        return;
      }
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
    if (connection && connection.classList.contains("is-live")) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    submitWithoutWebSocket(form, "Running…");
  }, true);

  function submitWithoutWebSocket(form, buttonLabel) {
    if (!form || form.dataset.scHttpSubmitting === "true") return;
    form.dataset.scHttpSubmitting = "true";
    var button = form.querySelector('button[type="submit"]');
    if (button) {
      button.disabled = true;
      if (buttonLabel) button.textContent = buttonLabel;
    }
    HTMLFormElement.prototype.submit.call(form);
  }

  document.addEventListener("htmx:ws:after:message:incoming", function (event) {
    var incoming = event.detail && event.detail.message;
    if (incoming && typeof incoming.json === "function") {
      incoming.json().then(function (message) {
        var nextUrl = message && message.selecto && message.selecto.url;
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
          rememberSelectoHistory(nextUrl, nextUrl !== currentUrl);
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
      closeRowDialog(rowDialogClose.closest("[data-sc-row-dialog]"));
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
      closeRowDialog(rowDialogBackdrop);
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
  }, true);

  document.addEventListener("cancel", function (event) {
    if (event.target.matches && event.target.matches("[data-sc-row-dialog]")) {
      clearRowDialog(event.target);
    }
  }, true);

  document.addEventListener("close", function (event) {
    if (event.target.matches && event.target.matches("[data-sc-row-dialog]")) {
      clearRowDialog(event.target);
    }
  }, true);
