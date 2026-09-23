(function (global) {
  "use strict";

  function apiPath(base, suffix) { return `${String(base).replace(/\/+$/, "")}${suffix}`; }
  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }
  function normalize(value) { return String(value || "").toLowerCase().replace(/[^a-z0-9]+/g, ""); }
  function json(value) { return JSON.stringify(value, null, 2); }
  function targetGroupLabel(domain, field) {
    const path = String(field).split(".");
    if (path.length === 1) return domain && domain.name || "Main record";
    const join = domain && domain.joins && domain.joins[path[0]] || {};
    return join.name || path[0].replace(/_/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
  }
  function addGroupedOption(select, groups, groupLabel, option) {
    let group = groups.get(groupLabel);
    if (!group) {
      group = document.createElement("optgroup");
      group.label = groupLabel;
      groups.set(groupLabel, group);
      select.add(group);
    }
    group.append(option);
  }

  class Importer {
    constructor(root) {
      this.root = root;
      this.base = String(root.dataset.apiBase || "").replace(/\/+$/, "");
      this.curlAuth = root.dataset.curlAuth || "cookie";
      this.csrfToken = String(root.dataset.csrfToken || "");
      this.domain = null;
      this.upload = null;
      this.profiles = [];
      this.profile = null;
      this.mappings = new Map();
      this.actionMappings = new Map();
      this.extraFields = new Set();
      this.extraActionInputs = new Set();
      this.selectedKeySetId = null;
      this.idempotencyEnabled = true;
      this.selectedRows = new Set();
      this.executionScope = "all_valid";
      this.stagedRows = [];
    }

    async fetchJSON(path, options) {
      const request = Object.assign({credentials: "same-origin"}, options || {});
      request.headers = Object.assign({Accept: "application/json"}, options && options.headers || {});
      if (String(request.method || "GET").toUpperCase() !== "GET") {
        request.headers["X-CSRF-Token"] = this.csrfToken;
      }
      const response = await fetch(path, request);
      const refreshedCSRF = response.headers.get("X-CSRF-Token");
      if (refreshedCSRF) this.csrfToken = refreshedCSRF;
      const payload = await response.json().catch(() => ({}));
      if (!response.ok || payload.ok === false) {
        const apiError = payload.error || {};
        const error = new Error(apiError.message || `Request failed (${response.status})`);
        error.code = apiError.code;
        error.details = apiError.details || {};
        throw error;
      }
      return payload.data === undefined ? payload : payload.data;
    }

    async start() {
      try {
        const [domain, profiles] = await Promise.all([
          this.fetchJSON(apiPath(this.base, "/domain")),
          this.fetchJSON(apiPath(this.base, "/import-profiles")),
        ]);
        this.domain = domain;
        this.profiles = profiles.profiles || [];
        this.render();
      } catch (error) {
        this.root.replaceChildren(element("section", "sai-fatal", error.message || String(error)));
      }
    }

    async refreshDomain() {
      this.domain = await this.fetchJSON(apiPath(this.base, "/domain"));
      const fields = this.importFields();
      let removed = 0;
      this.mappings.forEach((mapping, field) => {
        if (!fields[field]) { this.mappings.delete(field); this.extraFields.delete(field); removed += 1; }
      });
      this.actionMappings.forEach((mapping, key) => {
        const [action, input] = key.split(":");
        if (!this.actionInput(action, input)) { this.actionMappings.delete(key); this.extraActionInputs.delete(key); removed += 1; }
      });
      if (this.upload) this.renderMapping();
      return removed;
    }

    importerContract() { return this.domain && this.domain.imports || null; }
    importFields() { return this.importerContract() && this.importerContract().fields || {}; }
    importActions() { return this.importerContract() && this.importerContract().actions || {}; }
    actionInputEntries() {
      const entries = [];
      Object.entries(this.importActions()).forEach(([action, actionSpec]) => {
        const publishedAction = (this.domain.actions || {})[action] || {};
        const publishedInputs = new Map(Object.entries(publishedAction.inputs || {}));
        Object.entries(actionSpec.inputs || {}).forEach(([input, inputSpec]) => {
          const publishedInput = publishedInputs.get(input) || {};
          entries.push({
            action, input, spec: Object.assign({}, inputSpec, {
              type: inputSpec.type || publishedInput.type,
              required: Boolean(inputSpec.required || publishedInput.required),
            }),
            label: `${actionSpec.label || publishedAction.label || action}: ${inputSpec.label || publishedInput.label || input}`,
          });
        });
      });
      return entries;
    }
    actionInput(action, input) {
      return this.actionInputEntries().find((entry) => entry.action === action && entry.input === input);
    }

    render() {
      const title = this.root.dataset.title || `${this.domain.name || "Data"} Importer`;
      this.root.innerHTML = `
        <header class="sai-header"><div><h1></h1><p>Map a file to governed writes, validate every row, then import deliberately.</p></div><a class="sai-back" href="${this.base}/console">API Console</a></header>
        <section class="sai-card"><h2>1. Upload or choose a profile</h2><div class="sai-inline"><label>Import profile<select data-sai-profile><option value="">New mapping</option></select></label><label>File<input type="file" accept=".csv,.tsv,text/csv,text/tab-separated-values" data-sai-file></label><button type="button" class="sai-button" data-sai-upload>Inspect file</button></div><p class="sai-message" data-sai-message></p></section>
        <section class="sai-card" data-sai-mapping-card hidden><h2>2. Map file data</h2><div data-sai-file-summary></div><p class="sai-hint">Each row below is a column in the uploaded file. Choose a governed write field or governed action input that should receive it. A Match radio appears only for file columns that can identify an existing record.</p><div class="sai-mapping" data-sai-mappings></div><details class="sai-additional-values"><summary>Additional values not in the file</summary><p class="sai-hint">Use these for static values, run parameters, and trusted context such as the active client.</p><label class="sai-add-field">Add field<select data-sai-add-extra></select></label><div class="sai-mapping" data-sai-extra-mappings></div></details><div class="sai-inline"><label>On existing<select data-sai-on-match></select></label><label>When missing<select data-sai-on-missing></select></label><label>Rows from<input type="number" min="1" value="1" data-sai-start></label><label>through<input type="number" min="1" data-sai-end></label><label><input type="checkbox" checked data-sai-idempotency> Skip rows already imported from this file</label></div><p class="sai-hint">Turn off duplicate protection only when deliberately replaying a corrected mapping; the import will ask for confirmation.</p><label class="sai-label">Configuration JSON<textarea spellcheck="false" data-sai-config></textarea></label><div class="sai-actions"><button type="button" class="sai-button sai-secondary" data-sai-copy>Copy JSON</button><button type="button" class="sai-button sai-secondary" data-sai-save-profile>Save profile</button><button type="button" class="sai-button" data-sai-preview>Validate & preview</button><button type="button" class="sai-button sai-primary" data-sai-run>Import valid rows</button></div></section>
        <section class="sai-card" data-sai-results-card hidden><h2>3. Staged rows</h2><div data-sai-results></div></section>`;
      this.root.querySelector("h1").textContent = title;
      this.populateProfiles();
      this.bind();
    }

    populateProfiles() {
      const select = this.root.querySelector("[data-sai-profile]");
      this.profiles.forEach((profile) => select.add(new Option(`${profile.name} (rev ${profile.revision})`, profile.id)));
    }

    bind() {
      this.root.addEventListener("click", (event) => {
        const target = event.target;
        if (target.matches("[data-sai-upload]")) this.uploadFile();
        if (target.matches("[data-sai-preview]")) this.preview();
        if (target.matches("[data-sai-run]")) this.run();
        if (target.matches("[data-sai-run-scope]")) this.runScope();
        if (target.matches("[data-sai-select-valid]")) this.selectValidRows();
        if (target.matches("[data-sai-clear-selection]")) { this.selectedRows.clear(); this.renderResults(this.stagedRows, "previewed"); }
        if (target.matches("[data-sai-run-row]")) this.runRow(Number(target.dataset.saiRunRow));
        if (target.matches("[data-sai-save-profile]")) this.saveProfile();
        if (target.matches("[data-sai-copy]")) navigator.clipboard && navigator.clipboard.writeText(this.configJSON());
      });
      this.root.addEventListener("change", (event) => {
        if (event.target.matches("[data-sai-profile]")) this.chooseProfile(event.target.value);
        if (event.target.matches("[data-sai-column]")) this.columnChanged(event.target);
        if (event.target.matches("[data-sai-source]")) this.sourceChanged(event.target);
        if (event.target.matches("[data-sai-action-source]")) this.actionSourceChanged(event.target);
        if (event.target.matches("[data-sai-add-extra]")) this.addExtraField(event.target.value);
        if (event.target.matches("[data-sai-key-set]")) {
          this.selectedKeySetId = event.target.value;
          this.renderMatchChoices();
        }
        if (event.target.matches("[data-sai-idempotency]")) {
          this.idempotencyEnabled = event.target.checked;
          this.syncConfigEditor();
          if (!this.idempotencyEnabled) this.message("Duplicate protection is off: completed rows from this file can be deliberately replayed.");
        }
        if (event.target.matches("[data-sai-row-select]")) {
          const rowNumber = Number(event.target.dataset.saiRowSelect);
          if (event.target.checked) this.selectedRows.add(rowNumber); else this.selectedRows.delete(rowNumber);
          this.updateSelectionSummary();
        }
        if (event.target.matches("[data-sai-execution-scope]")) {
          this.executionScope = event.target.value;
          this.updateSelectionSummary();
        }
        if (event.target.matches("[data-sai-config]")) this.loadJSON(event.target.value);
        if (event.target.matches("[data-sai-static]")) this.mappings.get(event.target.dataset.saiStatic).value = event.target.value;
        if (event.target.matches("[data-sai-action-static]")) this.actionMappings.get(event.target.dataset.saiActionStatic).value = event.target.value;
      });
      this.root.addEventListener("input", (event) => {
        if (event.target.matches("[data-sai-static]")) this.mappings.get(event.target.dataset.saiStatic).value = event.target.value;
        if (event.target.matches("[data-sai-action-static]")) this.actionMappings.get(event.target.dataset.saiActionStatic).value = event.target.value;
        if (event.target.matches("[data-sai-start],[data-sai-end]")) this.syncConfigEditor();
      });
    }

    message(text, error) {
      const node = this.root.querySelector("[data-sai-message]");
      node.textContent = text || "";
      node.classList.toggle("is-error", Boolean(error));
    }

    staticValueControl(spec, value, datasetName, datasetValue) {
      const choices = Array.isArray(spec && spec.options)
        ? spec.options : Array.isArray(spec && spec.enum) ? spec.enum : null;
      let control;
      if (choices) {
        control = element("select", "");
        control.add(new Option("Choose…", ""));
        choices.forEach((choice) => {
          const optionValue = choice && typeof choice === "object"
            ? choice.value : choice;
          const optionLabel = choice && typeof choice === "object"
            ? (choice.label || optionValue) : optionValue;
          control.add(new Option(String(optionLabel), String(optionValue)));
        });
      } else {
        control = element("input", "");
        control.type = this.inputType((spec || {}).type);
        control.placeholder = "Value";
      }
      control.value = value === undefined || value === null ? "" : String(value);
      control.dataset[datasetName] = datasetValue;
      return control;
    }

    async uploadFile() {
      const file = this.root.querySelector("[data-sai-file]").files[0];
      if (!file) return this.message("Choose a CSV or TSV file first.", true);
      this.message("Inspecting file…");
      try {
        const form = new FormData();
        form.append("file", file);
        const response = await fetch(apiPath(this.base, "/imports/uploads"), {method: "POST", credentials: "same-origin", body: form, headers: {Accept: "application/json", "X-CSRF-Token": this.csrfToken}});
        const payload = await response.json();
        if (!response.ok || payload.ok === false) throw new Error(payload.error && payload.error.message || "Upload failed");
        this.upload = payload.data.upload;
        this.autoMap();
        this.renderMapping();
        this.message(`Read ${this.upload.inspection.row_count} data rows from ${this.upload.filename}.`);
      } catch (error) { this.message(error.message || String(error), true); }
    }

    autoMap() {
      this.mappings.clear();
      this.actionMappings.clear();
      this.extraFields.clear();
      this.extraActionInputs.clear();
      this.selectedKeySetId = null;
      const columns = this.upload.inspection.columns || [];
      const claimedColumns = new Set();
      // Action inputs are operational semantics rather than ordinary table
      // assignments.  Give their explicit aliases precedence, then ensure a
      // file column can never feed more than one destination.
      this.actionInputEntries().forEach(({action, input, spec}) => {
        const aliases = [input, ...(spec.header_aliases || [])].map(normalize);
        const column = columns.find((item) => !claimedColumns.has(item.id) && aliases.includes(normalize(item.header)));
        if (column) {
          this.actionMappings.set(`${action}:${input}`, {kind: "column", column_id: column.id});
          claimedColumns.add(column.id);
        } else this.actionMappings.set(`${action}:${input}`, {kind: "omit", value: ""});
      });
      Object.entries(this.importFields()).forEach(([field, spec]) => {
        const aliases = [field, ...(spec.header_aliases || [])].map(normalize);
        const column = columns.find((item) => !claimedColumns.has(item.id) && aliases.includes(normalize(item.header)));
        if (column) {
          this.mappings.set(field, {kind: "column", column_id: column.id});
          claimedColumns.add(column.id);
        }
        else if ((spec.sources || []).length === 1 && spec.sources[0] === "trusted") {
          this.mappings.set(field, {kind: "trusted", value: ""});
          this.extraFields.add(field);
        } else this.mappings.set(field, {kind: "omit", value: ""});
      });
    }

    renderMapping() {
      const card = this.root.querySelector("[data-sai-mapping-card]");
      card.hidden = false;
      const inspection = this.upload.inspection;
      this.root.querySelector("[data-sai-file-summary]").textContent = `${inspection.row_count} rows · ${inspection.columns.map((column) => column.label).join(", ")}`;
      const body = this.root.querySelector("[data-sai-mappings]");
      body.replaceChildren();
      const fields = this.importFields();
      const mappedColumns = new Map();
      this.mappings.forEach((mapping, field) => {
        if (mapping.kind === "column") mappedColumns.set(mapping.column_id, field);
      });
      this.actionMappings.forEach((mapping, key) => {
        if (mapping.kind === "column") mappedColumns.set(mapping.column_id, `action:${key}`);
      });
      this.renderKeySetChoices();
      const eligibleKeySets = this.eligibleKeySets();
      (inspection.columns || []).forEach((column) => {
        const row = element("div", "sai-mapping-row");
        const copy = element("div", "");
        copy.append(element("strong", "", column.label), element("code", "", column.header || `Column ${column.ordinal}`));
        const target = element("select", "");
        target.dataset.saiColumn = column.id;
        target.add(new Option("Do not send", "", false, !mappedColumns.has(column.id)));
        const targetGroups = new Map();
        Object.entries(fields).sort(([a], [b]) => a.localeCompare(b)).forEach(([field, spec]) => {
          if (!(spec.sources || []).includes("column")) return;
          const option = new Option(`${this.fieldLabel(field)} (${field})`, field, false, mappedColumns.get(column.id) === field);
          const existing = this.mappings.get(field);
          option.disabled = Boolean(existing && existing.kind === "column" && existing.column_id !== column.id);
          addGroupedOption(target, targetGroups, targetGroupLabel(this.domain, field), option);
        });
        this.actionInputEntries().sort((a, b) => a.label.localeCompare(b.label)).forEach(({action, input, spec, label}) => {
          if (!(spec.sources || []).includes("column")) return;
          const key = `${action}:${input}`;
          const existing = this.actionMappings.get(key);
          const option = new Option(`${label} (${action}.${input})`, `action:${key}`, false, mappedColumns.get(column.id) === `action:${key}`);
          option.disabled = Boolean(existing && existing.kind === "column" && existing.column_id !== column.id);
          addGroupedOption(target, targetGroups, "Actions", option);
        });
        const field = mappedColumns.get(column.id);
        const matchSets = field && !field.startsWith("action:")
          ? eligibleKeySets.filter((set) => (set.fields || []).includes(field)) : [];
        const match = element("div", "sai-match-choice");
        matchSets.forEach((set) => {
          const label = element("label", "sai-key-choice");
          const input = element("input", "");
          input.type = "radio"; input.name = "selecto-import-key-set"; input.value = set.id;
          input.checked = set.id === this.selectedKeySetId; input.dataset.saiKeySet = "";
          label.append(input, document.createTextNode(` Match: ${set.label || set.id}`));
          match.append(label);
        });
        row.append(copy, target, match);
        body.append(row);
      });
      this.renderExtraMappings(fields);
      this.renderActionRequirements(card);
      this.renderMatchChoices();
      this.syncConfigEditor();
    }

    configuredActions() {
      return Object.keys(this.importActions()).filter((action) => this.actionInputEntries().some(({action: candidate, input}) =>
        candidate === action && (this.actionMappings.get(`${action}:${input}`) || {}).kind !== "omit"
      ));
    }
    actionInputMissing(action, input, spec) {
      const mapping = this.actionMappings.get(`${action}:${input}`) || {kind: "omit"};
      if (mapping.kind === "omit") return true;
      if (mapping.kind === "static") return !String(mapping.value || "").trim();
      if (mapping.kind === "parameter") return !String(mapping.value || mapping.name || "").trim();
      return false;
    }
    missingRequiredActionInputs() {
      return this.actionInputEntries().filter(({action, input, spec}) =>
        spec.required && this.configuredActions().includes(action) && this.actionInputMissing(action, input, spec)
      );
    }
    renderActionRequirements(card) {
      let panel = card.querySelector("[data-sai-action-requirements]");
      if (!panel) {
        panel = element("section", "sai-action-requirements"); panel.dataset.saiActionRequirements = "";
        const config = card.querySelector("[data-sai-config]");
        card.insertBefore(panel, config && config.closest("label"));
      }
      panel.replaceChildren();
      const actions = this.configuredActions();
      panel.hidden = !actions.length;
      if (!actions.length) return;
      panel.append(element("h3", "", "Action inputs"), element("p", "sai-hint", "Every required action input must be mapped from the file, supplied as a static value, or supplied as a run parameter."));
      actions.forEach((action) => {
        const actionSpec = this.importActions()[action] || {};
        const group = element("div", "sai-action-requirement");
        group.append(element("strong", "", actionSpec.label || ((this.domain.actions || {})[action] || {}).label || action));
        const list = element("ul", "");
        this.actionInputEntries().filter((entry) => entry.action === action).forEach(({input, spec, label}) => {
          const missing = spec.required && this.actionInputMissing(action, input, spec);
          const mapping = this.actionMappings.get(`${action}:${input}`) || {kind: "omit"};
          const item = element("li", missing ? "is-missing" : "");
          const requirement = spec.required ? "Required" : "Optional";
          const source = missing ? "Missing — choose a file column or add a static/parameter value." : `Configured from ${mapping.kind}.`;
          item.textContent = `${label} — ${requirement}. ${source}`;
          list.append(item);
        });
        group.append(list); panel.append(group);
      });
    }

    sourceChanged(node) {
      const value = node.value;
      const field = node.dataset.saiSource;
      if (value.startsWith("column:")) this.mappings.set(field, {kind: "column", column_id: value.slice(7)});
      else this.mappings.set(field, {kind: value, value: ""});
      this.renderMapping();
    }

    actionSourceChanged(node) {
      const value = node.value;
      const key = node.dataset.saiActionSource;
      this.actionMappings.set(key, {kind: value, value: ""});
      this.renderMapping();
    }

    fieldLabel(field) { return (this.domain.source.columns[field] || {}).label || field; }
    inputType(type) {
      if (type === "date") return "date";
      if (type === "number" || type === "integer" || type === "decimal") return "number";
      return "text";
    }

    columnChanged(node) {
      const columnId = node.dataset.saiColumn;
      this.mappings.forEach((mapping, field) => {
        if (mapping.kind === "column" && mapping.column_id === columnId) this.mappings.set(field, {kind: "omit", value: ""});
      });
      this.actionMappings.forEach((mapping, key) => {
        if (mapping.kind === "column" && mapping.column_id === columnId) this.actionMappings.set(key, {kind: "omit", value: ""});
      });
      if (node.value) {
        if (node.value.startsWith("action:")) {
          const key = node.value.slice(7);
          const old = this.actionMappings.get(key);
          if (old && old.kind === "column") this.actionMappings.set(key, {kind: "omit", value: ""});
          this.actionMappings.set(key, {kind: "column", column_id: columnId});
          this.extraActionInputs.delete(key);
          this.renderMapping();
          return;
        }
        const old = this.mappings.get(node.value);
        if (old && old.kind === "column") this.mappings.set(node.value, {kind: "omit", value: ""});
        this.mappings.set(node.value, {kind: "column", column_id: columnId});
        this.extraFields.delete(node.value);
      }
      this.renderMapping();
    }

    renderExtraMappings(fields) {
      const add = this.root.querySelector("[data-sai-add-extra]");
      add.replaceChildren(new Option("Choose a field…", ""));
      const addGroups = new Map();
      Object.entries(fields).sort(([a], [b]) => a.localeCompare(b)).forEach(([field, spec]) => {
        if ((spec.sources || []).some((source) => source !== "column")) {
          addGroupedOption(add, addGroups, targetGroupLabel(this.domain, field),
            new Option(`${this.fieldLabel(field)} (${field})`, field));
        }
      });
      this.actionInputEntries().sort((a, b) => a.label.localeCompare(b.label)).forEach(({action, input, spec, label}) => {
        if ((spec.sources || []).some((source) => source !== "column")) {
          addGroupedOption(add, addGroups, "Actions",
            new Option(`${label} (${action}.${input})`, `action:${action}:${input}`));
        }
      });
      const body = this.root.querySelector("[data-sai-extra-mappings]");
      body.replaceChildren();
      [...this.extraFields].sort().forEach((field) => {
        const spec = fields[field]; if (!spec) return;
        const mapping = this.mappings.get(field) || {kind: "omit", value: ""};
        if (mapping.kind === "column") return;
        const row = element("div", "sai-mapping-row");
        const copy = element("div", "");
        copy.append(element("strong", "", this.fieldLabel(field)), element("code", "", field));
        const source = element("select", ""); source.dataset.saiSource = field;
        source.add(new Option("Do not send", "omit", false, mapping.kind === "omit"));
        if ((spec.sources || []).includes("static")) source.add(new Option("Static value", "static", false, mapping.kind === "static"));
        if ((spec.sources || []).includes("parameter")) source.add(new Option("Run parameter", "parameter", false, mapping.kind === "parameter"));
        if ((spec.sources || []).includes("trusted")) source.add(new Option("Current trusted context", "trusted", false, mapping.kind === "trusted"));
        row.append(copy, source);
        if (mapping.kind === "static" || mapping.kind === "parameter") {
          const column = this.domain.source.columns[field] || {};
          const input = mapping.kind === "static"
            ? this.staticValueControl(column, mapping.value, "saiStatic", field)
            : element("input", "");
          if (mapping.kind === "parameter") {
            input.type = "text"; input.value = mapping.name || "";
            input.placeholder = "Parameter name"; input.dataset.saiStatic = field;
          }
          row.append(input);
        }
        body.append(row);
      });
      [...this.extraActionInputs].sort().forEach((key) => {
        const [action, input] = key.split(":");
        const entry = this.actionInput(action, input);
        if (!entry) return;
        const spec = entry.spec;
        const mapping = this.actionMappings.get(key) || {kind: "omit", value: ""};
        if (mapping.kind === "column") return;
        const row = element("div", "sai-mapping-row");
        const copy = element("div", "");
        copy.append(element("strong", "", entry.label), element("code", "", `${action}.${input}`));
        const source = element("select", ""); source.dataset.saiActionSource = key;
        source.add(new Option("Do not send", "omit", false, mapping.kind === "omit"));
        if ((spec.sources || []).includes("static")) source.add(new Option("Static value", "static", false, mapping.kind === "static"));
        if ((spec.sources || []).includes("parameter")) source.add(new Option("Run parameter", "parameter", false, mapping.kind === "parameter"));
        if ((spec.sources || []).includes("trusted")) source.add(new Option("Current trusted context", "trusted", false, mapping.kind === "trusted"));
        row.append(copy, source);
        if (mapping.kind === "static" || mapping.kind === "parameter") {
          const value = mapping.kind === "static"
            ? this.staticValueControl(spec, mapping.value, "saiActionStatic", key)
            : element("input", "");
          if (mapping.kind === "parameter") {
            value.type = "text"; value.value = mapping.name || "";
            value.placeholder = "Parameter name";
            value.dataset.saiActionStatic = key;
          }
          row.append(value);
        }
        body.append(row);
      });
    }

    addExtraField(field) {
      if (!field) return;
      if (field.startsWith("action:")) {
        const key = field.slice(7);
        const [action, input] = key.split(":");
        const entry = this.actionInput(action, input);
        if (!entry) return;
        const spec = entry.spec;
        const kind = (spec.sources || []).find((source) => source !== "column") || "omit";
        this.actionMappings.set(key, {kind, value: ""});
        this.extraActionInputs.add(key);
        this.renderMapping();
        return;
      }
      const spec = this.importFields()[field];
      const kind = (spec.sources || []).find((source) => source !== "column") || "omit";
      this.mappings.set(field, {kind, value: ""});
      this.extraFields.add(field);
      this.renderMapping();
    }

    eligibleKeySets() {
      return (this.importerContract().key_sets || []).filter((set) =>
        (set.fields || []).every((field) => (this.mappings.get(field) || {}).kind === "column")
      );
    }
    renderKeySetChoices() {
      const sets = this.eligibleKeySets();
      if (!sets.some((set) => set.id === this.selectedKeySetId)) this.selectedKeySetId = sets[0] && sets[0].id || null;
    }
    selectedKeySet() { return this.eligibleKeySets().find((set) => set.id === this.selectedKeySetId); }
    renderMatchChoices() {
      const set = this.selectedKeySet();
      const fill = (selector, values, selected) => {
        const select = this.root.querySelector(selector); select.replaceChildren();
        values.forEach((value) => select.add(new Option(value, value, false, value === selected)));
      };
      if (!set) {
        fill("[data-sai-on-match]", [], "");
        fill("[data-sai-on-missing]", [], "");
        this.syncConfigEditor();
        return;
      }
      fill("[data-sai-on-match]", set.allowed_on_match || [], set.default_on_match);
      fill("[data-sai-on-missing]", set.allowed_on_missing || [], set.default_on_missing);
      this.syncConfigEditor();
    }

    configuration() {
      const mappings = [];
      this.mappings.forEach((mapping, target) => {
        if (mapping.kind === "omit") return;
        const source = {kind: mapping.kind};
        if (mapping.kind === "column") source.column_id = mapping.column_id;
        if (mapping.kind === "static") source.value = mapping.value || "";
        if (mapping.kind === "parameter") source.name = mapping.value || target;
        mappings.push({target, source, transforms: []});
      });
      const actions = [];
      Object.entries(this.importActions()).forEach(([action]) => {
        const inputs = {};
        this.actionMappings.forEach((mapping, key) => {
          const [mappedAction, input] = key.split(":");
          if (mappedAction !== action || mapping.kind === "omit") return;
          const source = {kind: mapping.kind};
          if (mapping.kind === "column") source.column_id = mapping.column_id;
          if (mapping.kind === "static") source.value = mapping.value || "";
          if (mapping.kind === "parameter") source.name = mapping.value || input;
          inputs[input] = {source, transforms: []};
        });
        if (Object.keys(inputs).length) actions.push({action, inputs});
      });
      const end = Number(this.root.querySelector("[data-sai-end]").value || 0);
      return {
        config_version: 1, domain_fingerprint: this.domain.domain_fingerprint,
        upload_id: this.upload && this.upload.id, mappings, ...(actions.length ? {actions} : {}),
        rows: {start: Number(this.root.querySelector("[data-sai-start]").value || 1), ...(end ? {end} : {})},
        match: {key_set: this.selectedKeySetId, on_match: this.root.querySelector("[data-sai-on-match]").value, on_missing: this.root.querySelector("[data-sai-on-missing]").value},
        errors: {mode: "continue"}, idempotency: this.idempotencyEnabled
          ? {mode: "source_row", on_duplicate: "skip"} : {mode: "none"},
      };
    }
    configJSON() { return json(this.configuration()); }
    syncConfigEditor() { const node = this.root.querySelector("[data-sai-config]"); if (node) node.value = this.configJSON(); }
    loadJSON(value) {
      try {
        const config = JSON.parse(value); if (!config || !Array.isArray(config.mappings)) throw new Error("Configuration needs mappings.");
        this.mappings.clear(); this.actionMappings.clear(); this.extraFields.clear(); this.extraActionInputs.clear();
        this.selectedKeySetId = config.match && config.match.key_set || null;
        this.idempotencyEnabled = !config.idempotency || config.idempotency.mode !== "none";
        const idempotency = this.root.querySelector("[data-sai-idempotency]");
        if (idempotency) idempotency.checked = this.idempotencyEnabled;
        config.mappings.forEach((mapping) => {
          const source = Object.assign({value: ""}, mapping.source);
          this.mappings.set(mapping.target, source);
          if (source.kind !== "column") this.extraFields.add(mapping.target);
        });
        (config.actions || []).forEach((action) => Object.entries(action.inputs || {}).forEach(([input, mapping]) => {
          const source = Object.assign({value: ""}, mapping.source);
          const key = `${action.action}:${input}`;
          this.actionMappings.set(key, source);
          if (source.kind !== "column") this.extraActionInputs.add(key);
        }));
        this.renderMapping(); this.message("Configuration loaded.");
      } catch (error) { this.message(`Configuration could not be loaded: ${error.message}`, true); }
    }
    requestBody(overrides) {
      const profileId = this.root.querySelector("[data-sai-profile]").value;
      const request = profileId
        ? {upload_id: this.upload.id, profile_id: profileId}
        : {upload_id: this.upload.id, configuration: this.configuration()};
      if (profileId && !this.idempotencyEnabled) request.idempotency = {mode: "none"};
      return Object.assign(request, overrides || {});
    }
    async chooseProfile(id) {
      this.profile = this.profiles.find((profile) => profile.id === id) || null;
      if (this.upload && this.profile) {
        this.message(`Profile ${this.profile.name} will be checked against this file when you preview.`);
      }
    }
    async preview() { return this.execute("/imports/preview", "Previewing rows…"); }
    async run() {
      this.executionScope = "all_valid";
      return this.runScope();
    }
    selection() {
      const scope = this.executionScope || "all_valid";
      return scope === "selected"
        ? {scope, row_numbers: [...this.selectedRows].sort((a, b) => a - b)} : {scope};
    }
    selectValidRows() {
      this.selectedRows = new Set(this.stagedRows.filter((row) => !row.status && (row.decision === "insert" || row.decision === "update")).map((row) => row.row_number));
      this.renderResults(this.stagedRows, "previewed");
    }
    updateSelectionSummary() {
      const node = this.root.querySelector("[data-sai-selection-summary]");
      if (!node) return;
      const selected = this.selectedRows.size;
      node.textContent = this.executionScope === "selected"
        ? `${selected} row${selected === 1 ? "" : "s"} selected` : `Import scope: ${this.executionScope.replace(/_/g, " ")}`;
    }
    async runScope() {
      const selection = this.selection();
      if (selection.scope === "selected" && !selection.row_numbers.length) return this.message("Select one or more valid preview rows first.", true);
      if (!this.idempotencyEnabled && !global.confirm("Duplicate protection is off. Re-run matching rows from this file?")) return;
      return this.execute("/imports/runs", "Importing selected rows…", {mode: "run", selection});
    }
    async runRow(rowNumber) {
      if (!Number.isInteger(rowNumber) || rowNumber < 1) return;
      if (!this.idempotencyEnabled && !global.confirm("Duplicate protection is off. Re-run this source row?")) return;
      this.message(`Importing row ${rowNumber}…`);
      try {
        const payload = await this.fetchJSON(apiPath(this.base, "/imports/runs"), {method: "POST", headers: {"Content-Type": "application/json", Accept: "application/json"}, body: JSON.stringify(this.requestBody({mode: "run", rows: {start: rowNumber, end: rowNumber}}))});
        const updated = payload.run && payload.run.rows || [];
        updated.forEach((row) => {
          const index = this.stagedRows.findIndex((candidate) => candidate.row_number === row.row_number);
          if (index >= 0) this.stagedRows[index] = row;
        });
        this.renderResults(this.stagedRows, payload.run && payload.run.status || "completed");
        this.message(`Completed row ${rowNumber}.`);
      } catch (error) { this.message(error.message || String(error), true); }
    }
    async execute(path, message, extra) {
      if (!this.upload) return this.message("Inspect a file first.", true);
      if (!this.selectedKeySet()) return this.message("Map a file column to a match field before previewing or importing.", true);
      const missingInputs = this.missingRequiredActionInputs();
      if (missingInputs.length) {
        return this.message(`Action setup is incomplete: ${missingInputs.map(({label}) => label).join(", ")} ${missingInputs.length === 1 ? "is" : "are"} required.`, true);
      }
      this.message(message);
      try {
        const payload = await this.fetchJSON(apiPath(this.base, path), {method: "POST", headers: {"Content-Type": "application/json", Accept: "application/json"}, body: JSON.stringify(Object.assign(this.requestBody(), extra || {}))});
        const rows = payload.rows || payload.run && payload.run.rows || [];
        this.stagedRows = rows;
        if (path === "/imports/preview") this.selectedRows = new Set([...this.selectedRows].filter((number) => rows.some((row) => row.row_number === number && (row.decision === "insert" || row.decision === "update"))));
        this.renderResults(this.stagedRows, payload.run && payload.run.status || "previewed");
        this.message(`Completed ${rows.length} staged rows.`);
      } catch (error) {
        if (error.code === "import_domain_changed") {
          try {
            const removed = await this.refreshDomain();
            this.message(`The published domain changed; the mapping now uses the current contract${removed ? ` (${removed} obsolete mapping${removed === 1 ? "" : "s"} removed)` : ""}. Preview again before importing.`);
            return;
          } catch (refreshError) { this.message(refreshError.message || String(refreshError), true); return; }
        }
        this.message(error.message || String(error), true);
      }
    }
    renderResults(rows, status) {
      this.root.querySelector("[data-sai-results-card]").hidden = false;
      const container = this.root.querySelector("[data-sai-results]"); container.replaceChildren(element("p", "", `Run status: ${status}`));
      const preview = rows.some((row) => !row.status);
      if (preview) {
        const controls = element("div", "sai-execution-controls");
        const scopeLabel = element("label", "", "Import");
        const scope = element("select", ""); scope.dataset.saiExecutionScope = "";
        [["all_valid", "All valid rows"], ["selected", "Selected rows"], ["inserts", "Inserts only"], ["updates", "Updates only"]].forEach(([value, label]) => scope.add(new Option(label, value, false, value === this.executionScope)));
        scopeLabel.append(scope);
        const selectValid = element("button", "sai-button sai-secondary", "Select all valid"); selectValid.type = "button"; selectValid.dataset.saiSelectValid = "";
        const clear = element("button", "sai-button sai-secondary", "Clear selection"); clear.type = "button"; clear.dataset.saiClearSelection = "";
        const run = element("button", "sai-button sai-primary", "Import scope"); run.type = "button"; run.dataset.saiRunScope = "";
        const summary = element("span", "sai-selection-summary"); summary.dataset.saiSelectionSummary = "";
        controls.append(scopeLabel, selectValid, clear, run, summary); container.append(controls);
      }
      const table = element("table", "sai-results-table");
      table.innerHTML = `<thead><tr>${preview ? "<th>Select</th>" : ""}<th>Row</th><th>Decision</th><th>Key</th><th>Source data</th><th>Proposed work</th><th>Result / issues</th><th>Action</th></tr></thead>`;
      const body = element("tbody", "");
      rows.forEach((row) => {
        const tr = element("tr", row.status === "failed" || row.decision === "error" ? "is-error" : "");
        const action = element("td", "");
        if (!row.status && (row.decision === "insert" || row.decision === "update")) {
          const button = element("button", "sai-button sai-row-action", "Import row");
          button.type = "button"; button.dataset.saiRunRow = row.row_number; action.append(button);
        } else action.textContent = "—";
        const errors = (row.errors || []).map((error) => {
          const label = error.field || (error.action ? `${error.action}${error.input ? `.${error.input}` : ""}` : "");
          return `${label ? `${label}: ` : ""}${error.message}`;
        }).join("; ");
        const actionResults = (row.action_results || []).map((result) => result.message).filter(Boolean).join("; ");
        const writeResult = json(row.result && row.result.values || row.target || {});
        const details = errors || [writeResult === "{}" ? "" : writeResult, actionResults].filter(Boolean).join(" — ") || "—";
        if (preview) {
          const choice = element("td", "");
          const allowed = row.decision === "insert" || row.decision === "update";
          const input = element("input", ""); input.type = "checkbox"; input.dataset.saiRowSelect = row.row_number; input.checked = this.selectedRows.has(row.row_number); input.disabled = !allowed;
          choice.append(input); tr.append(choice);
        }
        const proposed = {};
        if (row.assignments && Object.keys(row.assignments).length) proposed.assignments = row.assignments;
        if (row.actions && row.actions.length) proposed.actions = row.actions.map(({action: actionId, inputs}) => ({action: actionId, inputs}));
        tr.append(element("td", "", String(row.row_number)), element("td", "", row.status || row.decision), element("td", "", json(row.key || {})), element("td", "", json(row.source || {})), element("td", "", json(proposed)), element("td", "", details), action);
        body.append(tr);
      });
      table.append(body); container.append(table); this.updateSelectionSummary();
    }
    async saveProfile() {
      if (!this.upload) return this.message("Inspect a file before saving its mapping.", true);
      const name = global.prompt("Profile name"); if (!name) return;
      try {
        const payload = await this.fetchJSON(apiPath(this.base, "/import-profiles"), {method: "POST", headers: {"Content-Type": "application/json", Accept: "application/json"}, body: JSON.stringify({name, upload_id: this.upload.id, configuration: this.configuration()})});
        this.profiles.push(payload.profile); this.populateProfiles(); this.message(`Saved profile ${payload.profile.name}, revision ${payload.profile.revision}.`);
      } catch (error) { this.message(error.message || String(error), true); }
    }
  }

  function mountAll(documentRoot) { return Array.from((documentRoot || global.document).querySelectorAll("[data-selecto-importer]"), (root) => { const importer = new Importer(root); importer.start(); return importer; }); }
  global.SelectoImporter = {Importer, mountAll, targetGroupLabel};
  if (typeof module !== "undefined" && module.exports) module.exports = global.SelectoImporter;
  if (global.document && global.addEventListener) global.addEventListener("DOMContentLoaded", () => mountAll(global.document));
})(typeof globalThis !== "undefined" ? globalThis : this);
