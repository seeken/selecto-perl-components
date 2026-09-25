  function activateBuilderTab(root, name, remember) {
    if (!root) return;
    var key = root.dataset.scBuilderShell;
    var available = Array.from(root.querySelectorAll("[data-sc-builder-tab]"));
    if (!available.some(function (tab) { return tab.dataset.scBuilderTab === name; })) {
      name = "view";
    }
    if (remember !== false) activeBuilderTabs[key] = name;
    available.forEach(function (tab) {
      var selected = tab.dataset.scBuilderTab === name;
      tab.setAttribute("aria-selected", selected ? "true" : "false");
      tab.tabIndex = selected ? 0 : -1;
    });
    root.querySelectorAll("[data-sc-builder-panel]").forEach(function (panel) {
      panel.hidden = panel.dataset.scBuilderPanel !== name;
    });
    var query = root.querySelector("[data-sc-builder-query]");
    if (query) query.hidden = name === "saved";
  }

  function restoreBuilderTabs() {
    document.querySelectorAll("[data-sc-builder-shell]").forEach(function (root) {
      activateBuilderTab(root, activeBuilderTabs[root.dataset.scBuilderShell] || "view", false);
    });
  }

  function builderTrayForToggle(toggle) {
    var key = toggle && toggle.dataset.scBuilderId;
    return Array.from(document.querySelectorAll("[data-sc-builder-shell]")).find(function (root) {
      return root.dataset.scBuilderShell === key;
    });
  }

  function builderToggleForTray(root) {
    var key = root && root.dataset.scBuilderShell;
    return Array.from(document.querySelectorAll("[data-sc-builder-toggle]")).find(function (button) {
      return button.dataset.scBuilderId === key;
    });
  }

  function setBuilderTrayCollapsed(root, collapsed, remember) {
    if (!root) return;
    var key = root.dataset.scBuilderShell;
    if (remember !== false) collapsedBuilderTrays[key] = !!collapsed;
    root.classList.toggle("is-collapsed", !!collapsed);
    root.dataset.scBuilderCollapsed = collapsed ? "true" : "false";
    var workspace = root.closest("[data-sc-workspace]");
    if (workspace) workspace.classList.toggle("is-builder-collapsed", !!collapsed);
    var button = builderToggleForTray(root);
    if (button) {
      button.setAttribute("aria-expanded", collapsed ? "false" : "true");
      button.setAttribute("aria-label", collapsed ? "Expand view menu" : "Collapse view menu");
      var chevron = button.querySelector("[data-sc-builder-chevron]");
      if (chevron) chevron.textContent = collapsed ? "›" : "‹";
    }
  }

  function restoreBuilderTrays() {
    document.querySelectorAll("[data-sc-builder-shell]").forEach(function (root) {
      var key = root.dataset.scBuilderShell;
      var collapsed = Object.prototype.hasOwnProperty.call(collapsedBuilderTrays, key)
        ? collapsedBuilderTrays[key]
        : root.dataset.scBuilderCollapsed === "true";
      setBuilderTrayCollapsed(root, collapsed, false);
    });
  }

  function renderConnectionStatus() {
    // HTMX can report a message/swap error while the underlying transport is
    // still healthy, and a very fast connection can open before this bundle's
    // lifecycle listeners are installed. Prefer the socket's current state so
    // the badge describes connectivity instead of the last event observed.
    var liveSocket = Array.from(document.querySelectorAll('[hx-ws\\:connect]')).some(function (channel) {
      var connection = channel._htmx && channel._htmx.ws && channel._htmx.ws.connection;
      return connection && connection.socket
        && connection.socket.readyState === WebSocket.OPEN;
    });
    if (liveSocket) connectionStatus = "Live";
    document.querySelectorAll("[data-selecto-connection]").forEach(function (node) {
      node.textContent = connectionStatus;
      node.classList.toggle("is-live", connectionStatus === "Live");
    });
  }

  function markBuilderDirty(root) {
    if (!root) return;
    if (!root.matches("[data-sc-builder]")) root = root.closest("[data-sc-builder]");
    if (!root) return;
    root.classList.add("is-dirty");
    var pending = root.querySelector("[data-sc-builder-pending]");
    if (pending) pending.textContent = "Pending changes";
  }

  function showWorkspaceResultsLoading(workspace) {
    var results = workspace && workspace.querySelector(".sc-results");
    if (!results) return;
    destroyChartsWithin(results);
    results.setAttribute("aria-busy", "true");

    var loading = document.createElement("div");
    loading.className = "sc-results-loading";
    loading.dataset.scResultsLoading = "true";
    loading.setAttribute("role", "status");

    var spinner = document.createElement("span");
    spinner.className = "sc-results-spinner";
    spinner.setAttribute("aria-hidden", "true");
    var message = document.createElement("strong");
    message.textContent = "Running query…";
    var detail = document.createElement("span");
    detail.textContent = "Loading the new result set";
    loading.append(spinner, message, detail);
    results.replaceChildren(loading);
  }

  function showResultsLoading(form) {
    showWorkspaceResultsLoading(form && form.closest("[data-sc-workspace]"));
  }

  // Each result-view panel (detail; summary = aggregate/graph) carries hidden
  // copies of the other panel's selections, because only the active panel is
  // submitted. The copies come from the last server render, so refresh them
  // from the other panel's live controls before switching or submitting;
  // otherwise edits made in one view are lost when the query runs or is saved
  // from the other.
  var VIEW_PANEL_NAMES = {
    detail: ["field", "field_alias", "field_format", "row_click_action", "order", "direction"],
    summary: ["group", "group_alias", "group_format", "group_bucket_ranges", "group_prefix_length",
      "group_exclude_articles", "measure", "measure_alias", "measure_function", "measure_bucket_ranges",
      "measure_ignore_nulls", "measure_series_id", "measure_chart_type", "measure_axis", "measure_stack",
      "measure_color", "measure_transform", "measure_transform_window"]
  };

  function viewPanelValues(panel, names) {
    var values = [];
    Array.from(panel.querySelectorAll("input[name], select[name], textarea[name]")).forEach(function (control) {
      if (names.indexOf(control.name) < 0) return;
      if ((control.type === "checkbox" || control.type === "radio") && !control.checked) return;
      if (control.tagName === "SELECT" && control.multiple) {
        Array.from(control.selectedOptions).forEach(function (option) { values.push([control.name, option.value]); });
        return;
      }
      values.push([control.name, control.value]);
    });
    return values;
  }

  function syncViewPanelCopies(root) {
    if (!root) return;
    var panels = {};
    root.querySelectorAll("[data-sc-result-view-panel]").forEach(function (panel) {
      panels[panel.dataset.scResultViewPanel] = panel;
    });
    ["detail", "summary"].forEach(function (owner) {
      var source = panels[owner];
      var target = panels[owner === "detail" ? "summary" : "detail"];
      if (!source || !target) return;
      var names = VIEW_PANEL_NAMES[owner];
      var copies = Array.from(target.querySelectorAll('input[type="hidden"][name]')).filter(function (input) {
        return names.indexOf(input.name) >= 0;
      });
      // A panel that was never shown has no live controls of its own; keep its copies.
      var values = viewPanelValues(source, names);
      if (!values.length && copies.length) return;
      var anchor = copies.length ? copies[0] : null;
      var fragment = document.createDocumentFragment();
      values.forEach(function (pair) {
        var input = document.createElement("input");
        input.type = "hidden";
        input.name = pair[0];
        input.value = pair[1];
        input.setAttribute("data-sc-view-copy", owner);
        fragment.appendChild(input);
      });
      if (anchor) anchor.before(fragment); else target.appendChild(fragment);
      copies.forEach(function (input) { input.remove(); });
    });
  }

  document.addEventListener("submit", function (event) {
    var form = event.target;
    if (form && form.querySelector && form.querySelector("[data-sc-result-view-panel]")) {
      syncViewPanelCopies(form);
    }
  }, true);

  function stageResultView(root, view) {
    if (!root) return;
    syncViewPanelCopies(root);
    var mode = view === "detail" ? "detail" : "summary";
    root.querySelectorAll("[data-sc-result-view-panel]").forEach(function (panel) {
      var active = panel.dataset.scResultViewPanel === mode;
      panel.hidden = !active;
      panel.disabled = !active;
    });
    root.querySelectorAll("[data-sc-graph-options]").forEach(function (panel) {
      var graphActive = view === "graph";
      panel.hidden = !graphActive;
      panel.disabled = !graphActive;
    });
    root.querySelectorAll("[data-sc-aggregate-options]").forEach(function (panel) {
      var aggregateActive = view === "aggregate";
      panel.hidden = !aggregateActive;
      panel.disabled = !aggregateActive;
    });
    var graphActive = view === "graph";
    var limitLabel = root.querySelector("[data-sc-limit-label]");
    if (limitLabel) limitLabel.textContent = graphActive ? "Points" : "Rows";
    var pageControl = root.querySelector("[data-sc-page-control]");
    if (pageControl) {
      pageControl.hidden = graphActive;
      var pageInput = pageControl.querySelector('input[name="page"]');
      if (pageInput) {
        pageInput.disabled = graphActive;
        if (graphActive) pageInput.value = "1";
      }
    }
    var limit = root.querySelector("[data-sc-limit]");
    if (limit) {
      var options = Array.from(limit.options);
      options.forEach(function (option) {
        var tooSmall = Number(option.value) < 250;
        option.hidden = graphActive && tooSmall;
        option.disabled = graphActive && tooSmall;
      });
      if (graphActive && Number(limit.value) < 250) {
        var next = options.find(function (option) { return Number(option.value) >= 500; }) ||
          options.find(function (option) { return Number(option.value) >= 250; }) ||
          options[options.length - 1];
        if (next) limit.value = next.value;
      }
    }
    root.querySelectorAll("[data-sc-picker-root]").forEach(refreshColumnPicker);
    root.querySelectorAll("[data-sc-filter-root]").forEach(refreshFilterPicker);
  }

  function restoreResultViews() {
    document.querySelectorAll("[data-sc-builder]").forEach(function (root) {
      var selected = root.querySelector('input[name="view"]:checked');
      if (selected) stageResultView(root, selected.value);
      else {
        root.querySelectorAll("[data-sc-picker-root]").forEach(refreshColumnPicker);
        root.querySelectorAll("[data-sc-filter-root]").forEach(refreshFilterPicker);
      }
    });
  }
