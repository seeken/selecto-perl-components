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

  class Importer {
    constructor(root) {
      this.root = root;
      this.base = String(root.dataset.apiBase || "").replace(/\/+$/, "");
      this.curlAuth = root.dataset.curlAuth || "cookie";
      this.domain = null;
      this.upload = null;
      this.profiles = [];
      this.profile = null;
      this.mappings = new Map();
      this.extraFields = new Set();
    }

    async fetchJSON(path, options) {
      const response = await fetch(path, Object.assign({headers: {Accept: "application/json"}}, options || {}));
      const payload = await response.json().catch(() => ({}));
      if (!response.ok || payload.ok === false) throw new Error(payload.error && payload.error.message || `Request failed (${response.status})`);
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

    importerContract() { return this.domain && this.domain.extensions && this.domain.extensions.importer || null; }
    importFields() { return this.importerContract() && this.importerContract().fields || {}; }

    render() {
      const title = this.root.dataset.title || `${this.domain.name || "Selecto"} Importer`;
      this.root.innerHTML = `
        <header class="sai-header"><div><span class="sai-kicker">Selecto Importer</span><h1></h1><p>Map a file to governed writes, validate every row, then import deliberately.</p></div><a class="sai-back" href="${this.base}/console">API Console</a></header>
        <section class="sai-card"><h2>1. Upload or choose a profile</h2><div class="sai-inline"><label>Import profile<select data-sai-profile><option value="">New mapping</option></select></label><label>File<input type="file" accept=".csv,.tsv,text/csv,text/tab-separated-values" data-sai-file></label><button type="button" class="sai-button" data-sai-upload>Inspect file</button></div><p class="sai-message" data-sai-message></p></section>
        <section class="sai-card" data-sai-mapping-card hidden><h2>2. Map file data</h2><div data-sai-file-summary></div><p class="sai-hint">Each row below is a column in the uploaded file. Choose the governed field that should receive it.</p><div class="sai-mapping" data-sai-mappings></div><details class="sai-additional-values"><summary>Additional values not in the file</summary><p class="sai-hint">Use these for static values, run parameters, and trusted context such as the active client.</p><label class="sai-add-field">Add field<select data-sai-add-extra></select></label><div class="sai-mapping" data-sai-extra-mappings></div></details><label class="sai-label">Match existing records with<select data-sai-key-set></select></label><div class="sai-inline"><label>On existing<select data-sai-on-match></select></label><label>When missing<select data-sai-on-missing></select></label><label>Rows from<input type="number" min="1" value="1" data-sai-start></label><label>through<input type="number" min="1" data-sai-end></label></div><label class="sai-label">Configuration JSON<textarea spellcheck="false" data-sai-config></textarea></label><div class="sai-actions"><button type="button" class="sai-button sai-secondary" data-sai-copy>Copy JSON</button><button type="button" class="sai-button sai-secondary" data-sai-save-profile>Save profile</button><button type="button" class="sai-button" data-sai-preview>Validate & preview</button><button type="button" class="sai-button sai-primary" data-sai-run>Import valid rows</button></div></section>
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
        if (target.matches("[data-sai-save-profile]")) this.saveProfile();
        if (target.matches("[data-sai-copy]")) navigator.clipboard && navigator.clipboard.writeText(this.configJSON());
      });
      this.root.addEventListener("change", (event) => {
        if (event.target.matches("[data-sai-profile]")) this.chooseProfile(event.target.value);
        if (event.target.matches("[data-sai-column]")) this.columnChanged(event.target);
        if (event.target.matches("[data-sai-source]")) this.sourceChanged(event.target);
        if (event.target.matches("[data-sai-add-extra]")) this.addExtraField(event.target.value);
        if (event.target.matches("[data-sai-key-set]")) this.renderMatchChoices();
        if (event.target.matches("[data-sai-config]")) this.loadJSON(event.target.value);
      });
      this.root.addEventListener("input", (event) => {
        if (event.target.matches("[data-sai-static]")) this.mappings.get(event.target.dataset.saiStatic).value = event.target.value;
        if (event.target.matches("[data-sai-start],[data-sai-end]")) this.syncConfigEditor();
      });
    }

    message(text, error) {
      const node = this.root.querySelector("[data-sai-message]");
      node.textContent = text || "";
      node.classList.toggle("is-error", Boolean(error));
    }

    async uploadFile() {
      const file = this.root.querySelector("[data-sai-file]").files[0];
      if (!file) return this.message("Choose a CSV or TSV file first.", true);
      this.message("Inspecting file…");
      try {
        const form = new FormData();
        form.append("file", file);
        const response = await fetch(apiPath(this.base, "/imports/uploads"), {method: "POST", body: form, headers: {Accept: "application/json"}});
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
      this.extraFields.clear();
      const columns = this.upload.inspection.columns || [];
      Object.entries(this.importFields()).forEach(([field, spec]) => {
        const aliases = [field, ...(spec.header_aliases || [])].map(normalize);
        const column = columns.find((item) => aliases.includes(normalize(item.header)));
        if (column) this.mappings.set(field, {kind: "column", column_id: column.id});
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
      (inspection.columns || []).forEach((column) => {
        const row = element("div", "sai-mapping-row");
        const copy = element("div", "");
        copy.append(element("strong", "", column.label), element("code", "", column.header || `Column ${column.ordinal}`));
        const target = element("select", "");
        target.dataset.saiColumn = column.id;
        target.add(new Option("Do not send", "", false, !mappedColumns.has(column.id)));
        Object.entries(fields).sort(([a], [b]) => a.localeCompare(b)).forEach(([field, spec]) => {
          if (!(spec.sources || []).includes("column")) return;
          const option = new Option(`${this.fieldLabel(field)} (${field})`, field, false, mappedColumns.get(column.id) === field);
          const existing = this.mappings.get(field);
          option.disabled = Boolean(existing && existing.kind === "column" && existing.column_id !== column.id);
          target.add(option);
        });
        row.append(copy, target);
        body.append(row);
      });
      this.renderExtraMappings(fields);
      const key = this.root.querySelector("[data-sai-key-set]");
      key.replaceChildren();
      (this.importerContract().key_sets || []).forEach((set) => key.add(new Option(set.label || set.id, set.id)));
      this.renderMatchChoices();
      this.syncConfigEditor();
    }

    sourceChanged(node) {
      const value = node.value;
      const field = node.dataset.saiSource;
      if (value.startsWith("column:")) this.mappings.set(field, {kind: "column", column_id: value.slice(7)});
      else this.mappings.set(field, {kind: value, value: ""});
      this.renderMapping();
    }

    fieldLabel(field) { return (this.domain.source.columns[field] || {}).label || field; }

    columnChanged(node) {
      const columnId = node.dataset.saiColumn;
      this.mappings.forEach((mapping, field) => {
        if (mapping.kind === "column" && mapping.column_id === columnId) this.mappings.set(field, {kind: "omit", value: ""});
      });
      if (node.value) {
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
      Object.entries(fields).sort(([a], [b]) => a.localeCompare(b)).forEach(([field, spec]) => {
        if ((spec.sources || []).some((source) => source !== "column")) add.add(new Option(`${this.fieldLabel(field)} (${field})`, field));
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
          const input = element("input", ""); input.value = mapping.value || mapping.name || ""; input.placeholder = mapping.kind === "parameter" ? "Parameter name" : "Value"; input.dataset.saiStatic = field; row.append(input);
        }
        body.append(row);
      });
    }

    addExtraField(field) {
      if (!field) return;
      const spec = this.importFields()[field];
      const kind = (spec.sources || []).find((source) => source !== "column") || "omit";
      this.mappings.set(field, {kind, value: ""});
      this.extraFields.add(field);
      this.renderMapping();
    }

    selectedKeySet() { return (this.importerContract().key_sets || []).find((set) => set.id === this.root.querySelector("[data-sai-key-set]").value); }
    renderMatchChoices() {
      const set = this.selectedKeySet(); if (!set) return;
      const fill = (selector, values, selected) => {
        const select = this.root.querySelector(selector); select.replaceChildren();
        values.forEach((value) => select.add(new Option(value, value, false, value === selected)));
      };
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
      const end = Number(this.root.querySelector("[data-sai-end]").value || 0);
      return {
        config_version: 1, domain_fingerprint: this.domain.domain_fingerprint,
        upload_id: this.upload && this.upload.id, mappings,
        rows: {start: Number(this.root.querySelector("[data-sai-start]").value || 1), ...(end ? {end} : {})},
        match: {key_set: this.root.querySelector("[data-sai-key-set]").value, on_match: this.root.querySelector("[data-sai-on-match]").value, on_missing: this.root.querySelector("[data-sai-on-missing]").value},
        errors: {mode: "continue"}, idempotency: {mode: "source_row", on_duplicate: "skip"},
      };
    }
    configJSON() { return json(this.configuration()); }
    syncConfigEditor() { const node = this.root.querySelector("[data-sai-config]"); if (node) node.value = this.configJSON(); }
    loadJSON(value) {
      try {
        const config = JSON.parse(value); if (!config || !Array.isArray(config.mappings)) throw new Error("Configuration needs mappings.");
        this.mappings.clear(); this.extraFields.clear();
        config.mappings.forEach((mapping) => {
          const source = Object.assign({value: ""}, mapping.source);
          this.mappings.set(mapping.target, source);
          if (source.kind !== "column") this.extraFields.add(mapping.target);
        });
        this.renderMapping(); this.message("Configuration loaded.");
      } catch (error) { this.message(`Configuration could not be loaded: ${error.message}`, true); }
    }
    requestBody() {
      const profileId = this.root.querySelector("[data-sai-profile]").value;
      return profileId ? {upload_id: this.upload.id, profile_id: profileId} : {upload_id: this.upload.id, configuration: this.configuration()};
    }
    async chooseProfile(id) {
      this.profile = this.profiles.find((profile) => profile.id === id) || null;
      if (this.upload && this.profile) {
        this.message(`Profile ${this.profile.name} will be checked against this file when you preview.`);
      }
    }
    async preview() { return this.execute("/imports/preview", "Previewing rows…"); }
    async run() { return this.execute("/imports/runs", "Importing rows…", {mode: "run"}); }
    async execute(path, message, extra) {
      if (!this.upload) return this.message("Inspect a file first.", true);
      this.message(message);
      try {
        const payload = await this.fetchJSON(apiPath(this.base, path), {method: "POST", headers: {"Content-Type": "application/json", Accept: "application/json"}, body: JSON.stringify(Object.assign(this.requestBody(), extra || {}))});
        const rows = payload.rows || payload.run && payload.run.rows || [];
        this.renderResults(rows, payload.run && payload.run.status || "previewed");
        this.message(`Completed ${rows.length} staged rows.`);
      } catch (error) { this.message(error.message || String(error), true); }
    }
    renderResults(rows, status) {
      this.root.querySelector("[data-sai-results-card]").hidden = false;
      const container = this.root.querySelector("[data-sai-results]"); container.replaceChildren(element("p", "", `Run status: ${status}`));
      const table = element("table", "sai-results-table");
      table.innerHTML = "<thead><tr><th>Row</th><th>Decision</th><th>Key</th><th>Details</th></tr></thead>";
      const body = element("tbody", "");
      rows.forEach((row) => { const tr = element("tr", row.status === "failed" || row.decision === "error" ? "is-error" : ""); tr.append(element("td", "", String(row.row_number)), element("td", "", row.status || row.decision), element("td", "", json(row.key || {})), element("td", "", (row.errors || []).map((error) => `${error.field ? `${error.field}: ` : ""}${error.message}`).join("; ") || json(row.result && row.result.values || row.target || {}))); body.append(tr); });
      table.append(body); container.append(table);
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
  global.SelectoImporter = {Importer, mountAll};
  if (typeof module !== "undefined" && module.exports) module.exports = global.SelectoImporter;
  if (global.document && global.addEventListener) global.addEventListener("DOMContentLoaded", () => mountAll(global.document));
})(typeof globalThis !== "undefined" ? globalThis : this);
