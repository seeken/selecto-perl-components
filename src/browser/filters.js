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
