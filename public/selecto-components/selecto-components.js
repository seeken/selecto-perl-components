(function () {
  "use strict";

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
  });

  function submitPicker(root) {
    var form = root.closest("form");
    if (!form) return;
    if (typeof form.requestSubmit === "function") {
      form.requestSubmit();
    } else {
      form.dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}));
    }
  }

  function setItems(root) {
    return Array.from(root.querySelectorAll("[data-sc-picker-set-item]"));
  }

  document.addEventListener("input", function (event) {
    if (event.target.matches("[data-sc-picker-filter]")) {
      var pickerRoot = event.target.closest("[data-sc-picker-root]");
      if (!pickerRoot) return;
      var pickerQuery = event.target.value.trim().toLowerCase();
      pickerRoot.querySelectorAll("[data-sc-picker-available-item]").forEach(function (item) {
        item.hidden = pickerQuery.length > 0 && !item.dataset.search.includes(pickerQuery);
      });
    } else if (event.target.matches("[data-sc-filter-search]")) {
      var filterRoot = event.target.closest("[data-sc-filter-root]");
      if (!filterRoot) return;
      var filterQuery = event.target.value.trim().toLowerCase();
      filterRoot.querySelectorAll("[data-sc-filter-available-item]").forEach(function (item) {
        item.hidden = filterQuery.length > 0 && !item.dataset.search.includes(filterQuery);
      });
    }
  });

  document.addEventListener("click", function (event) {
    var control = event.target.closest("[data-sc-picker-action]");
    if (!control || control.disabled) return;
    var root = control.closest("[data-sc-picker-root]");
    var set = root && root.querySelector("[data-sc-picker-set]");
    if (!root || !set) return;
    var action = control.dataset.scPickerAction;

    if (action === "add") {
      var input = document.createElement("input");
      input.type = "hidden";
      input.name = "field";
      input.value = control.dataset.field;
      set.appendChild(input);
      control.disabled = true;
      submitPicker(root);
      return;
    }

    var item = control.closest("[data-sc-picker-set-item]");
    if (!item) return;
    var items = setItems(root);
    var index = items.indexOf(item);
    if (action === "remove") {
      item.remove();
    } else if (action === "up" && index > 0) {
      set.insertBefore(item, items[index - 1]);
    } else if (action === "down" && index >= 0 && index < items.length - 1) {
      set.insertBefore(items[index + 1], item);
    } else {
      return;
    }
    submitPicker(root);
  });

  document.addEventListener("click", function (event) {
    var control = event.target.closest("[data-sc-filter-action]");
    if (!control || control.disabled) return;
    var root = control.closest("[data-sc-filter-root]");
    var set = root && root.querySelector("[data-sc-filter-set]");
    if (!root || !set) return;

    if (control.dataset.scFilterAction === "add") {
      var draft = document.createElement("div");
      [
        ["filter_field", control.dataset.field],
        ["filter_op", "eq"],
        ["filter_value", ""]
      ].forEach(function (entry) {
        var input = document.createElement("input");
        input.type = "hidden";
        input.name = entry[0];
        input.value = entry[1];
        draft.appendChild(input);
      });
      set.appendChild(draft);
      control.disabled = true;
      submitPicker(root);
      return;
    }

    if (control.dataset.scFilterAction === "remove") {
      var item = control.closest("[data-sc-filter-set-item]");
      if (!item) return;
      item.remove();
      submitPicker(root);
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
    submitPicker(root);
  });

  document.addEventListener("dragend", function (event) {
    var item = event.target.closest("[data-sc-picker-set-item]");
    if (item) item.classList.remove("is-dragging");
  });
})();
