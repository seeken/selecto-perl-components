(function () {
  "use strict";

  var activeBuilderTabs = Object.create(null);
  var collapsedBuilderTrays = Object.create(null);
  var connectionStatus = "Connecting";
  var chartInstances = new WeakMap();
  var dateFormats = [
    ["day", "Day"], ["day_hour", "Day + Hour"], ["week", "Week"],
    ["month", "Month"], ["quarter", "Quarter"], ["year", "Year"],
    ["month_of_year", "Month of Year"], ["day_of_month", "Day of Month"],
    ["day_of_week", "Day of Week"], ["hour", "Hour of Day"]
  ];

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

  function showResultsLoading(form) {
    var workspace = form && form.closest("[data-sc-workspace]");
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
    root.querySelectorAll("[data-sc-picker-root]").forEach(refreshColumnPicker);
  }

  function restoreResultViews() {
    document.querySelectorAll("[data-sc-builder]").forEach(function (root) {
      var selected = root.querySelector('input[name="view"]:checked');
      if (selected) stageResultView(root, selected.value);
    });
  }

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
    document.querySelectorAll("[data-sc-chart]").forEach(initializeChart);
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

  document.addEventListener("DOMContentLoaded", function () {
    renderConnectionStatus();
    restoreBuilderTabs();
    restoreBuilderTrays();
    restoreResultViews();
    restoreCharts();
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
    var form = event.target.closest("[data-sc-builder]");
    if (!form) return;
    showResultsLoading(form);
    setBuilderTrayCollapsed(form.closest("[data-sc-builder-shell]"), true);
    var connection = document.querySelector("[data-selecto-connection]");
    if (connection && connection.classList.contains("is-live")) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    var button = form.querySelector('button[type="submit"]');
    if (button) {
      button.disabled = true;
      button.textContent = "Running…";
    }
    HTMLFormElement.prototype.submit.call(form);
  }, true);

  document.addEventListener("htmx:ws:after:message:incoming", function (event) {
    var incoming = event.detail && event.detail.message;
    if (incoming && typeof incoming.json === "function") {
      incoming.json().then(function (message) {
        var nextUrl = message && message.selecto && message.selecto.url;
        if (typeof nextUrl === "string" && nextUrl.charAt(0) === "/") {
          window.history.replaceState({selecto: true}, "", nextUrl);
        }
      }).catch(function () {});
    }
    window.requestAnimationFrame(function () {
      renderConnectionStatus();
      restoreBuilderTabs();
      restoreBuilderTrays();
      restoreResultViews();
      restoreCharts();
    });
  });

  document.addEventListener("htmx:after:swap", function () {
    restoreBuilderTabs();
    restoreBuilderTrays();
    restoreResultViews();
    restoreCharts();
  });

  document.addEventListener("htmx:before:swap", function (event) {
    destroyChartsWithin(event.detail && event.detail.target);
  });

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
    var badge = builder.querySelector("[data-sc-filter-badge]");
    if (badge) badge.textContent = visualCount + queryLibrarySegmentIds(builder).size;
  }

  function syncPromotedFilterInput(control) {
    var field = control && control.dataset.filterField;
    var kind = control && control.dataset.scPromotedFilterInput;
    if (!field || !kind) return;
    var filterItem = Array.from(document.querySelectorAll("[data-sc-filter-set-item]")).find(function (item) {
      return item.dataset.field === field;
    });
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
    var card = control && control.closest("[data-sc-promoted-filter]");
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
      }
    });
    current.replaceWith(replacement);
  }

  function promotedFilterBuilder(control) {
    var root = control && control.closest("[data-sc-promoted-filters]");
    var submit = root && root.querySelector("button[form]");
    return submit ? document.getElementById(submit.getAttribute("form")) : null;
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
      updateFilterDraft(event.target.closest("[data-sc-filter-set-item]"));
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
      var filterItem = event.target.closest("[data-sc-filter-set-item]");
      var currentValue = filterItem.querySelector('[name="filter_value"]');
      var currentEnd = filterItem.querySelector('[name="filter_value_end"]');
      rebuildFilterValues(
        filterItem,
        currentValue ? currentValue.value : "",
        currentEnd ? currentEnd.value : ""
      );
      updateFilterDraft(filterItem);
    } else if (event.target.matches('[name="filter_value"], [name="filter_value_end"]')) {
      updateFilterDraft(event.target.closest("[data-sc-filter-set-item]"));
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
      groupedActionStates[key] = {groupCount: 0, assignments: Object.create(null), inputs: Object.create(null)};
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

  function groupInputControl(spec, value, groupIndex) {
    var control;
    if (spec.type === "select") {
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

  function renderGroupedActionDialog(root, form) {
    var groups = activeActionGroups(root);
    var specs = groupedActionInputSpecs(root);
    var container = form.querySelector("[data-sc-group-action-groups]");
    if (!container) return;
    container.replaceChildren();
    groups.forEach(function (group) {
      var card = document.createElement("section");
      card.className = "sc-group-action-card";
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
        var label = document.createElement("label");
        label.className = "sc-action-input";
        var caption = document.createElement("span");
        caption.textContent = spec.label + (spec.required ? " *" : "");
        label.append(caption, groupInputControl(spec, group.inputs[spec.id], group.index));
        card.appendChild(label);
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

  document.addEventListener("click", function (event) {
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
        submit.textContent = root.dataset.scActionSubmitLabel || "Apply to selected rows";
      }
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
        result.textContent = outcome.payload.message || (succeeded ? "Action completed." : "Action failed.");
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
        if (submit) submit.textContent = actionMode(root) === "groups" ? "Built" : "Applied";
      } else if (submit) {
        submit.disabled = false;
        submit.textContent = root.dataset.scActionSubmitLabel || "Apply to selected rows";
      }
    }).catch(function () {
      if (result) {
        result.hidden = false;
        result.classList.add("is-error");
        result.textContent = "The action request could not reach the server.";
      }
      if (submit) {
        submit.disabled = false;
        submit.textContent = root.dataset.scActionSubmitLabel || "Apply to selected rows";
      }
    });
  });
})();
