  // Template transport consistency is independent from the Explorer lifecycle.
  // The generated bundle keeps these functions private inside its shared closure.
  function normalizedTemplateRevision(value) {
    if (typeof value === "number") {
      if (!Number.isSafeInteger(value) || value < 0) return null;
      value = String(value);
    }
    if (typeof value !== "string" || !/^\d+$/.test(value)) return null;
    return value.replace(/^0+(?=\d)/, "");
  }

  function compareTemplateRevisions(left, right) {
    if (left.length !== right.length) return left.length < right.length ? -1 : 1;
    if (left === right) return 0;
    return left < right ? -1 : 1;
  }

  var pendingTemplateControlSnapshots = new Map();

  function templateControlKey(control) {
    if (!(control instanceof Element)
        || !control.matches("input, select, textarea")) return null;
    var field = control.getAttribute("data-selecto-template-field");
    if (field) return "field:" + field;
    return control.id ? "id:" + control.id : null;
  }

  function templateControlState(control) {
    if (control instanceof HTMLInputElement) {
      if (control.type === "file" || control.type === "hidden") return null;
      if (control.type === "checkbox" || control.type === "radio") {
        return {kind: "checked", checked: control.checked};
      }
    }
    if (control instanceof HTMLSelectElement && control.multiple) {
      return {
        kind: "selected",
        values: Array.from(control.selectedOptions, function (option) {
          return option.value;
        })
      };
    }
    return {kind: "value", value: control.value};
  }

  function templateEventForm(root, eventId) {
    if (!eventId) return null;
    for (var input of root.querySelectorAll('form input[name="event_id"]')) {
      if (input.value === eventId) return input.form;
    }
    return null;
  }

  function templateControlMap(root) {
    var controls = new Map();
    var duplicates = new Set();
    for (var control of root.querySelectorAll("input, select, textarea")) {
      var key = templateControlKey(control);
      if (!key || duplicates.has(key)) continue;
      if (controls.has(key)) {
        controls.delete(key);
        duplicates.add(key);
      } else {
        controls.set(key, control);
      }
    }
    return controls;
  }

  function captureTemplateControls(root, metadata) {
    if (!root) return null;
    var controls = templateControlMap(root);
    var submittedForm = templateEventForm(root, metadata && metadata.event_id);
    var values = [];
    controls.forEach(function (control, key) {
      if (!control.hasAttribute("data-selecto-template-dirty")
          || (submittedForm && submittedForm.contains(control))) return;
      var state = templateControlState(control);
      if (state) values.push({key: key, state: state});
    });
    var active = document.activeElement;
    var focus = null;
    if (active && root.contains(active)) {
      var activeKey = templateControlKey(active);
      if (activeKey && controls.get(activeKey) === active) {
        focus = {key: activeKey};
        try {
          if (typeof active.selectionStart === "number") {
            focus.start = active.selectionStart;
            focus.end = active.selectionEnd;
            focus.direction = active.selectionDirection;
          }
        } catch (_error) {}
      }
    }
    return {
      instance_id: root.dataset.selectoTemplateInstance,
      values: values,
      focus: focus
    };
  }

  function restoreTemplateControls(snapshot) {
    if (!snapshot || typeof snapshot.instance_id !== "string") return;
    var root = templateRootForInstance(snapshot.instance_id);
    if (!root) return;
    var controls = templateControlMap(root);
    snapshot.values.forEach(function (entry) {
      var control = controls.get(entry.key);
      if (!control) return;
      if (entry.state.kind === "checked") control.checked = entry.state.checked;
      else if (entry.state.kind === "selected" && control instanceof HTMLSelectElement) {
        var selected = new Set(entry.state.values);
        for (var option of control.options) option.selected = selected.has(option.value);
      } else if (entry.state.kind === "value") control.value = entry.state.value;
      else return;
      control.setAttribute("data-selecto-template-dirty", "true");
    });
    var focus = snapshot.focus;
    var focused = focus && controls.get(focus.key);
    if (!focused) return;
    try { focused.focus({preventScroll: true}); }
    catch (_error) { focused.focus(); }
    if (typeof focus.start === "number" && focused.setSelectionRange) {
      try { focused.setSelectionRange(focus.start, focus.end, focus.direction); }
      catch (_error) {}
    }
  }

  function templateRootForInstance(instanceId, target) {
    if (target !== undefined) {
      if (!(target instanceof Element)) return null;
      var targetedRoot = target.closest("[data-selecto-template-instance]");
      if (targetedRoot
          && targetedRoot.dataset.selectoTemplateInstance === instanceId) {
        return targetedRoot;
      }
      return null;
    }
    for (var candidate of document.querySelectorAll("[data-selecto-template-instance]")) {
      if (candidate.dataset.selectoTemplateInstance === instanceId) return candidate;
    }
    return null;
  }

  function templateResponseIsStale(metadata, target) {
    if (!metadata || typeof metadata.instance_id !== "string") return false;
    if (metadata.state_revision === undefined || metadata.store_revision === undefined) {
      return false;
    }
    var incomingState = normalizedTemplateRevision(metadata.state_revision);
    var incomingStore = normalizedTemplateRevision(metadata.store_revision);
    if (incomingState === null || incomingStore === null) return true;
    var root = templateRootForInstance(metadata.instance_id, target);
    if (!root) return true;
    var currentState = normalizedTemplateRevision(root.dataset.selectoStateRevision);
    var currentStore = normalizedTemplateRevision(root.dataset.selectoStoreRevision);
    if (currentState === null || currentStore === null) return false;
    return compareTemplateRevisions(incomingStore, currentStore) < 0
      || compareTemplateRevisions(incomingState, currentState) < 0;
  }

  function templateResponseKey(metadata) {
    if (!metadata || typeof metadata.instance_id !== "string") return null;
    var state = normalizedTemplateRevision(metadata.state_revision);
    var store = normalizedTemplateRevision(metadata.store_revision);
    return state === null || store === null
      ? null : metadata.instance_id + "\u0000" + state + "\u0000" + store;
  }

  function httpTemplateMetadata(ctx) {
    var headers = ctx && ctx.response && ctx.response.raw && ctx.response.raw.headers;
    if (!headers || typeof headers.get !== "function") return null;
    var instanceId = headers.get("X-Selecto-Template-Instance");
    var stateRevision = headers.get("X-Selecto-State-Revision");
    var storeRevision = headers.get("X-Selecto-Store-Revision");
    if (instanceId === null || stateRevision === null || storeRevision === null) return null;
    return {
      instance_id: instanceId,
      state_revision: stateRevision,
      store_revision: storeRevision,
      event_id: headers.get("X-Selecto-Event-ID"),
      source_id: headers.get("X-Selecto-Source"),
      source_generation: headers.get("X-Selecto-Source-Generation")
    };
  }

  function prepareTemplateWebSocketMessage(message) {
    var target;
    if (message && typeof message.target === "string") {
      try { target = document.querySelector(message.target); }
      catch (_error) { target = null; }
    }
    var metadata = message && message.selecto;
    if (templateResponseIsStale(metadata, target)) return false;
    var key = templateResponseKey(metadata);
    if (!key) return true;
    pendingTemplateControlSnapshots.set(
      key,
      captureTemplateControls(
        templateRootForInstance(metadata.instance_id, target), metadata
      )
    );
    while (pendingTemplateControlSnapshots.size > 32) {
      pendingTemplateControlSnapshots.delete(
        pendingTemplateControlSnapshots.keys().next().value
      );
    }
    return true;
  }

  function reconcileTemplateWebSocketMessage(message) {
    var key = templateResponseKey(message && message.selecto);
    if (!key) return;
    var snapshot = pendingTemplateControlSnapshots.get(key);
    pendingTemplateControlSnapshots.delete(key);
    restoreTemplateControls(snapshot);
  }

  function prepareTemplateHttpSwap(ctx) {
    var metadata = httpTemplateMetadata(ctx);
    if (templateResponseIsStale(metadata, ctx && ctx.target)) return false;
    if (metadata) {
      ctx.selectoTemplateControlSnapshot = captureTemplateControls(
        templateRootForInstance(metadata.instance_id, ctx.target), metadata
      );
    }
    return true;
  }

  function reconcileTemplateHttpSwap(ctx) {
    restoreTemplateControls(ctx && ctx.selectoTemplateControlSnapshot);
  }

  document.addEventListener("input", function (event) {
    var control = event.target;
    if (!templateControlKey(control)
        || !control.closest("[data-selecto-template-instance]")) return;
    control.setAttribute("data-selecto-template-dirty", "true");
  });

  document.addEventListener("change", function (event) {
    var control = event.target;
    if (!templateControlKey(control)
        || !control.closest("[data-selecto-template-instance]")) return;
    control.setAttribute("data-selecto-template-dirty", "true");
  });
