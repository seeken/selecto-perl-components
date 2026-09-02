(function (global) {
  "use strict";

  const MAX_RELATION_DEPTH = 4;
  const TEMPORAL_TYPES = new Set(["date", "datetime", "naive_datetime", "utc_datetime", "epoch_datetime"]);
  const NUMERIC_TYPES = new Set(["integer", "decimal", "float", "number"]);

  function normalizeAPIBase(value, fallback) {
    const candidate = String(value || fallback || "/api/v1/selecto").replace(/\/+$/, "");
    const invalidSegment = candidate.split("/").some((segment) => {
      try {
        const decoded = decodeURIComponent(segment);
        return decoded === "." || decoded === "..";
      } catch (_error) {
        return true;
      }
    });
    if (!/^\/[A-Za-z0-9._~!$&'()*+,;=:@%/-]+$/.test(candidate) || candidate.includes("//") || invalidSegment) {
      throw new Error("The API console requires an absolute same-origin API path.");
    }
    return candidate;
  }

  function standaloneOption(name) {
    if (typeof global.location === "undefined") return "";
    return new URLSearchParams(global.location.search || "").get(name) || "";
  }

  async function discoverCanonicalAPI(base, fetchJSON) {
    const normalizedBase = normalizeAPIBase(base);
    const manifest = await fetchJSON(`${normalizedBase}/`);
    const routes = Array.isArray(manifest.routes) ? manifest.routes : [];
    const route = (operation, fallback) => {
      const match = routes.find((item) => item && item.operation_id === operation && String(item.path || "").startsWith("/"));
      if (!match) return fallback;
      try {
        return normalizeAPIBase(match.path);
      } catch (_error) {
        return fallback;
      }
    };
    const domainPath = route("getDomain", `${normalizedBase}/domain`);
    const openapiPath = route("getOpenApi", `${normalizedBase}/openapi.json`);
    const queryPath = route("queryDomain", `${normalizedBase}/query`);
    const [domain, openapi] = await Promise.all([fetchJSON(domainPath), fetchJSON(openapiPath)]);
    return {base: normalizedBase, manifest, domain, openapi, queryPath};
  }

  function humanize(value) {
    return String(value || "")
      .replace(/\./g, " · ")
      .replace(/_/g, " ")
      .replace(/\b\w/g, (letter) => letter.toUpperCase());
  }

  function compareSemanticFields(left, right) {
    const options = {numeric: true, sensitivity: "base"};
    const labelOrder = String(left.label || "").localeCompare(String(right.label || ""), undefined, options);
    return labelOrder || String(left.path || "").localeCompare(String(right.path || ""), undefined, options);
  }

  function relationFields(relation, schemas, prefix, depth, schemaStack, output) {
    if (!relation || depth > MAX_RELATION_DEPTH) return;
    const columns = relation.columns || {};
    const declared = Array.isArray(relation.fields) ? relation.fields : Object.keys(columns);
    declared.slice().sort().forEach((name) => {
      const column = columns[name] || {};
      if (column.internal) return;
      const path = prefix ? `${prefix}.${name}` : name;
      output.push({
        path,
        name,
        label: column.label || humanize(name),
        type: String(column.type || "string").toLowerCase(),
        relation: prefix || "Root",
      });
    });

    const associations = relation.associations || {};
    Object.keys(associations).sort().forEach((name) => {
      const association = associations[name] || {};
      const queryable = association.queryable;
      const schema = queryable && schemas[queryable];
      if (!schema || schemaStack.includes(queryable)) return;
      relationFields(
        schema,
        schemas,
        prefix ? `${prefix}.${name}` : name,
        depth + 1,
        schemaStack.concat(queryable),
        output
      );
    });
  }

  function collectFields(domain) {
    const output = [];
    relationFields(domain && domain.source, (domain && domain.schemas) || {}, "", 0, [], output);
    return output.sort(compareSemanticFields);
  }

  function operatorsForType(type) {
    const common = ["eq", "ne", "in", "is_null", "not_null"];
    if (TEMPORAL_TYPES.has(type) || NUMERIC_TYPES.has(type)) {
      return ["eq", "ne", "gt", "gte", "lt", "lte", "between", "in", "is_null", "not_null"];
    }
    if (type === "boolean") return ["eq", "ne", "is_null", "not_null"];
    return common;
  }

  function optionLabel(operator) {
    return ({
      eq: "equals",
      ne: "does not equal",
      gt: "greater than / after",
      gte: "at least / on or after",
      lt: "less than / before",
      lte: "at most / on or before",
      between: "between",
      in: "one of",
      is_null: "is empty",
      not_null: "is not empty",
    })[operator] || operator;
  }

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function appendOptions(select, values, selected, placeholder) {
    select.replaceChildren();
    if (placeholder !== undefined) select.add(new Option(placeholder, ""));
    values.forEach((item) => {
      const value = typeof item === "string" ? item : item.value;
      const label = typeof item === "string" ? item : item.label;
      select.add(new Option(label, value, false, value === selected));
    });
  }

  function shellEscape(value) {
    return `'${String(value).replace(/'/g, `'"'"'`)}'`;
  }

  function renderValue(value) {
    if (value === null || value === undefined) return "NULL";
    if (typeof value === "object") return JSON.stringify(value);
    return String(value);
  }

  function segmentParameterSpecs(library, ids) {
    const segments = (library && library.segments) || {};
    const specs = {};
    const visited = new Set();
    function visit(id) {
      if (!id || visited.has(id)) return;
      visited.add(id);
      const segment = segments[id];
      if (!segment) return;
      Object.entries(segment.parameters || {}).forEach(([name, spec]) => {
        specs[name] = spec || {};
      });
      (segment.segments || []).forEach(visit);
      (segment.segment_groups || []).forEach((group) => (group.segments || []).forEach(visit));
    }
    ids.forEach(visit);
    return specs;
  }

  class APIConsole {
    constructor(root) {
      this.root = root;
      this.base = root.dataset.apiBase || standaloneOption("api");
      this.title = root.dataset.title || standaloneOption("title") || "Selecto API Console";
      this.domain = null;
      this.manifest = null;
      this.openapi = null;
      this.queryPath = `${this.base}/query`;
      this.fields = [];
      this.fieldMap = new Map();
      this.state = {
        mode: "select",
        selectedFields: [],
        projection: "",
        view: "",
        segments: [],
        parameters: {},
        filters: [],
        orders: [],
        ordering: "",
        limit: 100,
        offset: 0,
        rawDirty: false,
        response: null,
      };
      this.nextFilterId = 1;
      this.nextOrderId = 1;
    }

    async start() {
      try {
        const discovery = await discoverCanonicalAPI(this.base, (path) => this.fetchJSON(path));
        this.base = discovery.base;
        this.manifest = discovery.manifest;
        this.domain = discovery.domain;
        this.openapi = discovery.openapi;
        this.queryPath = discovery.queryPath;
        this.fields = collectFields(discovery.domain);
        this.fieldMap = new Map(this.fields.map((field) => [field.path, field]));
        this.seedState();
        this.render();
      } catch (error) {
        this.renderFatal(error);
      }
    }

    async fetchJSON(url, options) {
      const response = await fetch(url, Object.assign({credentials: "same-origin"}, options || {}));
      const text = await response.text();
      let payload;
      try {
        payload = text ? JSON.parse(text) : null;
      } catch (_error) {
        throw new Error(`${response.status} ${response.statusText}: the server did not return JSON.`);
      }
      if (!response.ok) {
        const message = payload && payload.error && payload.error.message;
        throw new Error(message || `${response.status} ${response.statusText}`);
      }
      return payload;
    }

    seedState() {
      const defaults = Array.isArray(this.domain.default_selected) ? this.domain.default_selected : [];
      const publicDefaults = defaults.filter((field) => this.fieldMap.has(field));
      if (publicDefaults.length) {
        this.state.selectedFields = publicDefaults.slice(0, 12);
        return;
      }
      const primaryKey = this.domain.source && this.domain.source.primary_key;
      const rootFields = this.fields.filter((field) => field.relation === "Root");
      const initial = [];
      if (primaryKey && this.fieldMap.has(primaryKey)) initial.push(primaryKey);
      rootFields.forEach((field) => {
        if (initial.length < 5 && !initial.includes(field.path)) initial.push(field.path);
      });
      this.state.selectedFields = initial;
    }

    render() {
      this.root.innerHTML = `
        <header class="sac-header">
          <div class="sac-brand">
            <span class="sac-kicker">Selecto API</span>
            <h1 data-sac-title></h1>
            <div class="sac-domain-meta"><span data-sac-domain-name></span><code data-sac-base></code></div>
          </div>
          <div class="sac-header-actions">
            <span class="sac-live"><i></i>Authenticated</span>
            <a class="sac-button sac-secondary" data-sac-domain-link>Domain JSON</a>
            <a class="sac-button sac-secondary" data-sac-openapi-link>OpenAPI</a>
          </div>
        </header>
        <nav class="sac-tabs" aria-label="API console sections">
          <button type="button" class="is-active" data-sac-main-tab="query">Query</button>
          <button type="button" data-sac-main-tab="domain">Domain</button>
          <button type="button" data-sac-main-tab="openapi">OpenAPI</button>
        </nav>
        <section data-sac-main-panel="query" class="sac-main-panel">
          <div class="sac-query-layout">
            <aside class="sac-builder">
              <section class="sac-card">
                <div class="sac-card-heading"><div><span class="sac-step">1</span><h2>Choose data</h2></div></div>
                <label class="sac-label" for="sac-source-mode">Query source</label>
                <select id="sac-source-mode" data-sac-mode>
                  <option value="select">Choose fields</option>
                  <option value="projection">Named projection</option>
                  <option value="view">Named view</option>
                </select>
                <div data-sac-select-mode>
                  <div class="sac-selected-fields" data-sac-selected-fields></div>
                  <label class="sac-label" for="sac-field-search">Available fields</label>
                  <input id="sac-field-search" type="search" placeholder="Search domain fields" data-sac-field-search>
                  <div class="sac-field-list" data-sac-field-list></div>
                </div>
                <div data-sac-projection-mode hidden>
                  <label class="sac-label" for="sac-projection">Projection</label>
                  <select id="sac-projection" data-sac-projection></select>
                </div>
                <div data-sac-view-mode hidden>
                  <label class="sac-label" for="sac-view">View</label>
                  <select id="sac-view" data-sac-view></select>
                  <p class="sac-help" data-sac-view-help></p>
                </div>
              </section>
              <section class="sac-card">
                <div class="sac-card-heading"><div><span class="sac-step">2</span><h2>Constrain</h2></div><button type="button" class="sac-text-button" data-sac-add-filter>+ Filter</button></div>
                <label class="sac-label" for="sac-segments">Named segments</label>
                <select id="sac-segments" multiple size="4" data-sac-segments></select>
                <p class="sac-help">Use Ctrl/⌘ to choose more than one reusable segment.</p>
                <div class="sac-parameters" data-sac-parameters></div>
                <div class="sac-filter-list" data-sac-filters></div>
              </section>
              <section class="sac-card">
                <div class="sac-card-heading"><div><span class="sac-step">3</span><h2>Order & page</h2></div><button type="button" class="sac-text-button" data-sac-add-order>+ Sort</button></div>
                <label class="sac-label" for="sac-ordering">Named ordering</label>
                <select id="sac-ordering" data-sac-ordering></select>
                <div class="sac-order-list" data-sac-orders></div>
                <div class="sac-inline-controls">
                  <label>Limit<input type="number" min="0" max="1000" data-sac-limit></label>
                  <label>Offset<input type="number" min="0" data-sac-offset></label>
                </div>
              </section>
            </aside>
            <section class="sac-execution">
              <section class="sac-request-card">
                <div class="sac-card-heading">
                  <div><span class="sac-method">POST</span><code data-sac-query-path></code></div>
                  <div class="sac-compact-actions"><span class="sac-edited" data-sac-edited hidden>Manually edited</span><button type="button" class="sac-text-button" data-sac-reset-json>Reset JSON</button><button type="button" class="sac-text-button" data-sac-copy-request>Copy</button></div>
                </div>
                <textarea class="sac-request-editor" spellcheck="false" aria-label="Query request JSON" data-sac-request></textarea>
                <div class="sac-run-row"><p>All fields and identifiers are validated against the published domain.</p><button type="button" class="sac-button sac-primary" data-sac-run><span data-sac-run-label>Run query</span></button></div>
              </section>
              <section class="sac-response-card">
                <div class="sac-response-heading">
                  <div><h2>Response</h2><span class="sac-response-status" data-sac-response-status>Ready</span></div>
                  <div class="sac-result-tabs" role="tablist">
                    <button type="button" class="is-active" data-sac-result-tab="table">Table</button>
                    <button type="button" data-sac-result-tab="json">JSON</button>
                    <button type="button" data-sac-result-tab="curl">cURL</button>
                  </div>
                </div>
                <div class="sac-empty-response" data-sac-empty-response><strong>Build a query, then run it.</strong><span>The result table and canonical JSON response will appear here.</span></div>
                <div class="sac-result-panel" data-sac-result-panel="table" hidden><div class="sac-table-wrap"><table><thead data-sac-result-head></thead><tbody data-sac-result-body></tbody></table></div></div>
                <div class="sac-result-panel" data-sac-result-panel="json" hidden><div class="sac-code-heading"><span>Canonical response</span><button type="button" class="sac-text-button" data-sac-copy-response>Copy</button></div><pre data-sac-response-json></pre></div>
                <div class="sac-result-panel" data-sac-result-panel="curl" hidden><div class="sac-code-heading"><span>Command line</span><button type="button" class="sac-text-button" data-sac-copy-curl>Copy</button></div><pre data-sac-curl></pre><p class="sac-help">The browser uses your current authenticated session. Supply the corresponding session cookie when running cURL separately.</p></div>
              </section>
            </section>
          </div>
        </section>
        <section data-sac-main-panel="domain" class="sac-document-panel" hidden><div class="sac-document-heading"><div><span class="sac-kicker">Discovery</span><h2>Canonical domain</h2></div><button type="button" class="sac-button sac-secondary" data-sac-copy-domain>Copy JSON</button></div><pre data-sac-domain-json></pre></section>
        <section data-sac-main-panel="openapi" class="sac-document-panel" hidden><div class="sac-document-heading"><div><span class="sac-kicker">Discovery</span><h2>OpenAPI 3.1</h2></div><button type="button" class="sac-button sac-secondary" data-sac-copy-openapi>Copy JSON</button></div><pre data-sac-openapi-json></pre></section>`;

      this.refs = {};
      this.root.querySelectorAll("[data-sac-title]").forEach((node) => (node.textContent = this.title));
      this.root.querySelector("[data-sac-domain-name]").textContent = this.domain.name || "Domain";
      this.root.querySelector("[data-sac-base]").textContent = this.base;
      this.root.querySelector("[data-sac-query-path]").textContent = this.queryPath;
      this.root.querySelector("[data-sac-domain-link]").href = `${this.base}/domain`;
      this.root.querySelector("[data-sac-openapi-link]").href = `${this.base}/openapi.json`;
      this.root.querySelector("[data-sac-domain-json]").textContent = JSON.stringify(this.domain, null, 2);
      this.root.querySelector("[data-sac-openapi-json]").textContent = JSON.stringify(this.openapi, null, 2);
      this.bind();
      this.populateLibraryControls();
      this.renderAll();
    }

    bind() {
      this.root.addEventListener("click", (event) => this.onClick(event));
      this.root.addEventListener("change", (event) => this.onChange(event));
      this.root.addEventListener("input", (event) => this.onInput(event));
    }

    populateLibraryControls() {
      const library = this.domain.query_library || {};
      const definitions = (kind) => Object.entries(library[kind] || {}).map(([id, spec]) => ({
        value: id,
        label: (spec && spec.label) || humanize(id),
      }));
      appendOptions(this.root.querySelector("[data-sac-projection]"), definitions("projections"), "", "Choose a projection");
      appendOptions(this.root.querySelector("[data-sac-view]"), definitions("views"), "", "Choose a view");
      appendOptions(this.root.querySelector("[data-sac-ordering]"), definitions("orderings"), "", "Custom ordering");
      appendOptions(this.root.querySelector("[data-sac-segments]"), definitions("segments"), "");
    }

    renderAll() {
      const mode = this.state.mode;
      this.root.querySelector("[data-sac-mode]").value = mode;
      this.root.querySelector("[data-sac-select-mode]").hidden = mode !== "select";
      this.root.querySelector("[data-sac-projection-mode]").hidden = mode !== "projection";
      this.root.querySelector("[data-sac-view-mode]").hidden = mode !== "view";
      this.root.querySelector("[data-sac-projection]").value = this.state.projection;
      this.root.querySelector("[data-sac-view]").value = this.state.view;
      this.root.querySelector("[data-sac-ordering]").value = this.state.ordering;
      this.root.querySelector("[data-sac-limit]").value = this.state.limit;
      this.root.querySelector("[data-sac-offset]").value = this.state.offset;
      Array.from(this.root.querySelector("[data-sac-segments]").options).forEach((option) => {
        option.selected = this.state.segments.includes(option.value);
      });
      this.renderSelectedFields();
      this.renderFieldList();
      this.renderViewHelp();
      this.renderParameters();
      this.renderFilters();
      this.renderOrders();
      this.syncRequest();
    }

    renderSelectedFields() {
      const container = this.root.querySelector("[data-sac-selected-fields]");
      container.replaceChildren();
      if (!this.state.selectedFields.length) {
        container.append(element("p", "sac-muted", "Choose at least one field."));
        return;
      }
      this.state.selectedFields.forEach((path, index) => {
        const field = this.fieldMap.get(path) || {label: path, type: "field"};
        const row = element("div", "sac-selected-field");
        row.dataset.field = path;
        const handle = element("span", "sac-drag", "⋮⋮");
        handle.setAttribute("aria-hidden", "true");
        const copy = element("div", "sac-selected-copy");
        copy.append(element("strong", "", field.label), element("code", "", path));
        const actions = element("div", "sac-field-actions");
        [["up", "↑", "Move up"], ["down", "↓", "Move down"], ["remove", "×", "Remove"]].forEach(([action, text, label]) => {
          const button = element("button", "", text);
          button.type = "button";
          button.dataset.sacFieldAction = action;
          button.setAttribute("aria-label", `${label} ${field.label}`);
          if ((action === "up" && index === 0) || (action === "down" && index === this.state.selectedFields.length - 1)) button.disabled = true;
          actions.append(button);
        });
        row.append(handle, copy, actions);
        container.append(row);
      });
    }

    renderFieldList() {
      const query = (this.root.querySelector("[data-sac-field-search]").value || "").trim().toLowerCase();
      const selected = new Set(this.state.selectedFields);
      const container = this.root.querySelector("[data-sac-field-list]");
      container.replaceChildren();
      const matches = this.fields.filter((field) => !selected.has(field.path) && (!query || `${field.path} ${field.label} ${field.type}`.toLowerCase().includes(query)));
      matches.slice(0, 150).forEach((field) => {
        const button = element("button", "sac-available-field");
        button.type = "button";
        button.dataset.sacAddField = field.path;
        const copy = element("span", "");
        copy.append(element("strong", "", field.label), element("code", "", field.path));
        button.append(copy, element("small", "", field.type), element("b", "", "+"));
        container.append(button);
      });
      if (!matches.length) container.append(element("p", "sac-muted", "No matching available fields."));
    }

    renderViewHelp() {
      const help = this.root.querySelector("[data-sac-view-help]");
      const view = ((this.domain.query_library || {}).views || {})[this.state.view];
      if (!view) {
        help.textContent = "A view supplies its projection, segments, and default ordering.";
        return;
      }
      const parts = [];
      if (view.projection) parts.push(`Projection: ${view.projection}`);
      if ((view.segments || []).length) parts.push(`Segments: ${view.segments.join(", ")}`);
      if (view.ordering) parts.push(`Ordering: ${view.ordering}`);
      help.textContent = parts.join(" · ") || "This view has no additional metadata.";
    }

    activeParameterSpecs() {
      const library = this.domain.query_library || {};
      const ids = this.state.segments.slice();
      if (this.state.mode === "view" && this.state.view) {
        const view = (library.views || {})[this.state.view] || {};
        ids.push(...(view.segments || []));
      }
      return segmentParameterSpecs(library, ids);
    }

    renderParameters() {
      const container = this.root.querySelector("[data-sac-parameters]");
      container.replaceChildren();
      const specs = this.activeParameterSpecs();
      Object.entries(specs).forEach(([name, spec]) => {
        const label = element("label", "sac-parameter");
        const text = element("span", "", (spec.label || humanize(name)) + (spec.required ? " *" : ""));
        const input = element("input", "");
        input.dataset.sacParameter = name;
        input.value = this.state.parameters[name] !== undefined
          ? this.state.parameters[name]
          : (spec.default !== undefined ? spec.default : "");
        input.placeholder = spec.type || "value";
        label.append(text, input);
        container.append(label);
      });
    }

    renderFilters() {
      const container = this.root.querySelector("[data-sac-filters]");
      container.replaceChildren();
      this.state.filters.forEach((filter) => {
        const field = this.fieldMap.get(filter.field) || this.fields[0];
        if (!field) return;
        const row = element("div", "sac-filter-row");
        row.dataset.filterId = filter.id;
        const fieldSelect = element("select", "");
        fieldSelect.dataset.sacFilterField = "";
        appendOptions(fieldSelect, this.fields.map((item) => ({value: item.path, label: `${item.label} — ${item.path}`})), field.path);
        const operator = element("select", "");
        operator.dataset.sacFilterOp = "";
        appendOptions(operator, operatorsForType(field.type).map((op) => ({value: op, label: optionLabel(op)})), filter.op);
        row.append(fieldSelect, operator);
        if (!/^(is_null|not_null)$/.test(filter.op)) {
          row.append(this.filterValueControl(filter, field, false));
          if (filter.op === "between") row.append(this.filterValueControl(filter, field, true));
        }
        const remove = element("button", "sac-icon-button", "×");
        remove.type = "button";
        remove.dataset.sacRemoveFilter = filter.id;
        remove.setAttribute("aria-label", "Remove filter");
        row.append(remove);
        container.append(row);
      });
      if (!this.state.filters.length) container.append(element("p", "sac-muted", "No ad hoc filters."));
    }

    filterValueControl(filter, field, end) {
      let input;
      if (field.type === "boolean" && filter.op !== "in") {
        input = element("select", "");
        appendOptions(input, [{value: "true", label: "True"}, {value: "false", label: "False"}], end ? filter.end : filter.value);
      } else {
        input = element("input", "");
        if (TEMPORAL_TYPES.has(field.type)) input.type = field.type === "date" ? "date" : "datetime-local";
        else if (NUMERIC_TYPES.has(field.type) && filter.op !== "in") {
          input.type = "number";
          input.step = "any";
        }
        else input.type = "text";
        input.value = end ? filter.end : filter.value;
        input.placeholder = filter.op === "in" ? "comma-separated values" : (end ? "End" : "Value");
      }
      input.dataset[end ? "sacFilterEnd" : "sacFilterValue"] = "";
      input.setAttribute("aria-label", end ? "Filter end value" : "Filter value");
      return input;
    }

    renderOrders() {
      const container = this.root.querySelector("[data-sac-orders]");
      container.replaceChildren();
      const named = Boolean(this.state.ordering);
      this.state.orders.forEach((order) => {
        const row = element("div", "sac-order-row");
        row.dataset.orderId = order.id;
        const field = element("select", "");
        field.dataset.sacOrderField = "";
        field.disabled = named;
        appendOptions(field, this.fields.map((item) => ({value: item.path, label: `${item.label} — ${item.path}`})), order.field);
        const direction = element("select", "");
        direction.dataset.sacOrderDirection = "";
        direction.disabled = named;
        appendOptions(direction, [{value: "asc", label: "Ascending"}, {value: "desc", label: "Descending"}], order.direction);
        const remove = element("button", "sac-icon-button", "×");
        remove.type = "button";
        remove.disabled = named;
        remove.dataset.sacRemoveOrder = order.id;
        remove.setAttribute("aria-label", "Remove sorting");
        row.append(field, direction, remove);
        container.append(row);
      });
      if (named) container.append(element("p", "sac-help", "The named ordering replaces custom sort fields."));
      else if (!this.state.orders.length) container.append(element("p", "sac-muted", "No explicit ordering."));
    }

    filterPayload(filter) {
      const field = this.fieldMap.get(filter.field);
      const payload = {field: filter.field, op: filter.op};
      if (/^(is_null|not_null)$/.test(filter.op)) return payload;
      if (filter.op === "in") {
        payload.value = String(filter.value).split(",").map((value) => value.trim()).filter(Boolean);
      } else if (field && field.type === "boolean") {
        payload.value = String(filter.value) === "true";
      } else {
        payload.value = filter.value;
      }
      if (filter.op === "between") payload.end = filter.end;
      return payload;
    }

    buildPayload() {
      const payload = {};
      if (this.state.mode === "select") payload.select = this.state.selectedFields.slice();
      if (this.state.mode === "projection") payload.projection = this.state.projection;
      if (this.state.mode === "view") payload.view = this.state.view;
      if (this.state.segments.length) payload.segments = this.state.segments.slice();
      const specs = this.activeParameterSpecs();
      const parameters = {};
      Object.keys(specs).forEach((name) => {
        const value = this.state.parameters[name];
        if (value !== undefined && value !== "") parameters[name] = value;
      });
      if (Object.keys(parameters).length) payload.parameters = parameters;
      if (this.state.filters.length) payload.filters = this.state.filters.map((filter) => this.filterPayload(filter));
      if (this.state.ordering) payload.ordering = this.state.ordering;
      else if (this.state.orders.length) payload.order_by = this.state.orders.map((order) => ({field: order.field, direction: order.direction}));
      payload.limit = Number.parseInt(this.state.limit, 10) || 0;
      payload.offset = Number.parseInt(this.state.offset, 10) || 0;
      return payload;
    }

    syncRequest(force) {
      if (this.state.rawDirty && !force) return;
      this.root.querySelector("[data-sac-request]").value = JSON.stringify(this.buildPayload(), null, 2);
      this.state.rawDirty = false;
      this.root.querySelector("[data-sac-edited]").hidden = true;
      this.updateCurl();
    }

    updateCurl() {
      const editor = this.root.querySelector("[data-sac-request]");
      const body = editor ? editor.value : JSON.stringify(this.buildPayload(), null, 2);
      const url = `${window.location.origin}${this.queryPath}`;
      const command = `curl -X POST ${shellEscape(url)} \\\n  -H 'Content-Type: application/json' \\\n  -H 'Accept: application/json' \\\n  --cookie 'YOUR_SESSION_COOKIE' \\\n  --data-binary ${shellEscape(body)}`;
      const target = this.root.querySelector("[data-sac-curl]");
      if (target) target.textContent = command;
    }

    onClick(event) {
      const mainTab = event.target.closest("[data-sac-main-tab]");
      if (mainTab) return this.switchMainTab(mainTab.dataset.sacMainTab);
      const resultTab = event.target.closest("[data-sac-result-tab]");
      if (resultTab) return this.switchResultTab(resultTab.dataset.sacResultTab);
      const addField = event.target.closest("[data-sac-add-field]");
      if (addField) {
        this.state.selectedFields.push(addField.dataset.sacAddField);
        this.changed();
        return;
      }
      const fieldAction = event.target.closest("[data-sac-field-action]");
      if (fieldAction) return this.moveField(fieldAction.closest("[data-field]").dataset.field, fieldAction.dataset.sacFieldAction);
      if (event.target.closest("[data-sac-add-filter]")) {
        if (!this.fields.length) return;
        const initialField = this.fields[0];
        this.state.filters.push({
          id: String(this.nextFilterId++),
          field: initialField.path,
          op: "eq",
          value: initialField.type === "boolean" ? "true" : "",
          end: "",
        });
        this.changed();
        return;
      }
      const removeFilter = event.target.closest("[data-sac-remove-filter]");
      if (removeFilter) {
        this.state.filters = this.state.filters.filter((filter) => filter.id !== removeFilter.dataset.sacRemoveFilter);
        this.changed();
        return;
      }
      if (event.target.closest("[data-sac-add-order]")) {
        if (!this.fields.length || this.state.ordering) return;
        this.state.orders.push({id: String(this.nextOrderId++), field: this.fields[0].path, direction: "asc"});
        this.changed();
        return;
      }
      const removeOrder = event.target.closest("[data-sac-remove-order]");
      if (removeOrder) {
        this.state.orders = this.state.orders.filter((order) => order.id !== removeOrder.dataset.sacRemoveOrder);
        this.changed();
        return;
      }
      if (event.target.closest("[data-sac-reset-json]")) return this.syncRequest(true);
      if (event.target.closest("[data-sac-run]")) return this.run();
      if (event.target.closest("[data-sac-copy-request]")) return this.copy(this.root.querySelector("[data-sac-request]").value, event.target);
      if (event.target.closest("[data-sac-copy-response]")) return this.copy(this.root.querySelector("[data-sac-response-json]").textContent, event.target);
      if (event.target.closest("[data-sac-copy-curl]")) return this.copy(this.root.querySelector("[data-sac-curl]").textContent, event.target);
      if (event.target.closest("[data-sac-copy-domain]")) return this.copy(JSON.stringify(this.domain, null, 2), event.target);
      if (event.target.closest("[data-sac-copy-openapi]")) return this.copy(JSON.stringify(this.openapi, null, 2), event.target);
    }

    onChange(event) {
      const target = event.target;
      if (target.matches("[data-sac-mode]")) this.state.mode = target.value;
      else if (target.matches("[data-sac-projection]")) this.state.projection = target.value;
      else if (target.matches("[data-sac-view]")) this.state.view = target.value;
      else if (target.matches("[data-sac-segments]")) this.state.segments = Array.from(target.selectedOptions).map((option) => option.value);
      else if (target.matches("[data-sac-ordering]")) this.state.ordering = target.value;
      else if (target.matches("[data-sac-filter-field]")) {
        const filter = this.filterFor(target);
        filter.field = target.value;
        filter.op = "eq";
        filter.value = (this.fieldMap.get(target.value) || {}).type === "boolean" ? "true" : "";
        filter.end = "";
      } else if (target.matches("[data-sac-filter-op]")) {
        this.filterFor(target).op = target.value;
      } else if (target.matches("[data-sac-order-field]")) this.orderFor(target).field = target.value;
      else if (target.matches("[data-sac-order-direction]")) this.orderFor(target).direction = target.value;
      else return;
      this.changed();
    }

    onInput(event) {
      const target = event.target;
      if (target.matches("[data-sac-field-search]")) return this.renderFieldList();
      if (target.matches("[data-sac-request]")) {
        this.state.rawDirty = true;
        this.root.querySelector("[data-sac-edited]").hidden = false;
        this.updateCurl();
        return;
      }
      if (target.matches("[data-sac-parameter]")) this.state.parameters[target.dataset.sacParameter] = target.value;
      else if (target.matches("[data-sac-filter-value]")) this.filterFor(target).value = target.value;
      else if (target.matches("[data-sac-filter-end]")) this.filterFor(target).end = target.value;
      else if (target.matches("[data-sac-limit]")) this.state.limit = target.value;
      else if (target.matches("[data-sac-offset]")) this.state.offset = target.value;
      else return;
      this.syncRequest(true);
    }

    filterFor(target) {
      const id = target.closest("[data-filter-id]").dataset.filterId;
      return this.state.filters.find((filter) => filter.id === id);
    }

    orderFor(target) {
      const id = target.closest("[data-order-id]").dataset.orderId;
      return this.state.orders.find((order) => order.id === id);
    }

    moveField(path, action) {
      const index = this.state.selectedFields.indexOf(path);
      if (index < 0) return;
      if (action === "remove") this.state.selectedFields.splice(index, 1);
      if (action === "up" && index > 0) [this.state.selectedFields[index - 1], this.state.selectedFields[index]] = [this.state.selectedFields[index], this.state.selectedFields[index - 1]];
      if (action === "down" && index < this.state.selectedFields.length - 1) [this.state.selectedFields[index + 1], this.state.selectedFields[index]] = [this.state.selectedFields[index], this.state.selectedFields[index + 1]];
      this.changed();
    }

    changed() {
      this.state.rawDirty = false;
      this.renderAll();
    }

    switchMainTab(name) {
      this.root.querySelectorAll("[data-sac-main-tab]").forEach((button) => button.classList.toggle("is-active", button.dataset.sacMainTab === name));
      this.root.querySelectorAll("[data-sac-main-panel]").forEach((panel) => (panel.hidden = panel.dataset.sacMainPanel !== name));
    }

    switchResultTab(name) {
      this.root.querySelectorAll("[data-sac-result-tab]").forEach((button) => button.classList.toggle("is-active", button.dataset.sacResultTab === name));
      this.root.querySelectorAll("[data-sac-result-panel]").forEach((panel) => (panel.hidden = panel.dataset.sacResultPanel !== name));
      this.root.querySelector("[data-sac-empty-response]").hidden = Boolean(this.state.response);
    }

    async run() {
      const editor = this.root.querySelector("[data-sac-request]");
      let request;
      try {
        request = JSON.parse(editor.value);
      } catch (error) {
        this.setStatus("Invalid request JSON", "error");
        this.showLocalError(error.message);
        return;
      }
      const button = this.root.querySelector("[data-sac-run]");
      button.disabled = true;
      button.classList.add("is-running");
      this.root.querySelector("[data-sac-run-label]").textContent = "Running…";
      this.setStatus("Running query", "running");
      const started = performance.now();
      let response;
      let payload;
      try {
        response = await fetch(this.queryPath, {
          method: "POST",
          credentials: "same-origin",
          headers: {"Content-Type": "application/json", Accept: "application/json"},
          body: JSON.stringify(request),
        });
        const text = await response.text();
        try {
          payload = text ? JSON.parse(text) : null;
        } catch (_error) {
          payload = {ok: false, error: {code: "invalid_response", message: text || "Empty response", details: {}}};
        }
        const elapsed = Math.round(performance.now() - started);
        this.state.response = payload;
        this.renderResponse(payload);
        this.setStatus(`${response.status} ${response.statusText} · ${elapsed} ms`, response.ok ? "success" : "error");
      } catch (error) {
        this.state.response = {ok: false, error: {code: "network_error", message: error.message, details: {}}};
        this.renderResponse(this.state.response);
        this.setStatus("Network error", "error");
      } finally {
        button.disabled = false;
        button.classList.remove("is-running");
        this.root.querySelector("[data-sac-run-label]").textContent = "Run query";
      }
    }

    setStatus(text, kind) {
      const status = this.root.querySelector("[data-sac-response-status]");
      status.textContent = text;
      status.dataset.kind = kind || "";
    }

    showLocalError(message) {
      this.state.response = {ok: false, error: {code: "invalid_request_json", message, details: {}}};
      this.renderResponse(this.state.response);
    }

    renderResponse(payload) {
      this.root.querySelector("[data-sac-empty-response]").hidden = true;
      this.root.querySelector("[data-sac-response-json]").textContent = JSON.stringify(payload, null, 2);
      this.updateCurl();
      const head = this.root.querySelector("[data-sac-result-head]");
      const body = this.root.querySelector("[data-sac-result-body]");
      head.replaceChildren();
      body.replaceChildren();
      const data = payload && payload.data;
      const columns = data && Array.isArray(data.columns) ? data.columns : [];
      const rows = data && Array.isArray(data.rows) ? data.rows : [];
      if (columns.length) {
        const tr = element("tr", "");
        columns.forEach((column) => tr.append(element("th", "", column)));
        head.append(tr);
        rows.forEach((row) => {
          const resultRow = element("tr", "");
          columns.forEach((_column, index) => resultRow.append(element("td", "", renderValue(row[index]))));
          body.append(resultRow);
        });
      } else {
        const tr = element("tr", "");
        const td = element("td", "sac-error-cell", payload && payload.error ? `${payload.error.code}: ${payload.error.message}` : "No tabular result.");
        td.colSpan = 1;
        tr.append(td);
        body.append(tr);
      }
      this.switchResultTab(columns.length ? "table" : "json");
    }

    async copy(text, source) {
      const button = source.closest("button") || source;
      const original = button.textContent;
      try {
        await navigator.clipboard.writeText(text);
        button.textContent = "Copied";
      } catch (_error) {
        button.textContent = "Copy failed";
      }
      global.setTimeout(() => (button.textContent = original), 1200);
    }

    renderFatal(error) {
      this.root.replaceChildren();
      const panel = element("section", "sac-fatal");
      panel.append(element("span", "sac-kicker", "Selecto API Console"), element("h1", "", "Could not load the API"), element("p", "", error.message || String(error)));
      const retry = element("button", "sac-button sac-primary", "Retry");
      retry.type = "button";
      retry.addEventListener("click", () => global.location.reload());
      panel.append(retry);
      this.root.append(panel);
    }
  }

  function mountAll(rootDocument) {
    const currentDocument = rootDocument || global.document;
    if (!currentDocument) return [];
    return Array.from(currentDocument.querySelectorAll("[data-selecto-api-console]"), (root) => {
      const consoleInstance = new APIConsole(root);
      consoleInstance.start();
      return consoleInstance;
    });
  }

  const api = {
    version: "0.2.0",
    APIConsole,
    collectFields,
    compareSemanticFields,
    discoverCanonicalAPI,
    mountAll,
    normalizeAPIBase,
    operatorsForType,
    segmentParameterSpecs,
  };
  global.SelectoAPIConsole = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  if (typeof global.document !== "undefined" && global.addEventListener) {
    global.addEventListener("DOMContentLoaded", () => mountAll(global.document));
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
