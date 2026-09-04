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
