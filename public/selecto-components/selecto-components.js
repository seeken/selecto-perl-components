(function () {
  "use strict";

  // Source: shared.js
  var activeBuilderTabs = Object.create(null);
  var collapsedBuilderTrays = Object.create(null);
  var connectionStatus = "Connecting";
  var chartInstances = new WeakMap();
  var selectoPerformance = null;
  var selectoSwapStarted = 0;
  var dateFormats = [
    ["day", "Day"], ["day_hour", "Day + Hour"], ["week", "Week"],
    ["month", "Month"], ["quarter", "Quarter"], ["year", "Year"],
    ["month_of_year", "Month of Year"], ["day_of_month", "Day of Month"],
    ["day_of_week", "Day of Week"], ["hour", "Hour of Day"]
  ];

  // Source: shell.js
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

  // Source: charts.js
  function chartJsType(type) {
    if (type === "area") return "line";
    if (type === "horizontal_bar" || type === "stacked_bar") return "bar";
    return type;
  }

  function chartColorWithAlpha(color, alpha) {
    var match = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(color || "");
    if (!match) return color;
    return "rgba(" + parseInt(match[1], 16) + "," + parseInt(match[2], 16) + "," +
      parseInt(match[3], 16) + "," + alpha + ")";
  }

  function chartOptions(root, type) {
    var styles = window.getComputedStyle(root);
    var ink = styles.getPropertyValue("--sc-ink").trim() || "#dce6e8";
    var muted = styles.getPropertyValue("--sc-muted").trim() || "#9fb0b3";
    var border = styles.getPropertyValue("--sc-border").trim() || "#9fb0b3";
    var options = {
      responsive: true,
      maintainAspectRatio: false,
      interaction: {mode: "nearest", intersect: true},
      plugins: {
        legend: {labels: {color: ink, usePointStyle: true}},
        tooltip: {callbacks: {title: function (items) {
          if (!items.length) return "";
          var raw = items[0].raw;
          return raw && raw.label ? raw.label : items[0].label;
        }}}
      },
      onClick: function (_event, elements) {
        if (!elements.length) return;
        var form = root.querySelector('[data-sc-graph-drilldown="' + elements[0].index + '"]');
        if (!form) return;
        if (typeof form.requestSubmit === "function") form.requestSubmit();
        else form.submit();
      }
    };
    if (type !== "pie" && type !== "doughnut") {
      var axis = {
        ticks: {color: muted},
        grid: {color: chartColorWithAlpha(border, 0.45)},
        border: {color: border}
      };
      options.scales = {x: Object.assign({}, axis), y: Object.assign({}, axis, {beginAtZero: true})};
    }
    if (type === "horizontal_bar") options.indexAxis = "y";
    if (type === "stacked_bar") {
      options.scales.x.stacked = true;
      options.scales.y.stacked = true;
    }
    return options;
  }

  function initializeChart(root) {
    if (!root || chartInstances.has(root) || !window.Chart) return;
    var canvas = root.querySelector("canvas");
    if (!canvas) return;
    var type = root.dataset.chartType || "bar";
    var data;
    try {
      data = JSON.parse(root.dataset.chartData || "{}");
    } catch (_error) {
      return;
    }
    var styles = window.getComputedStyle(root);
    var brand = styles.getPropertyValue("--sc-brand").trim();
    (data.datasets || []).forEach(function (dataset, index) {
      if (brand && index === 0 && type !== "pie" && type !== "doughnut") {
        dataset.borderColor = brand;
        dataset.backgroundColor = brand;
      }
      if (type === "line" || type === "area") dataset.tension = 0.28;
      if (type === "area") {
        dataset.fill = "origin";
        dataset.backgroundColor = chartColorWithAlpha(dataset.borderColor, 0.22);
      }
      if (type === "scatter") {
        dataset.pointRadius = 5;
        dataset.pointHoverRadius = 7;
        dataset.showLine = false;
      }
    });
    try {
      var chart = new window.Chart(canvas, {
        type: chartJsType(type),
        data: data,
        options: chartOptions(root, type)
      });
      chartInstances.set(root, chart);
      root.classList.add("is-ready");
    } catch (_error) {
      root.classList.remove("is-ready");
    }
  }

  function restoreCharts() {
    var roots = Array.from(document.querySelectorAll("[data-sc-chart]"));
    if (!roots.length) return;
    if (window.Chart) {
      roots.forEach(initializeChart);
      return;
    }
    loadChartLibrary(roots[0]).then(function () {
      roots.filter(function (root) { return root.isConnected; }).forEach(initializeChart);
    }).catch(function () {});
  }

  function destroyChartsWithin(node) {
    if (!node || !node.querySelectorAll) return;
    var roots = Array.from(node.querySelectorAll("[data-sc-chart]"));
    if (node.matches && node.matches("[data-sc-chart]")) roots.unshift(node);
    roots.forEach(function (root) {
      var chart = chartInstances.get(root);
      if (chart) chart.destroy();
      chartInstances.delete(root);
    });
  }

  function copyDebugSql(button) {
    var target = document.getElementById(button.dataset.scDebugCopy || "");
    if (!target) return;
    var text = target.textContent || "";
    var copied = function () {
      var original = button.dataset.scOriginalLabel || button.textContent;
      button.dataset.scOriginalLabel = original;
      button.textContent = "Copied";
      window.setTimeout(function () { button.textContent = original; }, 1600);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(copied).catch(function () {});
      return;
    }
    var fallback = document.createElement("textarea");
    fallback.value = text;
    fallback.setAttribute("readonly", "");
    fallback.style.position = "fixed";
    fallback.style.opacity = "0";
    document.body.appendChild(fallback);
    fallback.select();
    try { if (document.execCommand("copy")) copied(); } catch (_error) {}
    fallback.remove();
  }
  var chartLoadPromise;

  function loadChartLibrary(root) {
    if (window.Chart) return Promise.resolve();
    if (chartLoadPromise) return chartLoadPromise;
    var surface = root && root.closest("[data-sc-chart-src]");
    var source = surface && surface.dataset.scChartSrc;
    if (!source) return Promise.reject(new Error("Chart library URL is unavailable"));
    chartLoadPromise = new Promise(function (resolve, reject) {
      var script = document.createElement("script");
      script.src = source;
      script.async = true;
      script.onload = resolve;
      script.onerror = function () {
        chartLoadPromise = null;
        reject(new Error("Chart library could not be loaded"));
      };
      document.head.appendChild(script);
    });
    return chartLoadPromise;
  }

  // Source: row-dialog.js
  function rowClickIsInteractive(target) {
    return !!target.closest(
      "a,button,input,select,textarea,label,summary,[role=button],[contenteditable=true]"
    );
  }

  function openResultRow(row) {
    var url = row && row.dataset.scRowClickUrl;
    if (!url) return;
    if (row.dataset.scRowClickType === "iframe_modal") {
      openRowDialog(row);
      return;
    }
    var target = row.dataset.scRowClickTarget || "_self";
    if (target === "_blank") {
      window.open(url, "_blank", "noopener,noreferrer");
      return;
    }
    if (target === "_parent") {
      window.parent.location.assign(url);
      return;
    }
    if (target === "_top") {
      window.top.location.assign(url);
      return;
    }
    window.location.assign(url);
  }

  function rowDialogRows(dialog) {
    if (!dialog) return [];
    var root = dialog.closest(".sc-results") || document;
    return Array.from(root.querySelectorAll('[data-sc-row-click-type="iframe_modal"]')).filter(
      function (row) { return row.dataset.scRowDialogId === dialog.id; }
    );
  }

  function setRowDialogIndex(dialog, index) {
    var rows = rowDialogRows(dialog);
    if (!rows.length) return;
    var nextIndex = Math.max(0, Math.min(Number(index) || 0, rows.length - 1));
    var row = rows[nextIndex];
    var url = row.dataset.scRowClickUrl || "";
    var title = row.dataset.scRowClickTitle || "Details";
    var heading = dialog.querySelector("[data-sc-row-dialog-title]");
    var frame = dialog.querySelector("[data-sc-row-dialog-frame]");
    var loading = dialog.querySelector("[data-sc-row-dialog-loading]");
    var fullPage = dialog.querySelector("[data-sc-row-dialog-open]");
    var position = dialog.querySelector("[data-sc-row-dialog-position]");
    var previous = dialog.querySelector('[data-sc-row-dialog-nav="previous"]');
    var next = dialog.querySelector('[data-sc-row-dialog-nav="next"]');
    dialog.dataset.scRowDialogIndex = String(nextIndex);
    if (heading) heading.textContent = title;
    if (fullPage) fullPage.href = url;
    if (position) position.textContent = "Row " + (nextIndex + 1) + " of " + rows.length + " on this page";
    if (previous) previous.disabled = nextIndex === 0;
    if (next) next.disabled = nextIndex === rows.length - 1;
    if (frame) {
      frame.title = title;
      if (frame.getAttribute("src") !== url) {
        if (loading) loading.hidden = false;
        frame.classList.add("is-loading");
        frame.setAttribute("src", url);
      }
    }
  }

  function openRowDialog(row) {
    var dialog = document.getElementById(row && row.dataset.scRowDialogId || "");
    if (!dialog) return;
    var rows = rowDialogRows(dialog);
    var index = rows.indexOf(row);
    if (index < 0) return;
    setRowDialogIndex(dialog, index);
    if (!dialog.open) {
      if (typeof dialog.showModal === "function") dialog.showModal();
      else dialog.setAttribute("open", "");
    }
  }

  function moveRowDialog(dialog, offset) {
    if (!dialog) return;
    var current = Number(dialog.dataset.scRowDialogIndex || 0);
    setRowDialogIndex(dialog, current + offset);
  }

  function clearRowDialog(dialog) {
    if (!dialog) return;
    var frame = dialog.querySelector("[data-sc-row-dialog-frame]");
    var loading = dialog.querySelector("[data-sc-row-dialog-loading]");
    if (frame) {
      frame.removeAttribute("src");
      frame.classList.remove("is-loading");
    }
    if (loading) loading.hidden = true;
    delete dialog.dataset.scRowDialogIndex;
  }

  function closeRowDialog(dialog) {
    if (!dialog) return;
    clearRowDialog(dialog);
    if (typeof dialog.close === "function") dialog.close();
    else dialog.removeAttribute("open");
  }

  // Source: grid.js
  function gridCells(root, selector) {
    var cells = Array.from(root.querySelectorAll("[data-sc-grid-cell]"));
    return selector ? cells.filter(selector) : cells;
  }

  function gridIndex(root) {
    var cells = gridCells(root);
    var rows = new Map();
    var columns = new Map();
    cells.forEach(function (cell) {
      var row = cell.dataset.scGridRow;
      var column = cell.dataset.scGridColumn;
      if (!rows.has(row)) rows.set(row, []);
      if (!columns.has(column)) columns.set(column, []);
      rows.get(row).push(cell);
      columns.get(column).push(cell);
    });
    return {cells: cells, rows: rows, columns: columns};
  }

  function clearGridAxisHover(root) {
    if (!root) return;
    root.querySelectorAll(".is-grid-axis-hover").forEach(function (header) {
      header.classList.remove("is-grid-axis-hover");
    });
  }

  function showGridAxisHover(cell) {
    var root = cell && cell.closest("[data-sc-grid-selection]");
    if (!root) return;
    clearGridAxisHover(root);
    var rowToggle = root.querySelector('[data-sc-grid-row-toggle="' + cell.dataset.scGridRow + '"]');
    var columnToggle = root.querySelector('[data-sc-grid-column-toggle="' + cell.dataset.scGridColumn + '"]');
    if (rowToggle && rowToggle.closest("th")) rowToggle.closest("th").classList.add("is-grid-axis-hover");
    if (columnToggle && columnToggle.closest("th")) columnToggle.closest("th").classList.add("is-grid-axis-hover");
  }

  document.addEventListener("mouseover", function (event) {
    var cell = event.target.closest && event.target.closest(".sc-aggregate-grid td[data-sc-grid-row][data-sc-grid-column]");
    if (!cell || (event.relatedTarget && cell.contains(event.relatedTarget))) return;
    showGridAxisHover(cell);
  });

  document.addEventListener("mouseout", function (event) {
    var cell = event.target.closest && event.target.closest(".sc-aggregate-grid td[data-sc-grid-row][data-sc-grid-column]");
    if (!cell || (event.relatedTarget && cell.contains(event.relatedTarget))) return;
    clearGridAxisHover(cell.closest("[data-sc-grid-selection]"));
  });

  document.addEventListener("focusin", function (event) {
    if (event.target.matches && event.target.matches("[data-sc-grid-cell]")) showGridAxisHover(event.target);
  });

  document.addEventListener("focusout", function (event) {
    if (event.target.matches && event.target.matches("[data-sc-grid-cell]")) {
      clearGridAxisHover(event.target.closest("[data-sc-grid-selection]"));
    }
  });

  function gridSelectionPlan(root, index) {
    index = index || gridIndex(root);
    var selected = index.cells.filter(function (cell) { return cell.checked; });
    var uncovered = new Set(selected);
    var candidates = [];
    root.querySelectorAll("[data-sc-grid-row-toggle], [data-sc-grid-column-toggle]").forEach(function (toggle) {
      var cells = toggle.matches("[data-sc-grid-row-toggle]")
        ? (index.rows.get(toggle.dataset.scGridRowToggle) || [])
        : (index.columns.get(toggle.dataset.scGridColumnToggle) || []);
      if (cells.length && cells.every(function (cell) { return cell.checked; })) {
        candidates.push({toggle: toggle, cells: cells});
      }
    });
    var axes = [];
    while (true) {
      var best = null;
      var bestCoverage = 0;
      candidates.forEach(function (candidate) {
        var coverage = candidate.cells.filter(function (cell) { return uncovered.has(cell); }).length;
        if (coverage > bestCoverage) {
          best = candidate;
          bestCoverage = coverage;
        }
      });
      if (!best) break;
      axes.push(best.toggle);
      best.cells.forEach(function (cell) { uncovered.delete(cell); });
      candidates = candidates.filter(function (candidate) { return candidate !== best; });
    }
    return {axes: axes, cells: Array.from(uncovered), clauseCount: axes.length + uncovered.size};
  }

  function setGridCells(root, cells, checked) {
    var maximum = Number(root.dataset.scGridMax || 50);
    var previous = cells.map(function (cell) { return cell.checked; });
    cells.forEach(function (cell) {
      cell.checked = !!checked;
    });
    var plan = gridSelectionPlan(root);
    if (checked && plan.clauseCount > maximum) {
      cells.forEach(function (cell, index) { cell.checked = previous[index]; });
      root.dataset.scGridSelectionError = "That selection would create " + plan.clauseCount +
        " filter groups; the limit is " + maximum + ". Clear some cells and try again.";
      return false;
    }
    delete root.dataset.scGridSelectionError;
    return true;
  }

  function syncGridAxisToggle(toggle, cells) {
    var selected = cells.filter(function (cell) { return cell.checked; }).length;
    toggle.checked = cells.length > 0 && selected === cells.length;
    toggle.indeterminate = selected > 0 && selected < cells.length;
  }

  function updateGridSelection(root) {
    if (!root) return;
    var index = gridIndex(root);
    var cells = index.cells;
    var selected = cells.filter(function (cell) { return cell.checked; });
    var plan = gridSelectionPlan(root, index);
    var maximum = Number(root.dataset.scGridMax || 50);
    var count = root.querySelector("[data-sc-grid-selection-count]");
    var label = root.querySelector("[data-sc-grid-selection-label]");
    var apply = root.querySelector("[data-sc-grid-apply]");
    var clear = root.querySelector("[data-sc-grid-clear]");
    var help = root.querySelector("[data-sc-grid-selection-help]");
    if (count) count.textContent = selected.length;
    if (label) label.textContent = selected.length === 1 ? "cell selected" : "cells selected";
    if (apply) apply.disabled = selected.length === 0;
    if (clear) clear.disabled = selected.length === 0;
    if (help) {
      var selectionError = root.dataset.scGridSelectionError || "";
      help.textContent = selectionError || ("Selected cells compile to " + plan.clauseCount + " of " + maximum +
        " filter groups. Full rows and columns become one condition; remaining cells use paired conditions.");
      help.classList.toggle("is-error", !!selectionError);
    }
    root.querySelectorAll("[data-sc-grid-row-toggle]").forEach(function (toggle) {
      syncGridAxisToggle(toggle, index.rows.get(toggle.dataset.scGridRowToggle) || []);
    });
    root.querySelectorAll("[data-sc-grid-column-toggle]").forEach(function (toggle) {
      syncGridAxisToggle(toggle, index.columns.get(toggle.dataset.scGridColumnToggle) || []);
    });
    var all = root.querySelector("[data-sc-grid-toggle-all]");
    if (all) syncGridAxisToggle(all, cells);
  }

  function restoreGridSelections() {
    document.querySelectorAll("[data-sc-grid-selection]").forEach(updateGridSelection);
  }

  document.addEventListener("change", function (event) {
    var root = event.target.closest && event.target.closest("[data-sc-grid-selection]");
    if (!root) return;
    if (event.target.matches("[data-sc-grid-cell]")) {
      var maximum = Number(root.dataset.scGridMax || 50);
      var plan = gridSelectionPlan(root);
      if (event.target.checked && plan.clauseCount > maximum) {
        event.target.checked = false;
        root.dataset.scGridSelectionError = "The limit is " + maximum +
          " filter groups. Complete a row or column, or clear a cell before choosing another.";
      } else {
        delete root.dataset.scGridSelectionError;
      }
    } else if (event.target.matches("[data-sc-grid-row-toggle]")) {
      setGridCells(root,
        gridIndex(root).rows.get(event.target.dataset.scGridRowToggle) || [],
        event.target.checked);
    } else if (event.target.matches("[data-sc-grid-column-toggle]")) {
      setGridCells(root,
        gridIndex(root).columns.get(event.target.dataset.scGridColumnToggle) || [],
        event.target.checked);
    } else if (event.target.matches("[data-sc-grid-toggle-all]")) {
      setGridCells(root, gridCells(root), event.target.checked);
    } else {
      return;
    }
    updateGridSelection(root);
  });

  document.addEventListener("submit", function (event) {
    var root = event.target.closest && event.target.closest("[data-sc-grid-selection]");
    if (!root) return;
    var plan = gridSelectionPlan(root);
    var controls = Array.from(root.querySelectorAll("[data-sc-grid-cell], [name='grid_axis']"));
    controls.forEach(function (control) { control.disabled = true; });
    plan.axes.forEach(function (axis) {
      var input = document.createElement("input");
      input.type = "hidden";
      input.name = "grid_axis";
      input.value = axis.value;
      input.dataset.scGridCompactInput = "";
      root.appendChild(input);
    });
    plan.cells.forEach(function (cell) {
      var input = document.createElement("input");
      input.type = "hidden";
      input.name = "grid_cell";
      input.value = cell.value;
      input.dataset.scGridCompactInput = "";
      root.appendChild(input);
    });
    window.setTimeout(function () {
      controls.forEach(function (control) { control.disabled = false; });
      root.querySelectorAll("[data-sc-grid-compact-input]").forEach(function (input) { input.remove(); });
    }, 0);
  }, true);

  // Source: lifecycle.js
  document.addEventListener("DOMContentLoaded", function () {
    renderConnectionStatus();
    restoreBuilderTabs();
    restoreBuilderTrays();
    restoreResultViews();
    restoreCharts();
    restoreGridSelections();
  });

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
      var websocketConnection = document.querySelector("[data-selecto-connection]");
      if (websocketConnection && websocketConnection.classList.contains("is-live")) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      submitWithoutWebSocket(websocketForm);
      return;
    }
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
        if (typeof nextUrl === "string" && nextUrl.charAt(0) === "/") {
          window.history.replaceState({selecto: true}, "", nextUrl);
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

  // Source: picker.js
  function setItems(root) {
    return Array.from(root.querySelectorAll("[data-sc-picker-set-item]"));
  }

  function appendLabel(parent, label, type, className) {
    var wrapper = document.createElement("span");
    if (className) wrapper.className = className;
    var strong = document.createElement("strong");
    strong.textContent = label;
    var small = document.createElement("small");
    small.textContent = type;
    wrapper.appendChild(strong);
    wrapper.appendChild(small);
    parent.appendChild(wrapper);
    return wrapper;
  }

  function createAvailableChoice(kind, field, label, type, metadata) {
    metadata = metadata || {};
    var choice = document.createElement("button");
    choice.className = "sc-picker-choice";
    choice.type = "button";
    choice.dataset.field = field;
    choice.dataset.label = label;
    choice.dataset.type = type;
    choice.dataset.search = (label + " " + type).toLowerCase();
    choice.dataset.defaultFunction = metadata.defaultFunction || "";
    choice.dataset.measureField = metadata.measureField || "";
    if (kind === "filter") {
      choice.dataset.scFilterAction = "add";
      choice.setAttribute("data-sc-filter-available-item", "");
    } else {
      choice.dataset.scPickerAction = "add";
      choice.setAttribute("data-sc-picker-available-item", "");
    }
    appendLabel(choice, label, type);
    var plus = document.createElement("span");
    plus.setAttribute("aria-hidden", "true");
    plus.textContent = "+";
    choice.appendChild(plus);
    return choice;
  }

  function createColumnControl(action, label, text) {
    var control = document.createElement("button");
    control.type = "button";
    control.dataset.scPickerAction = action;
    var verb = action === "up" ? "Move " : action === "down" ? "Move " : "Remove ";
    var suffix = action === "up" ? " up" : action === "down" ? " down" : "";
    control.setAttribute("aria-label", verb + label + suffix);
    control.title = action === "up" ? "Move up" : action === "down" ? "Move down" : "Remove";
    control.textContent = text;
    return control;
  }

  function createColumnSetItem(choice, root) {
    var field = choice.dataset.field;
    var label = choice.dataset.label;
    var type = choice.dataset.type;
    var kind = root.dataset.scPickerKind || "field";
    var item = document.createElement("article");
    item.className = "sc-picker-set-item";
    item.draggable = true;
    item.setAttribute("data-sc-picker-set-item", "");
    item.dataset.field = field;
    item.dataset.label = label;
    item.dataset.type = type;
    item.dataset.defaultFunction = choice.dataset.defaultFunction || "";
    item.dataset.measureField = choice.dataset.measureField || "";
    var input = document.createElement("input");
    input.type = "hidden";
    input.name = kind;
    input.value = field;
    item.appendChild(input);
    var grip = document.createElement("button");
    grip.className = "sc-picker-grip";
    grip.type = "button";
    grip.title = "Drag to reorder";
    grip.setAttribute("aria-label", "Drag " + label + " to reorder");
    grip.textContent = "⠿";
    item.appendChild(grip);
    appendLabel(item, label, type, "sc-picker-set-label");
    var controls = document.createElement("span");
    controls.className = "sc-picker-controls";
    controls.appendChild(createColumnControl("up", label, "↑"));
    controls.appendChild(createColumnControl("down", label, "↓"));
    controls.appendChild(createColumnControl("remove", label, "×"));
    item.appendChild(controls);
    if (kind === "field" && type === "action") {
      ["field_alias", "field_format"].forEach(function (name) {
        var alignment = document.createElement("input");
        alignment.type = "hidden";
        alignment.name = name;
        item.appendChild(alignment);
      });
    } else if (kind === "order") {
      var directionLabel = document.createElement("label");
      directionLabel.className = "sc-order-direction";
      directionLabel.appendChild(document.createTextNode("Direction"));
      var direction = document.createElement("select");
      direction.name = "direction";
      direction.setAttribute("aria-label", "Direction for " + label);
      [["asc", "Ascending"], ["desc", "Descending"]].forEach(function (entry) {
        var option = document.createElement("option");
        option.value = entry[0];
        option.textContent = entry[1];
        direction.appendChild(option);
      });
      directionLabel.appendChild(direction);
      item.appendChild(directionLabel);
    } else {
      var details = document.createElement("details");
      details.className = "sc-column-config";
      var summary = document.createElement("summary");
      summary.textContent = "Configure";
      details.appendChild(summary);
      var grid = document.createElement("div");
      grid.className = "sc-column-config-grid";
      var aliasLabel = document.createElement("label");
      aliasLabel.appendChild(document.createTextNode(kind === "measure" ? "Measure label" : "Column label"));
      var alias = document.createElement("input");
      alias.name = kind + "_alias";
      alias.maxLength = 80;
      alias.setAttribute("aria-label", (kind === "measure" ? "Measure label for " : "Column label for ") + label);
      aliasLabel.appendChild(alias);
      grid.appendChild(aliasLabel);
      if (kind === "group") {
        appendGroupConfig(grid, type, label);
      } else if (kind === "measure") {
        appendMeasureConfig(grid, type, label, choice.dataset.defaultFunction || "count");
      } else if (/(?:date|time)/i.test(type)) {
        var formatLabel = document.createElement("label");
        formatLabel.appendChild(document.createTextNode("Date format"));
        var format = document.createElement("select");
        format.name = kind + "_format";
        format.setAttribute("aria-label", "Date format for " + label);
        [["", "Default"]].concat(dateFormats).forEach(function (entry) {
          var option = document.createElement("option");
          option.value = entry[0];
          option.textContent = entry[1];
          format.appendChild(option);
        });
        formatLabel.appendChild(format);
        grid.appendChild(formatLabel);
      } else {
        var emptyFormat = document.createElement("input");
        emptyFormat.type = "hidden";
        emptyFormat.name = kind + "_format";
        grid.appendChild(emptyFormat);
      }
      details.appendChild(grid);
      item.appendChild(details);
      syncPickerConfig(item);
    }
    return item;
  }

  function appendOptions(select, options, selected) {
    options.forEach(function (entry) {
      var option = document.createElement("option");
      option.value = entry[0];
      option.textContent = entry[1];
      option.selected = entry[0] === selected;
      select.appendChild(option);
    });
  }

  function appendConfigLabel(grid, text, control, marker) {
    var label = document.createElement("label");
    if (marker) label.setAttribute(marker, "");
    label.appendChild(document.createTextNode(text));
    label.appendChild(control);
    grid.appendChild(label);
    return label;
  }

  function groupFormatsForType(type) {
    if (/(?:date|time)/i.test(type)) {
      return [["", "Default"]].concat(dateFormats).concat([
        ["age_buckets", "Age buckets"],
        ["custom_buckets", "Relative date buckets"],
        ["year_buckets", "Year buckets"]
      ]);
    }
    if (numericFilterType(type)) return [["", "Default"], ["buckets", "Buckets"]];
    if (/(?:string|text|char|citext)/i.test(type)) {
      return [["", "Default"], ["text_prefix", "Text prefix"]];
    }
    return [["", "Default"]];
  }

  function appendGroupConfig(grid, type, label) {
    var format = document.createElement("select");
    format.name = "group_format";
    format.setAttribute("data-sc-group-format", "");
    format.setAttribute("aria-label", "Group format for " + label);
    appendOptions(format, groupFormatsForType(type), "");
    appendConfigLabel(grid, "Format", format);

    var ranges = document.createElement("input");
    ranges.name = "group_bucket_ranges";
    ranges.placeholder = "1, 2-5, 6-14, 15+ or */10";
    ranges.setAttribute("aria-label", "Bucket ranges for " + label);
    appendConfigLabel(grid, "Bucket ranges", ranges, "data-sc-group-buckets");

    var prefix = document.createElement("input");
    prefix.type = "number";
    prefix.min = "1";
    prefix.max = "10";
    prefix.value = "2";
    prefix.name = "group_prefix_length";
    prefix.setAttribute("aria-label", "Prefix length for " + label);
    appendConfigLabel(grid, "Prefix length", prefix, "data-sc-group-prefix");

    var articles = document.createElement("select");
    articles.name = "group_exclude_articles";
    articles.setAttribute("aria-label", "Leading articles for " + label);
    appendOptions(articles, [["1", "Exclude a, an, the"], ["0", "Keep articles"]], "1");
    appendConfigLabel(grid, "Leading articles", articles, "data-sc-group-prefix");
  }

  function measureFunctionsForType(type) {
    if (type === "rows") return [["count", "Count"]];
    if (numericFilterType(type)) {
      return [
        ["count", "Count"], ["count_distinct", "Count distinct"],
        ["avg", "Average"], ["sum", "Sum"], ["min", "Minimum"], ["max", "Maximum"],
        ["buckets", "Buckets"]
      ];
    }
    if (temporalFilterType(type)) {
      return [
        ["count", "Count"], ["count_distinct", "Count distinct"],
        ["min", "Minimum"], ["max", "Maximum"], ["age_buckets", "Age buckets"]
      ];
    }
    if (booleanFilterType(type)) {
      return [["count", "Count"], ["true_count", "True count"], ["false_count", "False count"]];
    }
    return [
      ["count", "Count"], ["count_distinct", "Count distinct"],
      ["min", "Minimum"], ["max", "Maximum"]
    ];
  }

  function appendMeasureConfig(grid, type, label, selected) {
    var functions = measureFunctionsForType(type);
    if (!functions.some(function (entry) { return entry[0] === selected; })) selected = functions[0][0];
    var functionSelect = document.createElement("select");
    functionSelect.name = "measure_function";
    functionSelect.setAttribute("data-sc-measure-function", "");
    functionSelect.setAttribute("aria-label", "Measure function for " + label);
    appendOptions(functionSelect, functions, selected);
    appendConfigLabel(grid, "Function", functionSelect);

    var ranges = document.createElement("input");
    ranges.name = "measure_bucket_ranges";
    ranges.placeholder = "0-10, 11-50, 51+";
    ranges.setAttribute("aria-label", "Measure bucket ranges for " + label);
    appendConfigLabel(grid, "Bucket ranges", ranges, "data-sc-measure-buckets");

    var nulls = document.createElement("select");
    nulls.name = "measure_ignore_nulls";
    nulls.setAttribute("aria-label", "NULL handling for " + label);
    appendOptions(nulls, [["0", "Keep SQL SUM behavior"], ["1", "Treat NULL as 0"]], "0");
    appendConfigLabel(grid, "NULL handling", nulls, "data-sc-measure-sum");
  }

  function syncPickerConfig(item) {
    var groupFormat = item.querySelector("[data-sc-group-format]");
    if (groupFormat) {
      var buckets = /^(?:buckets|age_buckets|custom_buckets|year_buckets)$/.test(groupFormat.value);
      item.querySelectorAll("[data-sc-group-buckets]").forEach(function (node) { node.hidden = !buckets; });
      item.querySelectorAll("[data-sc-group-prefix]").forEach(function (node) {
        node.hidden = groupFormat.value !== "text_prefix";
      });
    }
    var measureFunction = item.querySelector("[data-sc-measure-function]");
    if (measureFunction) {
      var measureBuckets = /^(?:buckets|age_buckets)$/.test(measureFunction.value);
      item.querySelectorAll("[data-sc-measure-buckets]").forEach(function (node) { node.hidden = !measureBuckets; });
      item.querySelectorAll("[data-sc-measure-sum]").forEach(function (node) {
        node.hidden = measureFunction.value !== "sum";
      });
    }
  }

  function refreshColumnPicker(root) {
    var items = setItems(root);
    var available = Array.from(root.querySelectorAll("[data-sc-picker-available-item]"));
    var availableList = root.querySelector("[data-sc-picker-available]");
    var availableEmpty = availableList && availableList.querySelector(".sc-picker-empty");
    if (available.length && availableEmpty) availableEmpty.remove();
    if (!available.length && availableList && !availableEmpty) {
      availableEmpty = document.createElement("p");
      availableEmpty.className = "sc-picker-empty";
      availableEmpty.textContent = "Every available field is set.";
      availableList.appendChild(availableEmpty);
    }
    var search = root.querySelector("[data-sc-picker-filter]");
    var query = search ? search.value.trim().toLowerCase() : "";
    var maximum = Number(root.dataset.scPickerMax || available.length + items.length);
    available.forEach(function (choice) {
      choice.disabled = items.length >= maximum;
      choice.hidden = query.length > 0 && !choice.dataset.search.includes(query);
    });
    var setCount = root.querySelector("[data-sc-picker-set-count]");
    var availableCount = root.querySelector("[data-sc-picker-available-count]");
    if (setCount) setCount.textContent = items.length;
    if (availableCount) availableCount.textContent = available.length;
    items.forEach(function (item, index) {
      syncPickerConfig(item);
      var up = item.querySelector('[data-sc-picker-action="up"]');
      var down = item.querySelector('[data-sc-picker-action="down"]');
      var remove = item.querySelector('[data-sc-picker-action="remove"]');
      if (up) up.disabled = index === 0;
      if (down) down.disabled = index === items.length - 1;
      if (remove) remove.disabled = items.length === 1;
    });
  }

  var dateShortcuts = [
    ["Days", "today", "Today"],
    ["Days", "yesterday", "Yesterday"],
    ["Days", "tomorrow", "Tomorrow"],
    ["Weeks", "this_week", "This Week"],
    ["Weeks", "last_week", "Last Week"],
    ["Weeks", "next_week", "Next Week"],
    ["Months", "this_month", "This Month"],
    ["Months", "last_month", "Last Month"],
    ["Months", "next_month", "Next Month"],
    ["Months", "mtd", "Month to Date"],
    ["Quarters", "this_quarter", "This Quarter"],
    ["Quarters", "last_quarter", "Last Quarter"],
    ["Quarters", "next_quarter", "Next Quarter"],
    ["Quarters", "qtd", "Quarter to Date"],
    ["Years", "this_year", "This Year"],
    ["Years", "last_year", "Last Year"],
    ["Years", "next_year", "Next Year"],
    ["Years", "ytd", "Year to Date"],
    ["Relative periods", "last_7_days", "Last 7 Days"],
    ["Relative periods", "last_30_days", "Last 30 Days"],
    ["Relative periods", "last_90_days", "Last 90 Days"],
    ["Relative periods", "next_7_days", "Next 7 Days"],
    ["Relative periods", "next_30_days", "Next 30 Days"]
  ];

  // Source: filters.js
  function temporalFilterType(type) {
    return /(?:date|time)/i.test(type || "");
  }

  function numericFilterType(type) {
    return /^(?:integer|decimal|number|numeric|float|double|real)$/i.test(type || "");
  }

  function booleanFilterType(type) {
    return /^(?:bool|boolean)$/i.test(type || "");
  }

  function filterOperatorsForType(type) {
    if (booleanFilterType(type)) {
      return [["eq", "is"], ["is_null", "is empty"], ["not_null", "is not empty"]];
    }
    if (temporalFilterType(type)) {
      return [
        ["eq", "on"], ["ne", "not on"], ["gt", "after"],
        ["gte", "on or after"], ["lt", "before"], ["lte", "on or before"],
        ["between", "between"], ["date_shortcut", "quick select"],
        ["is_null", "is empty"], ["not_null", "is not empty"]
      ];
    }
    if (numericFilterType(type)) {
      return [
        ["eq", "equals"], ["ne", "does not equal"], ["gte", "at least"],
        ["gt", "greater than"], ["lte", "at most"], ["lt", "less than"],
        ["between", "between"], ["in", "one of"],
        ["is_null", "is empty"], ["not_null", "is not empty"]
      ];
    }
    return [
      ["eq", "equals"], ["ne", "does not equal"], ["in", "one of"],
      ["is_null", "is empty"], ["not_null", "is not empty"]
    ];
  }

  function hiddenFilterValue(name, value) {
    var input = document.createElement("input");
    input.type = "hidden";
    input.name = name;
    input.value = value || "";
    return input;
  }

  function labeledFilterControl(text, control, wide) {
    var label = document.createElement("label");
    if (wide) label.className = "sc-filter-value-wide";
    label.appendChild(document.createTextNode(text));
    label.appendChild(control);
    return label;
  }

  function filterInput(type, name, value, label, placeholder) {
    var input = document.createElement("input");
    input.type = type;
    input.name = name;
    input.value = value || "";
    input.setAttribute("aria-label", label);
    if (placeholder) input.placeholder = placeholder;
    if (type === "number") input.step = "any";
    return input;
  }

  function rebuildFilterValues(item, previousValue, previousEnd) {
    var existing = item.querySelector("[data-sc-filter-values]");
    if (existing) existing.remove();
    var editor = item.querySelector(".sc-filter-editor");
    var operator = item.querySelector('[name="filter_op"]').value;
    var type = item.dataset.type || "string";
    var label = item.dataset.label;
    var values = document.createElement("div");
    values.className = "sc-filter-values";
    values.setAttribute("data-sc-filter-values", "");

    if (/_null$/.test(operator)) {
      values.appendChild(hiddenFilterValue("filter_value", ""));
      values.appendChild(hiddenFilterValue("filter_value_end", ""));
      var noValue = document.createElement("p");
      noValue.className = "sc-filter-value-note";
      noValue.textContent = "No value needed.";
      values.appendChild(noValue);
    } else if (operator === "date_shortcut") {
      var shortcut = document.createElement("select");
      shortcut.name = "filter_value";
      shortcut.setAttribute("aria-label", "Period for " + label);
      var selectedShortcut = dateShortcuts.some(function (entry) {
        return entry[1] === previousValue;
      }) ? previousValue : "today";
      var groups = {};
      dateShortcuts.forEach(function (entry) {
        if (!groups[entry[0]]) {
          groups[entry[0]] = document.createElement("optgroup");
          groups[entry[0]].label = entry[0];
          shortcut.appendChild(groups[entry[0]]);
        }
        var option = document.createElement("option");
        option.value = entry[1];
        option.textContent = entry[2];
        option.selected = entry[1] === selectedShortcut;
        groups[entry[0]].appendChild(option);
      });
      values.appendChild(labeledFilterControl("Period", shortcut, true));
      values.appendChild(hiddenFilterValue("filter_value_end", ""));
    } else if (operator === "between") {
      var rangeType = temporalFilterType(type) ?
        (String(type).toLowerCase() === "date" ? "date" : "datetime-local") :
        (numericFilterType(type) ? "number" : "text");
      values.appendChild(labeledFilterControl("Start",
        filterInput(rangeType, "filter_value", previousValue, "Start value for " + label, "Start")));
      values.appendChild(labeledFilterControl("End",
        filterInput(rangeType, "filter_value_end", previousEnd, "End value for " + label, "End")));
    } else if (booleanFilterType(type)) {
      var booleanValue = document.createElement("select");
      booleanValue.name = "filter_value";
      booleanValue.setAttribute("aria-label", "Value for " + label);
      [["", "Choose true or false"], ["true", "True"], ["false", "False"]].forEach(function (entry) {
        var option = document.createElement("option");
        option.value = entry[0];
        option.textContent = entry[1];
        option.selected = entry[0] === String(previousValue).toLowerCase();
        booleanValue.appendChild(option);
      });
      values.appendChild(labeledFilterControl("Value", booleanValue, true));
      values.appendChild(hiddenFilterValue("filter_value_end", ""));
    } else {
      var inputType = operator === "in" ? "text" : temporalFilterType(type) ?
        (String(type).toLowerCase() === "date" ? "date" : "datetime-local") :
        numericFilterType(type) ? "number" : "text";
      var placeholder = operator === "in" ? "Comma-separated values" :
        temporalFilterType(type) ? "Choose a date" : "Enter a value";
      values.appendChild(labeledFilterControl("Value",
        filterInput(inputType, "filter_value", previousValue, "Value for " + label, placeholder), true));
      values.appendChild(hiddenFilterValue("filter_value_end", ""));
    }
    editor.appendChild(values);
  }

  function createFilterSetItem(choice) {
    var field = choice.dataset.field;
    var label = choice.dataset.label;
    var type = choice.dataset.type;
    var item = document.createElement("article");
    item.className = "sc-filter-set-item is-draft";
    item.setAttribute("data-sc-filter-set-item", "");
    item.dataset.field = field;
    item.dataset.label = label;
    item.dataset.type = type;
    var fieldInput = document.createElement("input");
    fieldInput.type = "hidden";
    fieldInput.name = "filter_field";
    fieldInput.value = field;
    item.appendChild(fieldInput);
    item.appendChild(hiddenFilterValue("filter_group", "0"));
    item.appendChild(hiddenFilterValue("filter_clause", ""));
    var heading = document.createElement("div");
    heading.className = "sc-filter-set-heading";
    appendLabel(heading, label, type);
    var remove = document.createElement("button");
    remove.type = "button";
    remove.dataset.scFilterAction = "remove";
    remove.setAttribute("aria-label", "Remove " + label + " filter");
    remove.title = "Remove filter";
    remove.textContent = "×";
    heading.appendChild(remove);
    item.appendChild(heading);
    var editor = document.createElement("div");
    editor.className = "sc-filter-editor";
    var operatorLabel = document.createElement("label");
    operatorLabel.appendChild(document.createTextNode("Operator"));
    var operator = document.createElement("select");
    operator.name = "filter_op";
    operator.setAttribute("aria-label", "Operator for " + label);
    filterOperatorsForType(type).forEach(function (entry) {
      var option = document.createElement("option");
      option.value = entry[0];
      option.textContent = entry[1];
      operator.appendChild(option);
    });
    operatorLabel.appendChild(operator);
    editor.appendChild(operatorLabel);
    item.appendChild(editor);
    rebuildFilterValues(item, "", "");
    var note = document.createElement("p");
    note.className = "sc-filter-draft-note";
    note.textContent = "Enter a value to apply this filter.";
    item.appendChild(note);
    return item;
  }

  function updateFilterDraft(item) {
    if (!item) return;
    var operator = item.querySelector('[name="filter_op"]');
    var value = item.querySelector('[name="filter_value"]');
    if (!operator || !value) return;
    var nullOperator = /_null$/.test(operator.value);
    var end = item.querySelector('[name="filter_value_end"]');
    var draft = !nullOperator && (value.value.length === 0 ||
      (operator.value === "between" && (!end || end.value.length === 0)));
    item.classList.toggle("is-draft", draft);
    var note = item.querySelector(".sc-filter-draft-note");
    if (draft && !note) {
      note = document.createElement("p");
      note.className = "sc-filter-draft-note";
      note.textContent = operator.value === "between" ?
        "Enter both values to apply this filter." : "Enter a value to apply this filter.";
      item.appendChild(note);
    } else if (!draft && note) {
      note.remove();
    }
    var clause = item.closest("[data-sc-filter-clause]");
    if (clause) {
      var clauseDraft = Array.from(clause.querySelectorAll("[data-sc-filter-condition]")).some(function (condition) {
        return condition.classList.contains("is-draft");
      });
      clause.classList.toggle("is-draft", clauseDraft);
      var clauseNote = clause.querySelector("[data-sc-filter-clause-note]");
      if (clauseDraft && !clauseNote) {
        clauseNote = document.createElement("p");
        clauseNote.className = "sc-filter-draft-note";
        clauseNote.dataset.scFilterClauseNote = "";
        clauseNote.textContent = "Complete both conditions to apply this cell.";
        clause.appendChild(clauseNote);
      } else if (!clauseDraft && clauseNote) {
        clauseNote.remove();
      }
    }
  }

  function refreshFilterPicker(root) {
    var items = Array.from(root.querySelectorAll("[data-sc-filter-set-item]"));
    var available = Array.from(root.querySelectorAll("[data-sc-filter-available-item]"));
    var availableList = root.querySelector("[data-sc-filter-available]");
    var availableEmpty = availableList && availableList.querySelector(".sc-picker-empty");
    if (available.length && availableEmpty) availableEmpty.remove();
    if (!available.length && availableList && !availableEmpty) {
      availableEmpty = document.createElement("p");
      availableEmpty.className = "sc-picker-empty";
      availableEmpty.textContent = "Every available filter is set.";
      availableList.appendChild(availableEmpty);
    }
    var search = root.querySelector("[data-sc-filter-search]");
    var query = search ? search.value.trim().toLowerCase() : "";
    var maximum = Number(root.dataset.scFilterMax || 20);
    var setCount = root.querySelector("[data-sc-filter-set-count]");
    var availableCount = root.querySelector("[data-sc-filter-available-count]");
    if (setCount) setCount.textContent = items.length;
    if (availableCount) availableCount.textContent = available.length;
    available.forEach(function (choice) {
      choice.disabled = items.length >= maximum;
      choice.hidden = query.length > 0 && !choice.dataset.search.includes(query);
    });
    var builder = root.closest("[data-sc-builder]");
    refreshFilterBadge(builder, items.length);
  }

  function queryLibrarySegmentIds(builder) {
    var ids = new Set();
    if (!builder) return ids;
    var view = builder.querySelector('[name="query_library_view"]');
    var option = view && view.selectedOptions && view.selectedOptions[0];
    if (option && option.dataset.scViewSegments) {
      try {
        JSON.parse(option.dataset.scViewSegments).forEach(function (id) { ids.add(String(id)); });
      } catch (_error) {
        // Invalid presentation metadata cannot affect the submitted governed state.
      }
    }
    builder.querySelectorAll('[name="query_library_segment"]:checked').forEach(function (input) {
      ids.add(input.value);
    });
    return ids;
  }

  function refreshFilterBadge(builder, visualCount) {
    if (!builder) return;
    if (visualCount === undefined) {
      visualCount = builder.querySelectorAll("[data-sc-filter-set-item]").length;
    }
    visualCount += builder.querySelectorAll("[data-sc-filter-clause]").length;
    var badge = builder.querySelector("[data-sc-filter-badge]");
    if (badge) badge.textContent = visualCount + queryLibrarySegmentIds(builder).size;
  }

  function syncPromotedFilterInput(control) {
    var field = control && control.dataset.filterField;
    var kind = control && control.dataset.scPromotedFilterInput;
    if (!field || !kind) return;
    var builder = promotedFilterBuilder(control);
    var clauseId = control.dataset.filterClause;
    var filterItem;
    if (clauseId) {
      var clause = builder && Array.from(builder.querySelectorAll("[data-sc-filter-clause]")).find(function (item) {
        return item.dataset.scFilterClause === clauseId;
      });
      filterItem = clause && Array.from(clause.querySelectorAll("[data-sc-filter-condition]")).find(function (item) {
        return item.dataset.field === field;
      });
    } else {
      filterItem = builder && Array.from(builder.querySelectorAll("[data-sc-filter-set-item]")).find(function (item) {
        return item.dataset.field === field;
      });
    }
    if (!filterItem) return;
    var target = filterItem.querySelector('[name="filter_' + kind + '"]');
    if (target) {
      target.value = control.value;
      if (kind === "op") {
        target.dispatchEvent(new Event("change", { bubbles: true }));
        refreshPromotedFilterValues(control, filterItem);
      }
    }
    updateFilterDraft(filterItem);
  }

  function refreshPromotedFilterValues(control, filterItem) {
    var card = control && control.closest("[data-sc-promoted-filter-condition], [data-sc-promoted-filter]");
    var source = filterItem && filterItem.querySelector("[data-sc-filter-values]");
    var current = card && card.querySelector("[data-sc-promoted-filter-values]");
    if (!card || !source || !current) return;
    var replacement = document.createElement("div");
    replacement.setAttribute("data-sc-promoted-filter-values", "");
    replacement.appendChild(source.cloneNode(true));
    replacement.querySelectorAll("input, select, textarea").forEach(function (input) {
      var name = input.getAttribute("name");
      if (input.type === "hidden") {
        input.remove();
        return;
      }
      if (name === "filter_value" || name === "filter_value_end") {
        input.removeAttribute("name");
        input.dataset.scPromotedFilterInput = name === "filter_value_end" ? "value_end" : "value";
        input.dataset.filterField = control.dataset.filterField;
        if (control.dataset.filterClause) input.dataset.filterClause = control.dataset.filterClause;
      }
    });
    current.replaceWith(replacement);
  }

  function promotedFilterBuilder(control) {
    var root = control && control.closest("[data-sc-promoted-filters]");
    var submit = root && root.querySelector("button[form]");
    return submit ? document.getElementById(submit.getAttribute("form")) : null;
  }

  function removeFilterClause(builder, clauseId) {
    if (!builder || !clauseId) return;
    var clause = Array.from(builder.querySelectorAll("[data-sc-filter-clause]")).find(function (item) {
      return item.dataset.scFilterClause === clauseId;
    });
    var clauses = clause && clause.closest("[data-sc-filter-clauses]");
    if (!clause || !clauses) return;
    clause.remove();
    var remaining = clauses.querySelectorAll("[data-sc-filter-clause]").length;
    var count = clauses.querySelector("[data-sc-filter-clause-count]");
    if (count) count.textContent = remaining;
    if (!remaining) clauses.remove();
    var workspace = builder.closest("[data-sc-workspace]");
    var promoted = workspace && workspace.querySelector("[data-sc-promoted-filters]");
    var promotedClause = promoted && Array.from(promoted.querySelectorAll("[data-sc-promoted-filter-clause]")).find(function (item) {
      return item.dataset.scPromotedFilterClause === clauseId;
    });
    if (promotedClause) promotedClause.remove();
    if (promoted && !promoted.querySelector("[data-sc-promoted-filter]")) promoted.remove();
    refreshFilterBadge(builder);
    markBuilderDirty(builder);
  }

  document.addEventListener("input", function (event) {
    if (event.target.matches("[data-sc-promoted-filter-input]")) {
      syncPromotedFilterInput(event.target);
      markBuilderDirty(promotedFilterBuilder(event.target));
      return;
    }
    if (event.target.matches("[data-sc-picker-filter]")) {
      var pickerRoot = event.target.closest("[data-sc-picker-root]");
      if (!pickerRoot) return;
      var pickerQuery = event.target.value.trim().toLowerCase();
      pickerRoot.querySelectorAll("[data-sc-picker-available-item]").forEach(function (item) {
        item.hidden = pickerQuery.length > 0 && !item.dataset.search.includes(pickerQuery);
      });
      return;
    } else if (event.target.matches("[data-sc-filter-search]")) {
      var filterRoot = event.target.closest("[data-sc-filter-root]");
      if (!filterRoot) return;
      var filterQuery = event.target.value.trim().toLowerCase();
      filterRoot.querySelectorAll("[data-sc-filter-available-item]").forEach(function (item) {
        item.hidden = filterQuery.length > 0 && !item.dataset.search.includes(filterQuery);
      });
      return;
    }
    if (event.target.matches('[name="filter_value"], [name="filter_value_end"]')) {
      updateFilterDraft(event.target.closest("[data-sc-filter-set-item], [data-sc-filter-condition]"));
    }
    markBuilderDirty(event.target);
  });

  document.addEventListener("change", function (event) {
    if (event.target.matches("[data-sc-promoted-filter-input]")) {
      syncPromotedFilterInput(event.target);
      markBuilderDirty(promotedFilterBuilder(event.target));
      return;
    }
    var builder = event.target.closest("[data-sc-builder]");
    if (!builder) return;
    if (event.target.matches('input[name="view"]')) {
      stageResultView(builder, event.target.value);
    } else if (event.target.matches('[name="filter_op"]')) {
      var filterItem = event.target.closest("[data-sc-filter-set-item], [data-sc-filter-condition]");
      var currentValue = filterItem.querySelector('[name="filter_value"]');
      var currentEnd = filterItem.querySelector('[name="filter_value_end"]');
      rebuildFilterValues(
        filterItem,
        currentValue ? currentValue.value : "",
        currentEnd ? currentEnd.value : ""
      );
      updateFilterDraft(filterItem);
    } else if (event.target.matches('[name="filter_value"], [name="filter_value_end"]')) {
      updateFilterDraft(event.target.closest("[data-sc-filter-set-item], [data-sc-filter-condition]"));
    } else if (event.target.matches('[name="query_library_view"], [name="query_library_segment"]')) {
      refreshFilterBadge(builder);
    } else if (event.target.matches("[data-sc-group-format], [data-sc-measure-function]")) {
      syncPickerConfig(event.target.closest("[data-sc-picker-set-item]"));
    }
    markBuilderDirty(builder);
  });

  document.addEventListener("click", function (event) {
    var control = event.target.closest("[data-sc-picker-action]");
    if (!control || control.disabled) return;
    var root = control.closest("[data-sc-picker-root]");
    var set = root && root.querySelector("[data-sc-picker-set]");
    if (!root || !set) return;
    var action = control.dataset.scPickerAction;

    if (action === "add") {
      var empty = set.querySelector(".sc-picker-empty");
      if (empty) empty.remove();
      set.appendChild(createColumnSetItem(control, root));
      control.remove();
      refreshColumnPicker(root);
      markBuilderDirty(root);
      return;
    }

    var item = control.closest("[data-sc-picker-set-item]");
    if (!item) return;
    var items = setItems(root);
    var index = items.indexOf(item);
    if (action === "remove") {
      var available = root.querySelector("[data-sc-picker-available]");
      var availableEmpty = available && available.querySelector(".sc-picker-empty");
      if (availableEmpty) availableEmpty.remove();
      if (available) {
        available.appendChild(createAvailableChoice(
          "column", item.dataset.field, item.dataset.label, item.dataset.type, {
            defaultFunction: item.dataset.defaultFunction,
            measureField: item.dataset.measureField
          }
        ));
      }
      item.remove();
    } else if (action === "up" && index > 0) {
      set.insertBefore(item, items[index - 1]);
    } else if (action === "down" && index >= 0 && index < items.length - 1) {
      set.insertBefore(items[index + 1], item);
    } else {
      return;
    }
    refreshColumnPicker(root);
    markBuilderDirty(root);
  });

  document.addEventListener("click", function (event) {
    var clauseRemove = event.target.closest("[data-sc-filter-clause-remove], [data-sc-promoted-clause-remove]");
    if (clauseRemove) {
      var clause = clauseRemove.closest("[data-sc-filter-clause]");
      var builder = clause ? clause.closest("[data-sc-builder]") : promotedFilterBuilder(clauseRemove);
      var clauseId = clause ? clause.dataset.scFilterClause : clauseRemove.dataset.filterClause;
      removeFilterClause(builder, clauseId);
      return;
    }
    var control = event.target.closest("[data-sc-filter-action]");
    if (!control || control.disabled) return;
    var root = control.closest("[data-sc-filter-root]");
    var set = root && root.querySelector("[data-sc-filter-set]");
    if (!root || !set) return;

    if (control.dataset.scFilterAction === "add") {
      var empty = set.querySelector(".sc-picker-empty");
      if (empty) empty.remove();
      set.appendChild(createFilterSetItem(control));
      control.remove();
      refreshFilterPicker(root);
      markBuilderDirty(root);
      return;
    }

    if (control.dataset.scFilterAction === "remove") {
      var item = control.closest("[data-sc-filter-set-item]");
      if (!item) return;
      var available = root.querySelector("[data-sc-filter-available]");
      var availableEmpty = available && available.querySelector(".sc-picker-empty");
      if (availableEmpty) availableEmpty.remove();
      if (available) {
        available.appendChild(createAvailableChoice(
          "filter", item.dataset.field, item.dataset.label, item.dataset.type
        ));
      }
      item.remove();
      refreshFilterPicker(root);
      markBuilderDirty(root);
    }
  });

  document.addEventListener("dragstart", function (event) {
    var item = event.target.closest("[data-sc-picker-set-item]");
    if (!item) return;
    item.classList.add("is-dragging");
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", item.dataset.field);
  });

  document.addEventListener("dragover", function (event) {
    if (!event.target.closest("[data-sc-picker-set-item]")) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
  });

  document.addEventListener("drop", function (event) {
    var target = event.target.closest("[data-sc-picker-set-item]");
    if (!target) return;
    event.preventDefault();
    var root = target.closest("[data-sc-picker-root]");
    var set = root && root.querySelector("[data-sc-picker-set]");
    if (!root || !set) return;
    var field = event.dataTransfer.getData("text/plain");
    var dragged = setItems(root).find(function (item) { return item.dataset.field === field; });
    if (!dragged || dragged === target) return;
    var bounds = target.getBoundingClientRect();
    if (event.clientY > bounds.top + bounds.height / 2) {
      target.after(dragged);
    } else {
      set.insertBefore(dragged, target);
    }
    dragged.classList.remove("is-dragging");
    refreshColumnPicker(root);
    markBuilderDirty(root);
  });

  document.addEventListener("dragend", function (event) {
    var item = event.target.closest("[data-sc-picker-set-item]");
    if (item) item.classList.remove("is-dragging");
  });

  // Source: actions.js
  function bulkActionResults(root) {
    return root && root.closest(".sc-results");
  }

  function actionIdFor(root) {
    return root && root.dataset.scActionId || "";
  }

  function actionMode(root) {
    return root && root.dataset.scActionMode || "rows";
  }

  function actionControls(results, selector, actionId) {
    if (!results || !actionId) return [];
    return Array.from(results.querySelectorAll(selector)).filter(function (input) {
      return input.dataset.scActionId === actionId;
    });
  }

  function actionRoot(results, actionId) {
    if (!results) return null;
    return Array.from(results.querySelectorAll("[data-sc-bulk-action]")).find(function (root) {
      return actionIdFor(root) === actionId;
    });
  }

  var groupedActionStates = Object.create(null);

  function groupedActionState(root) {
    var key = root.dataset.scActionStateKey || actionIdFor(root);
    if (!groupedActionStates[key]) {
      groupedActionStates[key] = {
        groupCount: 0,
        assignments: Object.create(null),
        inputs: Object.create(null),
        lookupLabels: Object.create(null)
      };
    }
    if (!groupedActionStates[key].lookupLabels) {
      groupedActionStates[key].lookupLabels = Object.create(null);
    }
    return groupedActionStates[key];
  }

  function groupedActionMarkers(root) {
    if (root._scActionMarkers) return root._scActionMarkers;
    try {
      root._scActionMarkers = JSON.parse(root.dataset.scActionMarkers || "[]");
    } catch (_error) {
      root._scActionMarkers = [];
    }
    return root._scActionMarkers;
  }

  function groupedActionInputSpecs(root) {
    if (root._scGroupInputs) return root._scGroupInputs;
    try {
      root._scGroupInputs = JSON.parse(root.dataset.scGroupInputs || "[]");
    } catch (_error) {
      root._scGroupInputs = [];
    }
    return root._scGroupInputs;
  }

  function groupedActionRows(root) {
    var results = bulkActionResults(root);
    return actionControls(results, "[data-sc-group-markers]", actionIdFor(root));
  }

  function groupedRowDetails(cell) {
    try {
      var details = JSON.parse(cell.dataset.scRowDetails || "[]");
      return Array.isArray(details) ? details.filter(function (detail) {
        return detail && typeof detail === "object";
      }) : [];
    } catch (_error) {
      return [];
    }
  }

  function selectedGroupedRows(root) {
    var state = groupedActionState(root);
    return groupedActionRows(root).reduce(function (rows, cell) {
      var rowId = cell.dataset.scRowId;
      if (rowId && Object.prototype.hasOwnProperty.call(state.assignments, rowId)) {
        rows.push({
          id: rowId,
          index: state.assignments[rowId],
          details: groupedRowDetails(cell)
        });
      }
      return rows;
    }, []);
  }

  function activeActionGroups(root) {
    var state = groupedActionState(root);
    var markers = groupedActionMarkers(root);
    var byIndex = Object.create(null);
    selectedGroupedRows(root).forEach(function (row) {
      if (!byIndex[row.index]) {
        byIndex[row.index] = {
          index: row.index,
          marker: markers[row.index],
          selected_ids: [],
          orders: [],
          inputs: state.inputs[row.index] || Object.create(null)
        };
      }
      byIndex[row.index].selected_ids.push(row.id);
      byIndex[row.index].orders.push(row);
    });
    return Object.keys(byIndex).map(Number).sort(function (left, right) {
      return left - right;
    }).map(function (index) {
      return byIndex[index];
    });
  }

  function markerSvgPart(svg, name, attributes) {
    var part = document.createElementNS("http://www.w3.org/2000/svg", name);
    Object.keys(attributes).forEach(function (attribute) {
      part.setAttribute(attribute, attributes[attribute]);
    });
    svg.appendChild(part);
    return part;
  }

  function markerGlyph(marker, filled) {
    var glyph = document.createElement("span");
    glyph.className = "sc-group-marker-glyph";
    glyph.dataset.scMarkerShape = marker.shape;
    glyph.setAttribute("aria-hidden", "true");

    var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("focusable", "false");
    var shape = {
      fill: filled ? "currentColor" : "none",
      stroke: "currentColor",
      "stroke-width": filled ? "1.1" : "1.7",
      "stroke-linecap": "round",
      "stroke-linejoin": "round"
    };

    if (marker.shape === "star") {
      markerSvgPart(svg, "polygon", Object.assign({
        points: "12,2.3 14.9,8.2 21.4,9.1 16.7,13.7 17.8,20.2 12,17.2 6.2,20.2 7.3,13.7 2.6,9.1 9.1,8.2"
      }, shape));
    } else if (marker.shape === "circle") {
      markerSvgPart(svg, "circle", Object.assign({cx: "12", cy: "12", r: "8.2"}, shape));
    } else if (marker.shape === "horseshoe") {
      markerSvgPart(svg, "path", Object.assign({
        d: "M5 3.5v8.3a7 7 0 0 0 14 0V3.5h-4v8.3a3 3 0 0 1-6 0V3.5Z"
      }, shape));
    } else if (marker.shape === "moon") {
      markerSvgPart(svg, "path", Object.assign({
        d: "M18.8 16.8A8.5 8.5 0 0 1 9.2 4.7a8.5 8.5 0 1 0 9.6 12.1Z"
      }, shape));
    } else if (marker.shape === "heart") {
      markerSvgPart(svg, "path", Object.assign({
        d: "M12 20.3 4.2 13A5.2 5.2 0 0 1 12 6.2 5.2 5.2 0 0 1 19.8 13Z"
      }, shape));
    } else if (marker.shape === "clover") {
      [[9, 8], [15, 8], [9, 14], [15, 14]].forEach(function (center) {
        markerSvgPart(svg, "circle", Object.assign({
          cx: String(center[0]), cy: String(center[1]), r: "3.5"
        }, shape));
      });
      markerSvgPart(svg, "path", {
        d: "M12 16.5v4", fill: "none", stroke: "currentColor",
        "stroke-width": filled ? "2.1" : "1.7", "stroke-linecap": "round"
      });
    } else if (marker.shape === "diamond") {
      markerSvgPart(svg, "polygon", Object.assign({points: "12,2.5 21,12 12,21.5 3,12"}, shape));
    } else if (marker.shape === "rainbow") {
      [0, 3, 6].forEach(function (inset) {
        markerSvgPart(svg, "path", {
          d: "M" + (3 + inset / 2) + " " + (18 - inset / 2) +
            "a" + (9 - inset / 2) + " " + (9 - inset / 2) + " 0 0 1 " +
            (18 - inset) + " 0",
          fill: "none", stroke: "currentColor",
          "stroke-width": filled ? "2.2" : "1.35", "stroke-linecap": "round"
        });
      });
    } else {
      markerSvgPart(svg, "circle", Object.assign({cx: "12", cy: "12", r: "8.2"}, shape));
    }
    glyph.appendChild(svg);
    return glyph;
  }

  function markerButton(marker, index, rowId, selected) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "sc-group-marker" + (selected ? " is-selected" : "");
    button.dataset.scGroupMarker = String(index);
    button.dataset.scRowId = rowId;
    button.style.setProperty("--sc-marker-color", marker.color);
    button.title = selected ? "Remove from " + marker.label + " load" : "Add to " + marker.label + " load";
    button.setAttribute("aria-label", button.title);
    button.appendChild(markerGlyph(marker, selected));
    return button;
  }

  function rememberGroupedRowOrder(root) {
    if (root._scGroupedRowOrder) return root._scGroupedRowOrder;
    root._scGroupedRowOrder = Object.create(null);
    groupedActionRows(root).forEach(function (cell, index) {
      var rowId = cell.dataset.scRowId;
      if (rowId) root._scGroupedRowOrder[rowId] = index;
    });
    return root._scGroupedRowOrder;
  }

  function reorderGroupedActionRows(root) {
    var state = groupedActionState(root);
    var originalOrder = rememberGroupedRowOrder(root);
    var tableBodies = new Map();
    groupedActionRows(root).forEach(function (cell) {
      var row = cell.closest("tr");
      var body = row && row.parentElement;
      if (!row || !body || body.tagName !== "TBODY") return;
      if (!tableBodies.has(body)) tableBodies.set(body, []);
      tableBodies.get(body).push({row: row, id: cell.dataset.scRowId});
    });
    tableBodies.forEach(function (rows, body) {
      var firstPositions = new Map();
      rows.forEach(function (entry) {
        Array.from(entry.row.children).forEach(function (cell) {
          if (typeof cell.getAnimations === "function") {
            cell.getAnimations().forEach(function (animation) { animation.cancel(); });
          }
        });
        firstPositions.set(entry.row, entry.row.getBoundingClientRect().top);
      });
      rows.sort(function (left, right) {
        var leftAssigned = Object.prototype.hasOwnProperty.call(state.assignments, left.id);
        var rightAssigned = Object.prototype.hasOwnProperty.call(state.assignments, right.id);
        if (leftAssigned !== rightAssigned) return leftAssigned ? -1 : 1;
        if (leftAssigned && state.assignments[left.id] !== state.assignments[right.id]) {
          return state.assignments[left.id] - state.assignments[right.id];
        }
        return (originalOrder[left.id] || 0) - (originalOrder[right.id] || 0);
      });
      rows.forEach(function (entry) { body.appendChild(entry.row); });
      if (typeof window.matchMedia === "function"
          && window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
      rows.forEach(function (entry) {
        var previousTop = firstPositions.get(entry.row);
        var currentTop = entry.row.getBoundingClientRect().top;
        var distance = previousTop - currentTop;
        if (Math.abs(distance) < 1) return;
        Array.from(entry.row.children).forEach(function (cell) {
          if (typeof cell.animate !== "function") return;
          cell.animate([
            {transform: "translateY(" + distance + "px)"},
            {transform: "translateY(0)"}
          ], {
            duration: 280,
            easing: "cubic-bezier(.2,.8,.2,1)"
          });
        });
      });
    });
  }

  function renderGroupedActionRows(root) {
    var state = groupedActionState(root);
    var markers = groupedActionMarkers(root);
    groupedActionRows(root).forEach(function (cell) {
      var rowId = cell.dataset.scRowId;
      cell.replaceChildren();
      if (!rowId || !markers.length) return;
      if (Object.prototype.hasOwnProperty.call(state.assignments, rowId)) {
        var selectedIndex = state.assignments[rowId];
        if (markers[selectedIndex]) {
          cell.appendChild(markerButton(markers[selectedIndex], selectedIndex, rowId, true));
        }
        return;
      }
      var visibleCount = Math.min(state.groupCount + 1, markers.length);
      for (var index = 0; index < visibleCount; index += 1) {
        cell.appendChild(markerButton(markers[index], index, rowId, false));
      }
    });
    reorderGroupedActionRows(root);
  }

  function restoreGroupedAction(root) {
    var visible = Object.create(null);
    groupedActionRows(root).forEach(function (cell) {
      if (cell.dataset.scRowId) visible[cell.dataset.scRowId] = true;
    });
    var state = groupedActionState(root);
    Object.keys(state.assignments).forEach(function (rowId) {
      if (!visible[rowId]) delete state.assignments[rowId];
    });
    renderGroupedActionRows(root);
  }

  function resetGroupedAction(root) {
    var state = groupedActionState(root);
    state.groupCount = 0;
    state.assignments = Object.create(null);
    state.inputs = Object.create(null);
    state.lookupLabels = Object.create(null);
    renderGroupedActionRows(root);
  }

  function selectedRowIds(root) {
    var results = bulkActionResults(root);
    if (!results) return [];
    if (actionMode(root) === "groups") {
      return selectedGroupedRows(root).map(function (row) { return row.id; });
    }
    var seen = Object.create(null);
    return actionControls(results, "[data-sc-row-select]:checked", actionIdFor(root)).reduce(function (ids, input) {
      if (input.value && !seen[input.value]) {
        seen[input.value] = true;
        ids.push(input.value);
      }
      return ids;
    }, []);
  }

  function populateActionTargets(form, ids) {
    var target = form.querySelector("[data-sc-action-targets]");
    if (!target) return;
    target.replaceChildren();
    ids.forEach(function (id) {
      var input = document.createElement("input");
      input.type = "hidden";
      input.name = "selected_id";
      input.value = id;
      target.appendChild(input);
    });
    var count = form.querySelector("[data-sc-action-selection-count]");
    if (count) count.textContent = ids.length;
  }

  function refreshBulkAction(root) {
    if (!root) return;
    var actionId = actionIdFor(root);
    var ids = selectedRowIds(root);
    var count = root.querySelector("[data-sc-selection-count]");
    var label = root.querySelector("[data-sc-selection-label]");
    if (count) count.textContent = ids.length;
    if (label) label.textContent = actionMode(root) === "groups"
      ? (ids.length === 1 ? "row assigned" : "rows assigned")
      : (ids.length === 1 ? "row selected" : "rows selected");
    if (actionMode(root) === "groups") {
      var groups = activeActionGroups(root);
      var groupCount = root.querySelector("[data-sc-group-count]");
      if (groupCount) groupCount.textContent = groups.length;
      root.querySelectorAll("[data-sc-action-open]").forEach(function (button) {
        button.disabled = ids.length === 0 || button.dataset.scActionDisabled === "1";
      });
      return;
    }
    root.querySelectorAll("[data-sc-action-open]").forEach(function (button) {
      button.disabled = ids.length === 0 || button.dataset.scActionDisabled === "1";
    });
    var results = bulkActionResults(root);
    var pageToggle = actionControls(results, "[data-sc-select-page]", actionId)[0];
    var rowToggles = actionControls(results, "[data-sc-row-select]:not(:disabled)", actionId);
    var checked = rowToggles.filter(function (input) { return input.checked; }).length;
    if (pageToggle) {
      pageToggle.checked = rowToggles.length > 0 && checked === rowToggles.length;
      pageToggle.indeterminate = checked > 0 && checked < rowToggles.length;
    }
  }

  function restoreBulkActions() {
    document.querySelectorAll("[data-sc-bulk-action]").forEach(function (root) {
      if (actionMode(root) === "groups") restoreGroupedAction(root);
      refreshBulkAction(root);
    });
  }

  document.addEventListener("DOMContentLoaded", restoreBulkActions);
  document.addEventListener("htmx:after:swap", restoreBulkActions);
  document.addEventListener("htmx:ws:after:message:incoming", function () {
    window.requestAnimationFrame(restoreBulkActions);
  });

  // Source: lookups.js
  function groupLookupControl(spec, value, displayValue, groupIndex) {
    var wrapper = document.createElement("div");
    wrapper.className = "sc-action-lookup";
    wrapper.dataset.scActionLookup = "";

    var selected = document.createElement("input");
    selected.type = "hidden";
    selected.dataset.scLookupValue = "";
    selected.dataset.scGroupInput = spec.id;
    selected.dataset.scGroupIndex = String(groupIndex);
    selected.value = value === undefined || value === null ? "" : value;

    var query = document.createElement("input");
    query.type = "search";
    query.autocomplete = "off";
    query.spellcheck = false;
    query.className = "sc-action-lookup-query";
    query.dataset.scLookupQuery = "";
    query.dataset.scLookupUrl = spec.lookup_url || "";
    query.dataset.scLookupInput = spec.id;
    query.dataset.scLookupGroupIndex = String(groupIndex);
    query.dataset.scLookupMinimumLength = String(spec.minimum_query_length || 2);
    query.dataset.scLookupDirectEntry = spec.direct_entry ? "1" : "0";
    query.dataset.scLookupValueType = spec.value_type || "string";
    query.dataset.scLookupSelectedValue = selected.value;
    query.placeholder = spec.placeholder || "Search and choose " + String(spec.label || spec.id).toLowerCase();
    query.setAttribute("role", "combobox");
    query.setAttribute("aria-autocomplete", "list");
    query.setAttribute("aria-expanded", "false");
    query.setAttribute("aria-label", spec.label || spec.id);
    query.required = Boolean(spec.required);
    query.value = displayValue || selected.value;

    var results = document.createElement("div");
    results.className = "sc-action-lookup-results";
    results.dataset.scLookupResults = "";
    results.id = "sc-action-lookup-" + groupIndex + "-" + spec.id;
    results.setAttribute("role", "listbox");
    results.hidden = true;
    query.setAttribute("aria-controls", results.id);

    var hint = document.createElement("small");
    hint.className = "sc-action-lookup-hint";
    hint.textContent = "Search by name, key, ID, or location.";
    wrapper.append(query, selected, results, hint);
    return wrapper;
  }

  function groupInputControl(spec, value, displayValue, groupIndex) {
    var control;
    if (spec.type === "lookup") {
      return groupLookupControl(spec, value, displayValue, groupIndex);
    } else if (spec.type === "select") {
      control = document.createElement("select");
      var blank = document.createElement("option");
      blank.value = "";
      blank.textContent = "Choose " + String(spec.label || spec.id).toLowerCase();
      control.appendChild(blank);
      (spec.options || []).forEach(function (option) {
        var item = document.createElement("option");
        item.value = option.value;
        item.textContent = option.label;
        control.appendChild(item);
      });
    } else if (spec.type === "textarea") {
      control = document.createElement("textarea");
      control.rows = spec.rows || 4;
    } else {
      control = document.createElement("input");
      control.type = spec.type === "string" ? "text" : spec.type;
    }
    control.dataset.scGroupInput = spec.id;
    control.dataset.scGroupIndex = String(groupIndex);
    control.required = Boolean(spec.required);
    if (spec.minimum !== undefined) control.min = spec.minimum;
    if (spec.maximum !== undefined) control.max = spec.maximum;
    if (spec.min_length !== undefined) control.minLength = spec.min_length;
    if (spec.max_length !== undefined) control.maxLength = spec.max_length;
    control.value = value === undefined || value === null ? "" : value;
    return control;
  }

  function lookupElements(query) {
    var wrapper = query && query.closest("[data-sc-action-lookup]");
    var resultsId = query && query.getAttribute("aria-controls");
    return {
      wrapper: wrapper,
      selected: wrapper && wrapper.querySelector("[data-sc-lookup-value]"),
      results: (wrapper && wrapper.querySelector("[data-sc-lookup-results]"))
        || (resultsId && document.getElementById(resultsId))
    };
  }

  function positionLookup(query) {
    var elements = lookupElements(query);
    if (!elements.results || elements.results.hidden || !query.isConnected) return;
    var bounds = query.getBoundingClientRect();
    var viewportWidth = document.documentElement.clientWidth || window.innerWidth;
    var viewportHeight = document.documentElement.clientHeight || window.innerHeight;
    var margin = 8;
    var width = Math.min(bounds.width, viewportWidth - margin * 2);
    var left = Math.max(margin, Math.min(bounds.left, viewportWidth - width - margin));
    var below = viewportHeight - bounds.bottom - margin;
    var above = bounds.top - margin;
    var openAbove = below < 150 && above > below;
    var available = Math.max(80, openAbove ? above : below);

    elements.results.classList.add("is-portaled");
    elements.results.style.left = left + "px";
    elements.results.style.right = "auto";
    elements.results.style.width = width + "px";
    elements.results.style.maxHeight = Math.min(260, available) + "px";
    if (openAbove) {
      elements.results.style.top = "auto";
      elements.results.style.bottom = (viewportHeight - bounds.top + 4) + "px";
    } else {
      elements.results.style.top = (bounds.bottom + 4) + "px";
      elements.results.style.bottom = "auto";
    }
  }

  function portalLookup(query) {
    var elements = lookupElements(query);
    var dialog = query && query.closest("[data-sc-action-dialog]");
    if (!elements.results || !dialog) return;
    if (elements.results.parentElement !== dialog) dialog.appendChild(elements.results);
    elements.results._scLookupQuery = query;
  }

  function closeLookup(query) {
    var elements = lookupElements(query);
    if (!elements.results) return;
    if (query._scLookupTimer) window.clearTimeout(query._scLookupTimer);
    if (query._scLookupAbort) query._scLookupAbort.abort();
    query._scLookupTimer = null;
    query._scLookupAbort = null;
    elements.results.hidden = true;
    elements.results.replaceChildren();
    elements.results.classList.remove("is-portaled");
    elements.results.removeAttribute("style");
    elements.results._scLookupQuery = null;
    if (elements.wrapper && elements.results.parentElement !== elements.wrapper) {
      elements.wrapper.appendChild(elements.results);
    }
    query.setAttribute("aria-expanded", "false");
    query.removeAttribute("aria-activedescendant");
    query._scLookupIndex = -1;
  }

  function lookupMessage(results, message) {
    results.replaceChildren();
    var status = document.createElement("div");
    status.className = "sc-action-lookup-status";
    status.setAttribute("role", "status");
    status.textContent = message;
    results.appendChild(status);
    results.hidden = false;
  }

  function chooseLookupResult(query, option) {
    var elements = lookupElements(query);
    if (!elements.selected || !elements.results) return;
    var value = option.dataset.scLookupValue || "";
    var label = option.dataset.scLookupLabel || value;
    elements.selected.value = value;
    query.value = label + (label.indexOf("(" + value + ")") === -1 ? " (" + value + ")" : "");
    query.dataset.scLookupSelectedValue = value;
    query.setCustomValidity("");

    var form = query.closest("[data-sc-action-form]");
    var root = form && form.closest("[data-sc-bulk-action]");
    var index = query.dataset.scLookupGroupIndex;
    if (root && index !== undefined) {
      var state = groupedActionState(root);
      if (!state.lookupLabels[index]) state.lookupLabels[index] = Object.create(null);
      state.lookupLabels[index][query.dataset.scLookupInput] = query.value;
      serializeGroupedAction(root, form);
    }
    closeLookup(query);
    query.focus();
  }

  function renderLookupResults(query, items) {
    var elements = lookupElements(query);
    if (!elements.results) return;
    elements.results.replaceChildren();
    if (!items.length) {
      lookupMessage(elements.results, "No matching records.");
      query.setAttribute("aria-expanded", "true");
      portalLookup(query);
      positionLookup(query);
      return;
    }
    items.forEach(function (item, index) {
      if (!item || item.value === undefined || item.label === undefined) return;
      var option = document.createElement("button");
      option.type = "button";
      option.className = "sc-action-lookup-option";
      option.id = elements.results.id + "-option-" + index;
      option.dataset.scLookupOption = "";
      option.dataset.scLookupValue = String(item.value);
      option.dataset.scLookupLabel = String(item.label);
      option.setAttribute("role", "option");
      option.setAttribute("aria-selected", "false");
      var label = document.createElement("strong");
      label.textContent = String(item.label);
      option.appendChild(label);
      if (item.description) {
        var description = document.createElement("small");
        description.textContent = String(item.description);
        option.appendChild(description);
      }
      elements.results.appendChild(option);
    });
    elements.results.hidden = false;
    query.setAttribute("aria-expanded", "true");
    query._scLookupIndex = -1;
    portalLookup(query);
    positionLookup(query);
  }

  function searchLookup(query) {
    var term = query.value.trim();
    var minimum = Number(query.dataset.scLookupMinimumLength || 2);
    var elements = lookupElements(query);
    if (!elements.results || term.length < minimum) {
      closeLookup(query);
      return;
    }
    if (query._scLookupAbort) query._scLookupAbort.abort();
    var abort = typeof window.AbortController === "function" ? new AbortController() : null;
    query._scLookupAbort = abort;
    lookupMessage(elements.results, "Searching…");
    query.setAttribute("aria-expanded", "true");
    portalLookup(query);
    positionLookup(query);

    var url = new URL(query.dataset.scLookupUrl, window.location.href);
    url.searchParams.set("q", term);
    var form = query.closest("[data-sc-action-form]");
    var root = form && form.closest("[data-sc-bulk-action]");
    var rawIndex = query.dataset.scLookupGroupIndex;
    var index = Number(rawIndex);
    if (root && rawIndex !== undefined) {
      var group = activeActionGroups(root).find(function (item) { return item.index === index; });
      (group ? group.selected_ids : []).forEach(function (id) {
        url.searchParams.append("selected_id", id);
      });
    } else if (form) {
      form.querySelectorAll('input[name="selected_id"]').forEach(function (input) {
        if (input.value) url.searchParams.append("selected_id", input.value);
      });
    }
    window.fetch(url.toString(), {
      credentials: "same-origin",
      headers: {"Accept": "application/json", "X-Requested-With": "XMLHttpRequest"},
      signal: abort ? abort.signal : undefined
    }).then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (payload) {
        if (!response.ok) throw new Error(payload.error || "Lookup failed");
        return Array.isArray(payload.results) ? payload.results : [];
      });
    }).then(function (items) {
      if (query._scLookupAbort !== abort) return;
      renderLookupResults(query, items);
    }).catch(function (error) {
      if (error && error.name === "AbortError") return;
      if (query._scLookupAbort !== abort) return;
      lookupMessage(elements.results, "Search unavailable. Try again.");
      query.setAttribute("aria-expanded", "true");
    });
  }

  function stageLookupSearch(query) {
    var elements = lookupElements(query);
    if (!elements.selected) return;
    var term = query.value.trim();
    var direct = query.dataset.scLookupDirectEntry === "1";
    var integer = query.dataset.scLookupValueType === "integer";
    var directValue = direct && (!integer || /^\d+$/.test(term));
    elements.selected.value = directValue ? term : "";
    query.dataset.scLookupSelectedValue = elements.selected.value;
    query.setCustomValidity(term && !directValue ? "Choose a result from the list." : "");

    var form = query.closest("[data-sc-action-form]");
    var root = form && form.closest("[data-sc-bulk-action]");
    var index = query.dataset.scLookupGroupIndex;
    if (root && index !== undefined) {
      var state = groupedActionState(root);
      if (!state.lookupLabels[index]) state.lookupLabels[index] = Object.create(null);
      state.lookupLabels[index][query.dataset.scLookupInput] = directValue ? term : "";
      serializeGroupedAction(root, form);
    }
    if (query._scLookupTimer) window.clearTimeout(query._scLookupTimer);
    query._scLookupTimer = window.setTimeout(function () { searchLookup(query); }, 300);
  }

  function renderGroupedActionDialog(root, form) {
    var groups = activeActionGroups(root);
    var specs = groupedActionInputSpecs(root);
    var container = form.querySelector("[data-sc-group-action-groups]");
    if (!container) return;
    container.replaceChildren();
    groups.forEach(function (group) {
      var card = document.createElement("section");
      card.className = "sc-group-action-card";
      card.dataset.scGroupActionCard = group.marker.id;
      card.style.setProperty("--sc-marker-color", group.marker.color);

      var header = document.createElement("header");
      header.className = "sc-group-action-card-header";
      var marker = document.createElement("span");
      marker.className = "sc-group-dialog-marker";
      marker.style.setProperty("--sc-marker-color", group.marker.color);
      marker.appendChild(markerGlyph(group.marker, true));
      var heading = document.createElement("div");
      var title = document.createElement("h4");
      title.textContent = group.marker.label + " load";
      var summary = document.createElement("p");
      summary.textContent = group.selected_ids.length +
        (group.selected_ids.length === 1 ? " order" : " orders");
      heading.append(title, summary);
      header.append(marker, heading);
      card.appendChild(header);

      var orders = document.createElement("ul");
      orders.className = "sc-group-action-orders";
      group.orders.forEach(function (order) {
        var item = document.createElement("li");
        var orderId = document.createElement("strong");
        orderId.textContent = "Order " + order.id;
        item.appendChild(orderId);
        var locations = (order.details || []).map(function (detail) {
          return detail.value === undefined || detail.value === null ? "" : String(detail.value);
        }).filter(function (value) { return value.length > 0; });
        if (locations.length) {
          var route = document.createElement("span");
          route.textContent = locations.join(" \u2192 ");
          item.appendChild(route);
        }
        orders.appendChild(item);
      });
      card.appendChild(orders);

      specs.forEach(function (spec) {
        var field = document.createElement("div");
        field.className = "sc-action-input";
        var caption = document.createElement("span");
        caption.textContent = spec.label + (spec.required ? " *" : "");
        var state = groupedActionState(root);
        var displayValue = state.lookupLabels[group.index]
          && state.lookupLabels[group.index][spec.id];
        field.append(
          caption,
          groupInputControl(spec, group.inputs[spec.id], displayValue, group.index)
        );
        card.appendChild(field);
      });
      container.appendChild(card);
    });
    var groupCount = form.querySelector("[data-sc-action-group-count]");
    if (groupCount) groupCount.textContent = groups.length;
    populateActionTargets(form, selectedRowIds(root));
    serializeGroupedAction(root, form);
  }

  function serializeGroupedAction(root, form) {
    var state = groupedActionState(root);
    form.querySelectorAll("[data-sc-group-input]").forEach(function (control) {
      var index = control.dataset.scGroupIndex;
      if (!state.inputs[index]) state.inputs[index] = Object.create(null);
      state.inputs[index][control.dataset.scGroupInput] = control.value;
    });
    var payload = activeActionGroups(root).map(function (group) {
      return {index: group.index, selected_ids: group.selected_ids, inputs: state.inputs[group.index] || {}};
    });
    var hidden = form.querySelector("[data-sc-action-groups]");
    if (hidden) hidden.value = JSON.stringify(payload);
  }

  document.addEventListener("change", function (event) {
    if (event.target.matches("[data-sc-group-input]")) {
      var groupForm = event.target.closest("[data-sc-action-form]");
      var groupRoot = groupForm && groupForm.closest("[data-sc-bulk-action]");
      if (groupRoot) serializeGroupedAction(groupRoot, groupForm);
      return;
    }
    if (event.target.matches("[data-sc-select-page]")) {
      var results = event.target.closest(".sc-results");
      var actionId = event.target.dataset.scActionId;
      actionControls(results, "[data-sc-row-select]:not(:disabled)", actionId).forEach(function (input) {
        input.checked = event.target.checked;
      });
      refreshBulkAction(actionRoot(results, actionId));
      return;
    }
    if (event.target.matches("[data-sc-row-select]")) {
      var rowResults = event.target.closest(".sc-results");
      refreshBulkAction(actionRoot(rowResults, event.target.dataset.scActionId));
    }
  });

  document.addEventListener("input", function (event) {
    if (event.target.matches("[data-sc-lookup-query]")) stageLookupSearch(event.target);
  });

  document.addEventListener("focusin", function (event) {
    if (!event.target.matches("[data-sc-lookup-query]")) return;
    var query = event.target;
    if (!query.dataset.scLookupSelectedValue) searchLookup(query);
  });

  document.addEventListener("scroll", function () {
    document.querySelectorAll("[data-sc-lookup-results].is-portaled:not([hidden])").forEach(function (results) {
      if (results._scLookupQuery) positionLookup(results._scLookupQuery);
    });
  }, true);

  window.addEventListener("resize", function () {
    document.querySelectorAll("[data-sc-lookup-results].is-portaled:not([hidden])").forEach(function (results) {
      if (results._scLookupQuery) positionLookup(results._scLookupQuery);
    });
  });

  document.addEventListener("keydown", function (event) {
    if (!event.target.matches("[data-sc-lookup-query]")) return;
    var query = event.target;
    var elements = lookupElements(query);
    var options = elements.results
      ? Array.from(elements.results.querySelectorAll("[data-sc-lookup-option]")) : [];
    if (event.key === "Escape") {
      closeLookup(query);
      return;
    }
    if (!options.length || (event.key !== "ArrowDown" && event.key !== "ArrowUp" && event.key !== "Enter")) {
      return;
    }
    event.preventDefault();
    var index = Number.isInteger(query._scLookupIndex) ? query._scLookupIndex : -1;
    if (event.key === "ArrowDown") index = Math.min(index + 1, options.length - 1);
    if (event.key === "ArrowUp") index = Math.max(index - 1, 0);
    if (event.key === "Enter" && index >= 0) {
      chooseLookupResult(query, options[index]);
      return;
    }
    query._scLookupIndex = index;
    options.forEach(function (option, optionIndex) {
      var active = optionIndex === index;
      option.classList.toggle("is-active", active);
      option.setAttribute("aria-selected", active ? "true" : "false");
    });
    query.setAttribute("aria-activedescendant", options[index].id);
    options[index].scrollIntoView({block: "nearest"});
  });

  document.addEventListener("click", function (event) {
    var lookupOption = event.target.closest("[data-sc-lookup-option]");
    if (lookupOption) {
      var lookupResults = lookupOption.closest("[data-sc-lookup-results]");
      var lookup = lookupOption.closest("[data-sc-action-lookup]");
      var lookupQuery = (lookupResults && lookupResults._scLookupQuery)
        || (lookup && lookup.querySelector("[data-sc-lookup-query]"));
      if (lookupQuery) chooseLookupResult(lookupQuery, lookupOption);
      return;
    }
    if (!event.target.closest("[data-sc-action-lookup]")) {
      document.querySelectorAll("[data-sc-lookup-query]").forEach(closeLookup);
    }
    var groupMarker = event.target.closest("[data-sc-group-marker]");
    if (groupMarker) {
      var markerResults = groupMarker.closest(".sc-results");
      var markerCell = groupMarker.closest("[data-sc-group-markers]");
      var markerRoot = actionRoot(markerResults, markerCell.dataset.scActionId);
      if (!markerRoot) return;
      var markerState = groupedActionState(markerRoot);
      var rowId = markerCell.dataset.scRowId;
      var markerIndex = Number(groupMarker.dataset.scGroupMarker);
      if (Object.prototype.hasOwnProperty.call(markerState.assignments, rowId)
          && markerState.assignments[rowId] === markerIndex) {
        delete markerState.assignments[rowId];
      } else {
        if (markerIndex === markerState.groupCount) markerState.groupCount += 1;
        markerState.assignments[rowId] = markerIndex;
      }
      renderGroupedActionRows(markerRoot);
      refreshBulkAction(markerRoot);
      return;
    }

    var open = event.target.closest("[data-sc-action-open]");
    if (open && !open.disabled) {
      var root = open.closest("[data-sc-bulk-action]");
      var dialog = document.getElementById(open.dataset.scActionOpen);
      var form = dialog && dialog.querySelector("[data-sc-action-form]");
      var ids = selectedRowIds(root);
      if (!form || ids.length === 0) return;
      form.reset();
      form.querySelectorAll("[data-sc-lookup-query]").forEach(function (query) {
        query.dataset.scLookupSelectedValue = "";
        query.setCustomValidity("");
        closeLookup(query);
      });
      populateActionTargets(form, ids);
      if (actionMode(root) === "groups") renderGroupedActionDialog(root, form);
      var result = form.querySelector("[data-sc-action-result]");
      if (result) {
        result.hidden = true;
        result.textContent = "";
        result.classList.remove("is-success", "is-error");
      }
      var submit = form.querySelector('button[type="submit"]');
      if (submit) {
        submit.disabled = false;
        submit.hidden = false;
        submit.textContent = root.dataset.scActionSubmitLabel || "Apply to selected rows";
      }
      var footerClose = form.querySelector("footer [data-sc-action-close]");
      if (footerClose) footerClose.textContent = "Cancel";
      if (typeof dialog.showModal === "function") dialog.showModal();
      else dialog.setAttribute("open", "");
      return;
    }

    var close = event.target.closest("[data-sc-action-close]");
    if (close) {
      var closeDialog = close.closest("[data-sc-action-dialog]");
      if (!closeDialog) return;
      if (typeof closeDialog.close === "function") closeDialog.close();
      else closeDialog.removeAttribute("open");
    }
  });

  // Source: action-results.js
  function localActionResultUrl(value) {
    if (!value || typeof value !== "string") return "";
    try {
      var url = new URL(value, window.location.href);
      if (url.origin !== window.location.origin) return "";
      return url.pathname + url.search + url.hash;
    } catch (_error) {
      return "";
    }
  }

  function appendActionResultMeta(container, content) {
    if (!content) return;
    if (container.childNodes.length) {
      var separator = document.createElement("span");
      separator.className = "sc-action-built-load-separator";
      separator.textContent = "·";
      container.appendChild(separator);
    }
    if (content instanceof window.Node) container.appendChild(content);
    else {
      var text = document.createElement("span");
      text.textContent = String(content);
      container.appendChild(text);
    }
  }

  function builtLoadLink(load) {
    var loadLabel = "Load " + String(load.load_id);
    var loadUrl = localActionResultUrl(load.load_url);
    if (loadUrl) {
      var loadLink = document.createElement("a");
      loadLink.className = "sc-action-built-load-link";
      loadLink.href = loadUrl;
      loadLink.target = "_blank";
      loadLink.rel = "noopener noreferrer";
      loadLink.textContent = loadLabel;
      return loadLink;
    }
    var loadHeading = document.createElement("strong");
    loadHeading.className = "sc-action-built-load-link";
    loadHeading.textContent = loadLabel;
    return loadHeading;
  }

  function builtLoadMeta(load) {
    var meta = document.createElement("div");
    meta.className = "sc-action-built-load-meta";
    var count = Number(load.order_count);
    if (Number.isFinite(count) && count >= 0) {
      appendActionResultMeta(meta, count + (count === 1 ? " order" : " orders"));
    }
    var carrierUrl = localActionResultUrl(load.carrier_url);
    var carrierLabel = load.carrier_name
      ? String(load.carrier_name) + " (" + String(load.carrier_id || "") + ")"
      : (load.carrier_id ? "Carrier " + String(load.carrier_id) : "");
    if (carrierLabel && carrierUrl) {
      var carrierLink = document.createElement("a");
      carrierLink.href = carrierUrl;
      carrierLink.textContent = carrierLabel;
      appendActionResultMeta(meta, carrierLink);
    } else {
      appendActionResultMeta(meta, carrierLabel);
    }
    var origin = load.origin ? String(load.origin) : "";
    var destination = load.destination ? String(load.destination) : "";
    appendActionResultMeta(meta, origin && destination ? origin + " → " + destination : origin || destination);
    if (Array.isArray(load.order_ids) && load.order_ids.length) {
      appendActionResultMeta(meta, "Orders " + load.order_ids.map(String).join(", "));
    }
    return meta;
  }

  function renderBuiltLoadCard(card, load) {
    card.replaceChildren();
    card.classList.add("is-built");
    if (load.marker && load.marker.color) {
      card.style.setProperty("--sc-marker-color", String(load.marker.color));
    }

    var header = document.createElement("header");
    header.className = "sc-group-action-card-header";
    if (load.marker && typeof load.marker === "object") {
      var marker = document.createElement("span");
      marker.className = "sc-group-dialog-marker";
      marker.appendChild(markerGlyph(load.marker, true));
      header.appendChild(marker);
    }
    var heading = document.createElement("div");
    var title = document.createElement("h4");
    title.appendChild(builtLoadLink(load));
    var summary = document.createElement("p");
    var markerLabel = load.marker && load.marker.label ? String(load.marker.label) : "Grouped";
    summary.textContent = markerLabel + " load built";
    heading.append(title, summary);
    header.appendChild(heading);
    card.append(header, builtLoadMeta(load));
  }

  function renderActionResult(result, payload, succeeded, root) {
    result.replaceChildren();
    var message = document.createElement("div");
    message.className = "sc-action-result-message";
    message.textContent = payload.message || (succeeded ? "Action completed." : "Action failed.");
    result.appendChild(message);
    if (!succeeded || !Array.isArray(payload.loads) || !payload.loads.length) return;

    var unmatched = [];
    payload.loads.forEach(function (load) {
      if (!load || !/^\d+$/.test(String(load.load_id || ""))) return;
      var markerId = load.marker && load.marker.id ? String(load.marker.id) : "";
      var card = root && Array.from(root.querySelectorAll("[data-sc-group-action-card]")).find(function (candidate) {
        return candidate.dataset.scGroupActionCard === markerId;
      });
      if (card) renderBuiltLoadCard(card, load);
      else unmatched.push(load);
    });
    if (!unmatched.length) return;

    var list = document.createElement("ul");
    list.className = "sc-action-built-loads";
    unmatched.forEach(function (load) {
      var item = document.createElement("li");
      item.className = "sc-action-built-load";

      if (load.marker && typeof load.marker === "object") {
        var marker = document.createElement("span");
        marker.className = "sc-group-dialog-marker sc-action-built-load-marker";
        if (load.marker.color) marker.style.setProperty("--sc-marker-color", String(load.marker.color));
        marker.appendChild(markerGlyph(load.marker, true));
        item.appendChild(marker);
      }

      var detail = document.createElement("div");
      detail.append(builtLoadLink(load), builtLoadMeta(load));
      item.appendChild(detail);
      list.appendChild(item);
    });
    if (list.childNodes.length) result.appendChild(list);
  }

  document.addEventListener("submit", function (event) {
    var form = event.target.closest("[data-sc-action-form]");
    if (!form || typeof window.fetch !== "function") return;
    event.preventDefault();
    var root = form.closest("[data-sc-bulk-action]");
    var ids = selectedRowIds(root);
    populateActionTargets(form, ids);
    if (actionMode(root) === "groups") serializeGroupedAction(root, form);
    if (!ids.length || !form.reportValidity()) return;

    var submit = form.querySelector('button[type="submit"]');
    var result = form.querySelector("[data-sc-action-result]");
    if (submit) {
      submit.disabled = true;
      submit.textContent = actionMode(root) === "groups" ? "Building…" : "Applying…";
    }
    if (result) {
      result.hidden = true;
      result.replaceChildren();
      result.classList.remove("is-success", "is-error");
    }

    window.fetch(form.action, {
      method: "POST",
      body: new FormData(form),
      credentials: "same-origin",
      headers: {"Accept": "application/json", "X-Requested-With": "XMLHttpRequest"}
    }).then(function (response) {
      return response.json().catch(function () {
        return {ok: false, message: "The server returned an unreadable action response."};
      }).then(function (payload) {
        return {response: response, payload: payload};
      });
    }).then(function (outcome) {
      var succeeded = outcome.response.ok && outcome.payload.ok;
      if (result) {
        result.hidden = false;
        result.classList.add(succeeded ? "is-success" : "is-error");
        renderActionResult(result, outcome.payload, succeeded, root);
      }
      if (succeeded) {
        if (actionMode(root) === "groups") {
          resetGroupedAction(root);
        } else {
          actionControls(
            bulkActionResults(root), "[data-sc-row-select]:checked", actionIdFor(root)
          ).forEach(function (input) {
            input.checked = false;
          });
        }
        refreshBulkAction(root);
        if (submit) {
          if (actionMode(root) === "groups") submit.hidden = true;
          else submit.textContent = "Applied";
        }
        if (actionMode(root) === "groups") {
          var footerClose = form.querySelector("footer [data-sc-action-close]");
          if (footerClose) footerClose.textContent = "Close";
        }
      } else if (submit) {
        submit.disabled = false;
        submit.textContent = root.dataset.scActionSubmitLabel || "Apply to selected rows";
      }
    }).catch(function () {
      if (result) {
        result.hidden = false;
        result.classList.add("is-error");
        renderActionResult(result, {
          message: "The action request could not reach the server."
        }, false, root);
      }
      if (submit) {
        submit.disabled = false;
        submit.textContent = root.dataset.scActionSubmitLabel || "Apply to selected rows";
      }
    });
  });
})();
