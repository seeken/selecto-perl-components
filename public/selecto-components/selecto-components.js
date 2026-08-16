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

  function createAvailableChoice(kind, field, label, type) {
    var choice = document.createElement("button");
    choice.className = "sc-picker-choice";
    choice.type = "button";
    choice.dataset.field = field;
    choice.dataset.label = label;
    choice.dataset.type = type;
    choice.dataset.search = (label + " " + type).toLowerCase();
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
      aliasLabel.appendChild(document.createTextNode("Column label"));
      var alias = document.createElement("input");
      alias.name = kind + "_alias";
      alias.maxLength = 80;
      alias.setAttribute("aria-label", "Column label for " + label);
      aliasLabel.appendChild(alias);
      grid.appendChild(aliasLabel);
      if (/(?:date|time)/i.test(type)) {
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
    }
    return item;
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
      var up = item.querySelector('[data-sc-picker-action="up"]');
      var down = item.querySelector('[data-sc-picker-action="down"]');
      var remove = item.querySelector('[data-sc-picker-action="remove"]');
      if (up) up.disabled = index === 0;
      if (down) down.disabled = index === items.length - 1;
      if (remove) remove.disabled = items.length === 1;
    });
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
    [
      ["eq", "equals"], ["gte", "at least"], ["gt", "greater than"],
      ["in", "one of (comma-separated)"], ["is_null", "is empty"],
      ["not_null", "is not empty"]
    ].forEach(function (entry) {
      var option = document.createElement("option");
      option.value = entry[0];
      option.textContent = entry[1];
      operator.appendChild(option);
    });
    operatorLabel.appendChild(operator);
    editor.appendChild(operatorLabel);
    var valueLabel = document.createElement("label");
    valueLabel.appendChild(document.createTextNode("Value"));
    var value = document.createElement("input");
    value.name = "filter_value";
    value.setAttribute("aria-label", "Value for " + label);
    value.placeholder = "Enter a value";
    valueLabel.appendChild(value);
    editor.appendChild(valueLabel);
    item.appendChild(editor);
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
    if (nullOperator) value.value = "";
    value.readOnly = nullOperator;
    value.placeholder = nullOperator ? "Value not used" : "Enter a value";
    var draft = !nullOperator && value.value.length === 0;
    item.classList.toggle("is-draft", draft);
    var note = item.querySelector(".sc-filter-draft-note");
    if (draft && !note) {
      note = document.createElement("p");
      note.className = "sc-filter-draft-note";
      note.textContent = "Enter a value to apply this filter.";
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
    if (event.target.matches('[name="filter_value"]')) {
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
      updateFilterDraft(event.target.closest("[data-sc-filter-set-item]"));
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
          "column", item.dataset.field, item.dataset.label, item.dataset.type
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
})();
