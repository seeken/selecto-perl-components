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
