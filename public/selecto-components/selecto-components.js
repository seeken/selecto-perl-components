(function () {
  "use strict";

  var activeBuilderTabs = Object.create(null);
  var dateFormats = [
    ["day", "Day"], ["day_hour", "Day + Hour"], ["week", "Week"],
    ["month", "Month"], ["quarter", "Quarter"], ["year", "Year"],
    ["month_of_year", "Month of Year"], ["day_of_month", "Day of Month"],
    ["day_of_week", "Day of Week"], ["hour", "Hour of Day"]
  ];

  function activateBuilderTab(root, name, remember) {
    if (!root) return;
    var key = root.dataset.scBuilder;
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
  }

  function restoreBuilderTabs() {
    document.querySelectorAll("[data-sc-builder]").forEach(function (root) {
      activateBuilderTab(root, activeBuilderTabs[root.dataset.scBuilder] || "view", false);
    });
  }

  function markBuilderDirty(root) {
    if (!root) return;
    if (!root.matches("[data-sc-builder]")) root = root.closest("[data-sc-builder]");
    if (!root) return;
    root.classList.add("is-dirty");
    var pending = root.querySelector("[data-sc-builder-pending]");
    if (pending) pending.hidden = false;
  }

  function stageResultView(root, view) {
    if (!root) return;
    var mode = view === "detail" ? "detail" : "summary";
    root.querySelectorAll("[data-sc-result-view-panel]").forEach(function (panel) {
      var active = panel.dataset.scResultViewPanel === mode;
      panel.hidden = !active;
      panel.disabled = !active;
    });
    root.querySelectorAll("[data-sc-picker-root]").forEach(refreshColumnPicker);
  }

  function restoreResultViews() {
    document.querySelectorAll("[data-sc-builder]").forEach(function (root) {
      var selected = root.querySelector('input[name="view"]:checked');
      if (selected) stageResultView(root, selected.value);
    });
  }

  document.addEventListener("DOMContentLoaded", function () {
    restoreBuilderTabs();
    restoreResultViews();
  });

  document.addEventListener("htmx:after:ws:connection", function () {
    document.querySelectorAll("[data-selecto-connection]").forEach(function (node) {
      node.textContent = "Live";
      node.classList.add("is-live");
    });
  });

  document.addEventListener("htmx:ws:close", function () {
    document.querySelectorAll("[data-selecto-connection]").forEach(function (node) {
      node.textContent = "Reconnecting";
      node.classList.remove("is-live");
    });
  });

  window.addEventListener("submit", function (event) {
    var form = event.target.closest("[data-sc-builder]");
    if (!form) return;
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

  document.addEventListener("htmx:after:ws:message", function (event) {
    var message = event.detail && event.detail.message && event.detail.message.json;
    var nextUrl = message && message.selecto && message.selecto.url;
    if (typeof nextUrl === "string" && nextUrl.charAt(0) === "/") {
      window.history.replaceState({selecto: true}, "", nextUrl);
    }
    window.requestAnimationFrame(function () {
      restoreBuilderTabs();
      restoreResultViews();
    });
  });

  document.addEventListener("htmx:after:swap", function () {
    restoreBuilderTabs();
    restoreResultViews();
  });

  document.addEventListener("click", function (event) {
    var tab = event.target.closest("[data-sc-builder-tab]");
    if (!tab) return;
    activateBuilderTab(tab.closest("[data-sc-builder]"), tab.dataset.scBuilderTab);
  });

  document.addEventListener("keydown", function (event) {
    var tab = event.target.closest("[data-sc-builder-tab]");
    if (!tab || (event.key !== "ArrowLeft" && event.key !== "ArrowRight")) return;
    var root = tab.closest("[data-sc-builder]");
    var tabs = Array.from(root.querySelectorAll("[data-sc-builder-tab]"));
    var offset = event.key === "ArrowRight" ? 1 : -1;
    var next = tabs[(tabs.indexOf(tab) + offset + tabs.length) % tabs.length];
    event.preventDefault();
    activateBuilderTab(root, next.dataset.scBuilderTab);
    next.focus();
  });

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
    if (kind === "order") {
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
    var badge = builder && builder.querySelector('[data-sc-builder-tab="filters"] span');
    if (badge) badge.textContent = items.length;
  }

  document.addEventListener("input", function (event) {
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

  function selectedRowIds(root) {
    var results = bulkActionResults(root);
    if (!results) return [];
    var seen = Object.create(null);
    return Array.from(results.querySelectorAll("[data-sc-row-select]:checked")).reduce(function (ids, input) {
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

  function refreshBulkActions(root) {
    if (!root) return;
    var ids = selectedRowIds(root);
    var count = root.querySelector("[data-sc-selection-count]");
    var label = root.querySelector("[data-sc-selection-label]");
    if (count) count.textContent = ids.length;
    if (label) label.textContent = ids.length === 1 ? "row selected" : "rows selected";
    root.querySelectorAll("[data-sc-action-open]").forEach(function (button) {
      button.disabled = ids.length === 0 || button.dataset.scActionDisabled === "1";
    });
    var results = bulkActionResults(root);
    var pageToggle = results && results.querySelector("[data-sc-select-page]");
    var rowToggles = results ? Array.from(results.querySelectorAll("[data-sc-row-select]:not(:disabled)")) : [];
    var checked = rowToggles.filter(function (input) { return input.checked; }).length;
    if (pageToggle) {
      pageToggle.checked = rowToggles.length > 0 && checked === rowToggles.length;
      pageToggle.indeterminate = checked > 0 && checked < rowToggles.length;
    }
  }

  function restoreBulkActions() {
    document.querySelectorAll("[data-sc-bulk-actions]").forEach(refreshBulkActions);
  }

  document.addEventListener("DOMContentLoaded", restoreBulkActions);
  document.addEventListener("htmx:after:swap", restoreBulkActions);
  document.addEventListener("htmx:after:ws:message", function () {
    window.requestAnimationFrame(restoreBulkActions);
  });

  document.addEventListener("change", function (event) {
    if (event.target.matches("[data-sc-select-page]")) {
      var results = event.target.closest(".sc-results");
      results.querySelectorAll("[data-sc-row-select]:not(:disabled)").forEach(function (input) {
        input.checked = event.target.checked;
      });
      refreshBulkActions(results.querySelector("[data-sc-bulk-actions]"));
      return;
    }
    if (event.target.matches("[data-sc-row-select]")) {
      refreshBulkActions(event.target.closest(".sc-results").querySelector("[data-sc-bulk-actions]"));
    }
  });

  document.addEventListener("click", function (event) {
    var open = event.target.closest("[data-sc-action-open]");
    if (open && !open.disabled) {
      var root = open.closest("[data-sc-bulk-actions]");
      var dialog = document.getElementById(open.dataset.scActionOpen);
      var form = dialog && dialog.querySelector("[data-sc-action-form]");
      var ids = selectedRowIds(root);
      if (!form || ids.length === 0) return;
      form.reset();
      populateActionTargets(form, ids);
      var result = form.querySelector("[data-sc-action-result]");
      if (result) {
        result.hidden = true;
        result.textContent = "";
        result.classList.remove("is-success", "is-error");
      }
      var submit = form.querySelector('button[type="submit"]');
      if (submit) {
        submit.disabled = false;
        submit.textContent = "Apply to selected rows";
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
    var root = form.closest("[data-sc-bulk-actions]");
    var ids = selectedRowIds(root);
    populateActionTargets(form, ids);
    if (!ids.length || !form.reportValidity()) return;

    var submit = form.querySelector('button[type="submit"]');
    var result = form.querySelector("[data-sc-action-result]");
    if (submit) {
      submit.disabled = true;
      submit.textContent = "Applying…";
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
        bulkActionResults(root).querySelectorAll("[data-sc-row-select]:checked").forEach(function (input) {
          input.checked = false;
        });
        refreshBulkActions(root);
        if (submit) submit.textContent = "Applied";
      } else if (submit) {
        submit.disabled = false;
        submit.textContent = "Apply to selected rows";
      }
    }).catch(function () {
      if (result) {
        result.hidden = false;
        result.classList.add("is-error");
        result.textContent = "The action request could not reach the server.";
      }
      if (submit) {
        submit.disabled = false;
        submit.textContent = "Apply to selected rows";
      }
    });
  });
})();
