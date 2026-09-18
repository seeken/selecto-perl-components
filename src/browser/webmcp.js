  function browserToolDefinition(definition) {
    var schema = JSON.parse(JSON.stringify(definition.inputSchema || {type: "object"}));
    var internal = ["draft_id", "base_revision", "context_version", "undo_token"];
    internal.forEach(function (name) {
      if (schema.properties) delete schema.properties[name];
      if (Array.isArray(schema.required)) schema.required = schema.required.filter(function (item) {
        return item !== name;
      });
    });
    return Object.assign({}, definition, {inputSchema: schema});
  }

  async function registerQueryAssistantTools(session) {
    var context = document.modelContext;
    if (!context || typeof context.registerTool !== "function") {
      assistantStatus(session, "Query draft is ready; this browser does not expose WebMCP.", false);
      return;
    }
    for (const source of session.tools) {
      requireAssistantSession(session);
      var definition = browserToolDefinition(source);
      definition.execute = async function (argumentsObject) {
        return queueAssistantOperation(session, async function () {
          var form = session.surface.querySelector("[data-sc-builder]");
          var generation = form ? form.dataset.scEditGeneration || "0" : "0";
          await syncAssistantSession(session, form);
          var payload = Object.assign({}, argumentsObject || {});
          if (source.name === "validate_query_target" || source.name === "apply_query_draft") {
            payload.base_revision = session.revision;
            payload.context_version = session.contextVersion;
          }
          if (source.name === "undo_query_draft") {
            payload.base_revision = session.revision;
            payload.undo_token = session.undoToken;
          }
          var result = await assistantRequest(session, source.name, payload);
          if (result.stale_receipt) return result;
          if (source.name === "undo_query_draft" && result.ok) session.undoToken = "";
          if (source.name === "apply_query_draft" || source.name === "undo_query_draft") {
            applyAssistantBuilder(session, result, generation);
          }
          if (result.context_version) session.contextVersion = result.context_version;
          if (typeof result.revision === "number") session.revision = result.revision;
          return result;
        });
      };
      await context.registerTool(definition, {signal: session.controller.signal});
    }
    requireAssistantSession(session);
    assistantStatus(session, "WebMCP query tools are registered.", false);
  }

  window.addEventListener("pagehide", function () {
    queryAssistantSessions.forEach(function (session) { session.controller.abort(); });
    queryAssistantSessions.clear();
  });
