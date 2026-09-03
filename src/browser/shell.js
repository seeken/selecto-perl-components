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

  function stageResultView(root, view) {
    if (!root) return;
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
    root.querySelectorAll("[data-sc-picker-root]").forEach(refreshColumnPicker);
  }

  function restoreResultViews() {
    document.querySelectorAll("[data-sc-builder]").forEach(function (root) {
      var selected = root.querySelector('input[name="view"]:checked');
      if (selected) stageResultView(root, selected.value);
    });
  }
