  var queryAssistantSessions = new Map();

  function assistantFormInput(form) {
    var input = Object.create(null);
    new FormData(form).forEach(function (value, name) {
      if (typeof File !== "undefined" && value instanceof File) return;
      if (Object.prototype.hasOwnProperty.call(input, name)) {
        if (!Array.isArray(input[name])) input[name] = [input[name]];
        input[name].push(String(value));
      } else {
        input[name] = String(value);
      }
    });
    return input;
  }

  async function assistantRequest(session, tool, payload) {
    var response = await fetch(session.endpoint + "/" + encodeURIComponent(session.draftId)
      + "/tools/" + encodeURIComponent(tool), {
      method: "POST",
      credentials: "same-origin",
      headers: {"Content-Type": "application/json", "X-CSRF-Token": session.csrf},
      body: JSON.stringify(Object.assign({}, payload, {draft_id: session.draftId}))
    });
    var body = await response.json().catch(function () {
      return {ok: false, code: "invalid_response"};
    });
    if (!response.ok && body.ok !== false) body.ok = false;
    return body;
  }

  async function syncAssistantSession(session, form) {
    var generation = form ? String(form.dataset.scEditGeneration || "0") : "0";
    if (generation === String(session.syncedGeneration || "0")) return;
    var response = await fetch(session.endpoint + "/" + encodeURIComponent(session.draftId) + "/sync", {
      method: "POST", credentials: "same-origin",
      headers: {"Content-Type": "application/json", "X-CSRF-Token": session.csrf},
      body: JSON.stringify({base_revision: session.revision, input: assistantFormInput(form)})
    });
    var result = await response.json();
    if (!response.ok || !result.ok) throw new Error(result.code || "draft synchronization failed");
    session.revision = result.revision;
    session.undoToken = "";
    session.syncedGeneration = generation;
  }

  function assistantStatus(session, message, error) {
    var surface = session.surface && session.surface.isConnected ? session.surface
      : document.querySelector('[data-sc-query-assistant="' + CSS.escape(session.endpoint) + '"]');
    var status = surface && surface.querySelector("[data-sc-query-assistant-status]");
    if (status) {
      status.textContent = message;
      status.classList.toggle("is-error", Boolean(error));
    }
  }

  function applyAssistantBuilder(session, result, generation) {
    if (!result || !result.ok) return result;
    session.revision = result.revision;
    if (result.undo_token) session.undoToken = result.undo_token;
    if (!result.builder_html) return result;
    var current = document.querySelector('[data-sc-query-assistant="' + CSS.escape(session.endpoint) + '"]');
    var form = current && current.querySelector("[data-sc-builder]");
    if (!form || String(form.dataset.scEditGeneration || "0") !== String(generation)) {
      result.ui_applied = false;
      result.ui_message = "The validated draft was not inserted because the form changed locally.";
      assistantStatus(session, result.ui_message, true);
      return result;
    }
    var shell = form.closest("[data-sc-builder-shell]");
    var template = document.createElement("template");
    template.innerHTML = result.builder_html.trim();
    var replacement = template.content.firstElementChild;
    if (!shell || !replacement) return result;
    shell.replaceWith(replacement);
    if (window.htmx && typeof window.htmx.process === "function") window.htmx.process(replacement);
    var nextForm = replacement.querySelector("[data-sc-builder]");
    if (nextForm) {
      nextForm.dataset.scEditGeneration = String(Number(generation) + 1);
      nextForm.classList.add("is-dirty");
      session.syncedGeneration = nextForm.dataset.scEditGeneration;
    }
    restoreBuilderTabs();
    restoreBuilderTrays();
    restoreResultViews();
    var undo = replacement.querySelector("[data-sc-query-assistant-undo]");
    if (undo) undo.hidden = !session.undoToken;
    assistantStatus(session, result.no_op ? "No query changes needed." : "Assistant changes ready. Review them, then run the query.", false);
    result.ui_applied = true;
    return result;
  }

  async function initializeQueryAssistantSurface(surface) {
    var endpoint = surface && surface.dataset.scQueryAssistant;
    if (!endpoint) return;
    var existing = queryAssistantSessions.get(endpoint);
    if (existing && existing.surface === surface && surface.isConnected) return;
    if (existing) {
      existing.controller.abort();
      queryAssistantSessions.delete(endpoint);
    }
    var form = surface.querySelector("[data-sc-builder]");
    if (!form) return;
    var session = {
      endpoint: endpoint,
      surface: surface,
      csrf: surface.dataset.scQueryAssistantCsrf || "",
      controller: new AbortController(),
      revision: 0,
      contextVersion: "",
      undoToken: "",
      syncedGeneration: String(form.dataset.scEditGeneration || "0")
    };
    queryAssistantSessions.set(endpoint, session);
    try {
      var response = await fetch(endpoint, {
        method: "POST", credentials: "same-origin",
        headers: {"Content-Type": "application/json", "X-CSRF-Token": session.csrf},
        body: JSON.stringify({input: assistantFormInput(form)})
      });
      var bootstrap = await response.json();
      if (!response.ok || !bootstrap.ok) throw new Error(bootstrap.code || "draft bootstrap failed");
      session.draftId = bootstrap.draft_id;
      session.revision = bootstrap.revision;
      session.contextVersion = bootstrap.context_version;
      session.tools = bootstrap.tools || [];
      assistantStatus(session, "Browser assistant tools are ready.", false);
      await registerQueryAssistantTools(session);
    } catch (error) {
      session.controller.abort();
      queryAssistantSessions.delete(endpoint);
      assistantStatus(session, "Browser assistant is unavailable: " + error.message, true);
    }
  }

  function initializeQueryAssistants() {
    document.querySelectorAll("[data-sc-query-assistant]").forEach(initializeQueryAssistantSurface);
  }

  document.addEventListener("click", function (event) {
    var button = event.target.closest("[data-sc-query-assistant-undo]");
    if (!button) return;
    var surface = button.closest("[data-sc-query-assistant]");
    var session = surface && queryAssistantSessions.get(surface.dataset.scQueryAssistant);
    if (!session || !session.undoToken) return;
    var form = surface.querySelector("[data-sc-builder]");
    var generation = form ? form.dataset.scEditGeneration || "0" : "0";
    button.disabled = true;
    syncAssistantSession(session, form).then(function () {
      if (!session.undoToken) throw new Error("The form changed after the assistant edit.");
      return assistantRequest(session, "undo_query_draft", {
        base_revision: session.revision, undo_token: session.undoToken
      });
    }).then(function (result) {
      if (result.ok) session.undoToken = "";
      applyAssistantBuilder(session, result, generation);
    }).catch(function (error) {
      assistantStatus(session, "Undo could not be completed: " + error.message, true);
    }).finally(function () { button.disabled = false; });
  });

  document.addEventListener("DOMContentLoaded", initializeQueryAssistants);
  document.addEventListener("htmx:after:swap", initializeQueryAssistants);
  window.addEventListener("pageshow", initializeQueryAssistants);
