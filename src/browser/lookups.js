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
