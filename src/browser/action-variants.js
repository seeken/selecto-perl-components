  function actionVariantState(root) {
    var spec;
    try { spec = JSON.parse(root.dataset.scActionVariants); } catch (_) { return null; }
    var selectors = new Set();
    spec.variants.forEach(function (variant) {
      Object.keys(variant.when).forEach(function (id) { selectors.add(id); });
    });
    var values = Object.create(null);
    var base = root.querySelector("[data-sc-action-base]");
    spec.inputs.forEach(function (input) {
      if (!selectors.has(input.id)) return;
      var control = Array.from(base.querySelectorAll("[name]")).find(function (item) {
        return item.name === "action_input_" + input.id;
      });
      if (!control) return;
      var value = input.trim ? control.value.trim() : control.value;
      if (value === "") return;
      if (input.type === "boolean") {
        if (!/^(true|false|1|0)$/i.test(value)) return;
        value = /^(true|1)$/i.test(value);
      } else if (input.type === "number" || input.type === "integer") {
        if (!/^-?(\d+(\.\d*)?|\.\d+)$/.test(value)) return;
        value = Number(value);
        if (input.type === "integer" && !Number.isInteger(value)) return;
      } else if (input.type === "collection") {
        try { value = JSON.parse(value); } catch (_) { return; }
        if (!Array.isArray(value)) return;
      }
      values[input.id] = value;
    });
    function same(left, right) {
      if (left === right) return true;
      if (!left || !right || typeof left !== "object" || typeof right !== "object"
          || Array.isArray(left) !== Array.isArray(right)) return false;
      var keys = Object.keys(left);
      return keys.length === Object.keys(right).length && keys.every(function (key) {
        return Object.prototype.hasOwnProperty.call(right, key) && same(left[key], right[key]);
      });
    }
    var matches = spec.variants.filter(function (variant) {
      return Object.keys(variant.when).every(function (id) {
        return Object.prototype.hasOwnProperty.call(values, id) && same(values[id], variant.when[id]);
      });
    });
    return {values: values, matches: matches};
  }

  function updateActionVariant(root) {
    var state = actionVariantState(root);
    var selected = state && state.matches.length === 1 ? state.matches[0] : null;
    var changed = root.dataset.scActiveVariant !== (selected ? selected.id : "");
    root.dataset.scActiveVariant = selected ? selected.id : "";
    root.querySelectorAll("[data-sc-action-variant]").forEach(function (panel) {
      var active = !!selected && panel.dataset.scActionVariant === selected.id;
      panel.hidden = !active;
      panel.disabled = !active;
    });
    root.querySelectorAll("[data-sc-action-base] [data-sc-action-input-id]").forEach(function (field) {
      var overridden = !!selected && selected.fields.includes(field.dataset.scActionInputId);
      field.hidden = overridden;
      field.querySelectorAll("input,select,textarea,button").forEach(function (control) {
        control.disabled = overridden;
      });
    });
    if (changed) root.querySelectorAll("[data-sc-lookup-query]").forEach(function (query) {
      if (query._scLookupTimer) window.clearTimeout(query._scLookupTimer);
      if (query._scLookupAbort) query._scLookupAbort.abort();
      query._scLookupAbort = null;
      closeLookup(query);
    });
    var message = selected ? selected.label + " form. Required fields are marked *."
      : state && state.matches.length > 1
        ? "These choices match more than one action form. Contact the administrator."
        : "Choose values that select an available action form.";
    var status = root.querySelector("[data-sc-action-variant-status]");
    if (status && status.textContent !== message) status.textContent = message;
    var first = root.querySelector('[data-sc-action-base] input:not([type="hidden"]), [data-sc-action-base] select, [data-sc-action-base] textarea');
    if (first) {
      if (first._scVariantValidity && first.validationMessage === first._scVariantValidity) first.setCustomValidity("");
      first._scVariantValidity = selected ? "" : message;
      if (!selected) first.setCustomValidity(message);
    }
  }

  function restoreActionVariants(scope) {
    (scope || document).querySelectorAll("[data-sc-action-variants]").forEach(updateActionVariant);
  }

  function loadTargetActionForm(form, ids) {
    if (!form.dataset.scActionFormUrl) return;
    if (form._scFormAbort) form._scFormAbort.abort();
    var abort = new AbortController();
    form._scFormAbort = abort;
    var fields = form.querySelector("[data-sc-action-fields]");
    var submit = form.querySelector('button[type="submit"]');
    var result = form.querySelector("[data-sc-action-result]");
    form.dataset.scActionFormReady = "0";
    form.setAttribute("aria-busy", "true");
    if (submit) submit.disabled = true;
    fields.replaceChildren();
    fields.textContent = "Loading action form…";
    var url = new URL(form.dataset.scActionFormUrl, window.location.href);
    ids.forEach(function (id) { url.searchParams.append("selected_id", id); });
    window.fetch(url, {credentials: "same-origin", cache: "no-store", signal: abort.signal,
      headers: {"Accept": "application/json"}}).then(async function (response) {
      var body = await response.json();
      if (!response.ok || !body.ok || typeof body.html !== "string") {
        throw new Error(body.message || "The action form could not be loaded.");
      }
      if (abort.signal.aborted || form._scFormAbort !== abort) return;
      // Same-origin, authorized, server-rendered fragment; all field content is escaped.
      fields.innerHTML = body.html;
      restoreActionVariants(fields);
      form.dataset.scActionFormReady = "1";
      if (submit) submit.disabled = false;
      var focus = fields.querySelector('input:not([type="hidden"]),select,textarea');
      if (focus) focus.focus();
    }).catch(function (error) {
      if (abort.signal.aborted || form._scFormAbort !== abort) return;
      fields.replaceChildren();
      if (result) {
        result.hidden = false;
        result.classList.add("is-error");
        result.textContent = error.message || "The action form could not be loaded. Close and try again.";
      }
    }).finally(function () {
      if (form._scFormAbort === abort) form.removeAttribute("aria-busy");
    });
  }

  document.addEventListener("close", function (event) {
    if (!event.target.matches("[data-sc-action-dialog]")) return;
    var form = event.target.querySelector("[data-sc-action-form]");
    if (form && form._scFormAbort) form._scFormAbort.abort();
  }, true);

  ["input", "change"].forEach(function (name) {
    document.addEventListener(name, function (event) {
      var root = event.target.closest && event.target.closest("[data-sc-action-variants]");
      if (root) updateActionVariant(root);
    });
  });
  document.addEventListener("reset", function (event) {
    if (event.target.matches("[data-sc-action-form]")) {
      window.setTimeout(function () { restoreActionVariants(event.target); }, 0);
    }
  });
