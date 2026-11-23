  function setItems(root) {
    return Array.from(root.querySelectorAll("[data-sc-picker-set-item]"));
  }

  function setAvailablePickerOpen(root, open) {
    if (!root) return;
    var available = root.querySelector(".sc-picker-available-pane");
    var mobile = window.matchMedia("(max-width: 620px)").matches;
    var focusWasInside = available && available.contains(document.activeElement);
    if (available && typeof available.showPopover === "function"
      && available.matches(":popover-open")) available.hidePopover();
    if (available) {
      available.removeAttribute("popover");
      available.removeAttribute("role");
      available.removeAttribute("aria-modal");
      available.removeAttribute("aria-label");
    }
    root.classList.toggle("is-available-open", open);
    var toggle = root.querySelector("[data-sc-picker-available-toggle]");
    if (toggle) toggle.setAttribute("aria-expanded", open ? "true" : "false");
    if (open) {
      if (mobile && available && typeof available.showPopover === "function") {
        available.setAttribute("popover", "manual");
        available.setAttribute("role", "dialog");
        available.setAttribute("aria-modal", "true");
        available.setAttribute("aria-label", root.hasAttribute("data-sc-filter-root")
          ? "Available filters" : "Available fields");
        available.showPopover();
      }
      var search = root.querySelector("[data-sc-picker-filter], [data-sc-filter-search]");
      if (search) search.focus();
    } else if (focusWasInside && toggle && getComputedStyle(toggle).display !== "none") {
      toggle.focus();
    }
  }

  window.matchMedia("(max-width: 620px)").addEventListener("change", function () {
    document.querySelectorAll(".sc-list-picker.is-available-open").forEach(function (picker) {
      setAvailablePickerOpen(picker, false);
    });
  });

  document.addEventListener("click", function (event) {
    var control = event.target.closest(
      "[data-sc-picker-available-toggle], [data-sc-picker-available-close]"
    );
    if (control) {
      var picker = control.closest(".sc-list-picker");
      var opening = control.hasAttribute("data-sc-picker-available-toggle")
        && !picker.classList.contains("is-available-open");
      if (opening) {
        document.querySelectorAll(".sc-list-picker.is-available-open").forEach(function (other) {
          if (other !== picker) setAvailablePickerOpen(other, false);
        });
      }
      setAvailablePickerOpen(picker, opening);
      return;
    }
    document.querySelectorAll(".sc-list-picker.is-available-open").forEach(function (picker) {
      if (!picker.contains(event.target)) setAvailablePickerOpen(picker, false);
    });
  });

  document.addEventListener("keydown", function (event) {
    if (event.key === "Tab") {
      var sheet = typeof HTMLElement.prototype.showPopover === "function"
        ? document.querySelector(".sc-picker-available-pane:popover-open") : null;
      if (sheet) {
        var focusable = Array.from(sheet.querySelectorAll(
          'button:not(:disabled), input:not(:disabled), select:not(:disabled), summary, a[href]'
        )).filter(function (element) { return element.getClientRects().length > 0; });
        if (focusable.length) {
          var first = focusable[0];
          var last = focusable[focusable.length - 1];
          if (event.shiftKey && (document.activeElement === first || !sheet.contains(document.activeElement))) {
            last.focus();
            event.preventDefault();
          } else if (!event.shiftKey && (document.activeElement === last || !sheet.contains(document.activeElement))) {
            first.focus();
            event.preventDefault();
          }
        }
      }
    }
    if (event.key !== "Escape") return;
    var openPickers = document.querySelectorAll(".sc-list-picker.is-available-open");
    if (!openPickers.length) return;
    openPickers.forEach(function (picker) {
      setAvailablePickerOpen(picker, false);
    });
    var toggle = openPickers[openPickers.length - 1].querySelector(
      "[data-sc-picker-available-toggle]"
    );
    if (toggle) toggle.focus();
    event.preventDefault();
  });

  function pickerTone(path) {
    var hash = 2166136261;
    Array.from(String(path || "")).forEach(function (character) {
      hash = Math.imul(hash ^ character.charCodeAt(0), 16777619);
    });
    hash ^= hash >>> 16;
    return (hash >>> 0) % 8;
  }

  function refreshPickerHighlights(items, available) {
    var selected = new Set(items.map(function (item) { return item.dataset.field; }));
    items.concat(available).forEach(function (item) {
      for (var tone = 0; tone < 8; tone += 1) item.classList.remove("sc-pick-tone-" + tone);
      item.classList.remove("sc-is-picked");
      if (selected.has(item.dataset.field)) {
        item.classList.add("sc-is-picked", "sc-pick-tone-" + pickerTone(item.dataset.field));
      }
    });
  }

  var activeDraggedItem = null;

  function appendLabel(parent, label, type, field, className, description) {
    var wrapper = document.createElement("span");
    if (className) wrapper.className = className;
    var strong = document.createElement("strong");
    strong.textContent = label;
    var small = document.createElement("small");
    small.textContent = field + " - " + type;
    wrapper.appendChild(strong);
    wrapper.appendChild(small);
    if (description) {
      var note = document.createElement("small");
      note.className = "sc-field-description";
      note.textContent = description;
      wrapper.appendChild(note);
    }
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
    choice.dataset.search = (label + " " + type + (metadata.description ? " " + metadata.description : "")).toLowerCase();
    if (metadata.description) {
      choice.dataset.description = metadata.description;
      choice.title = metadata.description;
    }
    choice.dataset.defaultFunction = metadata.defaultFunction || "";
    choice.dataset.measureField = metadata.measureField || "";
    choice.dataset.scPickerGroupKey = metadata.groupKey || "";
    if (kind === "filter") {
      choice.dataset.scFilterAction = "add";
      choice.setAttribute("data-sc-filter-available-item", "");
    } else {
      choice.dataset.scPickerAction = "add";
      choice.setAttribute("data-sc-picker-available-item", "");
    }
    appendLabel(choice, label, type, field);
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
    if (choice.dataset.description) item.dataset.description = choice.dataset.description;
    item.dataset.measureField = choice.dataset.measureField || "";
    item.dataset.scPickerGroupKey = choice.dataset.scPickerGroupKey || "";
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
    appendLabel(item, label, type, field, "sc-picker-set-label", choice.dataset.description);
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
        ["year_buckets", "Year buckets"],
        ["month_buckets", "Month buckets"]
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
    // One group may become the aggregate grid's columns. syncPickerConfig
    // gives the box its group's field and hides it outside the aggregate view.
    var gridColumn = document.createElement("label");
    gridColumn.className = "sc-option-check";
    gridColumn.setAttribute("data-sc-group-grid-column", "");
    var gridColumnBox = document.createElement("input");
    gridColumnBox.type = "checkbox";
    gridColumnBox.name = "pivot_column";
    gridColumnBox.value = "";
    gridColumnBox.setAttribute("data-sc-grid-column-choice", "");
    gridColumnBox.setAttribute("aria-label", "Show " + label + " as columns");
    gridColumn.appendChild(gridColumnBox);
    var gridColumnText = document.createElement("span");
    gridColumnText.textContent = "Show as columns";
    gridColumn.appendChild(gridColumnText);
    var gridColumnHelp = document.createElement("small");
    gridColumnHelp.textContent = "The other groups become rows, with every aggregate under each column.";
    gridColumn.appendChild(gridColumnHelp);
    grid.appendChild(gridColumn);

    // The pivot's Total columns: sent only by the group shown as columns.
    var pivotTotals = document.createElement("label");
    pivotTotals.className = "sc-option-check";
    pivotTotals.setAttribute("data-sc-group-pivot-totals", "");
    pivotTotals.hidden = true;
    var pivotTotalsOff = document.createElement("input");
    pivotTotalsOff.type = "hidden";
    pivotTotalsOff.name = "pivot_totals";
    pivotTotalsOff.value = "0";
    pivotTotalsOff.disabled = true;
    pivotTotals.appendChild(pivotTotalsOff);
    var pivotTotalsBox = document.createElement("input");
    pivotTotalsBox.type = "checkbox";
    pivotTotalsBox.name = "pivot_totals";
    pivotTotalsBox.value = "1";
    pivotTotalsBox.checked = true;
    pivotTotalsBox.disabled = true;
    pivotTotalsBox.setAttribute("aria-label", "Show Total columns");
    pivotTotals.appendChild(pivotTotalsBox);
    var pivotTotalsText = document.createElement("span");
    pivotTotalsText.textContent = "Show Total columns";
    pivotTotals.appendChild(pivotTotalsText);
    var pivotTotalsHelp = document.createElement("small");
    pivotTotalsHelp.textContent = "A last group of columns with each row's totals.";
    pivotTotals.appendChild(pivotTotalsHelp);
    grid.appendChild(pivotTotals);
    var values = document.createElement("div");
    values.setAttribute("data-sc-pivot-values", "");
    values.hidden = true;
    values.innerHTML = '<div data-sc-pivot-chosen-controls><label>Choose column values<input type="search" data-sc-pivot-search autocomplete="off" aria-label="Search column values"></label><div data-sc-pivot-options role="list"></div><ol data-sc-pivot-chosen></ol></div><label>Top columns<input type="number" name="pivot_column_top" min="1" max="500" disabled></label><label>Rank by<select name="pivot_column_top_measure" disabled></select></label><label data-sc-pivot-top-order hidden>Column order<select name="pivot_column_top_order" aria-label="Column order" disabled><option value="rank">Largest first</option><option value="natural">Natural order</option></select></label><small>Top columns applies when no values are chosen.</small><label><input type="checkbox" name="pivot_column_other" value="1" disabled>Include Other</label>';
    grid.appendChild(values);

    // Leaving out rows with no value is a filter on the group's field.
    var excludeMissing = document.createElement("label");
    excludeMissing.className = "sc-option-check";
    excludeMissing.setAttribute("data-sc-group-exclude-missing", "");
    var excludeMissingBox = document.createElement("input");
    excludeMissingBox.type = "checkbox";
    excludeMissingBox.name = "group_exclude_missing";
    excludeMissingBox.value = "";
    excludeMissingBox.setAttribute("aria-label", "Leave out rows with no " + label);
    excludeMissing.appendChild(excludeMissingBox);
    var excludeMissingText = document.createElement("span");
    excludeMissingText.textContent = "Leave out rows with no value";
    excludeMissing.appendChild(excludeMissingText);
    var excludeMissingHelp = document.createElement("small");
    excludeMissingHelp.textContent = "Adds a filter, so totals leave them out too. Bucket ranges already leave out everything outside them.";
    excludeMissing.appendChild(excludeMissingHelp);
    grid.appendChild(excludeMissing);
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

  // Show Total columns appears, and is sent, only for the group shown as
  // columns in the aggregate view.
  function syncPivotTotals(root, viewName) {
    root.querySelectorAll("[data-sc-group-pivot-totals], [data-sc-pivot-values]").forEach(function (node) {
      var item = node.closest("[data-sc-picker-set-item]");
      var choice = item && item.querySelector("[data-sc-grid-column-choice]");
      var seriesGroup = root.closest("form") && root.closest("form").querySelector('select[name="graph_series_group"]');
      if (viewName === "graph" && seriesGroup && choice) choice.checked = choice.value === seriesGroup.value;
      var active = !!choice && choice.checked && (viewName === "aggregate" ||
        (node.hasAttribute("data-sc-pivot-values") && viewName === "graph"));
      var format = item && item.querySelector('[name="group_format"]');
      node.hidden = !active;
      node.querySelectorAll("input, select").forEach(function (input) { input.disabled = !active; });
      var chosen = node.querySelector("[data-sc-pivot-chosen-controls]");
      if (chosen) {
        var formatted = format && format.value && format.value !== "default";
        chosen.hidden = !!formatted;
        chosen.querySelectorAll("input").forEach(function (input) { input.disabled = !active || formatted; });
      }
      syncPivotTopOrder(node);
    });
  }

  function syncPivotTopOrder(node) {
    var order = node.querySelector("[data-sc-pivot-top-order]");
    var top = node.querySelector('[name="pivot_column_top"]');
    if (!order || !top) return;
    order.hidden = !top.value;
    order.querySelector("select").disabled = top.disabled || !top.value;
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
    appendConfigLabel(grid, "Series style", chartType, "data-sc-measure-graph");

    var axis = document.createElement("select");
    axis.name = "measure_axis";
    axis.setAttribute("aria-label", "Y axis for " + label);
    appendOptions(axis, [["auto", "Automatic"], ["left", "Left"], ["right", "Right"]], "auto");
    appendConfigLabel(grid, "Y axis", axis, "data-sc-measure-graph");

    var stack = document.createElement("input");
    stack.name = "measure_stack";
    stack.maxLength = 32;
    stack.pattern = "[a-z][a-z0-9_]*";
    stack.placeholder = "e.g. expenses";
    stack.setAttribute("aria-label", "Stack group for " + label);
    appendConfigLabel(grid, "Stack group", stack, "data-sc-measure-graph");

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
    // The colour block has its own display rule, so a plain wrapper hides it.
    var colorWrapper = document.createElement("div");
    colorWrapper.setAttribute("data-sc-measure-graph", "");
    colorWrapper.appendChild(colorControl);
    grid.appendChild(colorWrapper);

    var opacity = document.createElement("input");
    opacity.type = "number";
    opacity.name = "measure_fill_opacity";
    opacity.min = "0";
    opacity.max = "1";
    opacity.step = "0.01";
    opacity.value = "0.22";
    opacity.setAttribute("aria-label", "Fill opacity for " + label);
    appendConfigLabel(grid, "Fill opacity", opacity, "data-sc-measure-graph");

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
    // Series settings only draw a graph: show them in the graph view alone.
    var form = item.closest("form");
    var view = form && form.querySelector('input[name="view"]:checked');
    var viewName = view ? view.value : "";
    item.querySelectorAll("[data-sc-measure-graph]").forEach(function (node) { node.hidden = viewName !== "graph"; });
    // The grid column choice belongs to the aggregate view.
    item.querySelectorAll("[data-sc-group-grid-column]").forEach(function (node) { node.hidden = viewName !== "aggregate"; });
    var gridColumnChoice = item.querySelector("[data-sc-grid-column-choice]");
    if (gridColumnChoice && !gridColumnChoice.value) gridColumnChoice.value = item.dataset.field || "";
    var topMeasure = item.querySelector('[name="pivot_column_top_measure"]');
    if (topMeasure && form) {
      var selectedTop = topMeasure.value;
      topMeasure.replaceChildren();
      form.querySelectorAll('[data-sc-picker-kind="measure"] [data-sc-picker-set-item]').forEach(function (measure) {
        var option = document.createElement("option"); option.value = measure.dataset.field;
        option.textContent = measure.dataset.label || option.value;
        option.selected = option.value === selectedTop; topMeasure.appendChild(option);
      });
    }
    syncPivotTotals(item, viewName);
    var excludeMissingChoice = item.querySelector('[data-sc-group-exclude-missing] input');
    if (excludeMissingChoice && !excludeMissingChoice.value) excludeMissingChoice.value = item.dataset.field || "";
    var groupFormat = item.querySelector("[data-sc-group-format]");
    if (groupFormat) {
      var groupRoot = item.closest('[data-sc-picker-kind="group"]');
      if (groupRoot) syncGroupReferences(groupRoot, setItems(groupRoot));
      var buckets = /^(?:buckets|age_buckets|custom_buckets|year_buckets|month_buckets)$/.test(groupFormat.value);
      item.querySelectorAll("[data-sc-group-buckets]").forEach(function (node) { node.hidden = !buckets; });
      var rangesInput = item.querySelector('input[name="group_bucket_ranges"]');
      if (rangesInput) {
        rangesInput.placeholder = groupFormat.value === "month_buckets"
          ? "Months ago: 12-6, 5-3, 2, 1, 0" : "1, 2-5, 6-14, 15+ or */10";
      }
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

  function addCategoryColor(root) {
    var list = root && root.querySelector("[data-sc-category-colors]");
    var button = list && list.querySelector("[data-sc-category-color-add]");
    if (!list || !button || list.querySelectorAll("[data-sc-category-color-row]").length >= 50) return;
    var row = document.createElement("div");
    row.className = "sc-category-color-row";
    row.setAttribute("data-sc-category-color-row", "");
    [["Group field", "graph_category_field", "text", ""],
      ["Value", "graph_category_value", "text", ""],
      ["Format", "graph_category_format", "text", ""],
      ["Color", "graph_category_color", "color", "#55d6be"]].forEach(function (definition) {
        var label = document.createElement("label");
        label.appendChild(document.createTextNode(definition[0]));
        var input = document.createElement("input");
        input.name = definition[1];
        input.type = definition[2];
        input.value = definition[3];
        label.appendChild(input);
        row.appendChild(label);
      });
    var remove = document.createElement("button");
    remove.type = "button";
    remove.className = "sc-button sc-secondary";
    remove.setAttribute("data-sc-category-color-remove", "");
    remove.textContent = "Remove";
    row.appendChild(remove);
    list.insertBefore(row, button);
  }

  function syncGroupReferences(root, items) {
    var form = root.closest("form");
    var series = form && form.querySelector('select[name="graph_series_group"]');
    var selectedItem = series && items.find(function (item) {
      return (item.dataset.scGroupId || item.dataset.field) === series.value;
    });
    var counts = {};
    items.forEach(function (item) { counts[item.dataset.field] = (counts[item.dataset.field] || 0) + 1; });
    items.forEach(function (item, index) {
      var id = counts[item.dataset.field] > 1 ? "group:" + (index + 1) : item.dataset.field;
      item.dataset.scGroupId = id;
      item.querySelectorAll('[name="pivot_column"], [name="group_exclude_missing"]').forEach(function (input) {
        input.value = id;
      });
    });
    if (series) {
      series.replaceChildren(new Option("One series per measure", ""));
      items.forEach(function (item) {
        var format = item.querySelector('[name="group_format"]');
        var alias = item.querySelector('[name="group_alias"]');
        var label = alias && alias.value || item.dataset.label;
        if (!(alias && alias.value) && counts[item.dataset.field] > 1 && format) {
          label += " (" + format.options[format.selectedIndex].textContent + ")";
        }
        series.add(new Option(label, item.dataset.scGroupId, false, item === selectedItem));
      });
    }
  }

  function refreshColumnPicker(root) {
    var items = setItems(root);
    if (root.dataset.scPickerKind === "group") syncGroupReferences(root, items);
    var available = Array.from(root.querySelectorAll("[data-sc-picker-available-item]"));
    refreshPickerHighlights(items, available);
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
    });
    refreshGroupedPickerSearch(availableList, query, "[data-sc-picker-available-item]");
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

  function refreshGroupedPickerSearch(container, query, selector) {
    if (!container) return;
    container.querySelectorAll("[data-sc-picker-group]").forEach(function (group) {
      var choices = Array.from(group.querySelectorAll(selector));
      var headingMatches = query && (group.dataset.searchLabel || "").includes(query);
      var matching = 0;
      choices.forEach(function (choice) {
        choice.hidden = !!query && !headingMatches && !(choice.dataset.search || "").includes(query);
        if (!choice.hidden) matching += 1;
      });
      var count = group.querySelector("summary small");
      if (count) count.textContent = choices.length;
      group.hidden = !choices.length || (!!query && !matching);
      if (query) {
        if (group.dataset.scOpenBeforeSearch === undefined) {
          group.dataset.scOpenBeforeSearch = group.open ? "1" : "0";
        }
        if (!group.hidden) group.open = true;
      } else if (group.dataset.scOpenBeforeSearch !== undefined) {
        group.open = group.dataset.scOpenBeforeSearch === "1";
        delete group.dataset.scOpenBeforeSearch;
      }
    });
    container.querySelectorAll(selector).forEach(function (choice) {
      if (choice.closest("[data-sc-picker-group]")) return;
      choice.hidden = !!query && !(choice.dataset.search || "").includes(query);
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

  async function searchPivotValues(input) {
    var box = input.closest("[data-sc-pivot-values]");
    var item = box.closest("[data-sc-picker-set-item]");
    var form = input.closest("form");
    var url = new URL(form.action.replace(/\/$/, "") + "/column-values", window.location.href);
    var body = new URLSearchParams({field: item.dataset.field, term: input.value,
      csrf_token: form.dataset.scColumnValuesCsrf || ""});
    var sequence = (input._scSequence || 0) + 1;
    input._scSequence = sequence;
    try {
      var response = await fetch(url, {method: "POST", body: body, credentials: "same-origin", headers: {Accept: "application/json"}});
      if (!response.ok) throw new Error("Search failed");
      var data = await response.json();
      if (input._scSequence !== sequence || !input.isConnected) return;
      var options = box.querySelector("[data-sc-pivot-options]");
      options.replaceChildren();
      (data.choices || []).forEach(function (choice) {
        var button = document.createElement("button");
        button.type = "button";
        button.textContent = choice.label;
        button.dataset.scPivotAdd = String(choice.value);
        options.appendChild(button);
      });
    } catch (_) {
      box.querySelector("[data-sc-pivot-options]").textContent = "Search unavailable. Try again.";
    }
  }
  document.addEventListener("input", function (event) {
    if (event.target.matches("[data-sc-pivot-search]")) searchPivotValues(event.target);
    if (event.target.matches('[name="pivot_column_top"]')) syncPivotTopOrder(event.target.closest("[data-sc-pivot-values]"));
  });
  document.addEventListener("focusin", function (event) {
    if (event.target.matches("[data-sc-pivot-search]")) searchPivotValues(event.target);
  });
  document.addEventListener("click", function (event) {
    var button = event.target.closest("[data-sc-pivot-add], [data-sc-pivot-remove], [data-sc-pivot-move]");
    if (!button) return;
    event.preventDefault();
    var box = button.closest("[data-sc-pivot-values]");
    var list = box.querySelector("[data-sc-pivot-chosen]");
    var row = button.closest("li");
    if (button.hasAttribute("data-sc-pivot-add")) {
      var value = button.dataset.scPivotAdd;
      if (Array.from(list.querySelectorAll("input")).some(function (input) { return input.value === value; }) || list.children.length >= 100) return;
      row = document.createElement("li");
      var hidden = document.createElement("input");
      hidden.type = "hidden"; hidden.name = "pivot_column_value"; hidden.value = value;
      var label = document.createElement("span"); label.textContent = button.textContent;
      row.append(hidden, label);
      [["up", "Move value up"], ["down", "Move value down"], ["remove", "Remove value"]].forEach(function (action) {
        var control = document.createElement("button"); control.type = "button";
        control.textContent = action[1]; control.setAttribute("aria-label", action[1]);
        if (action[0] === "remove") control.setAttribute("data-sc-pivot-remove", "");
        else control.dataset.scPivotMove = action[0];
        row.appendChild(control);
      });
      list.appendChild(row);
    } else if (button.hasAttribute("data-sc-pivot-remove")) row.remove();
    else if (button.dataset.scPivotMove === "up" && row.previousElementSibling) list.insertBefore(row, row.previousElementSibling);
    else if (button.dataset.scPivotMove === "down" && row.nextElementSibling) list.insertBefore(row.nextElementSibling, row);
    box.dispatchEvent(new Event("change", {bubbles: true}));
  });
