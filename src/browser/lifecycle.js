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

  document.addEventListener("htmx:ws:close", function (event) {
    var closeCode = event.detail && event.detail.code;
    connectionStatus = closeCode === 1008 ? "Unavailable" : "Reconnecting";
    renderConnectionStatus();
    if (closeCode === 1008) return;
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
      if (websocketForm.hasAttribute("data-selecto-template-event")) {
        if (usesSelectoWebSocket(websocketForm)) {
          event.preventDefault();
          return;
        }
        event.preventDefault();
        event.stopImmediatePropagation();
        submitWithoutWebSocket(websocketForm);
        return;
      }
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

  function normalizedTemplateRevision(value) {
    if (typeof value === "number") {
      if (!Number.isSafeInteger(value) || value < 0) return null;
      value = String(value);
    }
    if (typeof value !== "string" || !/^\d+$/.test(value)) return null;
    return value.replace(/^0+(?=\d)/, "");
  }

  function compareTemplateRevisions(left, right) {
    if (left.length !== right.length) return left.length < right.length ? -1 : 1;
    if (left === right) return 0;
    return left < right ? -1 : 1;
  }

  var pendingTemplateControlSnapshots = new Map();

  function templateControlKey(control) {
    if (!(control instanceof Element)
        || !control.matches("input, select, textarea")) return null;
    var field = control.getAttribute("data-selecto-template-field");
    if (field) return "field:" + field;
    return control.id ? "id:" + control.id : null;
  }

  function templateControlState(control) {
    if (control instanceof HTMLInputElement) {
      if (control.type === "file" || control.type === "hidden") return null;
      if (control.type === "checkbox" || control.type === "radio") {
        return {kind: "checked", checked: control.checked};
      }
    }
    if (control instanceof HTMLSelectElement && control.multiple) {
      return {
        kind: "selected",
        values: Array.from(control.selectedOptions, function (option) {
          return option.value;
        })
      };
    }
    return {kind: "value", value: control.value};
  }

  function templateEventForm(root, eventId) {
    if (!eventId) return null;
    for (var input of root.querySelectorAll('form input[name="event_id"]')) {
      if (input.value === eventId) return input.form;
    }
    return null;
  }

  function templateControlMap(root) {
    var controls = new Map();
    var duplicates = new Set();
    for (var control of root.querySelectorAll("input, select, textarea")) {
      var key = templateControlKey(control);
      if (!key || duplicates.has(key)) continue;
      if (controls.has(key)) {
        controls.delete(key);
        duplicates.add(key);
      } else {
        controls.set(key, control);
      }
    }
    return controls;
  }

  function captureTemplateControls(root, metadata) {
    if (!root) return null;
    var controls = templateControlMap(root);
    var submittedForm = templateEventForm(root, metadata && metadata.event_id);
    var values = [];
    controls.forEach(function (control, key) {
      if (!control.hasAttribute("data-selecto-template-dirty")
          || (submittedForm && submittedForm.contains(control))) return;
      var state = templateControlState(control);
      if (state) values.push({key: key, state: state});
    });
    var active = document.activeElement;
    var focus = null;
    if (active && root.contains(active)) {
      var activeKey = templateControlKey(active);
      if (activeKey && controls.get(activeKey) === active) {
        focus = {key: activeKey};
        try {
          if (typeof active.selectionStart === "number") {
            focus.start = active.selectionStart;
            focus.end = active.selectionEnd;
            focus.direction = active.selectionDirection;
          }
        } catch (_error) {}
      }
    }
    return {
      instance_id: root.dataset.selectoTemplateInstance,
      values: values,
      focus: focus
    };
  }

  function restoreTemplateControls(snapshot) {
    if (!snapshot || typeof snapshot.instance_id !== "string") return;
    var root = templateRootForInstance(snapshot.instance_id);
    if (!root) return;
    var controls = templateControlMap(root);
    snapshot.values.forEach(function (entry) {
      var control = controls.get(entry.key);
      if (!control) return;
      if (entry.state.kind === "checked") control.checked = entry.state.checked;
      else if (entry.state.kind === "selected" && control instanceof HTMLSelectElement) {
        var selected = new Set(entry.state.values);
        for (var option of control.options) option.selected = selected.has(option.value);
      } else if (entry.state.kind === "value") control.value = entry.state.value;
      else return;
      control.setAttribute("data-selecto-template-dirty", "true");
    });
    var focus = snapshot.focus;
    var focused = focus && controls.get(focus.key);
    if (!focused) return;
    try { focused.focus({preventScroll: true}); }
    catch (_error) { focused.focus(); }
    if (typeof focus.start === "number" && focused.setSelectionRange) {
      try { focused.setSelectionRange(focus.start, focus.end, focus.direction); }
      catch (_error) {}
    }
  }

  function templateResponseKey(metadata) {
    if (!metadata || typeof metadata.instance_id !== "string") return null;
    var state = normalizedTemplateRevision(metadata.state_revision);
    var store = normalizedTemplateRevision(metadata.store_revision);
    return state === null || store === null
      ? null : metadata.instance_id + "\u0000" + state + "\u0000" + store;
  }

  document.addEventListener("input", function (event) {
    var control = event.target;
    if (!templateControlKey(control)
        || !control.closest("[data-selecto-template-instance]")) return;
    control.setAttribute("data-selecto-template-dirty", "true");
  });

  document.addEventListener("change", function (event) {
    var control = event.target;
    if (!templateControlKey(control)
        || !control.closest("[data-selecto-template-instance]")) return;
    control.setAttribute("data-selecto-template-dirty", "true");
  });

  function templateRootForInstance(instanceId, target) {
    if (target !== undefined) {
      if (!(target instanceof Element)) return null;
      var targetedRoot = target.closest("[data-selecto-template-instance]");
      if (targetedRoot
          && targetedRoot.dataset.selectoTemplateInstance === instanceId) {
        return targetedRoot;
      }
      return null;
    }
    for (var candidate of document.querySelectorAll("[data-selecto-template-instance]")) {
      if (candidate.dataset.selectoTemplateInstance === instanceId) return candidate;
    }
    return null;
  }

  function templateResponseIsStale(metadata, target) {
    if (!metadata || typeof metadata.instance_id !== "string") return false;
    if (metadata.state_revision === undefined || metadata.store_revision === undefined) {
      return false;
    }
    var incomingState = normalizedTemplateRevision(metadata.state_revision);
    var incomingStore = normalizedTemplateRevision(metadata.store_revision);
    if (incomingState === null || incomingStore === null) return true;
    var root = templateRootForInstance(metadata.instance_id, target);
    if (!root) return true;
    var currentState = normalizedTemplateRevision(root.dataset.selectoStateRevision);
    var currentStore = normalizedTemplateRevision(root.dataset.selectoStoreRevision);
    if (currentState === null || currentStore === null) return false;
    return compareTemplateRevisions(incomingStore, currentStore) < 0
      || compareTemplateRevisions(incomingState, currentState) < 0;
  }

  function httpTemplateMetadata(ctx) {
    var headers = ctx && ctx.response && ctx.response.raw && ctx.response.raw.headers;
    if (!headers || typeof headers.get !== "function") return null;
    var instanceId = headers.get("X-Selecto-Template-Instance");
    var stateRevision = headers.get("X-Selecto-State-Revision");
    var storeRevision = headers.get("X-Selecto-Store-Revision");
    if (instanceId === null || stateRevision === null || storeRevision === null) return null;
    return {
      instance_id: instanceId,
      state_revision: stateRevision,
      store_revision: storeRevision,
      event_id: headers.get("X-Selecto-Event-ID"),
      source_id: headers.get("X-Selecto-Source"),
      source_generation: headers.get("X-Selecto-Source-Generation")
    };
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
      var target;
      if (message && typeof message.target === "string") {
        try { target = document.querySelector(message.target); }
        catch (_error) { target = null; }
      }
      var metadata = message && message.selecto;
      if (templateResponseIsStale(metadata, target)) {
        detail.cancelled = true;
        return;
      }
      var key = templateResponseKey(metadata);
      if (key) {
        pendingTemplateControlSnapshots.set(
          key,
          captureTemplateControls(
            templateRootForInstance(metadata.instance_id, target), metadata
          )
        );
        while (pendingTemplateControlSnapshots.size > 32) {
          pendingTemplateControlSnapshots.delete(
            pendingTemplateControlSnapshots.keys().next().value
          );
        }
      }
    }).catch(function () {}));
  });

  document.addEventListener("htmx:ws:after:message:incoming", function (event) {
    var incoming = event.detail && event.detail.message;
    if (incoming && typeof incoming.json === "function") {
      incoming.json().then(function (message) {
        var templateKey = templateResponseKey(message && message.selecto);
        if (templateKey) {
          var controlSnapshot = pendingTemplateControlSnapshots.get(templateKey);
          pendingTemplateControlSnapshots.delete(templateKey);
          restoreTemplateControls(controlSnapshot);
        }
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

  document.addEventListener("htmx:after:swap", function (event) {
    var ctx = event.detail && event.detail.ctx;
    restoreTemplateControls(ctx && ctx.selectoTemplateControlSnapshot);
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
    var ctx = event.detail && event.detail.ctx;
    var metadata = httpTemplateMetadata(ctx);
    if (templateResponseIsStale(metadata, ctx && ctx.target)) {
      event.preventDefault();
      return;
    }
    if (metadata) {
      ctx.selectoTemplateControlSnapshot = captureTemplateControls(
        templateRootForInstance(metadata.instance_id, ctx.target), metadata
      );
    }
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
