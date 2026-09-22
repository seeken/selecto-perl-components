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

  function nextTemplateRevision(value) {
    value = normalizedTemplateRevision(value);
    if (value === null) return null;
    var digits = value.split("");
    var carry = 1;
    for (var index = digits.length - 1; index >= 0 && carry; index -= 1) {
      var digit = Number(digits[index]) + carry;
      digits[index] = String(digit % 10);
      carry = digit > 9 ? 1 : 0;
    }
    if (carry) digits.unshift("1");
    return digits.join("");
  }

  var pendingTemplateControlSnapshots = new Map();
  var templateEventQueues = new Map();
  var templateEventKeysById = new Map();
  var templateEventQueueLimit = 16;
  var templateControlDraftValues = new WeakMap();

  function templateEventFormInfo(form) {
    if (!(form instanceof HTMLFormElement)) return null;
    var action = form.querySelector('input[name="template_action"]');
    var event = form.querySelector('input[name="event"]');
    var eventId = form.querySelector('input[name="event_id"]');
    var revision = form.querySelector('input[name="state_revision"]');
    var componentId = form.querySelector('input[name="component_id"]');
    var componentLifetime = form.querySelector('input[name="component_lifetime"]');
    var formRevision = form.querySelector('input[name="form_revision"]');
    var root = form.closest("[data-selecto-template-instance]");
    var region = form.closest("[data-selecto-template-node]");
    if (!action || action.value !== "event" || !event || !event.value
        || !eventId || !eventId.value || !revision || !componentId
        || !componentId.value || !componentLifetime || !componentLifetime.value
        || !formRevision || normalizedTemplateRevision(formRevision.value) === null
        || !root || !region) return null;
    var values = new FormData(form).getAll("value");
    if (values.length !== 1 || typeof values[0] !== "string") return null;
    var key = [
      root.dataset.selectoTemplateInstance,
      componentId.value,
      event.value
    ].join("\u0000");
    return {
      key: key,
      instance_id: root.dataset.selectoTemplateInstance,
      component_id: componentId.value,
      component_lifetime: componentLifetime.value,
      form_revision: formRevision.value,
      event: event.value,
      event_id: eventId.value,
      value: values[0]
    };
  }

  function emitTemplateQueueEvent(name, entry, reason) {
    var root = entry && templateRootForInstance(entry.instance_id);
    (root || document).dispatchEvent(new CustomEvent(name, {
      bubbles: true,
      detail: {
        instance_id: entry && entry.instance_id,
        component_id: entry && entry.component_id,
        event: entry && entry.event,
        reason: reason
      }
    }));
  }

  function currentTemplateEventForm(entry) {
    var root = templateRootForInstance(entry.instance_id);
    if (!root) return null;
    for (var form of root.querySelectorAll("form")) {
      var info = templateEventFormInfo(form);
      if (info && info.key === entry.key) return form;
    }
    return null;
  }

  function setTemplateEventValue(form, value) {
    var controls = form.querySelectorAll('[name="value"]');
    if (controls.length !== 1
        || !(controls[0] instanceof HTMLInputElement
          || controls[0] instanceof HTMLSelectElement
          || controls[0] instanceof HTMLTextAreaElement)) return false;
    controls[0].value = value;
    return true;
  }

  function setTemplateEventFormRevision(form, revision) {
    var input = form && form.querySelector('input[name="form_revision"]');
    revision = normalizedTemplateRevision(revision);
    if (!input || revision === null) return false;
    input.value = revision;
    return true;
  }

  function advanceTemplateEventFormRevision(form) {
    var input = form && form.querySelector('input[name="form_revision"]');
    var next = input && nextTemplateRevision(input.value);
    if (!input || next === null) return false;
    input.value = next;
    return true;
  }

  function resetTemplateEventValue(form) {
    var controls = form.querySelectorAll('[name="value"]');
    if (controls.length !== 1) return false;
    var control = controls[0];
    if (control instanceof HTMLSelectElement) {
      for (var option of control.options) option.selected = option.defaultSelected;
      return true;
    }
    if (control instanceof HTMLInputElement
        || control instanceof HTMLTextAreaElement) {
      control.value = control.defaultValue;
      return true;
    }
    return false;
  }

  function cancelTemplateEventEntry(entry, reason) {
    if (!entry) return;
    if (entry.in_flight_event_id) {
      templateEventKeysById.delete(entry.in_flight_event_id);
    }
    templateEventQueues.delete(entry.key);
    emitTemplateQueueEvent("selecto:template:queue:cancelled", entry, reason);
  }

  function completeTemplateEvent(eventId, accepted) {
    if (typeof eventId !== "string" || !eventId) return;
    var key = templateEventKeysById.get(eventId);
    if (!key) return;
    templateEventKeysById.delete(eventId);
    var entry = templateEventQueues.get(key);
    if (!entry || entry.in_flight_event_id !== eventId) return;
    entry.in_flight_event_id = null;
    if (!accepted) return cancelTemplateEventEntry(entry, "request_failed");
    var form = currentTemplateEventForm(entry);
    if (form) resetTemplateEventValue(form);
    var queued = entry.pending.shift();
    if (!queued) {
      templateEventQueues.delete(key);
      return;
    }
    if (!form || !setTemplateEventValue(form, queued.value)
        || !setTemplateEventFormRevision(form, queued.form_revision)) {
      return cancelTemplateEventEntry(entry, "form_disposed");
    }
    form.requestSubmit();
  }

  function cancelTemplateEventQueuesForInstance(instanceId, reason) {
    if (typeof instanceId !== "string") return;
    for (var entry of Array.from(templateEventQueues.values())) {
      if (entry.instance_id === instanceId) cancelTemplateEventEntry(entry, reason);
    }
  }

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
    var editedForms = new Set();
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
      if (control.form && templateEventFormInfo(control.form)) {
        editedForms.add(control.form);
      }
    });
    editedForms.forEach(advanceTemplateEventFormRevision);
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

  function templateResponseComponentIsCurrent(metadata, root) {
    var fields = [
      metadata.component_id,
      metadata.component_lifetime,
      metadata.form_revision
    ];
    if (fields.every(function (value) { return value === undefined || value === null; })) {
      return true;
    }
    if (typeof metadata.component_id !== "string"
        || typeof metadata.component_lifetime !== "string") return false;
    var responseRevision = normalizedTemplateRevision(metadata.form_revision);
    if (responseRevision === null) return false;
    for (var form of root.querySelectorAll("form")) {
      var info = templateEventFormInfo(form);
      if (info && info.component_id === metadata.component_id
          && info.component_lifetime === metadata.component_lifetime
          && (normalizedTemplateRevision(info.form_revision) === responseRevision
            || templateResponseAdvancesQueuedDraft(metadata, info))) {
        return true;
      }
    }
    return false;
  }

  function templateResponseAdvancesQueuedDraft(metadata, info) {
    if (!metadata || Number(metadata.status || 0) >= 400
        || typeof metadata.event_id !== "string") return false;
    var key = templateEventKeysById.get(metadata.event_id);
    var entry = key && templateEventQueues.get(key);
    return !!(entry && entry.key === info.key
      && entry.in_flight_event_id === metadata.event_id
      && entry.pending.length);
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
    if (!templateResponseComponentIsCurrent(metadata, root)) return true;
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

  function applyTemplateMetadata(metadata) {
    if (!metadata || typeof metadata.instance_id !== "string") return;
    var state = normalizedTemplateRevision(metadata.state_revision);
    var store = normalizedTemplateRevision(metadata.store_revision);
    if (state === null || store === null) return;
    var root = templateRootForInstance(metadata.instance_id);
    if (!root) return;
    root.dataset.selectoStateRevision = state;
    root.dataset.selectoStoreRevision = store;
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
      component_id: headers.get("X-Selecto-Component-ID"),
      component_lifetime: headers.get("X-Selecto-Component-Lifetime"),
      form_revision: headers.get("X-Selecto-Form-Revision"),
      source_id: headers.get("X-Selecto-Source"),
      source_generation: headers.get("X-Selecto-Source-Generation"),
      status: ctx.response.status
    };
  }

  function prepareTemplateWebSocketMessage(message) {
    var target;
    if (message && typeof message.target === "string") {
      try { target = document.querySelector(message.target); }
      catch (_error) { target = null; }
    }
    var metadata = message && message.selecto;
    if (templateResponseIsStale(metadata, target)) {
      completeTemplateEvent(metadata && metadata.event_id, false);
      return false;
    }
    if (metadata && metadata.status) return true;
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
    var metadata = message && message.selecto;
    if (metadata && metadata.status) {
      if (typeof metadata.event_id === "string"
          && templateEventKeysById.has(metadata.event_id)) {
        completeTemplateEvent(metadata.event_id, false);
      } else if (typeof metadata.instance_id === "string") {
        cancelTemplateEventQueuesForInstance(metadata.instance_id, "server_rejected");
      }
      return;
    }
    var key = templateResponseKey(metadata);
    if (!key) return;
    var snapshot = pendingTemplateControlSnapshots.get(key);
    pendingTemplateControlSnapshots.delete(key);
    applyTemplateMetadata(metadata);
    restoreTemplateControls(snapshot);
    completeTemplateEvent(metadata.event_id, true);
  }

  function prepareTemplateHttpSwap(ctx) {
    var metadata = httpTemplateMetadata(ctx);
    if (templateResponseIsStale(metadata, ctx && ctx.target)) {
      completeTemplateEvent(metadata && metadata.event_id, false);
      return false;
    }
    if (metadata) {
      ctx.selectoTemplateMetadata = metadata;
      if (Number(metadata.status || 0) < 400) {
        ctx.selectoTemplateControlSnapshot = captureTemplateControls(
          templateRootForInstance(metadata.instance_id, ctx.target), metadata
        );
      }
    }
    return true;
  }

  function reconcileTemplateHttpSwap(ctx) {
    applyTemplateMetadata(ctx && ctx.selectoTemplateMetadata);
    restoreTemplateControls(ctx && ctx.selectoTemplateControlSnapshot);
  }

  document.addEventListener("submit", function (event) {
    var info = templateEventFormInfo(event.target);
    if (!info) return;
    var entry = templateEventQueues.get(info.key);
    if (!entry) {
      entry = {
        key: info.key,
        instance_id: info.instance_id,
        component_id: info.component_id,
        event: info.event,
        in_flight_event_id: info.event_id,
        pending: []
      };
      templateEventQueues.set(info.key, entry);
      templateEventKeysById.set(info.event_id, info.key);
      return;
    }
    if (!entry.in_flight_event_id) {
      entry.in_flight_event_id = info.event_id;
      templateEventKeysById.set(info.event_id, info.key);
      return;
    }
    event.preventDefault();
    event.stopImmediatePropagation();
    if (entry.pending.length >= templateEventQueueLimit) {
      emitTemplateQueueEvent("selecto:template:queue:overflow", entry, "queue_full");
      return;
    }
    entry.pending.push({value: info.value, form_revision: info.form_revision});
  }, true);

  document.addEventListener("htmx:finally:request", function (event) {
    var ctx = event.detail && event.detail.ctx;
    var source = ctx && ctx.sourceElement;
    var form = source instanceof HTMLFormElement
      ? source : source && (source.form || source.closest("form"));
    var eventId = form && form.querySelector('input[name="event_id"]');
    if (!eventId || !templateEventKeysById.has(eventId.value)) return;
    var metadata = httpTemplateMetadata(ctx);
    var status = ctx && ctx.response && ctx.response.status;
    completeTemplateEvent(
      eventId.value,
      status >= 200 && status < 300
        && metadata && metadata.event_id === eventId.value
    );
  });

  document.addEventListener("htmx:ws:close", function (event) {
    var root = event.target && event.target.querySelector
      && event.target.querySelector("[data-selecto-template-instance]");
    if (root) {
      cancelTemplateEventQueuesForInstance(
        root.dataset.selectoTemplateInstance, "connection_closed"
      );
    }
  });

  document.addEventListener("htmx:ws:error", function (event) {
    var root = event.target && event.target.querySelector
      && event.target.querySelector("[data-selecto-template-instance]");
    if (root) {
      cancelTemplateEventQueuesForInstance(
        root.dataset.selectoTemplateInstance, "connection_error"
      );
    }
  });

  function markTemplateControlEdited(control) {
    if (!templateControlKey(control)
        || !control.closest("[data-selecto-template-instance]")) return;
    var draftValue = control instanceof HTMLInputElement
        && (control.type === "checkbox" || control.type === "radio")
      ? String(control.checked)
      : control instanceof HTMLSelectElement && control.multiple
        ? Array.from(control.selectedOptions, function (option) {
            return option.value;
          }).join("\u0000")
        : control.value;
    if (templateControlDraftValues.get(control) === draftValue) return;
    templateControlDraftValues.set(control, draftValue);
    control.setAttribute("data-selecto-template-dirty", "true");
    if (control.form && templateEventFormInfo(control.form)) {
      advanceTemplateEventFormRevision(control.form);
    }
  }

  document.addEventListener("input", function (event) {
    var control = event.target;
    markTemplateControlEdited(control);
  });

  document.addEventListener("change", function (event) {
    var control = event.target;
    markTemplateControlEdited(control);
  });

  window.addEventListener("pageshow", function (event) {
    if (!event.persisted
        || !document.querySelector("[data-selecto-template-instance]")) return;
    // A private template restored from bfcache contains the previous session's
    // rendered DOM. Reload it so the host resolves tenant/session authority again.
    window.location.reload();
  });
