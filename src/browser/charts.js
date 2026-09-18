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
