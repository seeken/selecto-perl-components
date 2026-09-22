(function () {
  "use strict";

  // Source: shared.js
  var activeBuilderTabs = Object.create(null);
  var collapsedBuilderTrays = Object.create(null);
  var connectionStatus = "Connecting";
  var chartInstances = new WeakMap();
  var chartRetryTimers = new WeakMap();
  var selectoPerformance = null;
  var selectoSwapStarted = 0;
  var selectoHistorySnapshots = new Map();
  var selectoHistoryCounter = 0;
  var selectoRequestCounter = 0;
  var activeSelectoRequestId = null;
  var selectoWebSocketRecoveryTimer = null;
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

  function chartLibraryAvailable() {
    return typeof window.Chart === "function"
      && typeof window.Chart.register === "function"
      && typeof window.Chart.getChart === "function"
      && typeof window.Chart.version === "string";
  }

  function clearChartRetry(root) {
    var timer = root && chartRetryTimers.get(root);
    if (timer) window.clearTimeout(timer);
    if (root) chartRetryTimers.delete(root);
  }

  function setChartLoading(root) {
    if (!root) return;
    root.classList.remove("is-ready", "is-fallback");
    root.setAttribute("aria-busy", "true");
    root.removeAttribute("data-sc-chart-error");
    var notice = root.querySelector("[data-sc-chart-error-notice]");
    if (notice) notice.hidden = true;
  }

  function prepareChartsForSnapshot(node) {
    if (!node || !node.querySelectorAll) return;
    var roots = Array.from(node.querySelectorAll("[data-sc-chart]"));
    if (node.matches && node.matches("[data-sc-chart]")) roots.unshift(node);
    roots.forEach(function (root) {
      root.classList.remove("is-ready", "is-fallback");
      root.setAttribute("aria-busy", "true");
      root.removeAttribute("data-sc-chart-error");
      var notice = root.querySelector("[data-sc-chart-error-notice]");
      if (notice) notice.remove();
      var canvas = root.querySelector("canvas");
      if (canvas) {
        canvas.removeAttribute("width");
        canvas.removeAttribute("height");
        canvas.removeAttribute("style");
      }
    });
  }

  function scheduleChartInitialization(root, attempt) {
    if (!root || !root.isConnected || chartInstances.has(root)) return;
    clearChartRetry(root);
    var timer = window.setTimeout(function () {
      chartRetryTimers.delete(root);
      if (root.isConnected && !chartInstances.has(root)) initializeChart(root, attempt);
    }, attempt ? 75 * attempt : 0);
    chartRetryTimers.set(root, timer);
  }

  function chartColorWithAlpha(color, alpha) {
    var match = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(color || "");
    if (!match) return color;
    return "rgba(" + parseInt(match[1], 16) + "," + parseInt(match[2], 16) + "," +
      parseInt(match[3], 16) + "," + alpha + ")";
  }

  function formatChartValue(value, unit) {
    if (value === null || typeof value === "undefined") return "—";
    unit = unit || {};
    if (unit.kind === "currency" && unit.code) {
      try {
        return new Intl.NumberFormat(undefined, {
          style: "currency", currency: unit.code, maximumFractionDigits: 2
        }).format(value);
      } catch (_error) {}
    }
    if (unit.kind === "percentage") return Number(value).toLocaleString() + "%";
    if (unit.kind === "count") return Number(value).toLocaleString(undefined, {maximumFractionDigits: 0});
    var formatted = Number(value).toLocaleString(undefined, {maximumFractionDigits: 3});
    return unit.code ? formatted + " " + unit.code : formatted;
  }

  function submitGraphDrilldown(root, index) {
    if (!Number.isInteger(index) || index < 0) return false;
    var form = root.querySelector('[data-sc-graph-drilldown="' + index + '"]');
    if (!form) return false;
    if (typeof form.requestSubmit === "function") form.requestSubmit();
    else form.submit();
    return true;
  }

  function horizontalAxisDrilldownIndex(event, chart, type, data) {
    if (type === "horizontal_bar" || type === "scatter" || type === "pie" || type === "doughnut") {
      return null;
    }
    var scale = chart && chart.scales && chart.scales.x;
    if (!scale || !event || typeof scale.getValueForPixel !== "function") return null;
    if (event.y < scale.top || event.y > scale.bottom || event.x < scale.left || event.x > scale.right) {
      return null;
    }
    var value = Number(scale.getValueForPixel(event.x));
    var index = Math.round(value);
    return Number.isFinite(value) && index >= 0 && index < ((data && data.labels) || []).length
      ? index : null;
  }

  function chartOptions(root, type, data) {
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
        }, label: function (context) {
          var dataset = context.dataset || {};
          var value = context.parsed && typeof context.parsed.y !== "undefined"
            ? context.parsed.y : context.raw;
          return (dataset.label ? dataset.label + ": " : "") + formatChartValue(value, dataset.unit);
        }, afterLabel: function (context) {
          var dataset = context.dataset || {};
          if (!dataset.transforms || !dataset.transforms.length || !dataset.rawData) return "";
          var rawValue = dataset.rawData[context.dataIndex];
          return rawValue === null || typeof rawValue === "undefined" ? "Raw: —" : "Raw: " + rawValue;
        }}}
      },
      onClick: function (event, elements, chart) {
        if (elements.length && submitGraphDrilldown(root, elements[0].index)) return;
        var index = horizontalAxisDrilldownIndex(event, chart, type, data);
        if (index !== null) submitGraphDrilldown(root, index);
      },
      onHover: function (event, elements, chart) {
        if (!chart || !chart.canvas) return;
        var index = horizontalAxisDrilldownIndex(event, chart, type, data);
        chart.canvas.style.cursor = elements.length || index !== null ? "pointer" : "default";
      }
    };
    if (type !== "pie" && type !== "doughnut") {
      var axis = {
        ticks: {color: muted},
        grid: {color: chartColorWithAlpha(border, 0.45)},
        border: {color: border}
      };
      options.scales = {x: Object.assign({}, axis)};
      var axes = data && data.axes ? data.axes : {y: {side: "left"}};
      Object.keys(axes).forEach(function (axisId) {
        var definition = axes[axisId] || {};
        options.scales[axisId] = Object.assign({}, axis, {
          beginAtZero: true,
          position: definition.side === "right" ? "right" : "left",
          title: {display: Boolean(definition.label), text: definition.label || "", color: ink}
        });
        options.scales[axisId].stacked = Boolean(definition.stacked);
        options.scales[axisId].ticks = Object.assign({}, axis.ticks, {
          callback: function (value) { return formatChartValue(value, definition.unit); }
        });
        if (definition.side === "right") {
          options.scales[axisId].grid = Object.assign({}, axis.grid, {drawOnChartArea: false});
        }
      });
      if (Object.keys(axes).some(function (axisId) { return Boolean(axes[axisId].stacked); })) {
        options.scales.x.stacked = true;
      }
    }
    if (type === "horizontal_bar") options.indexAxis = "y";
    if (type === "stacked_bar") {
      options.scales.x.stacked = true;
      options.scales.y.stacked = true;
    }
    return options;
  }

  function initializeChart(root, attempt) {
    attempt = Number(attempt) || 0;
    if (!root || chartInstances.has(root)) return;
    if (!chartLibraryAvailable()) {
      showChartFallback(root, new Error("Chart.js is unavailable"));
      return;
    }
    var canvas = root.querySelector("canvas");
    if (!canvas) {
      showChartFallback(root);
      return;
    }
    var type = root.dataset.chartType || "bar";
    var data;
    try {
      data = JSON.parse(root.dataset.chartData || "{}");
    } catch (error) {
      showChartFallback(root, error);
      return;
    }
    var styles = window.getComputedStyle(root);
    var brand = styles.getPropertyValue("--sc-brand").trim();
    (data.datasets || []).forEach(function (dataset, index) {
      if (brand && index === 0 && dataset.colorAuto !== 0
          && type !== "pie" && type !== "doughnut") {
        dataset.borderColor = brand;
        dataset.backgroundColor = brand;
      }
      var seriesType = dataset.scType || type;
      if (seriesType === "line" || seriesType === "area") dataset.tension = 0.28;
      if (seriesType === "area") {
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
      if (typeof window.Chart.getChart === "function") {
        var stale = window.Chart.getChart(canvas);
        if (stale && typeof stale.destroy === "function") stale.destroy();
      }
      var chart = new window.Chart(canvas, {
        type: chartJsType(type),
        data: data,
        options: chartOptions(root, type, data)
      });
      chartInstances.set(root, chart);
      root.classList.remove("is-fallback");
      root.classList.add("is-ready");
      root.setAttribute("aria-busy", "false");
      root.removeAttribute("data-sc-chart-error");
    } catch (error) {
      if (attempt < 2) {
        setChartLoading(root);
        scheduleChartInitialization(root, attempt + 1);
        return;
      }
      showChartFallback(root, error);
    }
  }

  function showChartFallback(root, error) {
    if (!root) return;
    clearChartRetry(root);
    root.classList.remove("is-ready");
    root.classList.add("is-fallback");
    root.setAttribute("aria-busy", "false");
    var message = error && error.message ? String(error.message) : "Chart initialization failed";
    root.dataset.scChartError = message.slice(0, 240);
    var fallback = root.querySelector(".sc-chart-fallback");
    if (fallback) {
      var notice = fallback.querySelector("[data-sc-chart-error-notice]");
      var text;
      if (!notice) {
        notice = document.createElement("p");
        notice.className = "sc-chart-error";
        notice.dataset.scChartErrorNotice = "";
        text = document.createElement("span");
        text.dataset.scChartErrorMessage = "";
        var retry = document.createElement("button");
        retry.type = "button";
        retry.className = "sc-button sc-secondary";
        retry.dataset.scChartRetry = "";
        retry.textContent = "Retry chart";
        retry.addEventListener("click", function () { retryChart(root); });
        notice.append(text, retry);
        fallback.prepend(notice);
      }
      text = text || notice.querySelector("[data-sc-chart-error-message]");
      if (text) text.textContent = "The interactive chart could not be displayed: " + message;
      notice.hidden = false;
    }
    if (window.console && typeof window.console.warn === "function") {
      window.console.warn("Selecto chart initialization failed", error || message);
    }
  }

  function retryChart(root) {
    if (!root) return;
    clearChartRetry(root);
    var chart = chartInstances.get(root);
    if (chart && typeof chart.destroy === "function") chart.destroy();
    chartInstances.delete(root);
    setChartLoading(root);
    if (chartLibraryAvailable()) {
      scheduleChartInitialization(root, 0);
      return;
    }
    chartLoadPromise = null;
    loadChartLibrary(root).then(function () {
      scheduleChartInitialization(root, 0);
    }).catch(function (error) {
      showChartFallback(root, error);
    });
  }

  function loadChartsForRoots(roots, attempt) {
    roots = roots.filter(function (root) { return root.isConnected; });
    if (!roots.length) return;
    if (chartLibraryAvailable()) {
      roots.forEach(function (root) { scheduleChartInitialization(root, 0); });
      return;
    }
    loadChartLibrary(roots[0]).then(function () {
      roots.filter(function (root) { return root.isConnected; }).forEach(function (root) {
        scheduleChartInitialization(root, 0);
      });
    }).catch(function (error) {
      if (attempt < 2) {
        chartLoadPromise = null;
        window.setTimeout(function () { loadChartsForRoots(roots, attempt + 1); }, 100 * (attempt + 1));
        return;
      }
      roots.filter(function (root) { return root.isConnected; }).forEach(function (root) {
        showChartFallback(root, error);
      });
    });
  }

  function restoreCharts(refreshExisting) {
    var roots = Array.from(document.querySelectorAll("[data-sc-chart]"));
    if (!roots.length) return;
    var pending = [];
    roots.forEach(function (root) {
      var chart = chartInstances.get(root);
      if (!chart) {
        setChartLoading(root);
        pending.push(root);
        return;
      }
      if (!refreshExisting) return;
      // Browser history can restore the DOM and our WeakMap while discarding
      // or corrupting the canvas backing store. Chart.js may accept resize()
      // and update() in that state yet leave only the HTML fallback visible.
      // Reconstructing from the governed data is deterministic and avoids
      // carrying a stale canvas across bfcache/frame restoration.
      try {
        if (typeof chart.destroy === "function") chart.destroy();
      } catch (_error) {}
      chartInstances.delete(root);
      setChartLoading(root);
      pending.push(root);
    });
    loadChartsForRoots(pending, 0);
  }

  function destroyChartsWithin(node) {
    if (!node || !node.querySelectorAll) return;
    var roots = Array.from(node.querySelectorAll("[data-sc-chart]"));
    if (node.matches && node.matches("[data-sc-chart]")) roots.unshift(node);
    roots.forEach(function (root) {
      clearChartRetry(root);
      var chart = chartInstances.get(root);
      if (chart) chart.destroy();
      chartInstances.delete(root);
    });
  }

  function copyDebugSql(button) {
    var target = document.getElementById(
      button.dataset.scDebugCopySource || button.dataset.scDebugCopy || ""
    );
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
    if (chartLibraryAvailable()) return Promise.resolve();
    if (chartLoadPromise) return chartLoadPromise;
    var surface = root && root.closest("[data-sc-chart-src]");
    var source = surface && surface.dataset.scChartSrc;
    if (!source) return Promise.reject(new Error("Chart library URL is unavailable"));
    chartLoadPromise = new Promise(function (resolve, reject) {
      var script = document.createElement("script");
      script.src = source;
      script.async = true;
      script.onload = function () {
        if (chartLibraryAvailable()) {
          resolve();
          return;
        }
        chartLoadPromise = null;
        reject(new Error("Chart library loaded without providing Chart.js"));
      };
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
    if (row.dataset.scRowClickType === "iframe_modal"
        || row.dataset.scRowClickType === "record_editor") {
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
    var kind = dialog.dataset.scRowDialogKind || "iframe_modal";
    return Array.from(root.querySelectorAll("[data-sc-row-click-type]")).filter(
      function (row) {
        return row.dataset.scRowClickType === kind
          && row.dataset.scRowDialogId === dialog.id
          && row.dataset.scRowRetired !== "1";
      }
    );
  }

  function replaceEditorBody(body, html) {
    if (!body) return;
    var parsed = new DOMParser().parseFromString(String(html || ""), "text/html");
    var nodes = Array.from(parsed.body.childNodes).map(function (node) {
      return document.importNode(node, true);
    });
    body.replaceChildren.apply(body, nodes);
  }

  function recordEditorSignature(form) {
    var values = [];
    new FormData(form).forEach(function (value, name) {
      if (name.indexOf("editor_field_") === 0) values.push([name, String(value)]);
    });
    values.sort(function (left, right) {
      return left[0] === right[0] ? left[1].localeCompare(right[1]) : left[0].localeCompare(right[0]);
    });
    return JSON.stringify(values);
  }

  function updateRecordEditorDirty(form) {
    if (!form) return false;
    var dirty = recordEditorSignature(form) !== (form.dataset.scInitialValues || "[]");
    form.dataset.scRecordEditorDirty = dirty ? "1" : "0";
    var save = form.querySelector("[data-sc-record-editor-save]");
    if (save) save.disabled = !dirty;
    return dirty;
  }

  function initializeRecordEditor(form) {
    if (!form) return;
    form.dataset.scInitialValues = recordEditorSignature(form);
    updateRecordEditorDirty(form);
  }

  function recordEditorIsDirty(dialog) {
    var form = dialog && dialog.querySelector("[data-sc-record-editor-form]");
    return form ? updateRecordEditorDirty(form) : false;
  }

  function confirmEditorDiscard(dialog) {
    return !recordEditorIsDirty(dialog)
      || window.confirm("Discard the unsaved changes to this record?");
  }

  function preserveRowDialogHostTitle(dialog) {
    if (!dialog || !dialog.querySelector("[data-sc-row-dialog-frame]")) return;
    if (!Object.prototype.hasOwnProperty.call(dialog, "_scHostDocumentTitle")) {
      dialog._scHostDocumentTitle = document.title;
      if (typeof MutationObserver === "function" && document.head) {
        dialog._scHostTitleObserver = new MutationObserver(function () {
          restoreRowDialogHostTitle(dialog, false);
        });
        dialog._scHostTitleObserver.observe(document.head, {
          childList: true,
          characterData: true,
          subtree: true
        });
      }
    }
  }

  function restoreRowDialogHostTitle(dialog, release) {
    if (!dialog || !Object.prototype.hasOwnProperty.call(dialog, "_scHostDocumentTitle")) return;
    if (release && dialog._scHostTitleObserver) {
      dialog._scHostTitleObserver.disconnect();
      delete dialog._scHostTitleObserver;
    }
    if (document.title !== dialog._scHostDocumentTitle) {
      document.title = dialog._scHostDocumentTitle;
    }
    if (release) delete dialog._scHostDocumentTitle;
  }

  function loadRecordEditor(dialog, url, notice) {
    var body = dialog.querySelector("[data-sc-row-editor-body]");
    var loading = dialog.querySelector("[data-sc-row-dialog-loading]");
    if (!body) return Promise.resolve();
    if (dialog._scEditorAbort) dialog._scEditorAbort.abort();
    var abort = typeof AbortController === "function" ? new AbortController() : null;
    dialog._scEditorAbort = abort;
    if (!notice) body.replaceChildren();
    body.setAttribute("aria-busy", "true");
    if (loading) loading.hidden = !!notice;
    return window.fetch(url, {
      credentials: "same-origin",
      headers: {"X-Requested-With": "XMLHttpRequest"},
      signal: abort ? abort.signal : undefined
    }).then(function (response) {
      return response.text().then(function (html) {
        if (!response.ok) throw new Error(html.replace(/<[^>]*>/g, " ").trim()
          || "The editor could not be loaded.");
        return html;
      });
    }).then(function (html) {
      if (dialog._scEditorAbort !== abort) return;
      replaceEditorBody(body, html);
      initializeRecordEditor(body.querySelector("[data-sc-record-editor-form]"));
      if (notice) {
        var result = body.querySelector("[data-sc-record-editor-result]");
        if (result) {
          result.textContent = notice;
          result.hidden = false;
          result.classList.add("is-success");
        }
      }
      var first = body.querySelector("input:not([type=hidden]),textarea,select,button");
      if (first) first.focus();
    }).catch(function (error) {
      if (error && error.name === "AbortError") return;
      body.replaceChildren();
      var message = document.createElement("div");
      message.className = "sc-record-editor-error-panel";
      message.setAttribute("role", "alert");
      message.textContent = error && error.message || "The editor could not be loaded.";
      body.appendChild(message);
    }).finally(function () {
      if (dialog._scEditorAbort === abort) {
        body.removeAttribute("aria-busy");
        if (loading) loading.hidden = true;
      }
    });
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
    if (dialog.dataset.scRowDialogKind === "record_editor") {
      loadRecordEditor(dialog, url);
      return;
    }
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
    if (dialog.open && !confirmEditorDiscard(dialog)) return;
    var rows = rowDialogRows(dialog);
    var index = rows.indexOf(row);
    if (index < 0) return;
    preserveRowDialogHostTitle(dialog);
    setRowDialogIndex(dialog, index);
    if (!dialog.open) {
      if (typeof dialog.showModal === "function") dialog.showModal();
      else dialog.setAttribute("open", "");
    }
  }

  function moveRowDialog(dialog, offset) {
    if (!dialog) return;
    if (!confirmEditorDiscard(dialog)) return;
    var current = Number(dialog.dataset.scRowDialogIndex || 0);
    setRowDialogIndex(dialog, current + offset);
  }

  function clearRowDialog(dialog) {
    if (!dialog) return;
    if (dialog._scEditorAbort) {
      dialog._scEditorAbort.abort();
      dialog._scEditorAbort = null;
    }
    var frame = dialog.querySelector("[data-sc-row-dialog-frame]");
    var editorBody = dialog.querySelector("[data-sc-row-editor-body]");
    var loading = dialog.querySelector("[data-sc-row-dialog-loading]");
    if (frame) {
      frame.removeAttribute("src");
      frame.classList.remove("is-loading");
    }
    restoreRowDialogHostTitle(dialog, true);
    if (editorBody) editorBody.replaceChildren();
    if (loading) loading.hidden = true;
    delete dialog.dataset.scRowDialogIndex;
  }

  function closeRowDialog(dialog) {
    if (!dialog) return;
    var retiredFocus = dialog._scRetiredFocus;
    dialog._scRetiredFocus = null;
    clearRowDialog(dialog);
    if (typeof dialog.close === "function") dialog.close();
    else dialog.removeAttribute("open");
    if (retiredFocus && retiredFocus.isConnected) retiredFocus.focus();
  }

  function retireEditedRow(row, minimal) {
    if (!row) return null;
    if (row.dataset.scRowRetired === "1") {
      var existingNotice = row.nextElementSibling;
      return row.querySelector(".sc-row-retired-badge")
        || existingNotice && existingNotice.matches(".sc-row-retired-notice")
          && existingNotice.querySelector(".sc-row-retired-badge");
    }
    row.dataset.scRowRetired = "1";
    row.classList.add("sc-row-retired");
    row.setAttribute("aria-disabled", "true");
    row.removeAttribute("tabindex");
    row.removeAttribute("data-sc-row-click");
    row.removeAttribute("data-sc-row-click-url");
    row.querySelectorAll("a,button,input,select,textarea").forEach(function (control) {
      if ("disabled" in control) control.disabled = true;
      if ("checked" in control) control.checked = false;
      control.setAttribute("tabindex", "-1");
    });
    var cells = Array.from(row.children).filter(function (cell) {
      return cell.matches("td,th");
    });
    if (!cells.length) return null;
    var statusHost;
    if (minimal) {
      var first = cells[0];
      first.colSpan = cells.length;
      first.replaceChildren();
      cells.slice(1).forEach(function (cell) { cell.remove(); });
      var identity = document.createElement("span");
      identity.className = "sc-row-retired-identity";
      identity.textContent = "Record " + (row.dataset.scRecordId || "");
      first.appendChild(identity);
      statusHost = first;
    } else {
      var noticeRow = document.createElement("tr");
      noticeRow.className = "sc-row-retired-notice";
      noticeRow.dataset.scRowRetiredNotice = row.dataset.scRecordId || "";
      var noticeCell = document.createElement("td");
      noticeCell.colSpan = cells.length;
      statusHost = document.createElement("div");
      statusHost.className = "sc-row-retired-notice-content";
      noticeCell.appendChild(statusHost);
      noticeRow.appendChild(noticeCell);
      row.insertAdjacentElement("afterend", noticeRow);
    }
    var badge = document.createElement("span");
    badge.className = "sc-row-retired-badge";
    badge.textContent = minimal
      ? "Updated — no longer available"
      : "Updated — no longer matches this result";
    badge.setAttribute("role", "status");
    badge.setAttribute("tabindex", "-1");
    statusHost.appendChild(document.createTextNode(" "));
    statusHost.appendChild(badge);
    var refresh = document.createElement("button");
    refresh.type = "button";
    refresh.className = "sc-button sc-secondary sc-row-retired-refresh";
    refresh.dataset.scRefreshResults = "1";
    refresh.textContent = "Refresh results";
    statusHost.appendChild(refresh);
    var results = row.closest(".sc-results");
    if (results) {
      var total = results.querySelector(".sc-result-meta strong");
      var count = total && Number(String(total.textContent).replace(/,/g, ""));
      if (total && Number.isFinite(count) && count > 0) total.textContent = String(count - 1);
      results.querySelectorAll("[data-sc-bulk-action]").forEach(function (root) {
        refreshBulkAction(root);
      });
    }
    return badge;
  }

  function synchronizeEditedRow(dialog, payload) {
    var currentRows = rowDialogRows(dialog);
    var current = currentRows[Number(dialog.dataset.scRowDialogIndex || 0)];
    var rowId = String(payload.row_id || current && current.dataset.scRecordId || "");
    if (!current || !rowId) return Promise.resolve({retired: true});
    if (!payload.authorized) {
      dialog._scRetiredFocus = retireEditedRow(current, true);
      return Promise.resolve({retired: true});
    }
    var returnUrl = new URL(payload.return_to || window.location.href, window.location.href);
    var ordered = returnUrl.searchParams.getAll("order");
    if ((payload.changed_fields || []).some(function (field) { return ordered.includes(field); })) {
      window.location.assign(returnUrl.pathname + returnUrl.search + returnUrl.hash);
      return Promise.resolve({navigating: true});
    }
    return window.fetch(payload.return_to || window.location.href, {
      credentials: "same-origin",
      headers: {"X-Requested-With": "XMLHttpRequest"}
    }).then(function (response) {
      if (!response.ok) throw new Error("The updated result could not be refreshed.");
      return response.text();
    }).then(function (html) {
      var parsed = new DOMParser().parseFromString(html, "text/html");
      var replacement = Array.from(parsed.querySelectorAll("[data-sc-record-id]")).find(
        function (candidate) { return candidate.dataset.scRecordId === rowId; }
      );
      if (!replacement) {
        dialog._scRetiredFocus = retireEditedRow(current, false);
        return {retired: true};
      }
      var imported = document.importNode(replacement, true);
      current.replaceWith(imported);
      return {row: imported};
    }).catch(function () {
      window.location.assign(payload.return_to || window.location.href);
      return {navigating: true};
    });
  }

  function finishEditorMutation(dialog, payload, message) {
    return synchronizeEditedRow(dialog, payload).then(function (outcome) {
      if (!outcome || outcome.navigating) return;
      if (payload.close_dialog || outcome.retired) {
        closeRowDialog(dialog);
        return;
      }
      var editorUrl = outcome.row && outcome.row.dataset.scRowClickUrl;
      if (!editorUrl) {
        closeRowDialog(dialog);
        return;
      }
      return loadRecordEditor(dialog, editorUrl, message);
    });
  }

  document.addEventListener("submit", function (event) {
    var form = event.target.closest && event.target.closest("[data-sc-record-editor-form]");
    if (!form || typeof window.fetch !== "function") return;
    event.preventDefault();
    if (!form.reportValidity()) return;
    var dialog = form.closest("[data-sc-row-dialog]");
    var submit = form.querySelector('button[type="submit"]');
    var result = form.querySelector("[data-sc-record-editor-result]");
    form.querySelectorAll("[data-sc-record-editor-error]").forEach(function (node) {
      node.hidden = true;
      node.textContent = "";
    });
    if (submit) {
      submit.disabled = true;
      submit.dataset.scOriginalLabel = submit.textContent;
      submit.textContent = "Saving…";
    }
    if (result) {
      result.hidden = true;
      result.textContent = "";
      result.classList.remove("is-success", "is-error");
    }
    window.fetch(form.action, {
      method: "POST", body: new FormData(form), credentials: "same-origin",
      headers: {"Accept": "application/json", "X-Requested-With": "XMLHttpRequest"}
    }).then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (payload) {
        payload._responseOk = response.ok;
        return payload;
      });
    }).then(function (payload) {
      if (!payload._responseOk || !payload.ok) {
        Object.keys(payload.field_errors || {}).forEach(function (field) {
          var wrapper = form.querySelector('[data-sc-record-editor-field="' +
            (window.CSS && CSS.escape ? CSS.escape(field) : field) + '"]');
          var error = wrapper && wrapper.querySelector("[data-sc-record-editor-error]");
          if (error) {
            error.textContent = payload.field_errors[field];
            error.hidden = false;
          }
        });
        throw new Error(payload.message || "The record could not be saved.");
      }
      form.dataset.scInitialValues = recordEditorSignature(form);
      form.dataset.scRecordEditorDirty = "0";
      return finishEditorMutation(
        dialog, payload, payload.message || "The record was updated."
      );
    }).catch(function (error) {
      if (result) {
        result.textContent = error && error.message || "The record could not be saved.";
        result.hidden = false;
        result.classList.add("is-error");
      }
    }).finally(function () {
      if (submit && submit.isConnected) {
        submit.disabled = false;
        submit.textContent = submit.dataset.scOriginalLabel || "Save changes";
      }
    });
  });

  document.addEventListener("input", function (event) {
    var form = event.target.closest && event.target.closest("[data-sc-record-editor-form]");
    if (form) updateRecordEditorDirty(form);
  });

  document.addEventListener("change", function (event) {
    var form = event.target.closest && event.target.closest("[data-sc-record-editor-form]");
    if (form) updateRecordEditorDirty(form);
  });

  document.addEventListener("click", function (event) {
    var open = event.target.closest
      && event.target.closest("[data-sc-record-editor-action-open]");
    var close = event.target.closest
      && event.target.closest("[data-sc-record-editor-action-close]");
    if (!open && !close) return;
    var actions = (open || close).closest(".sc-record-editor-actions");
    if (!actions) return;
    var panels = Array.from(actions.querySelectorAll("[data-sc-record-editor-action-panel]"));
    var buttons = Array.from(actions.querySelectorAll("[data-sc-record-editor-action-open]"));
    panels.forEach(function (panel) { panel.hidden = true; });
    buttons.forEach(function (button) { button.setAttribute("aria-expanded", "false"); });
    actions.classList.remove("is-action-open");
    if (close) {
      var owner = buttons.find(function (button) {
        return button.dataset.scRecordEditorActionOpen === close.closest("form").id;
      });
      if (owner) owner.focus();
      return;
    }
    var panelId = open.dataset.scRecordEditorActionOpen;
    var panel = panels.find(function (candidate) { return candidate.id === panelId; });
    if (!panel) return;
    panel.hidden = false;
    open.setAttribute("aria-expanded", "true");
    actions.classList.add("is-action-open");
    var firstInput = panel.querySelector("input:not([type=hidden]),select,textarea,button[type=submit]");
    if (firstInput) firstInput.focus();
  });

  document.addEventListener("submit", function (event) {
    var form = event.target.closest && event.target.closest("[data-sc-record-editor-action-form]");
    if (!form || typeof window.fetch !== "function") return;
    event.preventDefault();
    if (!form.reportValidity()) return;
    var dialog = form.closest("[data-sc-row-dialog]");
    var submit = form.querySelector('button[type="submit"]');
    var result = form.querySelector("[data-sc-action-result]");
    if (submit) {
      submit.disabled = true;
      submit.dataset.scOriginalLabel = submit.textContent;
      submit.textContent = "Applying…";
    }
    if (result) {
      result.hidden = true;
      result.textContent = "";
      result.classList.remove("is-success", "is-error");
    }
    window.fetch(form.action, {
      method: "POST", body: new FormData(form), credentials: "same-origin",
      headers: {"Accept": "application/json", "X-Requested-With": "XMLHttpRequest"}
    }).then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (payload) {
        payload._responseOk = response.ok;
        return payload;
      });
    }).then(function (payload) {
      if (!payload._responseOk || !payload.ok) {
        throw new Error(payload.message || "The action could not be completed.");
      }
      if (!Object.prototype.hasOwnProperty.call(payload, "row_id")) {
        payload.row_id = form.dataset.scRecordId;
      }
      if (!Object.prototype.hasOwnProperty.call(payload, "return_to")) {
        payload.return_to = form.dataset.scReturnTo;
      }
      if (!Object.prototype.hasOwnProperty.call(payload, "authorized")) payload.authorized = 1;
      if (!Array.isArray(payload.changed_fields)) payload.changed_fields = [];
      return finishEditorMutation(
        dialog, payload, payload.message || "The action was completed."
      );
    }).catch(function (error) {
      if (result) {
        result.textContent = error && error.message || "The action could not be completed.";
        result.hidden = false;
        result.classList.add("is-error");
      }
    }).finally(function () {
      if (submit && submit.isConnected) {
        submit.disabled = false;
        submit.textContent = submit.dataset.scOriginalLabel || "Apply";
      }
    });
  });

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
      if (!prepareTemplateWebSocketMessage(message)) detail.cancelled = true;
    }).catch(function () {}));
  });

  document.addEventListener("htmx:ws:after:message:incoming", function (event) {
    var incoming = event.detail && event.detail.message;
    if (incoming && typeof incoming.json === "function") {
      incoming.json().then(function (message) {
        reconcileTemplateWebSocketMessage(message);
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
    reconcileTemplateHttpSwap(ctx);
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
    if (!prepareTemplateHttpSwap(ctx)) {
      event.preventDefault();
      return;
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

  // Source: picker.js
  function setItems(root) {
    return Array.from(root.querySelectorAll("[data-sc-picker-set-item]"));
  }

  var activeDraggedItem = null;

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
    if (choice.hasAttribute("data-sc-picker-repeatable")) {
      item.setAttribute("data-sc-picker-repeatable", "");
    }
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
    var seriesId = document.createElement("input");
    seriesId.type = "hidden";
    seriesId.name = "measure_series_id";
    var usedSeriesIds = new Set(Array.from(
      document.querySelectorAll('input[name="measure_series_id"]'),
      function (input) { return input.value; }
    ));
    var nextSeries = 1;
    while (usedSeriesIds.has("series_" + nextSeries)) nextSeries += 1;
    seriesId.value = "series_" + nextSeries;
    grid.appendChild(seriesId);
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
    appendOptions(nulls, [
      ["0", "Keep SQL SUM behavior"], ["1", "Always treat NULL as 0"],
      ["auto", "Automatic for view"]
    ], "auto");
    appendConfigLabel(grid, "NULL handling", nulls, "data-sc-measure-sum");

    var chartType = document.createElement("select");
    chartType.name = "measure_chart_type";
    chartType.setAttribute("aria-label", "Series style for " + label);
    appendOptions(chartType, [
      ["auto", "Use chart default"], ["bar", "Bar"], ["line", "Line"], ["area", "Area"]
    ], "auto");
    appendConfigLabel(grid, "Series style", chartType);

    var axis = document.createElement("select");
    axis.name = "measure_axis";
    axis.setAttribute("aria-label", "Y axis for " + label);
    appendOptions(axis, [["auto", "Automatic"], ["left", "Left"], ["right", "Right"]], "auto");
    appendConfigLabel(grid, "Y axis", axis);

    var stack = document.createElement("input");
    stack.name = "measure_stack";
    stack.maxLength = 32;
    stack.pattern = "[a-z][a-z0-9_]*";
    stack.placeholder = "e.g. expenses";
    stack.setAttribute("aria-label", "Stack group for " + label);
    appendConfigLabel(grid, "Stack group", stack);

    var colorControl = document.createElement("div");
    colorControl.className = "sc-series-color";
    colorControl.setAttribute("data-sc-measure-color-control", "");
    var colorTitle = document.createElement("span");
    colorTitle.textContent = "Series color";
    colorControl.appendChild(colorTitle);
    var colorValue = document.createElement("input");
    colorValue.type = "hidden";
    colorValue.name = "measure_color";
    colorControl.appendChild(colorValue);
    var colorPicker = document.createElement("input");
    colorPicker.type = "color";
    colorPicker.value = "#55d6be";
    colorPicker.disabled = true;
    colorPicker.setAttribute("data-sc-measure-color-picker", "");
    colorPicker.setAttribute("aria-label", "Color for " + label);
    colorControl.appendChild(colorPicker);
    var autoLabel = document.createElement("label");
    autoLabel.className = "sc-option-check";
    var autoColor = document.createElement("input");
    autoColor.type = "checkbox";
    autoColor.checked = true;
    autoColor.setAttribute("data-sc-measure-color-auto", "");
    autoLabel.appendChild(autoColor);
    var autoText = document.createElement("span");
    autoText.textContent = "Automatic contrasting color";
    autoLabel.appendChild(autoText);
    colorControl.appendChild(autoLabel);
    grid.appendChild(colorControl);

    var transform = document.createElement("select");
    transform.name = "measure_transform";
    transform.setAttribute("data-sc-measure-transform", "");
    transform.setAttribute("aria-label", "Analytical transform for " + label);
    appendOptions(transform, [
      ["", "None"], ["percent_of_total", "Percent of total"],
      ["percent_change", "Percent change"], ["index_to_first", "Index to first value"],
      ["cumulative", "Cumulative total"], ["moving_average", "Moving average"]
    ], "");
    appendConfigLabel(grid, "Transform", transform);

    var windowInput = document.createElement("input");
    windowInput.type = "number";
    windowInput.name = "measure_transform_window";
    windowInput.min = "2";
    windowInput.max = "365";
    windowInput.value = "3";
    windowInput.setAttribute("aria-label", "Moving-average window for " + label);
    appendConfigLabel(grid, "Moving window", windowInput, "data-sc-measure-transform-window");
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
    var measureTransform = item.querySelector("[data-sc-measure-transform]");
    if (measureTransform) {
      item.querySelectorAll("[data-sc-measure-transform-window]").forEach(function (node) {
        node.hidden = measureTransform.value !== "moving_average";
      });
    }
  }

  function syncMeasureColor(item, source) {
    var control = item && item.querySelector("[data-sc-measure-color-control]");
    if (!control) return;
    var hidden = control.querySelector('input[name="measure_color"]');
    var picker = control.querySelector("[data-sc-measure-color-picker]");
    var automatic = control.querySelector("[data-sc-measure-color-auto]");
    if (!hidden || !picker || !automatic) return;
    if (source === picker) automatic.checked = false;
    picker.disabled = automatic.checked;
    hidden.value = automatic.checked ? "" : picker.value.toLowerCase();
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
    ["Months", "mtd_all_years", "Month to Date (All Years)"],
    ["Quarters", "this_quarter", "This Quarter"],
    ["Quarters", "last_quarter", "Last Quarter"],
    ["Quarters", "next_quarter", "Next Quarter"],
    ["Quarters", "qtd", "Quarter to Date"],
    ["Quarters", "qtd_all_years", "Quarter to Date (All Years)"],
    ["Years", "this_year", "This Year"],
    ["Years", "last_year", "Last Year"],
    ["Years", "next_year", "Next Year"],
    ["Years", "ytd", "Year to Date"],
    ["Years", "ytd_all_years", "Year to Date (All Years)"],
    ["Relative periods", "last_7_days", "Last 7 Days"],
    ["Relative periods", "last_30_days", "Last 30 Days"],
    ["Relative periods", "last_90_days", "Last 90 Days"],
    ["Relative periods", "next_7_days", "Next 7 Days"],
    ["Relative periods", "next_30_days", "Next 30 Days"]
  ];

  function dateShortcutsFor(node) {
    var builder = node && node.closest("[data-sc-date-shortcuts]");
    if (!builder) return dateShortcuts;
    try {
      var configured = JSON.parse(builder.dataset.scDateShortcuts || "[]");
      return Array.isArray(configured) && configured.length ? configured : dateShortcuts;
    } catch (_error) {
      return dateShortcuts;
    }
  }

  // Source: filters.js
  function temporalFilterType(type) {
    return /(?:date|time)/i.test(type || "");
  }

  function temporalFilterInputType(type, values) {
    if (String(type || "").toLowerCase() === "date") return "date";
    var populated = (values || []).filter(function (value) {
      return String(value || "").length;
    });
    if (populated.length && populated.every(function (value) {
      return /^\d{4}-\d{2}-\d{2}$/.test(String(value));
    })) return "date";
    return "datetime-local";
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
      var availableShortcuts = dateShortcutsFor(item);
      var selectedShortcut = availableShortcuts.some(function (entry) {
        return entry[1] === previousValue;
      }) ? previousValue : "today";
      var groups = {};
      availableShortcuts.forEach(function (entry) {
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
        temporalFilterInputType(type, [previousValue, previousEnd]) :
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
        temporalFilterInputType(type, [previousValue]) :
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
    var filterInstance = control.dataset.filterInstance;
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
        return item.dataset.field === field &&
          (!filterInstance || item.dataset.filterInstance === filterInstance);
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
        if (control.dataset.filterInstance) {
          input.dataset.filterInstance = control.dataset.filterInstance;
        }
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
    } else if (event.target.matches("[data-sc-group-format], [data-sc-measure-function], [data-sc-measure-transform]")) {
      syncPickerConfig(event.target.closest("[data-sc-picker-set-item]"));
    } else if (event.target.matches("[data-sc-measure-color-auto], [data-sc-measure-color-picker]")) {
      syncMeasureColor(event.target.closest("[data-sc-picker-set-item]"), event.target);
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
      if (!control.hasAttribute("data-sc-picker-repeatable")) control.remove();
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
      if (available && !item.hasAttribute("data-sc-picker-repeatable")) {
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
      refreshFilterPicker(root);
      markBuilderDirty(root);
      return;
    }

    if (control.dataset.scFilterAction === "remove") {
      var item = control.closest("[data-sc-filter-set-item]");
      if (!item) return;
      item.remove();
      refreshFilterPicker(root);
      markBuilderDirty(root);
    }
  });

  document.addEventListener("dragstart", function (event) {
    var item = event.target.closest("[data-sc-picker-set-item]");
    if (!item) return;
    item.classList.add("is-dragging");
    activeDraggedItem = item;
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
    var dragged = activeDraggedItem;
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
    activeDraggedItem = null;
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

  function actionMaxRows(root) {
    var value = Number(root && root.dataset.scActionMaxRows);
    return Number.isInteger(value) && value > 0 ? value : Infinity;
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
    if (actionMode(root) === "row-dialog" || actionMode(root) === "row-inline") {
      return root && root.dataset.scRowId ? [root.dataset.scRowId] : [];
    }
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
    if (actionMode(root) === "row-dialog" || actionMode(root) === "row-inline") return;
    root.querySelectorAll("[data-sc-action-open]").forEach(function (button) {
      button.disabled = ids.length === 0 || button.dataset.scActionDisabled === "1";
    });
    var results = bulkActionResults(root);
    var pageToggle = actionControls(results, "[data-sc-select-page]", actionId)[0];
    var rowToggles = actionControls(results, "[data-sc-row-select]", actionId);
    var checked = rowToggles.filter(function (input) { return input.checked; }).length;
    var maximum = actionMaxRows(root);
    rowToggles.forEach(function (input) {
      input.disabled = !input.checked && checked >= maximum;
    });
    if (pageToggle) {
      pageToggle.checked = rowToggles.length > 0 && checked === rowToggles.length;
      pageToggle.indeterminate = checked > 0 && checked < rowToggles.length;
      pageToggle.disabled = maximum < rowToggles.length;
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
      var pageRoot = actionRoot(results, actionId);
      var maximum = actionMaxRows(pageRoot);
      actionControls(results, "[data-sc-row-select]", actionId).forEach(function (input, index) {
        input.checked = event.target.checked && index < maximum;
      });
      refreshBulkAction(pageRoot);
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
      var openResults = open.closest(".sc-results");
      var root = open.closest("[data-sc-bulk-action]")
        || actionRoot(openResults, open.dataset.scActionId);
      if (root && open.dataset.scRowActionTarget) {
        root.dataset.scRowId = open.dataset.scRowActionTarget;
      }
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
    if (form.matches("[data-sc-record-editor-action-form]")) return;
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

  // Source: templates.js
  // Template transport consistency is independent from the Explorer lifecycle.
  // The generated bundle keeps these functions private inside its shared closure.
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
  var templateEventQueues = new Map();
  var templateEventKeysById = new Map();
  var templateEventQueueLimit = 16;

  function templateEventFormInfo(form) {
    if (!(form instanceof HTMLFormElement)) return null;
    var action = form.querySelector('input[name="template_action"]');
    var event = form.querySelector('input[name="event"]');
    var eventId = form.querySelector('input[name="event_id"]');
    var revision = form.querySelector('input[name="state_revision"]');
    var root = form.closest("[data-selecto-template-instance]");
    var region = form.closest("[data-selecto-template-node]");
    if (!action || action.value !== "event" || !event || !event.value
        || !eventId || !eventId.value || !revision || !root || !region) return null;
    var values = new FormData(form).getAll("value");
    if (values.length !== 1 || typeof values[0] !== "string") return null;
    var key = [
      root.dataset.selectoTemplateInstance,
      region.dataset.selectoTemplateNode,
      event.value
    ].join("\u0000");
    return {
      key: key,
      instance_id: root.dataset.selectoTemplateInstance,
      node_id: region.dataset.selectoTemplateNode,
      event: event.value,
      event_id: eventId.value,
      value: values[0]
    };
  }

  function emitTemplateQueueEvent(name, entry, reason) {
    var root = entry && templateRootForInstance(entry.instance_id);
    (root || document).dispatchEvent(new CustomEvent(name, {
      bubbles: true,
      detail: {
        instance_id: entry && entry.instance_id,
        node_id: entry && entry.node_id,
        event: entry && entry.event,
        reason: reason
      }
    }));
  }

  function currentTemplateEventForm(entry) {
    var root = templateRootForInstance(entry.instance_id);
    if (!root) return null;
    for (var region of root.querySelectorAll("[data-selecto-template-node]")) {
      if (region.dataset.selectoTemplateNode !== entry.node_id) continue;
      for (var form of region.querySelectorAll("form")) {
        var info = templateEventFormInfo(form);
        if (info && info.key === entry.key) return form;
      }
    }
    return null;
  }

  function setTemplateEventValue(form, value) {
    var controls = form.querySelectorAll('[name="value"]');
    if (controls.length !== 1
        || !(controls[0] instanceof HTMLInputElement
          || controls[0] instanceof HTMLSelectElement
          || controls[0] instanceof HTMLTextAreaElement)) return false;
    controls[0].value = value;
    return true;
  }

  function resetTemplateEventValue(form) {
    var controls = form.querySelectorAll('[name="value"]');
    if (controls.length !== 1) return false;
    var control = controls[0];
    if (control instanceof HTMLSelectElement) {
      for (var option of control.options) option.selected = option.defaultSelected;
      return true;
    }
    if (control instanceof HTMLInputElement
        || control instanceof HTMLTextAreaElement) {
      control.value = control.defaultValue;
      return true;
    }
    return false;
  }

  function cancelTemplateEventEntry(entry, reason) {
    if (!entry) return;
    if (entry.in_flight_event_id) {
      templateEventKeysById.delete(entry.in_flight_event_id);
    }
    templateEventQueues.delete(entry.key);
    emitTemplateQueueEvent("selecto:template:queue:cancelled", entry, reason);
  }

  function completeTemplateEvent(eventId, accepted) {
    if (typeof eventId !== "string" || !eventId) return;
    var key = templateEventKeysById.get(eventId);
    if (!key) return;
    templateEventKeysById.delete(eventId);
    var entry = templateEventQueues.get(key);
    if (!entry || entry.in_flight_event_id !== eventId) return;
    entry.in_flight_event_id = null;
    if (!accepted) return cancelTemplateEventEntry(entry, "request_failed");
    var form = currentTemplateEventForm(entry);
    if (form) resetTemplateEventValue(form);
    var queued = entry.pending.shift();
    if (!queued) {
      templateEventQueues.delete(key);
      return;
    }
    if (!form || !setTemplateEventValue(form, queued.value)) {
      return cancelTemplateEventEntry(entry, "form_disposed");
    }
    form.requestSubmit();
  }

  function cancelTemplateEventQueuesForInstance(instanceId, reason) {
    if (typeof instanceId !== "string") return;
    for (var entry of Array.from(templateEventQueues.values())) {
      if (entry.instance_id === instanceId) cancelTemplateEventEntry(entry, reason);
    }
  }

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

  function templateResponseKey(metadata) {
    if (!metadata || typeof metadata.instance_id !== "string") return null;
    var state = normalizedTemplateRevision(metadata.state_revision);
    var store = normalizedTemplateRevision(metadata.store_revision);
    return state === null || store === null
      ? null : metadata.instance_id + "\u0000" + state + "\u0000" + store;
  }

  function applyTemplateMetadata(metadata) {
    if (!metadata || typeof metadata.instance_id !== "string") return;
    var state = normalizedTemplateRevision(metadata.state_revision);
    var store = normalizedTemplateRevision(metadata.store_revision);
    if (state === null || store === null) return;
    var root = templateRootForInstance(metadata.instance_id);
    if (!root) return;
    root.dataset.selectoStateRevision = state;
    root.dataset.selectoStoreRevision = store;
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

  function prepareTemplateWebSocketMessage(message) {
    var target;
    if (message && typeof message.target === "string") {
      try { target = document.querySelector(message.target); }
      catch (_error) { target = null; }
    }
    var metadata = message && message.selecto;
    if (templateResponseIsStale(metadata, target)) return false;
    var key = templateResponseKey(metadata);
    if (!key) return true;
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
    return true;
  }

  function reconcileTemplateWebSocketMessage(message) {
    var metadata = message && message.selecto;
    var key = templateResponseKey(metadata);
    if (!key) {
      if (metadata && metadata.status) {
        var target;
        try { target = document.querySelector(message.target); }
        catch (_error) { target = null; }
        var root = target && target.closest("[data-selecto-template-instance]");
        if (root) {
          cancelTemplateEventQueuesForInstance(
            root.dataset.selectoTemplateInstance, "server_rejected"
          );
        }
      }
      return;
    }
    var snapshot = pendingTemplateControlSnapshots.get(key);
    pendingTemplateControlSnapshots.delete(key);
    applyTemplateMetadata(metadata);
    restoreTemplateControls(snapshot);
    completeTemplateEvent(metadata.event_id, true);
  }

  function prepareTemplateHttpSwap(ctx) {
    var metadata = httpTemplateMetadata(ctx);
    if (templateResponseIsStale(metadata, ctx && ctx.target)) return false;
    if (metadata) {
      ctx.selectoTemplateMetadata = metadata;
      ctx.selectoTemplateControlSnapshot = captureTemplateControls(
        templateRootForInstance(metadata.instance_id, ctx.target), metadata
      );
    }
    return true;
  }

  function reconcileTemplateHttpSwap(ctx) {
    applyTemplateMetadata(ctx && ctx.selectoTemplateMetadata);
    restoreTemplateControls(ctx && ctx.selectoTemplateControlSnapshot);
  }

  document.addEventListener("submit", function (event) {
    var info = templateEventFormInfo(event.target);
    if (!info) return;
    var entry = templateEventQueues.get(info.key);
    if (!entry) {
      entry = {
        key: info.key,
        instance_id: info.instance_id,
        node_id: info.node_id,
        event: info.event,
        in_flight_event_id: info.event_id,
        pending: []
      };
      templateEventQueues.set(info.key, entry);
      templateEventKeysById.set(info.event_id, info.key);
      return;
    }
    if (!entry.in_flight_event_id) {
      entry.in_flight_event_id = info.event_id;
      templateEventKeysById.set(info.event_id, info.key);
      return;
    }
    event.preventDefault();
    event.stopImmediatePropagation();
    if (entry.pending.length >= templateEventQueueLimit) {
      emitTemplateQueueEvent("selecto:template:queue:overflow", entry, "queue_full");
      return;
    }
    entry.pending.push({value: info.value});
  }, true);

  document.addEventListener("htmx:finally:request", function (event) {
    var ctx = event.detail && event.detail.ctx;
    var source = ctx && ctx.sourceElement;
    var form = source instanceof HTMLFormElement
      ? source : source && (source.form || source.closest("form"));
    var eventId = form && form.querySelector('input[name="event_id"]');
    if (!eventId || !templateEventKeysById.has(eventId.value)) return;
    var metadata = httpTemplateMetadata(ctx);
    var status = ctx && ctx.response && ctx.response.status;
    completeTemplateEvent(
      eventId.value,
      status >= 200 && status < 300
        && metadata && metadata.event_id === eventId.value
    );
  });

  document.addEventListener("htmx:ws:close", function (event) {
    var root = event.target && event.target.querySelector
      && event.target.querySelector("[data-selecto-template-instance]");
    if (root) {
      cancelTemplateEventQueuesForInstance(
        root.dataset.selectoTemplateInstance, "connection_closed"
      );
    }
  });

  document.addEventListener("htmx:ws:error", function (event) {
    var root = event.target && event.target.querySelector
      && event.target.querySelector("[data-selecto-template-instance]");
    if (root) {
      cancelTemplateEventQueuesForInstance(
        root.dataset.selectoTemplateInstance, "connection_error"
      );
    }
  });

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

  window.addEventListener("pageshow", function (event) {
    if (!event.persisted
        || !document.querySelector("[data-selecto-template-instance]")) return;
    // A private template restored from bfcache contains the previous session's
    // rendered DOM. Reload it so the host resolves tenant/session authority again.
    window.location.reload();
  });
})();
