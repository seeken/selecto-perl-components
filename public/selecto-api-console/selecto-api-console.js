(function (global) {
  "use strict";

  const MAX_RELATION_DEPTH = 4;
  const TEMPORAL_TYPES = new Set(["date", "datetime", "naive_datetime", "utc_datetime", "epoch_datetime"]);
  const NUMERIC_TYPES = new Set(["integer", "decimal", "float", "number"]);
  const CURL_AUTH_MODES = new Set(["basic", "cookie", "none"]);
  const QUERY_RESPONSE_FORMATS = [
    {id: "json", label: "JSON", mediaType: "application/json", extension: "json"},
    {id: "csv", label: "CSV", mediaType: "text/csv", extension: "csv"},
    {id: "tsv", label: "TSV", mediaType: "text/tab-separated-values", extension: "tsv"},
    {id: "xlsx", label: "Excel (XLSX)", mediaType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", extension: "xlsx"},
  ];
  const DATE_SHORTCUTS = [
    ["Days", "today", "Today"],
    ["Days", "yesterday", "Yesterday"],
    ["Days", "tomorrow", "Tomorrow"],
    ["Weeks", "this_week", "This Week"],
    ["Weeks", "last_week", "Last Week"],
    ["Weeks", "next_week", "Next Week"],
    ["Months", "this_month", "This Month"],
    ["Months", "last_month", "Last Month"],
    ["Months", "next_month", "Next Month"],
    ["Months", "mtd", "Month to Date"],
    ["Months", "mtd_all_years", "Month to Date (All Years)"],
    ["Quarters", "this_quarter", "This Quarter"],
    ["Quarters", "last_quarter", "Last Quarter"],
    ["Quarters", "next_quarter", "Next Quarter"],
    ["Quarters", "qtd", "Quarter to Date"],
    ["Quarters", "qtd_all_years", "Quarter to Date (All Years)"],
    ["Years", "this_year", "This Year"],
    ["Years", "last_year", "Last Year"],
    ["Years", "next_year", "Next Year"],
    ["Years", "ytd", "Year to Date"],
    ["Years", "ytd_all_years", "Year to Date (All Years)"],
    ["Relative periods", "last_7_days", "Last 7 Days"],
    ["Relative periods", "last_30_days", "Last 30 Days"],
    ["Relative periods", "last_90_days", "Last 90 Days"],
    ["Relative periods", "next_7_days", "Next 7 Days"],
    ["Relative periods", "next_30_days", "Next 30 Days"],
  ];

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

  function requestPayloadFromLocation(locationLike) {
    const hash = String(locationLike && locationLike.hash || "").replace(/^#/, "");
    if (!hash) return null;
    const encoded = new URLSearchParams(hash).get("request");
    if (encoded === null) return null;
    let payload;
    try {
      payload = JSON.parse(encoded);
    } catch (error) {
      throw new Error(`The Explorer request in this URL is not valid JSON: ${error.message}`);
    }
    if (!isPlainObject(payload)) throw new Error("The Explorer request in this URL must be a JSON object.");
    return payload;
  }

  function normalizeCurlAuth(value, fallback) {
    const candidate = String(value || fallback || "cookie").trim().toLowerCase();
    if (!CURL_AUTH_MODES.has(candidate)) {
      throw new Error("The API console cURL authentication mode must be basic, cookie, or none.");
    }
    return candidate;
  }

  function curlAuthConfiguration(mode) {
    if (mode === "basic") {
      return {
        args: ["  --basic", "  --user 'YOUR_USERNAME:YOUR_PASSWORD'"],
        help: "Replace the username and password placeholders with your credentials. cURL sends them using HTTP Basic authentication over HTTPS.",
      };
    }
    if (mode === "none") {
      return {
        args: [],
        help: "This host does not add authentication credentials to generated cURL commands.",
      };
    }
    return {
      args: ["  --cookie 'YOUR_SESSION_COOKIE'", "  --header 'X-CSRF-Token: YOUR_CSRF_TOKEN'"],
      help: "The browser uses your current authenticated session. Supply the corresponding session cookie and a CSRF token from the console page when running cURL separately.",
    };
  }

  function standaloneOption(name) {
    if (typeof global.location === "undefined") return "";
    return new URLSearchParams(global.location.search || "").get(name) || "";
  }

  function discoverQueryResponseFormats(openapi, queryPath) {
    const content = openapi && openapi.paths && openapi.paths[queryPath]
      && openapi.paths[queryPath].post && openapi.paths[queryPath].post.responses
      && openapi.paths[queryPath].post.responses[200]
      && openapi.paths[queryPath].post.responses[200].content || {};
    const advertised = QUERY_RESPONSE_FORMATS.filter((format) => Object.prototype.hasOwnProperty.call(content, format.mediaType));
    return advertised.length ? advertised.map((format) => Object.assign({}, format))
      : [Object.assign({}, QUERY_RESPONSE_FORMATS[0])];
  }

  function downloadFilename(contentDisposition, fallback) {
    const match = String(contentDisposition || "").match(/(?:^|;)\s*filename="([^"]+)"/i);
    const candidate = match ? match[1] : String(fallback || "query-download");
    const basename = candidate.split(/[\\/]/).pop()
      .replace(/[^A-Za-z0-9._ ()-]+/g, "-").trim();
    return basename && basename !== "." && basename !== ".." && !basename.includes("..")
      ? basename : "query-download";
  }

  function suggestedDownloadFilename(domainName, extension) {
    const stem = String(domainName || "selecto").toLowerCase()
      .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "selecto";
    return `${stem}-query.${extension}`;
  }

  function validateDownloadFilename(value, format) {
    if (!format || format.id === "json") return {value: "", error: ""};
    const filename = String(value || "").trim();
    const extension = `.${format.extension}`;
    const safe = filename.length <= 160
      && /^[A-Za-z0-9][A-Za-z0-9._ ()-]*$/.test(filename)
      && !filename.includes("..")
      && filename.toLowerCase().endsWith(extension.toLowerCase());
    return safe
      ? {value: filename, error: ""}
      : {value: filename, error: `Filename must be a safe name ending in ${extension}.`};
  }

  function initialSurfaceTab(access) {
    const surfaces = [["query", access.read], ["writes", access.write], ["actions", access.action]];
    const available = surfaces.find(([, allowed]) => allowed);
    return available ? available[0] : "domain";
  }

  function pathWithDownloadFilename(path, filename) {
    return `${path}${path.includes("?") ? "&" : "?"}filename=${encodeURIComponent(filename)}`;
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
    const writePath = route("writeDomain", `${normalizedBase}/write`);
    const actionRoute = routes.find((item) => item && item.operation_id === "executeAction");
    let actionPath = `${normalizedBase}/actions/{action}`;
    if (actionRoute && typeof actionRoute.path === "string" && actionRoute.path.endsWith("/actions/{action}")) {
      const prefix = actionRoute.path.slice(0, -"/{action}".length);
      try {
        normalizeAPIBase(prefix);
        actionPath = actionRoute.path;
      } catch (_error) {
        // Keep the same-origin fallback.
      }
    }
    const [domain, openapi] = await Promise.all([fetchJSON(domainPath), fetchJSON(openapiPath)]);
    const advertisedAccess = manifest && manifest.access && typeof manifest.access === "object"
      ? manifest.access : {};
    const access = {
      read: advertisedAccess.read !== false,
      write: advertisedAccess.write !== false,
      action: advertisedAccess.action !== false,
      importer: advertisedAccess.importer === true,
    };
    const queryResponseFormats = discoverQueryResponseFormats(openapi, queryPath);
    return {base: normalizedBase, manifest, domain, openapi, queryPath, writePath, actionPath, access, queryResponseFormats};
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

  function relationshipLabel(path, joins) {
    const segments = String(path || "").split(".").filter(Boolean);
    let prefix = "";
    return segments.map((segment) => {
      prefix = prefix ? `${prefix}.${segment}` : segment;
      const join = joins[prefix] || joins[segment] || {};
      return join.name || humanize(segment);
    }).join(" · ");
  }

  function relationFields(relation, schemas, joins, prefix, depth, schemaStack, output) {
    if (!relation || depth > MAX_RELATION_DEPTH) return;
    const columns = relation.columns || {};
    const declared = Array.isArray(relation.fields) ? relation.fields : Object.keys(columns);
    declared.slice().sort().forEach((name) => {
      const column = columns[name] || {};
      if (column.internal) return;
      const path = prefix ? `${prefix}.${name}` : name;
      const fieldLabel = column.label || humanize(name);
      output.push({
        path,
        name,
        label: prefix ? `${relationshipLabel(prefix, joins)}: ${fieldLabel}` : fieldLabel,
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
        joins,
        prefix ? `${prefix}.${name}` : name,
        depth + 1,
        schemaStack.concat(queryable),
        output
      );
    });
  }

  function collectFields(domain) {
    const output = [];
    relationFields(
      domain && domain.source,
      (domain && domain.schemas) || {},
      (domain && domain.joins) || {},
      "", 0, [], output
    );
    return output.sort(compareSemanticFields);
  }

  function collectFilterFields(domain, fields) {
    const components = domain && domain.components || {};
    const hidden = Array.isArray(components.filter_picker_hidden_paths)
      ? components.filter_picker_hidden_paths : [];
    const choices = components.filter_choices || {};
    const available = fields.map((field) => {
      const spec = choices[field.path] || {};
      return {
        ...field,
        pickerHidden: Boolean(spec.picker_hidden) || hidden.some((path) =>
          path.endsWith(".") ? field.path.startsWith(path) : field.path === path),
        ...(Array.isArray(spec.choices) ? {filterChoices: spec.choices.map((choice) => ({
          value: String(choice.value), label: String(choice.label),
        }))} : {}),
      };
    });
    Object.entries(choices).forEach(([path, spec]) => {
      if (!spec || !spec.conditional || !Array.isArray(spec.choices)) return;
      const branch = available.find((field) => field.path === spec.conditional.present_field);
      available.push({
        path, label: spec.label || humanize(path), type: branch && branch.type || "integer",
        filterChoices: spec.choices.map((choice) => ({
          value: String(choice.value), label: String(choice.label),
        })),
        conditional: true, pickerHidden: Boolean(spec.picker_hidden),
      });
    });
    return available.sort(compareSemanticFields);
  }

  function operatorsForField(field) {
    return Array.isArray(field && field.filterChoices)
      ? ["eq", "ne", "in", "not_in", "is_null", "not_null"]
      : operatorsForType(field.type);
  }

  function associationIsMany(association, schemas) {
    if (!association || typeof association !== "object") return false;
    if (association.cardinality) return association.cardinality === "many";
    const schema = association.queryable && schemas && schemas[association.queryable];
    if (!schema || typeof association.related_key !== "string") return false;
    return association.related_key !== String(schema.primary_key || "id");
  }

  function operatorsForType(type) {
    const common = ["eq", "ne", "in", "is_null", "not_null"];
    if (TEMPORAL_TYPES.has(type)) {
      return ["eq", "ne", "gt", "gte", "lt", "lte", "between", "date_shortcut", "in", "is_null", "not_null"];
    }
    if (NUMERIC_TYPES.has(type)) {
      return ["eq", "ne", "gt", "gte", "lt", "lte", "between", "in", "is_null", "not_null"];
    }
    if (type === "boolean") return ["eq", "ne", "is_null", "not_null"];
    return common;
  }

  function writeControlKind(field) {
    const type = String(field && field.type || "string").toLowerCase();
    const column = field && field.column || {};
    if (Array.isArray(column.options) || Array.isArray(column.enum) || type === "boolean") return "select";
    if (type === "date") return "date";
    if (["datetime", "naive_datetime", "utc_datetime"].includes(type)) return "datetime-local";
    if (NUMERIC_TYPES.has(type) || type === "epoch_datetime") return "number";
    if (["json", "object", "array", "text"].includes(type)) return "textarea";
    return "text";
  }

  function writeFieldRequired(rule, operation) {
    return ["insert", "upsert"].includes(String(operation || "").toLowerCase())
      && Boolean(rule && rule.required);
  }

  function writeRequiredValueMissing(included, value) {
    return !included || value === null || value === undefined
      || (typeof value === "string" && value.trim() === "");
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
      date_shortcut: "quick select",
      in: "one of",
      not_in: "not one of",
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

  function rowValue(row, column, index) {
    if (Array.isArray(row)) return row[index];
    return row && typeof row === "object" ? row[column] : undefined;
  }

  function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  }

  function onlyKeys(value, allowed) {
    return Object.keys(value).filter((key) => !allowed.includes(key));
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
      this.title = root.dataset.title || standaloneOption("title") || "API Console";
      this.curlAuth = normalizeCurlAuth(root.dataset.curlAuth, standaloneOption("curl_auth"));
      this.csrfToken = String(root.dataset.csrfToken || "");
      this.domain = null;
      this.manifest = null;
      this.openapi = null;
      this.queryPath = `${this.base}/query`;
      this.writePath = `${this.base}/write`;
      this.actionPath = `${this.base}/actions/{action}`;
      this.access = {read: true, write: true, action: true, importer: false};
      this.queryResponseFormats = [Object.assign({}, QUERY_RESPONSE_FORMATS[0])];
      this.fields = [];
      this.fieldMap = new Map();
      this.filterFields = [];
      this.filterFieldMap = new Map();
      this.nextSelectedFieldId = 1;
      this.state = {
        mode: "select",
        selectedFields: [],
        configuredField: "",
        projection: "",
        view: "",
        segments: [],
        parameters: {},
        filters: [],
        orders: [],
        ordering: "",
        timezone: "",
        rowFormat: "arrays",
        responseFormat: "json",
        responseFilename: "selecto-query.json",
        subtables: [],
        limit: 100,
        offset: 0,
        rawDirty: false,
        response: null,
      };
      this.nextFilterId = 1;
      this.nextOrderId = 1;
      this.writeState = {
        operation: "", assignments: {}, included: {}, filters: [],
        expectedCount: 1, returning: [], conflictTarget: [], updateFields: [],
        relationships: {},
        rawDirty: false,
        response: null,
      };
      this.actionState = {id: "", targetIds: "", inputs: {}, groups: [], rawDirty: false, response: null};
    }

    async start() {
      try {
        const discovery = await discoverCanonicalAPI(this.base, (path) => this.fetchJSON(path));
        this.base = discovery.base;
        this.manifest = discovery.manifest;
        this.domain = discovery.domain;
        this.openapi = discovery.openapi;
        this.queryPath = discovery.queryPath;
        this.writePath = discovery.writePath;
        this.actionPath = discovery.actionPath;
        this.access = discovery.access;
        this.queryResponseFormats = discovery.queryResponseFormats;
        this.state.responseFormat = this.queryResponseFormats[0].id;
        this.state.responseFilename = suggestedDownloadFilename(
          this.domain.name, this.responseFormat(this.state.responseFormat).extension,
        );
        this.fields = collectFields(discovery.domain);
        this.fieldMap = new Map(this.fields.map((field) => [field.path, field]));
        this.filterFields = collectFilterFields(discovery.domain, this.fields);
        this.filterFieldMap = new Map(this.filterFields.map((field) => [field.path, field]));
        this.seedState();
        let initialRequest = null;
        let initialRequestError = null;
        try {
          initialRequest = requestPayloadFromLocation(global.location);
          if (initialRequest) this.loadPayloadIntoChooser(initialRequest);
        } catch (error) {
          initialRequestError = error;
        }
        this.render();
        if (initialRequestError) {
          if (initialRequest) {
            const editor = this.root.querySelector("[data-sac-request]");
            editor.value = JSON.stringify(initialRequest, null, 2);
            this.state.rawDirty = true;
            this.root.querySelector("[data-sac-edited]").hidden = false;
            this.updateCurl();
          }
          this.setImportMessage(
            `The chooser cannot represent the Explorer request: ${initialRequestError.message}` +
              (initialRequest ? " You can still run it in manual JSON mode." : ""),
            "error",
          );
        } else if (initialRequest) {
          this.setImportMessage("Query form loaded from Explorer.", "success");
        }
      } catch (error) {
        this.renderFatal(error);
      }
    }

    async fetchJSON(url, options) {
      const request = Object.assign({credentials: "same-origin"}, options || {});
      request.headers = Object.assign({}, options && options.headers || {});
      if (String(request.method || "GET").toUpperCase() !== "GET") {
        request.headers["X-CSRF-Token"] = this.csrfToken;
      }
      const response = await fetch(url, request);
      const refreshedCSRF = response.headers.get("X-CSRF-Token");
      if (refreshedCSRF) this.csrfToken = refreshedCSRF;
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
        this.state.selectedFields = publicDefaults.slice(0, 12)
          .map((path) => this.newSelectedField(path));
        return;
      }
      const primaryKey = this.domain.source && this.domain.source.primary_key;
      const rootFields = this.fields.filter((field) => field.relation === "Root");
      const initial = [];
      if (primaryKey && this.fieldMap.has(primaryKey)) initial.push(primaryKey);
      rootFields.forEach((field) => {
        if (initial.length < 5 && !initial.includes(field.path)) initial.push(field.path);
      });
      this.state.selectedFields = initial.map((path) => this.newSelectedField(path));
    }

    newSelectedField(path) {
      const occurrence = this.state.selectedFields
        .filter((selection) => selection.field === path).length + 1;
      return {
        id: String(this.nextSelectedFieldId++),
        field: path,
        alias: occurrence > 1 ? `${path.replace(/\./g, "_")}__${occurrence}` : "",
        format: "",
      };
    }

    render() {
      this.root.innerHTML = `
        <header class="sac-header">
          <div class="sac-brand">
            <h1 data-sac-title></h1>
            <div class="sac-domain-meta"><span data-sac-domain-name></span><code data-sac-base></code></div>
          </div>
          <div class="sac-header-actions">
            <span class="sac-live"><i></i>Authenticated</span>
            <a class="sac-button sac-secondary" data-sac-domain-link>Domain JSON</a>
            <a class="sac-button sac-secondary" data-sac-openapi-link>OpenAPI</a>
            <a class="sac-button sac-secondary" data-sac-importer-link hidden>Importer</a>
          </div>
        </header>
        <nav class="sac-tabs" aria-label="API console sections">
          <button type="button" class="is-active" data-sac-main-tab="query">Query</button>
          <button type="button" data-sac-main-tab="writes">Writes</button>
          <button type="button" data-sac-main-tab="actions">Actions</button>
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
                  <div class="sac-normalization" data-sac-normalization></div>
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
                <div class="sac-card-heading"><div><span class="sac-step">2</span><h2>Constrain</h2></div></div>
                <div data-sac-segment-list>
                  <label class="sac-label" for="sac-segments">Named segments</label>
                  <select id="sac-segments" multiple size="4" data-sac-segments></select>
                  <p class="sac-help">Use Ctrl/⌘ to choose more than one reusable segment.</p>
                </div>
                <div class="sac-segment-groups" data-sac-segment-groups></div>
                <div class="sac-parameters" data-sac-parameters></div>
                <div class="sac-filter-list" data-sac-filters></div>
                <label class="sac-label" for="sac-filter-search">Available filters</label>
                <input id="sac-filter-search" type="search" placeholder="Search filter fields" data-sac-filter-search>
                <div class="sac-field-list sac-filter-field-list" data-sac-filter-field-list></div>
              </section>
              <section class="sac-card">
                <div class="sac-card-heading"><div><span class="sac-step">3</span><h2>Order & page</h2></div><button type="button" class="sac-text-button" data-sac-add-order>+ Sort</button></div>
                <label class="sac-label" for="sac-ordering">Named ordering</label>
                <select id="sac-ordering" data-sac-ordering></select>
                <div class="sac-order-list" data-sac-orders></div>
                <label class="sac-label" for="sac-row-format">Result row shape</label>
                <select id="sac-row-format" data-sac-row-format>
                  <option value="arrays">Ordered arrays</option>
                  <option value="objects">JSON objects</option>
                </select>
                <p class="sac-help">The selected shape also applies to rows inside subtables.</p>
                <div class="sac-inline-controls">
                  <label>Limit<input type="number" min="0" max="1000" data-sac-limit></label>
                  <label>Offset<input type="number" min="0" data-sac-offset></label>
                  <label>Response<select data-sac-response-format></select></label>
                </div>
                <div data-sac-response-filename-wrap hidden>
                  <label class="sac-label" for="sac-response-filename">Download filename</label>
                  <input id="sac-response-filename" type="text" maxlength="160" required data-sac-response-filename>
                  <p class="sac-help" data-sac-response-filename-help></p>
                </div>
                <label class="sac-label" for="sac-timezone">Use timezone</label>
                <input id="sac-timezone" type="text" placeholder="America/New_York" data-sac-timezone>
                <p class="sac-help">Applies an IANA timezone to UTC and epoch date/time fields and filters.</p>
              </section>
            </aside>
            <section class="sac-execution">
              <section class="sac-request-card">
                <div class="sac-card-heading">
                  <div><span class="sac-method">POST</span><code data-sac-query-path></code></div>
                  <div class="sac-compact-actions"><span class="sac-edited" data-sac-edited hidden>Manually edited</span><button type="button" class="sac-text-button" data-sac-load-json>Load into chooser</button><button type="button" class="sac-text-button" data-sac-reset-json>Reset JSON</button><button type="button" class="sac-text-button" data-sac-copy-request>Copy</button></div>
                </div>
                <div class="sac-import-message" data-sac-import-message hidden></div>
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
                <div class="sac-result-panel" data-sac-result-panel="curl" hidden><div class="sac-code-heading"><span>Command line</span><button type="button" class="sac-text-button" data-sac-copy-curl>Copy</button></div><pre data-sac-curl></pre><p class="sac-help" data-sac-curl-auth-help></p></div>
              </section>
            </section>
          </div>
        </section>
        <section data-sac-main-panel="writes" class="sac-main-panel" hidden>
          <div class="sac-mutation-layout">
            <section class="sac-card sac-mutation-builder" data-sac-write-builder></section>
            <section class="sac-mutation-execution">
              <section class="sac-request-card">
                <div class="sac-card-heading"><div><span class="sac-method">POST</span><code data-sac-write-path></code></div><div class="sac-compact-actions"><span class="sac-edited" data-sac-write-edited hidden>Manually edited</span><button type="button" class="sac-text-button" data-sac-load-write-json>Load into write form</button><button type="button" class="sac-text-button" data-sac-reset-write-json>Reset JSON</button><button type="button" class="sac-text-button" data-sac-copy-write>Copy JSON</button></div></div>
                <div class="sac-import-message" data-sac-write-import-message hidden></div>
                <div class="sac-correctness" data-sac-write-correctness></div>
                <textarea class="sac-request-editor" spellcheck="false" aria-label="Governed write request JSON" data-sac-write-request></textarea>
                <div class="sac-code-heading"><span>cURL command</span><button type="button" class="sac-text-button" data-sac-copy-write-curl>Copy cURL</button></div>
                <pre class="sac-mutation-curl" data-sac-write-curl></pre>
                <p class="sac-help sac-curl-help" data-sac-write-curl-auth-help></p>
                <div class="sac-run-row"><p>Only operations and fields published by the governed write contract can be sent.</p><button type="button" class="sac-button sac-primary" data-sac-run-write><span>Send write</span></button></div>
              </section>
              <section class="sac-response-card sac-mutation-response"><div class="sac-response-heading"><div><h2>Response</h2><span class="sac-response-status" data-sac-write-status>Ready</span></div></div><pre data-sac-write-response>Build a valid governed write, then send it.</pre></section>
            </section>
          </div>
        </section>
        <section data-sac-main-panel="actions" class="sac-main-panel" hidden>
          <div class="sac-mutation-layout">
            <section class="sac-card sac-mutation-builder" data-sac-action-builder></section>
            <section class="sac-mutation-execution">
              <section class="sac-request-card">
                <div class="sac-card-heading"><div><span class="sac-method">POST</span><code data-sac-action-path></code></div><div class="sac-compact-actions"><span class="sac-edited" data-sac-action-edited hidden>Manually edited</span><button type="button" class="sac-text-button" data-sac-load-action-json>Load into action form</button><button type="button" class="sac-text-button" data-sac-reset-action-json>Reset JSON</button><button type="button" class="sac-text-button" data-sac-copy-action>Copy JSON</button></div></div>
                <div class="sac-import-message" data-sac-action-import-message hidden></div>
                <div class="sac-correctness" data-sac-action-correctness></div>
                <textarea class="sac-request-editor" spellcheck="false" aria-label="Governed action request JSON" data-sac-action-request></textarea>
                <div class="sac-code-heading"><span>cURL command</span><button type="button" class="sac-text-button" data-sac-copy-action-curl>Copy cURL</button></div>
                <pre class="sac-mutation-curl" data-sac-action-curl></pre>
                <p class="sac-help sac-curl-help" data-sac-action-curl-auth-help></p>
                <div class="sac-run-row"><p>Inputs and target IDs are checked locally, then governed and authorized again by the server.</p><button type="button" class="sac-button sac-primary" data-sac-run-action><span>Send action</span></button></div>
              </section>
              <section class="sac-response-card sac-mutation-response"><div class="sac-response-heading"><div><h2>Response</h2><span class="sac-response-status" data-sac-action-status>Ready</span></div></div><pre data-sac-action-response>Choose an action, complete its form, then send it.</pre></section>
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
      this.root.querySelector("[data-sac-write-path]").textContent = this.writePath;
      this.root.querySelector("[data-sac-domain-link]").href = `${this.base}/domain`;
      this.root.querySelector("[data-sac-openapi-link]").href = `${this.base}/openapi.json`;
      const importerLink = this.root.querySelector("[data-sac-importer-link]");
      importerLink.href = `${this.base}/importer`;
      importerLink.hidden = !this.access.importer;
      const surfaceTabs = [["query", this.access.read], ["writes", this.access.write], ["actions", this.access.action]];
      for (const [name, allowed] of surfaceTabs) {
        const tab = this.root.querySelector(`[data-sac-main-tab="${name}"]`);
        if (tab) tab.hidden = !allowed;
      }
      this.root.querySelector("[data-sac-domain-json]").textContent = JSON.stringify(this.domain, null, 2);
      this.root.querySelector("[data-sac-openapi-json]").textContent = JSON.stringify(this.openapi, null, 2);
      this.root.querySelector("[data-sac-curl-auth-help]").textContent = curlAuthConfiguration(this.curlAuth).help;
      this.root.querySelector("[data-sac-write-curl-auth-help]").textContent = curlAuthConfiguration(this.curlAuth).help;
      this.root.querySelector("[data-sac-action-curl-auth-help]").textContent = curlAuthConfiguration(this.curlAuth).help;
      appendOptions(
        this.root.querySelector("[data-sac-response-format]"),
        this.queryResponseFormats.map((format) => ({value: format.id, label: format.label})),
        this.state.responseFormat,
      );
      this.bind();
      this.populateLibraryControls();
      this.seedMutationState();
      this.renderAll();
      this.renderWritePanel();
      this.renderActionPanel();
      this.switchMainTab(initialSurfaceTab(this.access));
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
    }

    segmentOptions() {
      const segments = (this.domain.query_library || {}).segments || {};
      const grouped = new Set(this.segmentGroups().flatMap((group) => group.choices.map((choice) => choice.segment)));
      return Object.entries(segments)
        .filter(([id, spec]) => !grouped.has(id) && (!(spec && spec.picker_hidden) || this.state.segments.includes(id)))
        .map(([id, spec]) => ({value: id, label: (spec && spec.label) || humanize(id)}));
    }

    segmentGroups() {
      const groups = (this.domain.query_library || {}).segment_picker_groups || {};
      return Object.entries(groups).map(([id, spec]) => ({
        id,
        label: spec.label,
        description: spec.description || "",
        offLabel: spec.off_label || "Off",
        choices: spec.choices || [],
      }));
    }

    setSegmentGroupChoice(groupId, choice) {
      const group = this.segmentGroups().find((entry) => entry.id === groupId);
      if (!group || (choice && !group.choices.some((entry) => entry.segment === choice))) return false;
      const choices = new Set(group.choices.map((entry) => entry.segment));
      this.state.segments = this.state.segments.filter((id) => !choices.has(id));
      if (choice) this.state.segments.push(choice);
      return true;
    }

    setUngroupedSegments(ids) {
      const grouped = new Set(this.segmentGroups().flatMap((group) => group.choices.map((choice) => choice.segment)));
      this.state.segments = [
        ...this.state.segments.filter((id) => grouped.has(id)),
        ...ids,
      ];
    }

    conflictingSegmentGroup(ids) {
      return this.segmentGroups().find((group) =>
        group.choices.filter((choice) => ids.includes(choice.segment)).length > 1
      );
    }

    renderSegmentGroups() {
      const container = this.root.querySelector("[data-sac-segment-groups]");
      container.replaceChildren();
      const library = this.domain.query_library || {};
      const viewSegments = this.state.mode === "view"
        ? (((library.views || {})[this.state.view] || {}).segments || []) : [];
      for (const group of this.segmentGroups()) {
        const fieldset = element("fieldset", "sac-segment-group");
        fieldset.append(element("legend", "", group.label));
        if (group.description) fieldset.append(element("small", "sac-help", group.description));
        const selected = group.choices.filter((choice) =>
          this.state.segments.includes(choice.segment) || viewSegments.includes(choice.segment));
        const inherited = group.choices.some((choice) => viewSegments.includes(choice.segment));
        fieldset.disabled = inherited;
        const choices = [{segment: "", label: group.offLabel}, ...group.choices];
        if (selected.length > 1) choices.push({segment: "__conflict__", label: "Multiple selected; choose one"});
        for (const choice of choices) {
          const label = element("label", "sac-segment-group-choice");
          const radio = element("input");
          radio.type = "radio";
          radio.name = `sac-segment-group-${group.id}`;
          radio.value = choice.segment;
          radio.dataset.sacSegmentGroup = group.id;
          radio.checked = selected.length > 1 ? choice.segment === "__conflict__"
            : selected.length ? choice.segment === selected[0].segment : choice.segment === "";
          label.append(radio, document.createTextNode(choice.label));
          fieldset.append(label);
        }
        if (inherited) fieldset.append(element("small", "sac-help", "Set by the named view; change the view to change this choice."));
        container.append(fieldset);
      }
    }

    rootFields() {
      const source = this.domain && this.domain.source || {};
      const columns = source.columns || {};
      const names = Array.isArray(source.fields) ? source.fields : Object.keys(columns);
      return names.filter((name) => !(columns[name] || {}).internal).map((name) => ({
        name,
        label: (columns[name] || {}).label || humanize(name),
        type: String((columns[name] || {}).type || "string").toLowerCase(),
        column: columns[name] || {},
      }));
    }

    relationshipFields(spec) {
      const source = spec && spec.domain && spec.domain.source || {};
      const columns = source.columns || {};
      const names = Array.isArray(source.fields) ? source.fields : Object.keys(columns);
      return names.filter((name) => !(columns[name] || {}).internal).map((name) => ({
        name,
        label: (columns[name] || {}).label || humanize(name),
        type: String((columns[name] || {}).type || "string").toLowerCase(),
        column: columns[name] || {},
      }));
    }

    writeRelationships() {
      const relationships = this.domain && this.domain.writes && this.domain.writes.relationships || {};
      return Object.entries(relationships).filter(([_name, spec]) => {
        return spec && spec.writable && spec.cardinality !== "many"
          && spec.domain && spec.domain.writes;
      });
    }

    writeOperations() {
      const operations = this.domain && this.domain.writes && this.domain.writes.operations || {};
      return ["insert", "update", "upsert", "delete"].filter((name) => {
        const spec = operations[name];
        return spec && spec.enabled;
      });
    }

    writeFieldsForOperation(fields, fieldContract, operation) {
      const permission = ["insert", "upsert"].includes(operation) ? "insertable" : "updatable";
      return fields.filter((field) => {
        const spec = fieldContract[field.name];
        return operation !== "delete" && spec && spec[permission];
      }).map((field, index) => ({field, index})).sort((left, right) => {
        const leftRequired = writeFieldRequired(fieldContract[left.field.name], operation) ? 1 : 0;
        const rightRequired = writeFieldRequired(fieldContract[right.field.name], operation) ? 1 : 0;
        return rightRequired - leftRequired || left.index - right.index;
      }).map((entry) => entry.field);
    }

    actionCatalog() {
      const operation = this.openapi && this.openapi.paths && this.openapi.paths[this.actionPath]
        && this.openapi.paths[this.actionPath].post;
      const advertised = operation && operation["x-selecto-actions"];
      if (Array.isArray(advertised)) return advertised.filter((action) => action && action.id);
      return Object.entries(this.domain && this.domain.actions || {}).map(([id, spec]) => Object.assign({id}, spec));
    }

    seedMutationState() {
      const operations = this.writeOperations();
      this.writeState.operation = operations[0] || "";
      const actions = this.actionCatalog();
      this.actionState.id = actions[0] ? actions[0].id : "";
      const primaryKey = this.domain && this.domain.source && this.domain.source.primary_key || "id";
      if (operations.includes("update") || operations.includes("delete")) {
        this.writeState.filters = [{field: primaryKey, op: "eq", value: ""}];
      }
      this.ensureActionGroups();
    }

    selectedAction() {
      return this.actionCatalog().find((action) => action.id === this.actionState.id) || null;
    }

    actionUsesGroups(action) {
      return Boolean(action && action.selection && action.selection.mode === "groups");
    }

    ensureActionGroups() {
      const action = this.selectedAction();
      if (this.actionUsesGroups(action) && !this.actionState.groups.length) {
        this.actionState.groups = [{ids: "", inputs: {}}];
      }
      if (!this.actionUsesGroups(action)) this.actionState.groups = [];
    }

    valueControl(type, value, attributes) {
      let control;
      if (type === "textarea") control = element("textarea", "");
      else if (type === "select") control = element("select", "");
      else {
        control = element("input", "");
        control.type = type === "number" ? "number"
          : type === "date" ? "date"
          : type === "datetime-local" ? "datetime-local" : "text";
      }
      Object.entries(attributes || {}).forEach(([name, setting]) => {
        if (name === "dataset") Object.assign(control.dataset, setting);
        else if (setting !== undefined) control[name] = setting;
      });
      if (type !== "select") control.value = value === undefined ? "" : value;
      return control;
    }

    writeValueControl(field, value, attributes) {
      const type = String(field.type || "string").toLowerCase();
      const choices = Array.isArray(field.column && field.column.options)
        ? field.column.options
        : Array.isArray(field.column && field.column.enum) ? field.column.enum : null;
      const kind = writeControlKind(field);
      const control = this.valueControl(kind, value, attributes);
      if (choices) {
        appendOptions(control, choices.map((choice) => {
          return choice && typeof choice === "object"
            ? {value: String(choice.value), label: choice.label || String(choice.value)}
            : {value: String(choice), label: String(choice)};
        }), value === undefined ? "" : String(value), "Choose…");
      } else if (type === "boolean") {
        appendOptions(control, [
          {value: "true", label: "True"}, {value: "false", label: "False"},
        ], value === undefined || value === "" ? "true" : String(value));
      }
      if (control.tagName === "INPUT" && control.type === "number") {
        control.step = type === "integer" || type === "epoch_datetime" ? "1" : "any";
      }
      if (control.tagName === "TEXTAREA") control.rows = 3;
      return control;
    }

    renderWritePanel() {
      const container = this.root.querySelector("[data-sac-write-builder]");
      container.replaceChildren();
      const operations = this.writeOperations();
      const heading = element("div", "sac-card-heading");
      const headingCopy = element("div", "");
      headingCopy.append(element("span", "sac-step", "1"), element("h2", "", "Build a governed write"));
      heading.append(headingCopy);
      container.append(heading);
      if (!operations.length) {
        container.append(element("p", "sac-empty-contract", "This domain does not publish any governed write operations."));
        this.syncWriteRequest();
        return;
      }

      const operationLabel = element("label", "sac-label", "Operation");
      const operation = element("select", "");
      operation.dataset.sacWriteOperation = "";
      appendOptions(operation, operations.map((name) => ({value: name, label: humanize(name)})), this.writeState.operation);
      container.append(operationLabel, operation);

      const contract = this.domain.writes || {};
      const fieldContract = contract.fields || {};
      const writable = this.writeFieldsForOperation(
        this.rootFields(), fieldContract, this.writeState.operation,
      );
      if (this.writeState.operation !== "delete") {
        container.append(element("span", "sac-label", "Assignments"));
        const list = element("div", "sac-mutation-fields");
        writable.forEach((field) => {
          const rule = fieldContract[field.name];
          const required = writeFieldRequired(rule, this.writeState.operation);
          if (required) this.writeState.included[field.name] = true;
          const row = element("label", "sac-mutation-field");
          const checkbox = element("input", "");
          checkbox.type = "checkbox";
          checkbox.checked = Boolean(this.writeState.included[field.name]);
          checkbox.disabled = required;
          checkbox.title = required ? "Required for insert" : "Include this assignment";
          checkbox.dataset.sacWriteInclude = field.name;
          const copy = element("span", "");
          copy.append(
            element("strong", "", `${field.label}${required ? " *" : ""}`),
            element("code", "", field.name),
          );
          if (required) copy.append(element("small", "sac-required-field", "Required for insert"));
          const input = this.writeValueControl(field, this.writeState.assignments[field.name], {
            dataset: {sacWriteField: field.name}, disabled: !checkbox.checked, required,
          });
          row.append(checkbox, copy, input);
          list.append(row);
        });
        if (!writable.length) list.append(element("p", "sac-muted", "No fields are writable for this operation."));
        container.append(list);
      }

      this.renderWriteRelationships(container);

      if (["update", "delete"].includes(this.writeState.operation)) {
        const filterHeading = element("div", "sac-card-heading sac-mutation-subheading");
        const filterCopy = element("div", "");
        filterCopy.append(element("h2", "", "Target filters"));
        const add = element("button", "sac-text-button", "+ Filter");
        add.type = "button";
        add.dataset.sacAddWriteFilter = "";
        filterHeading.append(filterCopy, add);
        container.append(filterHeading);
        const fields = this.rootFields();
        const filters = element("div", "sac-mutation-filters");
        this.writeState.filters.forEach((filter, index) => {
          const row = element("div", "sac-write-filter");
          row.dataset.writeFilterIndex = String(index);
          const field = element("select", "");
          field.dataset.sacWriteFilterField = "";
          appendOptions(field, fields.map((item) => ({value: item.name, label: item.label})), filter.field);
          const op = element("select", "");
          op.dataset.sacWriteFilterOp = "";
          appendOptions(op, ["eq", "ne", "gt", "gte", "lt", "lte", "in", "is_null", "not_null"].map((name) => ({value: name, label: optionLabel(name)})), filter.op);
          const selectedField = fields.find((item) => item.name === filter.field) || {type: "string"};
          const value = filter.op === "in"
            ? this.valueControl("text", filter.value, {dataset: {sacWriteFilterValue: ""}})
            : this.writeValueControl(selectedField, filter.value, {
                dataset: {sacWriteFilterValue: ""},
              });
          value.hidden = /^(is_null|not_null)$/.test(filter.op);
          if (filter.op === "in") value.placeholder = "comma-separated values";
          const remove = element("button", "sac-icon-button", "×");
          remove.type = "button";
          remove.dataset.sacRemoveWriteFilter = String(index);
          row.append(field, op, value, remove);
          filters.append(row);
        });
        container.append(filters);
      }

      const countLabel = element("label", "sac-label", "Expected affected rows");
      const count = element("input", "");
      count.type = "number";
      count.min = "1";
      count.value = this.writeState.expectedCount;
      count.dataset.sacWriteExpected = "";
      container.append(countLabel, count);

      const returningLabel = element("label", "sac-label", "Return fields");
      const returning = element("select", "");
      returning.multiple = true;
      returning.size = Math.min(6, Math.max(2, this.rootFields().length));
      returning.dataset.sacWriteReturning = "";
      appendOptions(returning, this.rootFields().map((field) => ({value: field.name, label: field.label})), "");
      Array.from(returning.options).forEach((option) => (option.selected = this.writeState.returning.includes(option.value)));
      container.append(returningLabel, returning);

      if (this.writeState.operation === "upsert") {
        [["Conflict target", "sacWriteConflict", this.writeState.conflictTarget], ["Update on conflict", "sacWriteUpdateFields", this.writeState.updateFields]].forEach(([labelText, datasetName, selected]) => {
          container.append(element("label", "sac-label", labelText));
          const select = element("select", "");
          select.multiple = true;
          select.size = Math.min(6, Math.max(2, this.rootFields().length));
          select.dataset[datasetName] = "";
          appendOptions(select, this.rootFields().map((field) => ({value: field.name, label: field.label})), "");
          Array.from(select.options).forEach((option) => (option.selected = selected.includes(option.value)));
          container.append(select);
        });
      }
      this.syncWriteRequest();
    }

    renderWriteRelationships(container) {
      const relationships = this.writeRelationships();
      if (!relationships.length || !["insert", "update"].includes(this.writeState.operation)) return;
      container.append(element("span", "sac-label", "Related records"));
      relationships.forEach(([name, spec]) => {
        const nestedWrites = spec.domain.writes || {};
        const allowed = new Set(Array.isArray(spec.allowed_ops) ? spec.allowed_ops : []);
        const operations = ["insert", "update"].filter((operation) => {
          const operationSpec = nestedWrites.operations && nestedWrites.operations[operation];
          return allowed.has(operation) && operationSpec && operationSpec.enabled
            && !(operation === "update" && this.writeState.operation !== "update");
        });
        if (!operations.length) return;
        const state = this.writeState.relationships[name] || (this.writeState.relationships[name] = {
          enabled: false, operation: operations[0], assignments: {}, included: {}, returning: [],
        });
        if (!operations.includes(state.operation)) state.operation = operations[0];
        const fieldset = element("fieldset", "sac-write-relationship");
        const legend = element("legend", "");
        const enabled = element("input", "");
        enabled.type = "checkbox";
        enabled.checked = Boolean(state.enabled);
        enabled.dataset.sacWriteRelationship = name;
        legend.append(enabled, document.createTextNode(` ${humanize(name)}`));
        fieldset.append(legend);

        const operationLabel = element("label", "sac-label", "Related operation");
        const operation = element("select", "");
        operation.disabled = !state.enabled;
        operation.dataset.sacWriteRelationshipOperation = name;
        appendOptions(operation, operations.map((value) => ({value, label: humanize(value)})), state.operation);
        fieldset.append(operationLabel, operation);

        const fields = this.writeFieldsForOperation(
          this.relationshipFields(spec), nestedWrites.fields || {}, state.operation,
        );
        const list = element("div", "sac-mutation-fields");
        fields.forEach((field) => {
          const rule = nestedWrites.fields && nestedWrites.fields[field.name];
          const required = writeFieldRequired(rule, state.operation);
          if (required) state.included[field.name] = true;
          const row = element("label", "sac-mutation-field");
          const include = element("input", "");
          include.type = "checkbox";
          include.checked = Boolean(state.included[field.name]);
          include.disabled = !state.enabled || required;
          include.title = required ? "Required for insert" : "Include this assignment";
          include.dataset.sacWriteRelationshipInclude = name;
          include.dataset.field = field.name;
          const copy = element("span", "");
          copy.append(
            element("strong", "", `${field.label}${required ? " *" : ""}`),
            element("code", "", field.name),
          );
          if (required) copy.append(element("small", "sac-required-field", "Required for insert"));
          const input = this.writeValueControl(field, state.assignments[field.name], {
            dataset: {sacWriteRelationshipField: name, field: field.name},
            disabled: !state.enabled || !include.checked, required,
          });
          row.append(include, copy, input);
          list.append(row);
        });
        fieldset.append(list);
        const returningLabel = element("label", "sac-label", "Return related fields");
        const returning = element("select", "");
        returning.multiple = true;
        returning.size = Math.min(6, Math.max(2, this.relationshipFields(spec).length));
        returning.disabled = !state.enabled;
        returning.dataset.sacWriteRelationshipReturning = name;
        appendOptions(returning, this.relationshipFields(spec).map((field) => ({value: field.name, label: field.label})), "");
        Array.from(returning.options).forEach((option) => (option.selected = (state.returning || []).includes(option.value)));
        fieldset.append(returningLabel, returning);
        container.append(fieldset);
      });
    }

    actionInputControl(spec, value, dataset) {
      const type = String(spec.type || "string").toLowerCase();
      const control = this.valueControl(type, value, {dataset});
      if (type === "select") {
        const options = Array.isArray(spec.options) ? spec.options : [];
        appendOptions(control, options.map((option) => ({
          value: String(option.value), label: option.label || String(option.value),
        })), value || "", spec.required ? "Choose…" : "None");
      }
      if (spec.minimum !== undefined) control.min = spec.minimum;
      if (spec.maximum !== undefined) control.max = spec.maximum;
      if (spec.max_length !== undefined) control.maxLength = spec.max_length;
      if (spec.rows !== undefined && control.tagName === "TEXTAREA") control.rows = spec.rows;
      return control;
    }

    actionInputSpecs(specs) {
      if (Array.isArray(specs)) return specs;
      if (!isPlainObject(specs)) return [];
      return Object.entries(specs).map(([id, spec]) => Object.assign({id}, spec || {}));
    }

    appendActionInputs(container, specs, values, groupIndex) {
      this.actionInputSpecs(specs).forEach((spec) => {
        const label = element("label", "sac-action-input");
        label.append(element("span", "sac-label", `${spec.label || humanize(spec.id)}${spec.required ? " *" : ""}`));
        const dataset = groupIndex === undefined
          ? {sacActionInput: spec.id}
          : {sacActionGroupInput: spec.id, groupIndex: String(groupIndex)};
        const control = this.actionInputControl(spec, values[spec.id], dataset);
        label.append(control);
        container.append(label);
      });
    }

    renderActionPanel() {
      const container = this.root.querySelector("[data-sac-action-builder]");
      container.replaceChildren();
      const actions = this.actionCatalog();
      const heading = element("div", "sac-card-heading");
      const headingCopy = element("div", "");
      headingCopy.append(element("span", "sac-step", "1"), element("h2", "", "Choose an action"));
      heading.append(headingCopy);
      container.append(heading);
      if (!actions.length) {
        container.append(element("p", "sac-empty-contract", "No actions are available in this governed domain."));
        this.syncActionRequest();
        return;
      }
      const picker = element("select", "");
      picker.dataset.sacActionId = "";
      appendOptions(picker, actions.map((action) => ({value: action.id, label: action.label || action.name || humanize(action.id)})), this.actionState.id);
      container.append(element("label", "sac-label", "Action"), picker);
      const action = this.selectedAction();
      if (action && action.description) container.append(element("p", "sac-help", action.description));
      const inputs = element("div", "sac-action-inputs");
      this.appendActionInputs(inputs, action && action.inputs, this.actionState.inputs);
      container.append(inputs);

      if (this.actionUsesGroups(action)) {
        const groupsHeading = element("div", "sac-card-heading sac-mutation-subheading");
        const groupCopy = element("div", "");
        groupCopy.append(element("h2", "", "Target groups"));
        const add = element("button", "sac-text-button", "+ Group");
        add.type = "button";
        add.dataset.sacAddActionGroup = "";
        add.disabled = this.actionState.groups.length >= Number(action.selection.max_groups || 6);
        groupsHeading.append(groupCopy, add);
        container.append(groupsHeading);
        const groups = element("div", "sac-action-groups");
        this.actionState.groups.forEach((group, index) => {
          const card = element("section", "sac-action-group");
          const groupHeading = element("div", "sac-card-heading");
          const marker = action.selection.markers && action.selection.markers[index];
          const groupTitle = element("div", "");
          groupTitle.append(element("strong", "", marker && marker.label || `Group ${index + 1}`));
          const remove = element("button", "sac-icon-button", "×");
          remove.type = "button";
          remove.dataset.sacRemoveActionGroup = String(index);
          groupHeading.append(groupTitle, remove);
          const ids = element("textarea", "");
          ids.value = group.ids || "";
          ids.placeholder = "Load IDs, separated by commas or new lines";
          ids.dataset.sacActionGroupIds = String(index);
          card.append(groupHeading, element("span", "sac-label", "Target IDs *"), ids);
          this.appendActionInputs(card, action.selection.group_inputs || [], group.inputs, index);
          groups.append(card);
        });
        container.append(groups);
      } else {
        const ids = element("textarea", "");
        ids.value = this.actionState.targetIds;
        ids.placeholder = "IDs, separated by commas or new lines";
        ids.dataset.sacActionTargetIds = "";
        container.append(element("label", "sac-label", "Target IDs *"), ids);
      }
      this.syncActionRequest();
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
      this.root.querySelector("[data-sac-row-format]").value = this.state.rowFormat;
      this.root.querySelector("[data-sac-response-format]").value = this.state.responseFormat;
      this.renderResponseFileOptions();
      this.root.querySelector("[data-sac-limit]").value = this.state.limit;
      this.root.querySelector("[data-sac-offset]").value = this.state.offset;
      this.root.querySelector("[data-sac-timezone]").value = this.state.timezone;
      const segmentOptions = this.segmentOptions();
      this.root.querySelector("[data-sac-segment-list]").hidden = !segmentOptions.length;
      appendOptions(this.root.querySelector("[data-sac-segments]"), segmentOptions, "");
      Array.from(this.root.querySelector("[data-sac-segments]").options).forEach((option) => {
        option.selected = this.state.segments.includes(option.value);
      });
      this.renderSegmentGroups();
      this.renderSelectedFields();
      this.renderNormalization();
      this.renderFieldList();
      this.renderViewHelp();
      this.renderParameters();
      this.renderFilters();
      this.renderFilterFieldList();
      this.renderOrders();
      this.syncRequest();
    }

    renderNormalization() {
      const container = this.root.querySelector("[data-sac-normalization]");
      const selectItems = this.openapi && this.openapi.components && this.openapi.components.schemas
        && this.openapi.components.schemas.SelectoQuery
        && this.openapi.components.schemas.SelectoQuery.properties
        && this.openapi.components.schemas.SelectoQuery.properties.select
        && this.openapi.components.schemas.SelectoQuery.properties.select.items;
      const supportsSubtables = selectItems && Array.isArray(selectItems.oneOf)
        && selectItems.oneOf.some((item) => String(item && item.$ref || "").endsWith("/SelectoSubtableSelection"));
      const associations = this.domain && this.domain.source && this.domain.source.associations || {};
      const schemas = this.domain && this.domain.schemas || {};
      const selected = new Set(this.state.selectedFields.map((item) => item.field.split(".")[0]));
      const names = Object.keys(associations).filter((name) => {
        const specification = associations[name] || {};
        return associationIsMany(specification, schemas) && selected.has(name);
      }).sort();
      if (!supportsSubtables || !names.length) {
        container.replaceChildren();
        container.hidden = true;
        return;
      }
      container.hidden = false;
      container.replaceChildren(element("span", "sac-label", "To-many relationships"));
      names.forEach((name) => {
        const label = element("label", "sac-normalization-option");
        const checkbox = element("input", "");
        checkbox.type = "checkbox";
        checkbox.value = name;
        checkbox.dataset.sacSubtable = "";
        checkbox.checked = this.state.subtables.includes(name);
        const description = element("span", "");
        description.append("Return ", element("code", "", name), " as a subtable");
        label.append(checkbox, description);
        container.append(label);
      });
      container.append(element(
        "p", "sac-help",
        "A subtable preserves one root row. Unchecked to-many fields remain flat and may repeat the root row."
      ));
    }

    renderSelectedFields() {
      const container = this.root.querySelector("[data-sac-selected-fields]");
      container.replaceChildren();
      if (!this.state.selectedFields.length) {
        container.append(element("p", "sac-muted", "Choose at least one field."));
        return;
      }
      this.state.selectedFields.forEach((selection, index) => {
        const path = selection.field;
        const field = this.fieldMap.get(path) || {label: path, type: "field"};
        const row = element("div", "sac-selected-field");
        row.dataset.field = path;
        row.dataset.selectionId = selection.id;
        const handle = element("span", "sac-drag", "⋮⋮");
        handle.setAttribute("aria-hidden", "true");
        const copy = element("div", "sac-selected-copy");
        copy.append(element("strong", "", field.label), element("code", "", path));
        const configured = [selection.alias && `as ${selection.alias}`, selection.format].filter(Boolean).join(" · ");
        if (configured) copy.append(element("small", "sac-field-config-summary", configured));
        const actions = element("div", "sac-field-actions");
        [["configure", "Configure", "Configure"], ["up", "↑", "Move up"], ["down", "↓", "Move down"], ["remove", "×", "Remove"]].forEach(([action, text, label]) => {
          const button = element("button", "", text);
          button.type = "button";
          button.dataset.sacFieldAction = action;
          button.setAttribute("aria-label", `${label} ${field.label}`);
          if (action === "configure") {
            button.classList.add("sac-configure-field");
            button.setAttribute("aria-expanded", String(this.state.configuredField === selection.id));
          }
          if ((action === "up" && index === 0) || (action === "down" && index === this.state.selectedFields.length - 1)) button.disabled = true;
          actions.append(button);
        });
        row.append(handle, copy, actions);
        if (this.state.configuredField === selection.id) {
          row.classList.add("is-configuring");
          row.append(this.fieldConfiguration(field, selection));
        }
        container.append(row);
      });
    }

    selectionSchema() {
      return this.openapi && this.openapi.components && this.openapi.components.schemas
        && this.openapi.components.schemas.SelectoSelection || {};
    }

    fieldFormats(field) {
      if (!field || !TEMPORAL_TYPES.has(field.type)) return [];
      const format = (this.selectionSchema().properties || {}).format || {};
      return Array.isArray(format.enum) ? format.enum.filter((value) => typeof value === "string") : [];
    }

    fieldConfiguration(field, config) {
      const panel = element("div", "sac-field-configuration");
      const aliasLabel = element("label", "");
      aliasLabel.append(element("span", "", "Result alias"));
      const alias = element("input", "");
      alias.type = "text";
      alias.value = config.alias || "";
      alias.placeholder = field.path.replace(/\./g, "_");
      alias.pattern = "[A-Za-z_][A-Za-z0-9_]*";
      alias.maxLength = 80;
      alias.dataset.sacFieldAlias = "";
      alias.setAttribute("aria-label", `Result alias for ${field.label}`);
      aliasLabel.append(alias);
      panel.append(aliasLabel);

      const formats = this.fieldFormats(field);
      if (formats.length) {
        const formatLabel = element("label", "");
        formatLabel.append(element("span", "", "Format"));
        const format = element("select", "");
        format.dataset.sacFieldFormat = "";
        format.setAttribute("aria-label", `Format for ${field.label}`);
        appendOptions(format, formats.map((value) => ({value, label: humanize(value)})), config.format || "", "Default");
        formatLabel.append(format);
        panel.append(formatLabel);
      }
      return panel;
    }

    renderFieldList() {
      const query = (this.root.querySelector("[data-sac-field-search]").value || "").trim().toLowerCase();
      const container = this.root.querySelector("[data-sac-field-list]");
      container.replaceChildren();
      const matches = this.fields.filter((field) => !query || `${field.path} ${field.label} ${field.type}`.toLowerCase().includes(query));
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
        const field = this.filterFieldMap.get(filter.field) || this.filterFields[0];
        if (!field) return;
        const row = element("article", "sac-filter-row");
        row.dataset.filterId = filter.id;
        const heading = element("div", "sac-filter-heading");
        const copy = element("span", "sac-selected-copy");
        copy.append(element("strong", "", field.label));
        if (!field.conditional) copy.append(element("code", "", field.path));
        const remove = element("button", "sac-icon-button", "×");
        remove.type = "button";
        remove.dataset.sacRemoveFilter = filter.id;
        remove.setAttribute("aria-label", `Remove ${field.label} filter`);
        heading.append(copy, element("small", "", field.type), remove);
        const controls = element("div", "sac-filter-controls");
        const operator = element("select", "");
        operator.dataset.sacFilterOp = "";
        operator.setAttribute("aria-label", `Filter mode for ${field.label}`);
        appendOptions(operator, operatorsForField(field).map((op) => ({value: op, label: optionLabel(op)})), filter.op);
        controls.append(operator);
        if (!/^(is_null|not_null)$/.test(filter.op)) {
          controls.append(this.filterValueControl(filter, field, false));
          if (filter.op === "between") controls.append(this.filterValueControl(filter, field, true));
        }
        row.append(heading, controls);
        container.append(row);
      });
      if (!this.state.filters.length) container.append(element("p", "sac-muted", "Choose a field below to add a filter."));
    }

    dateShortcuts() {
      const schema = this.openapi && this.openapi.components && this.openapi.components.schemas
        && this.openapi.components.schemas.SelectoFilter;
      const advertised = schema && schema["x-selecto-date-shortcuts"];
      if (!Array.isArray(advertised)) return DATE_SHORTCUTS;
      const choices = advertised.filter((choice) => choice && typeof choice.id === "string")
        .map((choice) => [choice.group || "Periods", choice.id, choice.label || humanize(choice.id)]);
      return choices.length ? choices : DATE_SHORTCUTS;
    }

    renderFilterFieldList() {
      const search = this.root.querySelector("[data-sac-filter-search]");
      const query = (search.value || "").trim().toLowerCase();
      const selected = new Set(this.state.filters.map((filter) => filter.field));
      const container = this.root.querySelector("[data-sac-filter-field-list]");
      container.replaceChildren();
      const matches = this.filterFields.filter((field) => !field.pickerHidden && !selected.has(field.path)
        && (!query || `${field.path} ${field.label} ${field.type}`.toLowerCase().includes(query)));
      matches.slice(0, 150).forEach((field) => {
        const button = element("button", "sac-available-field");
        button.type = "button";
        button.dataset.sacAddFilter = field.path;
        const copy = element("span", "");
        copy.append(element("strong", "", field.label));
        if (!field.conditional) copy.append(element("code", "", field.path));
        button.append(copy, element("small", "", field.type), element("b", "", "+"));
        container.append(button);
      });
      if (!matches.length) container.append(element("p", "sac-muted", "No matching available filters."));
    }

    filterValueControl(filter, field, end) {
      let input;
      if (!end && Array.isArray(field.filterChoices)
        && ["eq", "ne", "in", "not_in"].includes(filter.op)) {
        input = element("select", "");
        const multiple = filter.op === "in" || filter.op === "not_in";
        input.multiple = multiple;
        if (multiple) input.size = Math.min(8, Math.max(3, field.filterChoices.length));
        else input.append(new Option("Choose a value", ""));
        const selected = String(filter.value || "").split(",").map((value) => value.trim());
        field.filterChoices.forEach((choice) => {
          input.append(new Option(choice.label, choice.value, false, selected.includes(choice.value)));
        });
        selected.filter(Boolean).forEach((value) => {
          if (!field.filterChoices.some((choice) => choice.value === value)) {
            input.append(new Option("Unavailable option", value, true, true));
          }
        });
      } else if (filter.op === "date_shortcut") {
        input = element("select", "");
        const groups = new Map();
        this.dateShortcuts().forEach(([group, value, label]) => {
          if (!groups.has(group)) {
            const optionGroup = document.createElement("optgroup");
            optionGroup.label = group;
            groups.set(group, optionGroup);
            input.append(optionGroup);
          }
          groups.get(group).append(new Option(label, value, false, value === filter.value));
        });
      } else if (field.type === "boolean" && filter.op !== "in") {
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
      input.setAttribute("aria-label", filter.op === "date_shortcut" ? `Quick period for ${field.label}` : (end ? "Filter end value" : "Filter value"));
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

    filterPayloads(filter) {
      const field = this.filterFieldMap.get(filter.field);
      const payload = {field: filter.field, op: filter.op};
      if (filter.op === "date_shortcut") {
        payload.value = filter.value;
        return [payload];
      }
      if (/^(is_null|not_null)$/.test(filter.op)) return [payload];
      if (filter.op === "in" || filter.op === "not_in") {
        payload.value = String(filter.value).split(",").map((value) => value.trim()).filter(Boolean);
      } else if (field && field.type === "boolean") {
        payload.value = String(filter.value) === "true";
      } else {
        payload.value = filter.value;
      }
      if (filter.op === "between") payload.end = filter.end;
      return [payload];
    }

    buildPayload() {
      const payload = {};
      if (this.state.mode === "select") {
        const selectedFields = this.state.selectedFields.map((selection) => {
          const alias = String(selection.alias || "").trim();
          const format = String(selection.format || "");
          const value = !alias && !format ? selection.field
            : Object.assign({field: selection.field}, alias ? {alias} : {}, format ? {format} : {});
          return {association: selection.field.split(".")[0], value};
        });
        const subtables = new Set(this.state.subtables);
        const grouped = new Map();
        payload.select = [];
        selectedFields.forEach((selection) => {
          if (!subtables.has(selection.association)) {
            payload.select.push(selection.value);
            return;
          }
          let group = grouped.get(selection.association);
          if (!group) {
            group = [];
            grouped.set(selection.association, group);
            payload.select.push(group);
          }
          group.push(selection.value);
        });
      }
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
      if (this.state.filters.length) payload.filters = this.state.filters.flatMap((filter) => this.filterPayloads(filter));
      if (this.state.ordering) payload.ordering = this.state.ordering;
      else if (this.state.orders.length) payload.order_by = this.state.orders.map((order) => ({field: order.field, direction: order.direction}));
      if (String(this.state.timezone || "").trim()) payload.timezone = String(this.state.timezone).trim();
      payload.row_format = this.state.rowFormat;
      payload.limit = Number.parseInt(this.state.limit, 10) || 0;
      payload.offset = Number.parseInt(this.state.offset, 10) || 0;
      return payload;
    }

    chooserStateFromPayload(payload) {
      if (!isPlainObject(payload)) throw new Error("The request must be a JSON object.");
      const allowed = ["select", "projection", "view", "segments", "parameters", "filters", "ordering", "order_by", "timezone", "row_format", "limit", "offset"];
      const unknown = onlyKeys(payload, allowed);
      if (unknown.length) throw new Error(`Unsupported request properties: ${unknown.join(", ")}.`);
      const sources = ["select", "projection", "view"].filter((key) => Object.prototype.hasOwnProperty.call(payload, key));
      if (sources.length !== 1) throw new Error("Use exactly one of select, projection, or view.");
      if (Object.prototype.hasOwnProperty.call(payload, "ordering") && Object.prototype.hasOwnProperty.call(payload, "order_by")) {
        throw new Error("The chooser cannot use ordering and order_by together.");
      }

      const library = this.domain && this.domain.query_library || {};
      const draft = {
        mode: sources[0], selectedFields: [], configuredField: "",
        projection: "", view: "", segments: [], parameters: {}, filters: [],
        orders: [], ordering: "", timezone: "", rowFormat: "arrays", subtables: [],
        limit: 100, offset: 0,
      };
      let selectedId = this.nextSelectedFieldId;
      let filterId = this.nextFilterId;
      let orderId = this.nextOrderId;

      const parseSelection = (entry) => {
        let field;
        let alias = "";
        let format = "";
        if (typeof entry === "string") field = entry;
        else if (isPlainObject(entry)) {
          const extra = onlyKeys(entry, ["field", "alias", "format"]);
          if (extra.length) throw new Error(`Unsupported selected-field properties: ${extra.join(", ")}.`);
          field = entry.field;
          if (Object.prototype.hasOwnProperty.call(entry, "alias")) alias = entry.alias;
          if (Object.prototype.hasOwnProperty.call(entry, "format")) format = entry.format;
        } else throw new Error("Each selected field must be a field name or field configuration object.");
        if (typeof field !== "string" || !this.fieldMap.has(field)) throw new Error(`The chooser does not know the field ${JSON.stringify(field)}.`);
        if (typeof alias !== "string" || (alias && !/^[A-Za-z_][A-Za-z0-9_]*$/.test(alias))) throw new Error(`The alias for ${field} is not representable.`);
        if (typeof format !== "string" || (format && !this.fieldFormats(this.fieldMap.get(field)).includes(format))) throw new Error(`The format for ${field} is not available in the chooser.`);
        return {id: String(selectedId++), field, alias, format};
      };

      if (draft.mode === "select") {
        if (!Array.isArray(payload.select) || !payload.select.length) throw new Error("select must be a non-empty array.");
        const nestedAssociations = new Set();
        const flatAssociations = new Set();
        payload.select.forEach((entry) => {
          if (!Array.isArray(entry)) {
            const selection = parseSelection(entry);
            draft.selectedFields.push(selection);
            flatAssociations.add(selection.field.split(".")[0]);
            return;
          }
          if (!entry.length) throw new Error("A subtable selection cannot be empty.");
          const selections = entry.map(parseSelection);
          const associations = new Set(selections.map((selection) => selection.field.split(".")[0]));
          if (associations.size !== 1 || selections.some((selection) => !selection.field.includes("."))) {
            throw new Error("Each subtable must contain fields from one direct relationship.");
          }
          const association = selections[0].field.split(".")[0];
          const specification = this.domain && this.domain.source && this.domain.source.associations && this.domain.source.associations[association];
          if (!specification || !associationIsMany(specification, this.domain.schemas || {})) throw new Error(`${association} is not an available to-many subtable.`);
          if (nestedAssociations.has(association)) throw new Error(`The chooser supports one ${association} subtable per request.`);
          nestedAssociations.add(association);
          draft.subtables.push(association);
          draft.selectedFields.push(...selections);
        });
        const mixed = Array.from(nestedAssociations).find((association) => flatAssociations.has(association));
        if (mixed) throw new Error(`The chooser cannot mix flat and subtable fields from ${mixed}.`);
      } else if (draft.mode === "projection") {
        if (typeof payload.projection !== "string" || !Object.prototype.hasOwnProperty.call(library.projections || {}, payload.projection)) {
          throw new Error("The chooser supports one published named projection.");
        }
        draft.projection = payload.projection;
      } else {
        if (typeof payload.view !== "string" || !Object.prototype.hasOwnProperty.call(library.views || {}, payload.view)) {
          throw new Error("The chooser only supports published named views.");
        }
        draft.view = payload.view;
      }

      if (payload.segments !== undefined) {
        if (!Array.isArray(payload.segments) || payload.segments.some((id) => typeof id !== "string" || !Object.prototype.hasOwnProperty.call(library.segments || {}, id))) {
          throw new Error("One or more named segments are not available in the chooser.");
        }
        if (new Set(payload.segments).size !== payload.segments.length) throw new Error("The chooser cannot represent repeated named segments.");
        draft.segments = payload.segments.slice();
      }
      const selectedSegmentIds = draft.segments.slice();
      if (draft.mode === "view") selectedSegmentIds.push(...(((library.views || {})[draft.view] || {}).segments || []));
      const segmentConflict = this.conflictingSegmentGroup(selectedSegmentIds);
      if (segmentConflict) throw new Error(`${segmentConflict.label} allows only one choice.`);
      if (payload.parameters !== undefined) {
        if (!isPlainObject(payload.parameters)) throw new Error("parameters must be a JSON object.");
        const segmentIds = draft.segments.slice();
        if (draft.mode === "view") segmentIds.push(...(((library.views || {})[draft.view] || {}).segments || []));
        const specs = segmentParameterSpecs(library, segmentIds);
        const unsupported = Object.keys(payload.parameters).filter((name) => !Object.prototype.hasOwnProperty.call(specs, name));
        if (unsupported.length) throw new Error(`Parameters not exposed by the selected segments: ${unsupported.join(", ")}.`);
        if (Object.values(payload.parameters).some((value) => value !== null && typeof value === "object")) throw new Error("The chooser only supports scalar parameter values.");
        draft.parameters = Object.assign({}, payload.parameters);
      }
      if (payload.filters !== undefined) {
        if (!Array.isArray(payload.filters)) throw new Error("filters must be an array.");
        draft.filters = payload.filters.map((filter) => {
          if (!isPlainObject(filter)) throw new Error("Each filter must be a JSON object.");
          const extra = onlyKeys(filter, ["field", "op", "value", "end"]);
          if (extra.length) throw new Error(`Unsupported filter properties: ${extra.join(", ")}.`);
          const field = this.filterFieldMap.get(filter.field);
          if (!field) throw new Error(`The chooser does not know the filter field ${JSON.stringify(filter.field)}.`);
          if (typeof filter.op !== "string" || !operatorsForField(field).includes(filter.op)) throw new Error(`The ${filter.op} filter is not available for ${filter.field}.`);
          if (["in", "not_in"].includes(filter.op) && (!Array.isArray(filter.value) || filter.value.some((value) => typeof value !== "string"))) throw new Error("The chooser supports membership-filter values as an array of strings.");
          if (!/^(is_null|not_null)$/.test(filter.op) && !Object.prototype.hasOwnProperty.call(filter, "value")) throw new Error(`The ${filter.op} filter requires a value.`);
          if (filter.op === "between" && !Object.prototype.hasOwnProperty.call(filter, "end")) throw new Error("A between filter requires an end value.");
          return {
            id: String(filterId++), field: filter.field, op: filter.op,
            value: ["in", "not_in"].includes(filter.op) ? filter.value.join(", ") : (filter.value === undefined ? "" : filter.value),
            end: filter.end === undefined ? "" : filter.end,
          };
        });
      }
      if (payload.ordering !== undefined) {
        if (typeof payload.ordering !== "string" || !Object.prototype.hasOwnProperty.call(library.orderings || {}, payload.ordering)) throw new Error("The named ordering is not available in the chooser.");
        draft.ordering = payload.ordering;
      }
      if (payload.order_by !== undefined) {
        if (!Array.isArray(payload.order_by)) throw new Error("order_by must be an array.");
        draft.orders = payload.order_by.map((order) => {
          if (!isPlainObject(order) || onlyKeys(order, ["field", "direction"]).length || !this.fieldMap.has(order.field) || !["asc", "desc"].includes(order.direction)) {
            throw new Error("Each custom ordering needs a known field and an asc or desc direction.");
          }
          return {id: String(orderId++), field: order.field, direction: order.direction};
        });
      }
      if (payload.timezone !== undefined) {
        if (typeof payload.timezone !== "string") throw new Error("timezone must be a string.");
        draft.timezone = payload.timezone;
      }
      if (payload.row_format !== undefined) {
        if (!["arrays", "objects"].includes(payload.row_format)) throw new Error("row_format must be arrays or objects.");
        draft.rowFormat = payload.row_format;
      }
      [["limit", 100], ["offset", 0]].forEach(([name, fallback]) => {
        if (payload[name] === undefined) return;
        if (!Number.isInteger(payload[name]) || payload[name] < 0) throw new Error(`${name} must be a non-negative integer.`);
        draft[name] = payload[name];
      });
      return {draft, counters: {selectedId, filterId, orderId}};
    }

    loadPayloadIntoChooser(payload) {
      const converted = this.chooserStateFromPayload(payload);
      Object.assign(this.state, converted.draft, {rawDirty: false});
      this.nextSelectedFieldId = converted.counters.selectedId;
      this.nextFilterId = converted.counters.filterId;
      this.nextOrderId = converted.counters.orderId;
      return this.state;
    }

    setImportMessage(message, kind) {
      const target = this.root.querySelector("[data-sac-import-message]");
      if (!target) return;
      target.textContent = message || "";
      target.dataset.kind = kind || "";
      target.hidden = !message;
    }

    loadRequestIntoChooser() {
      const editor = this.root.querySelector("[data-sac-request]");
      let payload;
      try {
        payload = JSON.parse(editor.value);
        this.loadPayloadIntoChooser(payload);
      } catch (error) {
        this.setImportMessage(`The chooser cannot represent this JSON: ${error.message} You can still run it, but the chooser will not track it; you are in manual JSON mode.`, "error");
        return false;
      }
      this.renderAll();
      this.setImportMessage("Chooser updated from the request JSON.", "success");
      return true;
    }

    syncRequest(force) {
      if (this.state.rawDirty && !force) return;
      this.root.querySelector("[data-sac-request]").value = JSON.stringify(this.buildPayload(), null, 2);
      this.state.rawDirty = false;
      this.root.querySelector("[data-sac-edited]").hidden = true;
      if (force) this.setImportMessage("", "");
      this.updateCurl();
    }

    renderResponseFileOptions() {
      const format = this.responseFormat(this.state.responseFormat);
      const wrapper = this.root.querySelector("[data-sac-response-filename-wrap]");
      const input = this.root.querySelector("[data-sac-response-filename]");
      const help = this.root.querySelector("[data-sac-response-filename-help]");
      const downloadable = format.id !== "json";
      wrapper.hidden = !downloadable;
      input.required = downloadable;
      input.value = this.state.responseFilename;
      input.placeholder = `query.${format.extension}`;
      const validation = validateDownloadFilename(this.state.responseFilename, format);
      input.setCustomValidity(validation.error);
      help.textContent = downloadable
        ? `Required. Use a safe filename ending in .${format.extension}.`
        : "";
    }

    updateCurl() {
      const editor = this.root.querySelector("[data-sac-request]");
      const body = editor ? editor.value : JSON.stringify(this.buildPayload(), null, 2);
      const command = this.curlCommand(
        this.queryPath, body, this.state.responseFormat, this.state.responseFilename,
      );
      const target = this.root.querySelector("[data-sac-curl]");
      if (target) target.textContent = command;
    }

    responseFormat(formatId) {
      return this.queryResponseFormats.find((format) => format.id === formatId)
        || QUERY_RESPONSE_FORMATS.find((format) => format.id === formatId)
        || QUERY_RESPONSE_FORMATS[0];
    }

    curlCommand(path, body, responseFormat = "json", responseFilename = "") {
      const auth = curlAuthConfiguration(this.curlAuth);
      const format = this.responseFormat(responseFormat);
      const validation = validateDownloadFilename(responseFilename, format);
      const filename = format.id === "json"
        ? "" : validation.error ? `query.${format.extension}` : validation.value;
      const requestPath = filename ? pathWithDownloadFilename(path, filename) : path;
      const url = `${window.location.origin}${requestPath}`;
      const command = [
        `curl -X POST ${shellEscape(url)}`,
        ...auth.args,
        "  -H 'Content-Type: application/json'",
        `  -H ${shellEscape(`Accept: ${format.mediaType}`)}`,
        `  --data-binary ${shellEscape(body)}`,
      ];
      if (format.id !== "json") command.push(`  --output ${shellEscape(filename)}`);
      return command.join(" \\\n");
    }

    updateMutationCurl(kind, path) {
      const editor = this.root.querySelector(`[data-sac-${kind}-request]`);
      const target = this.root.querySelector(`[data-sac-${kind}-curl]`);
      if (editor && target) target.textContent = this.curlCommand(path, editor.value);
    }

    coerceValue(raw, type, label) {
      const text = String(raw === undefined ? "" : raw).trim();
      if (type === "date") {
        const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text);
        const valid = match && (() => {
          const value = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])));
          return value.getUTCFullYear() === Number(match[1])
            && value.getUTCMonth() + 1 === Number(match[2])
            && value.getUTCDate() === Number(match[3]);
        })();
        return valid ? {value: text} : {
          value: raw, error: `${label} must be an ISO date (YYYY-MM-DD); uncheck it to omit it.`,
        };
      }
      if (type === "boolean") {
        if (text === "true") return {value: true};
        if (text === "false") return {value: false};
        return {value: raw, error: `${label} must be true or false.`};
      }
      if (type === "integer") {
        if (/^-?\d+$/.test(text)) return {value: Number.parseInt(text, 10)};
        return {value: raw, error: `${label} must be an integer.`};
      }
      if (["float", "number"].includes(type)) {
        const value = Number(text);
        if (text !== "" && Number.isFinite(value)) return {value};
        return {value: raw, error: `${label} must be a number.`};
      }
      // Decimal values remain strings so API clients do not lose precision.
      if (type === "decimal" && text !== "" && !/^-?(?:\d+(?:\.\d*)?|\.\d+)$/.test(text)) {
        return {value: raw, error: `${label} must be a decimal number.`};
      }
      if (type === "epoch_datetime") {
        if (/^-?\d+$/.test(text)) return {value: Number.parseInt(text, 10)};
        return {value: raw, error: `${label} must be epoch seconds.`};
      }
      if (["json", "object", "array"].includes(type)) {
        try {
          const value = JSON.parse(text);
          if (type === "array" && !Array.isArray(value)) throw new Error("array");
          if (type === "object" && (!value || Array.isArray(value) || typeof value !== "object")) throw new Error("object");
          return {value};
        } catch (_error) {
          return {value: raw, error: `${label} must be valid JSON${type === "json" ? "" : ` for an ${type}`}.`};
        }
      }
      return {value: String(raw === undefined ? "" : raw)};
    }

    formValueFor(value, type, label, column) {
      if (value === null || value === undefined) {
        throw new Error(`${label} cannot be represented by this form because it is null.`);
      }
      const normalizedType = String(type || "string").toLowerCase();
      const choices = Array.isArray(column && column.options)
        ? column.options : Array.isArray(column && column.enum) ? column.enum : null;
      if (choices && !choices.some((choice) => String(choice && typeof choice === "object" ? choice.value : choice) === String(value))) {
        throw new Error(`${label} is not an available choice.`);
      }
      if (["json", "object", "array"].includes(normalizedType)) {
        if (normalizedType === "array" && !Array.isArray(value)) throw new Error(`${label} must be an array.`);
        if (normalizedType === "object" && (!isPlainObject(value))) throw new Error(`${label} must be an object.`);
        return JSON.stringify(value);
      }
      if (normalizedType === "boolean") {
        if (value !== true && value !== false && value !== "true" && value !== "false") throw new Error(`${label} must be true or false.`);
        return String(value);
      }
      if (["integer", "epoch_datetime"].includes(normalizedType)) {
        const raw = String(value);
        if (!/^-?\d+$/.test(raw)) throw new Error(`${label} must be an integer.`);
        return raw;
      }
      if (["float", "number", "decimal"].includes(normalizedType)) {
        const raw = String(value);
        const converted = this.coerceValue(raw, normalizedType, label);
        if (converted.error) throw new Error(converted.error);
        return raw;
      }
      if (typeof value !== "string") throw new Error(`${label} must be a string.`);
      const converted = this.coerceValue(value, normalizedType, label);
      if (converted.error) throw new Error(converted.error);
      return value;
    }

    writeAssignmentState(assignments, fields, rules, permission, label) {
      if (!isPlainObject(assignments)) throw new Error(`${label} assignments must be a JSON object.`);
      const rawAssignments = {};
      const included = {};
      Object.entries(assignments).forEach(([name, value]) => {
        const field = fields.get(name);
        const rule = rules && rules[name];
        if (!field || !rule || !rule[permission]) throw new Error(`${label} field ${name} is not writable for this operation.`);
        rawAssignments[name] = this.formValueFor(value, field.type, `${label} ${field.label || name}`, field.column);
        included[name] = true;
      });
      return {assignments: rawAssignments, included};
    }

    writeStateFromPayload(payload) {
      if (!isPlainObject(payload)) throw new Error("The write request must be a JSON object.");
      const unknown = onlyKeys(payload, [
        "operation", "assignments", "filters", "expected_count", "returning",
        "conflict_target", "upsert_update_fields", "relationships",
      ]);
      if (unknown.length) throw new Error(`Unsupported write properties: ${unknown.join(", ")}.`);
      if (typeof payload.operation !== "string" || !this.writeOperations().includes(payload.operation)) {
        throw new Error("Choose an enabled write operation.");
      }

      const operation = payload.operation;
      const fields = new Map(this.rootFields().map((field) => [field.name, field]));
      const contract = this.domain && this.domain.writes || {};
      const permission = ["insert", "upsert"].includes(operation) ? "insertable" : "updatable";
      let assignmentState = {assignments: {}, included: {}};
      if (operation !== "delete") {
        assignmentState = this.writeAssignmentState(
          payload.assignments === undefined ? {} : payload.assignments,
          fields, contract.fields || {}, permission, "Root",
        );
      } else if (Object.prototype.hasOwnProperty.call(payload, "assignments")) {
        throw new Error("Delete JSON cannot include assignments because the delete form cannot represent them.");
      }

      const draft = {
        operation,
        assignments: assignmentState.assignments,
        included: assignmentState.included,
        filters: [],
        expectedCount: payload.expected_count === undefined ? 1 : payload.expected_count,
        returning: [],
        conflictTarget: [],
        updateFields: [],
        relationships: {},
        rawDirty: false,
        response: null,
      };

      if (payload.filters !== undefined) {
        if (!["update", "delete"].includes(operation)) throw new Error(`${humanize(operation)} does not use target filters in this form.`);
        if (!Array.isArray(payload.filters)) throw new Error("filters must be an array.");
        draft.filters = payload.filters.map((filter, index) => {
          if (!isPlainObject(filter)) throw new Error(`Filter ${index + 1} must be a JSON object.`);
          const extra = onlyKeys(filter, ["field", "op", "value"]);
          if (extra.length) throw new Error(`Filter ${index + 1} has unsupported properties: ${extra.join(", ")}.`);
          const field = fields.get(filter.field);
          if (!field) throw new Error(`Filter ${index + 1} must use a public root field.`);
          if (typeof filter.op !== "string" || !/^(eq|ne|gt|gte|lt|lte|in|is_null|not_null)$/.test(filter.op)) {
            throw new Error(`Filter ${index + 1} has an unsupported operator.`);
          }
          const nullOperator = /^(is_null|not_null)$/.test(filter.op);
          if (nullOperator && Object.prototype.hasOwnProperty.call(filter, "value")) throw new Error(`Filter ${index + 1} cannot include a value for ${filter.op}.`);
          if (!nullOperator && !Object.prototype.hasOwnProperty.call(filter, "value")) throw new Error(`Filter ${index + 1} requires a value.`);
          let value = "";
          if (filter.op === "in") {
            if (!Array.isArray(filter.value) || !filter.value.length) throw new Error(`Filter ${index + 1} requires a non-empty value array.`);
            value = filter.value.map((item) => {
              const raw = this.formValueFor(item, field.type, `Filter ${index + 1}`, field.column);
              if (raw.includes(",")) throw new Error(`Filter ${index + 1} contains a value with a comma that this form cannot represent.`);
              return raw;
            }).join(", ");
          } else if (!nullOperator) value = this.formValueFor(filter.value, field.type, `Filter ${index + 1}`, field.column);
          return {field: filter.field, op: filter.op, value};
        });
      } else if (["update", "delete"].includes(operation)) {
        draft.filters = [];
      }

      const arrayField = (name, destination) => {
        if (payload[name] === undefined) return;
        if (!Array.isArray(payload[name]) || payload[name].some((field) => typeof field !== "string" || !fields.has(field))) {
          throw new Error(`${name} must contain only public root field names.`);
        }
        if (new Set(payload[name]).size !== payload[name].length) throw new Error(`${name} cannot repeat a field.`);
        draft[destination] = payload[name].slice();
      };
      arrayField("returning", "returning");
      if (operation === "upsert") {
        arrayField("conflict_target", "conflictTarget");
        arrayField("upsert_update_fields", "updateFields");
      } else if (payload.conflict_target !== undefined || payload.upsert_update_fields !== undefined) {
        throw new Error("Conflict fields can only be represented for an upsert.");
      }

      if (payload.relationships !== undefined) {
        if (!["insert", "update"].includes(operation)) throw new Error(`${humanize(operation)} cannot include related writes in this form.`);
        if (!isPlainObject(payload.relationships)) throw new Error("relationships must be a JSON object.");
        const relationships = new Map(this.writeRelationships());
        Object.entries(payload.relationships).forEach(([name, related]) => {
          const spec = relationships.get(name);
          if (!spec) throw new Error(`${name} is not an available writable relationship.`);
          if (!isPlainObject(related)) throw new Error(`${humanize(name)} must be a JSON object.`);
          const extra = onlyKeys(related, ["operation", "assignments", "returning"]);
          if (extra.length) throw new Error(`${humanize(name)} has unsupported properties: ${extra.join(", ")}.`);
          const nestedOperation = related.operation;
          if (!["insert", "update"].includes(nestedOperation)) throw new Error(`${humanize(name)} requires an insert or update operation.`);
          const nestedWrites = spec.domain.writes || {};
          const nestedFields = new Map(this.relationshipFields(spec).map((field) => [field.name, field]));
          const nested = this.writeAssignmentState(
            related.assignments === undefined ? {} : related.assignments,
            nestedFields, nestedWrites.fields || {},
            nestedOperation === "insert" ? "insertable" : "updatable", humanize(name),
          );
          const state = {
            enabled: true, operation: nestedOperation,
            assignments: nested.assignments, included: nested.included, returning: [],
          };
          if (related.returning !== undefined) {
            if (!Array.isArray(related.returning) || related.returning.some((field) => typeof field !== "string" || !nestedFields.has(field))) {
              throw new Error(`${humanize(name)} returning must contain only public related field names.`);
            }
            if (new Set(related.returning).size !== related.returning.length) throw new Error(`${humanize(name)} returning cannot repeat a field.`);
            state.returning = related.returning.slice();
          }
          draft.relationships[name] = state;
        });
      }

      // Import is intentionally structural. Incomplete requests belong in the
      // form so its correctness panel can guide the next edit; only JSON that
      // cannot be represented by these controls is rejected here.
      return draft;
    }

    loadWritePayloadIntoForm(payload) {
      this.writeState = this.writeStateFromPayload(payload);
      return this.writeState;
    }

    buildWriteRequest() {
      const errors = [];
      const operation = this.writeState.operation;
      const operations = this.writeOperations();
      const payload = {operation};
      if (!operations.includes(operation)) errors.push("Choose an enabled write operation.");
      const fields = new Map(this.rootFields().map((field) => [field.name, field]));
      const contract = this.domain && this.domain.writes || {};
      const permission = ["insert", "upsert"].includes(operation) ? "insertable" : "updatable";
      if (operation !== "delete") {
        payload.assignments = {};
        this.rootFields().forEach((field) => {
          const rule = contract.fields && contract.fields[field.name];
          if (writeFieldRequired(rule, operation) && writeRequiredValueMissing(
            this.writeState.included[field.name], this.writeState.assignments[field.name],
          )) {
            errors.push(`${field.label} (${field.name}) is required for ${operation}.`);
          }
        });
        Object.keys(this.writeState.included).filter((name) => this.writeState.included[name]).forEach((name) => {
          const field = fields.get(name);
          const rule = contract.fields && contract.fields[name];
          if (!field || !rule || !rule[permission]) {
            errors.push(`${name} is not writable for ${operation}.`);
            return;
          }
          const converted = this.coerceValue(this.writeState.assignments[name], field.type, field.label);
          payload.assignments[name] = converted.value;
          if (converted.error) errors.push(converted.error);
        });
        if (!Object.keys(payload.assignments).length) errors.push("Choose at least one assignment.");
      }

      if (["update", "delete"].includes(operation)) {
        payload.filters = this.writeState.filters.map((filter, index) => {
          const field = fields.get(filter.field);
          const item = {field: filter.field, op: filter.op};
          if (!field) errors.push(`Filter ${index + 1} must use a public root field.`);
          if (!/^(eq|ne|gt|gte|lt|lte|in|is_null|not_null)$/.test(filter.op)) errors.push(`Filter ${index + 1} has an unsupported operator.`);
          if (!/^(is_null|not_null)$/.test(filter.op)) {
            if (filter.op === "in") {
              const values = String(filter.value || "").split(",").map((value) => value.trim()).filter(Boolean);
              if (!values.length) errors.push(`Filter ${index + 1} requires one or more values.`);
              item.value = values.map((value) => {
                const converted = this.coerceValue(value, field && field.type || "string", `Filter ${index + 1}`);
                if (converted.error) errors.push(converted.error);
                return converted.value;
              });
            } else {
              if (String(filter.value || "").trim() === "") errors.push(`Filter ${index + 1} requires a value.`);
              const converted = this.coerceValue(filter.value, field && field.type || "string", `Filter ${index + 1}`);
              item.value = converted.value;
              if (converted.error) errors.push(converted.error);
            }
          }
          return item;
        });
        if (!payload.filters.length) errors.push(`${humanize(operation)} requires at least one explicit filter.`);
      }

      const count = Number(this.writeState.expectedCount);
      const operationSpec = contract.operations && contract.operations[operation] || {};
      if (!Number.isInteger(count) || count < 1 || count > 1000) errors.push("Expected affected rows must be an integer from 1 to 1000.");
      else {
        payload.expected_count = count;
        if (count > 1 && !operationSpec.bulk) errors.push("This operation does not permit bulk changes.");
        if (["insert", "upsert"].includes(operation) && count !== 1) errors.push("Insert and upsert must expect exactly one row.");
      }
      if (this.writeState.returning.length) payload.returning = this.writeState.returning.slice();
      if (operation === "upsert") {
        payload.conflict_target = this.writeState.conflictTarget.slice();
        payload.upsert_update_fields = this.writeState.updateFields.slice();
        if (!payload.conflict_target.length) errors.push("Choose at least one conflict target field.");
        if (!payload.upsert_update_fields.length) errors.push("Choose at least one field to update on conflict.");
      }
      const related = {};
      this.writeRelationships().forEach(([name, spec]) => {
        const state = this.writeState.relationships[name];
        if (!state || !state.enabled) return;
        const nestedWrites = spec.domain.writes || {};
        const allowed = new Set(Array.isArray(spec.allowed_ops) ? spec.allowed_ops : []);
        const nestedOperation = state.operation;
        const operationSpec = nestedWrites.operations && nestedWrites.operations[nestedOperation];
        if (!allowed.has(nestedOperation) || !operationSpec || !operationSpec.enabled) {
          errors.push(`${humanize(name)} does not allow ${nestedOperation}.`);
          return;
        }
        if (nestedOperation === "update" && operation !== "update") {
          errors.push(`${humanize(name)} can only be updated with a root update.`);
          return;
        }
        const permission = nestedOperation === "insert" ? "insertable" : "updatable";
        const nestedFields = new Map(this.relationshipFields(spec).map((field) => [field.name, field]));
        const assignments = {};
        nestedFields.forEach((field, fieldName) => {
          const rule = nestedWrites.fields && nestedWrites.fields[fieldName];
          if (writeFieldRequired(rule, nestedOperation) && writeRequiredValueMissing(
            state.included[fieldName], state.assignments[fieldName],
          )) {
            errors.push(`${humanize(name)}: ${field.label} (${fieldName}) is required for ${nestedOperation}.`);
          }
        });
        Object.keys(state.included).filter((field) => state.included[field]).forEach((fieldName) => {
          const field = nestedFields.get(fieldName);
          const rule = nestedWrites.fields && nestedWrites.fields[fieldName];
          if (!field || !rule || !rule[permission]) {
            errors.push(`${humanize(name)}: ${fieldName} is not writable for ${nestedOperation}.`);
            return;
          }
          const converted = this.coerceValue(
            state.assignments[fieldName], field.type, `${humanize(name)}: ${field.label}`,
          );
          assignments[fieldName] = converted.value;
          if (converted.error) errors.push(converted.error);
        });
        if (!Object.keys(assignments).length) {
          errors.push(`${humanize(name)} requires at least one assignment.`);
        }
        related[name] = {operation: nestedOperation, assignments};
        if (state.returning && state.returning.length) related[name].returning = state.returning.slice();
      });
      if (Object.keys(related).length) payload.relationships = related;
      return {payload, errors};
    }

    actionInputValues(specs, rawValues, errors, prefix) {
      const values = {};
      this.actionInputSpecs(specs).forEach((spec) => {
        const label = `${prefix}${spec.label || humanize(spec.id)}`;
        const raw = rawValues[spec.id];
        const text = String(raw === undefined ? "" : raw).trim();
        if (!text) {
          if (spec.required) errors.push(`${label} is required.`);
          return;
        }
        let value = text;
        if (spec.type === "number") {
          const converted = this.coerceValue(text, "number", label);
          value = converted.value;
          if (converted.error) errors.push(converted.error);
          if (!converted.error && spec.minimum !== undefined && value < Number(spec.minimum)) errors.push(`${label} is below its minimum.`);
          if (!converted.error && spec.maximum !== undefined && value > Number(spec.maximum)) errors.push(`${label} is above its maximum.`);
        }
        if (spec.type === "lookup" && spec.value_type === "integer") {
          const converted = this.coerceValue(text, "integer", label);
          value = converted.value;
          if (converted.error) errors.push(converted.error);
        }
        if (spec.type === "select" && Array.isArray(spec.options) && spec.options.length
          && !spec.options.some((option) => String(option.value) === text)) errors.push(`${label} is not an available choice.`);
        if (spec.min_length !== undefined && text.length < Number(spec.min_length)) errors.push(`${label} is too short.`);
        if (spec.max_length !== undefined && text.length > Number(spec.max_length)) errors.push(`${label} is too long.`);
        values[spec.id] = value;
      });
      return values;
    }

    parseTargetIds(raw, errors, label) {
      const parts = String(raw || "").split(/[\s,]+/).map((value) => value.trim()).filter(Boolean);
      if (!parts.length) errors.push(`${label} requires at least one ID.`);
      const integerIds = (this.domain && this.domain.source && this.domain.source.columns
        && (this.domain.source.columns[this.domain.source.primary_key] || {}).type) === "integer";
      const ids = parts.map((value) => {
        if (integerIds && !/^\d+$/.test(value)) {
          errors.push(`${label} contains an invalid integer ID.`);
          return value;
        }
        return integerIds ? Number.parseInt(value, 10) : value;
      });
      if (new Set(ids.map(String)).size !== ids.length) errors.push(`${label} contains a repeated ID.`);
      if (ids.length > 1000) errors.push(`${label} exceeds the 1000-row action limit.`);
      return ids;
    }

    buildActionRequest() {
      const errors = [];
      const action = this.selectedAction();
      if (!action) return {path: this.actionPath, payload: {target: {ids: []}, inputs: {}}, errors: ["Choose an available action."]};
      const payload = {
        target: {ids: []},
        inputs: this.actionInputValues(action.inputs, this.actionState.inputs, errors, ""),
      };
      if (this.actionUsesGroups(action)) {
        const maximum = Number(action.selection.max_groups || 6);
        if (!this.actionState.groups.length) errors.push("Create at least one target group.");
        if (this.actionState.groups.length > maximum) errors.push(`This action allows at most ${maximum} groups.`);
        payload.groups = this.actionState.groups.map((group, index) => {
          const ids = this.parseTargetIds(group.ids, errors, `Group ${index + 1}`);
          payload.target.ids.push(...ids);
          return {
            index,
            selected_ids: ids,
            inputs: this.actionInputValues(action.selection.group_inputs, group.inputs, errors, `Group ${index + 1}: `),
          };
        });
        if (new Set(payload.target.ids.map(String)).size !== payload.target.ids.length) errors.push("A target ID may appear in only one group.");
      } else {
        payload.target.ids = this.parseTargetIds(this.actionState.targetIds, errors, "Action target");
      }
      const path = this.actionPath.replace("{action}", encodeURIComponent(action.id));
      return {path, payload, errors};
    }

    actionInputState(specs, values, label) {
      if (!isPlainObject(values)) throw new Error(`${label}inputs must be a JSON object.`);
      const specifications = new Map(this.actionInputSpecs(specs).map((spec) => [spec.id, spec]));
      const unknown = Object.keys(values).filter((name) => !specifications.has(name));
      if (unknown.length) throw new Error(`${label}unsupported inputs: ${unknown.join(", ")}.`);
      const raw = {};
      Object.entries(values).forEach(([name, value]) => {
        const spec = specifications.get(name);
        if (value === null || value === undefined || typeof value === "object") {
          throw new Error(`${label}${spec.label || humanize(name)} must be a scalar value.`);
        }
        if (String(value).trim() === "") throw new Error(`${label}${spec.label || humanize(name)} cannot be blank in imported JSON.`);
        raw[name] = String(value);
      });
      return raw;
    }

    actionIdsState(ids, label) {
      if (!Array.isArray(ids) || !ids.length) throw new Error(`${label} requires a non-empty IDs array.`);
      const integerIds = (this.domain && this.domain.source && this.domain.source.columns
        && (this.domain.source.columns[this.domain.source.primary_key] || {}).type) === "integer";
      return ids.map((value) => {
        if (integerIds && !/^\d+$/.test(String(value))) throw new Error(`${label} contains an invalid integer ID.`);
        if (!integerIds && !["string", "number"].includes(typeof value)) throw new Error(`${label} contains an ID this form cannot represent.`);
        const raw = String(value);
        if (/[\s,]/.test(raw)) throw new Error(`${label} contains an ID with whitespace or a comma that this form cannot represent.`);
        return raw;
      });
    }

    actionStateFromPayload(payload) {
      if (!isPlainObject(payload)) throw new Error("The action request must be a JSON object.");
      const unknown = onlyKeys(payload, ["target", "inputs", "groups"]);
      if (unknown.length) throw new Error(`Unsupported action properties: ${unknown.join(", ")}.`);
      const action = this.selectedAction();
      if (!action) throw new Error("Choose an action before loading its JSON.");
      if (!isPlainObject(payload.target) || onlyKeys(payload.target, ["ids"]).length || !Object.prototype.hasOwnProperty.call(payload.target, "ids")) {
        throw new Error("target must be an object containing only ids.");
      }
      if (!Object.prototype.hasOwnProperty.call(payload, "inputs")) throw new Error("inputs must be provided as a JSON object.");
      const targetIds = this.actionIdsState(payload.target.ids, "Action target");
      const draft = {
        id: action.id,
        targetIds: "",
        inputs: this.actionInputState(action.inputs, payload.inputs, ""),
        groups: [],
        rawDirty: false,
        response: null,
      };
      if (this.actionUsesGroups(action)) {
        if (!Array.isArray(payload.groups) || !payload.groups.length) throw new Error("This action requires a non-empty groups array.");
        draft.groups = payload.groups.map((group, index) => {
          if (!isPlainObject(group)) throw new Error(`Group ${index + 1} must be a JSON object.`);
          const extra = onlyKeys(group, ["index", "selected_ids", "inputs"]);
          if (extra.length) throw new Error(`Group ${index + 1} has unsupported properties: ${extra.join(", ")}.`);
          if (group.index !== index) throw new Error(`Group ${index + 1} must use index ${index}.`);
          if (!Object.prototype.hasOwnProperty.call(group, "selected_ids")) throw new Error(`Group ${index + 1} requires selected_ids.`);
          if (!Object.prototype.hasOwnProperty.call(group, "inputs")) throw new Error(`Group ${index + 1} requires inputs.`);
          return {
            ids: this.actionIdsState(group.selected_ids, `Group ${index + 1}`).join(", "),
            inputs: this.actionInputState(action.selection.group_inputs, group.inputs, `Group ${index + 1}: `),
          };
        });
        const groupedIds = draft.groups.flatMap((group) => group.ids.split(/,\s*/));
        if (targetIds.length !== groupedIds.length || targetIds.some((id, index) => id !== groupedIds[index])) {
          throw new Error("target.ids must match the grouped selected_ids in the same order.");
        }
      } else {
        if (payload.groups !== undefined) throw new Error("The selected action does not use target groups.");
        draft.targetIds = targetIds.join(", ");
      }

      const previous = this.actionState;
      this.actionState = draft;
      let model;
      try {
        model = this.buildActionRequest();
      } finally {
        this.actionState = previous;
      }
      if (model.errors.length) throw new Error(model.errors.join(" "));
      return draft;
    }

    loadActionPayloadIntoForm(payload) {
      this.actionState = this.actionStateFromPayload(payload);
      return this.actionState;
    }

    renderCorrectness(target, errors, success) {
      target.replaceChildren();
      if (!errors.length) {
        target.dataset.kind = "success";
        target.append(element("strong", "", success));
        return;
      }
      target.dataset.kind = "error";
      target.append(element("strong", "", `${errors.length} correction${errors.length === 1 ? "" : "s"} needed`));
      const list = element("ul", "");
      errors.forEach((error) => list.append(element("li", "", error)));
      target.append(list);
    }

    setMutationImportMessage(kind, message, messageKind) {
      const target = this.root.querySelector(`[data-sac-${kind}-import-message]`);
      if (!target) return;
      target.textContent = message || "";
      target.dataset.kind = messageKind || "";
      target.hidden = !message;
    }

    manualMutationModel(kind) {
      const isWrite = kind === "write";
      const editor = this.root.querySelector(isWrite ? "[data-sac-write-request]" : "[data-sac-action-request]");
      const errors = [];
      let payload = {};
      try {
        payload = JSON.parse(editor.value);
        if (!isPlainObject(payload)) errors.push(`The ${kind} request must be a JSON object.`);
      } catch (error) {
        errors.push(`Invalid JSON: ${error.message}`);
      }
      const action = isWrite ? null : this.selectedAction();
      if (!isWrite && !action) errors.push("Choose an action before sending its JSON.");
      return {
        payload,
        path: isWrite ? this.writePath : this.actionPath.replace("{action}", encodeURIComponent(action && action.id || "")),
        errors,
        manual: true,
      };
    }

    loadMutationRequestIntoForm(kind) {
      const isWrite = kind === "write";
      const editor = this.root.querySelector(isWrite ? "[data-sac-write-request]" : "[data-sac-action-request]");
      let payload;
      try {
        payload = JSON.parse(editor.value);
        if (isWrite) this.loadWritePayloadIntoForm(payload);
        else this.loadActionPayloadIntoForm(payload);
      } catch (error) {
        const state = isWrite ? this.writeState : this.actionState;
        state.rawDirty = true;
        const badge = this.root.querySelector(isWrite ? "[data-sac-write-edited]" : "[data-sac-action-edited]");
        if (badge) badge.hidden = false;
        if (isWrite) this.syncWriteRequest();
        else this.syncActionRequest();
        this.setMutationImportMessage(kind, `The ${kind} form cannot represent this JSON: ${error.message} The pasted JSON is unchanged and can still be sent in manual mode for server-side validation.`, "error");
        return false;
      }
      if (isWrite) this.renderWritePanel();
      else this.renderActionPanel();
      this.setMutationImportMessage(kind, `${humanize(kind)} form updated from the request JSON.`, "success");
      return true;
    }

    resetMutationJSON(kind) {
      const state = kind === "write" ? this.writeState : this.actionState;
      state.rawDirty = false;
      this.setMutationImportMessage(kind, "", "");
      return kind === "write" ? this.syncWriteRequest(true) : this.syncActionRequest(true);
    }

    mutationFormChanged(kind, render) {
      const state = kind === "write" ? this.writeState : this.actionState;
      state.rawDirty = false;
      this.setMutationImportMessage(kind, "", "");
      if (render) return kind === "write" ? this.renderWritePanel() : this.renderActionPanel();
      return kind === "write" ? this.syncWriteRequest(true) : this.syncActionRequest(true);
    }

    syncWriteRequest(force) {
      const editor = this.root.querySelector("[data-sac-write-request]");
      const badge = this.root.querySelector("[data-sac-write-edited]");
      if (this.writeState.rawDirty && !force) {
        const manual = this.manualMutationModel("write");
        this.renderCorrectness(this.root.querySelector("[data-sac-write-correctness]"), manual.errors, "Valid JSON in manual mode; the server will enforce the governed write contract.");
        this.root.querySelector("[data-sac-run-write]").disabled = Boolean(manual.errors.length);
        if (badge) badge.hidden = false;
        this.updateMutationCurl("write", manual.path);
        return manual;
      }
      const model = this.buildWriteRequest();
      editor.value = JSON.stringify(model.payload, null, 2);
      this.writeState.rawDirty = false;
      if (badge) badge.hidden = true;
      if (force) this.setMutationImportMessage("write", "", "");
      this.renderCorrectness(this.root.querySelector("[data-sac-write-correctness]"), model.errors, "This request matches the governed write contract.");
      this.root.querySelector("[data-sac-run-write]").disabled = Boolean(model.errors.length);
      this.updateMutationCurl("write", this.writePath);
      return model;
    }

    syncActionRequest(force) {
      const editor = this.root.querySelector("[data-sac-action-request]");
      const badge = this.root.querySelector("[data-sac-action-edited]");
      if (this.actionState.rawDirty && !force) {
        const manual = this.manualMutationModel("action");
        this.root.querySelector("[data-sac-action-path]").textContent = manual.path;
        this.renderCorrectness(this.root.querySelector("[data-sac-action-correctness]"), manual.errors, "Valid JSON in manual mode; the server will enforce the published action contract.");
        this.root.querySelector("[data-sac-run-action]").disabled = Boolean(manual.errors.length);
        if (badge) badge.hidden = false;
        this.updateMutationCurl("action", manual.path);
        return manual;
      }
      const model = this.buildActionRequest();
      editor.value = JSON.stringify(model.payload, null, 2);
      this.actionState.rawDirty = false;
      if (badge) badge.hidden = true;
      if (force) this.setMutationImportMessage("action", "", "");
      this.root.querySelector("[data-sac-action-path]").textContent = model.path;
      this.renderCorrectness(this.root.querySelector("[data-sac-action-correctness]"), model.errors, "This request matches the published action inputs.");
      this.root.querySelector("[data-sac-run-action]").disabled = Boolean(model.errors.length);
      this.updateMutationCurl("action", model.path);
      return model;
    }

    async runMutation(kind) {
      const isWrite = kind === "write";
      const model = isWrite ? this.syncWriteRequest() : this.syncActionRequest();
      if (model.errors.length) return;
      const path = isWrite ? this.writePath : model.path;
      const button = this.root.querySelector(isWrite ? "[data-sac-run-write]" : "[data-sac-run-action]");
      const status = this.root.querySelector(isWrite ? "[data-sac-write-status]" : "[data-sac-action-status]");
      const output = this.root.querySelector(isWrite ? "[data-sac-write-response]" : "[data-sac-action-response]");
      button.disabled = true;
      button.classList.add("is-running");
      status.textContent = "Sending…";
      status.dataset.kind = "running";
      const started = performance.now();
      try {
        const response = await fetch(path, {
          method: "POST", credentials: "same-origin",
          headers: {"Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": this.csrfToken},
          body: JSON.stringify(model.payload),
        });
        const text = await response.text();
        let payload;
        try {
          payload = text ? JSON.parse(text) : null;
        } catch (_error) {
          payload = {ok: false, error: {code: "invalid_response", message: text || "Empty response", details: {}}};
        }
        output.textContent = JSON.stringify(payload, null, 2);
        status.textContent = `${response.status} ${response.statusText} · ${Math.round(performance.now() - started)} ms`;
        status.dataset.kind = response.ok ? "success" : "error";
        if (isWrite) this.writeState.response = payload;
        else this.actionState.response = payload;
      } catch (error) {
        output.textContent = JSON.stringify({ok: false, error: {code: "network_error", message: error.message, details: {}}}, null, 2);
        status.textContent = "Network error";
        status.dataset.kind = "error";
      } finally {
        button.classList.remove("is-running");
        button.disabled = Boolean((isWrite ? this.syncWriteRequest() : this.syncActionRequest()).errors.length);
      }
    }

    onClick(event) {
      const mainTab = event.target.closest("[data-sac-main-tab]");
      if (mainTab) return this.switchMainTab(mainTab.dataset.sacMainTab);
      const resultTab = event.target.closest("[data-sac-result-tab]");
      if (resultTab) return this.switchResultTab(resultTab.dataset.sacResultTab);
      const addField = event.target.closest("[data-sac-add-field]");
      if (addField) {
        this.state.selectedFields.push(this.newSelectedField(addField.dataset.sacAddField));
        this.changed();
        return;
      }
      const fieldAction = event.target.closest("[data-sac-field-action]");
      if (fieldAction) return this.moveField(fieldAction.closest("[data-selection-id]").dataset.selectionId, fieldAction.dataset.sacFieldAction);
      const addFilter = event.target.closest("[data-sac-add-filter]");
      if (addFilter) {
        const initialField = this.filterFieldMap.get(addFilter.dataset.sacAddFilter);
        if (!initialField || this.state.filters.some((filter) => filter.field === initialField.path)) return;
        this.state.filters.push({
          id: String(this.nextFilterId++),
          field: initialField.path,
          op: initialField.filterChoices ? "in" : "eq",
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
      if (event.target.closest("[data-sac-load-json]")) return this.loadRequestIntoChooser();
      if (event.target.closest("[data-sac-reset-json]")) return this.syncRequest(true);
      if (event.target.closest("[data-sac-run]")) return this.run();
      if (event.target.closest("[data-sac-add-write-filter]")) {
        const primaryKey = this.domain && this.domain.source && this.domain.source.primary_key || "id";
        this.writeState.filters.push({field: primaryKey, op: "eq", value: ""});
        return this.mutationFormChanged("write", true);
      }
      const removeWriteFilter = event.target.closest("[data-sac-remove-write-filter]");
      if (removeWriteFilter) {
        this.writeState.filters.splice(Number(removeWriteFilter.dataset.sacRemoveWriteFilter), 1);
        return this.mutationFormChanged("write", true);
      }
      if (event.target.closest("[data-sac-add-action-group]")) {
        this.actionState.groups.push({ids: "", inputs: {}});
        return this.mutationFormChanged("action", true);
      }
      const removeActionGroup = event.target.closest("[data-sac-remove-action-group]");
      if (removeActionGroup) {
        this.actionState.groups.splice(Number(removeActionGroup.dataset.sacRemoveActionGroup), 1);
        return this.mutationFormChanged("action", true);
      }
      if (event.target.closest("[data-sac-load-write-json]")) return this.loadMutationRequestIntoForm("write");
      if (event.target.closest("[data-sac-reset-write-json]")) return this.resetMutationJSON("write");
      if (event.target.closest("[data-sac-load-action-json]")) return this.loadMutationRequestIntoForm("action");
      if (event.target.closest("[data-sac-reset-action-json]")) return this.resetMutationJSON("action");
      if (event.target.closest("[data-sac-run-write]")) return this.runMutation("write");
      if (event.target.closest("[data-sac-run-action]")) return this.runMutation("action");
      if (event.target.closest("[data-sac-copy-write]")) return this.copy(this.root.querySelector("[data-sac-write-request]").value, event.target);
      if (event.target.closest("[data-sac-copy-action]")) return this.copy(this.root.querySelector("[data-sac-action-request]").value, event.target);
      if (event.target.closest("[data-sac-copy-write-curl]")) return this.copy(this.root.querySelector("[data-sac-write-curl]").textContent, event.target);
      if (event.target.closest("[data-sac-copy-action-curl]")) return this.copy(this.root.querySelector("[data-sac-action-curl]").textContent, event.target);
      if (event.target.closest("[data-sac-copy-request]")) return this.copy(this.root.querySelector("[data-sac-request]").value, event.target);
      if (event.target.closest("[data-sac-copy-response]")) return this.copy(this.root.querySelector("[data-sac-response-json]").textContent, event.target);
      if (event.target.closest("[data-sac-copy-curl]")) return this.copy(this.root.querySelector("[data-sac-curl]").textContent, event.target);
      if (event.target.closest("[data-sac-copy-domain]")) return this.copy(JSON.stringify(this.domain, null, 2), event.target);
      if (event.target.closest("[data-sac-copy-openapi]")) return this.copy(JSON.stringify(this.openapi, null, 2), event.target);
    }

    onChange(event) {
      const target = event.target;
      if (target.matches("[data-sac-write-operation]")) {
        this.writeState.operation = target.value;
        this.writeState.assignments = {};
        this.writeState.included = {};
        this.writeState.conflictTarget = [];
        this.writeState.updateFields = [];
        if (["update", "delete"].includes(target.value) && !this.writeState.filters.length) {
          const primaryKey = this.domain && this.domain.source && this.domain.source.primary_key || "id";
          this.writeState.filters = [{field: primaryKey, op: "eq", value: ""}];
        }
        return this.mutationFormChanged("write", true);
      }
      if (target.matches("[data-sac-write-relationship]")) {
        this.writeState.relationships[target.dataset.sacWriteRelationship].enabled = target.checked;
        return this.mutationFormChanged("write", true);
      }
      if (target.matches("[data-sac-write-relationship-operation]")) {
        const state = this.writeState.relationships[target.dataset.sacWriteRelationshipOperation];
        state.operation = target.value;
        state.assignments = {};
        state.included = {};
        return this.mutationFormChanged("write", true);
      }
      if (target.matches("[data-sac-write-relationship-include]")) {
        const state = this.writeState.relationships[target.dataset.sacWriteRelationshipInclude];
        state.included[target.dataset.field] = target.checked;
        return this.mutationFormChanged("write", true);
      }
      if (target.matches("[data-sac-write-include]")) {
        this.writeState.included[target.dataset.sacWriteInclude] = target.checked;
        return this.mutationFormChanged("write", true);
      }
      if (target.matches("[data-sac-write-returning]")) {
        this.writeState.returning = Array.from(target.selectedOptions).map((option) => option.value);
        return this.mutationFormChanged("write", false);
      }
      if (target.matches("[data-sac-write-relationship-returning]")) {
        this.writeState.relationships[target.dataset.sacWriteRelationshipReturning].returning = Array.from(target.selectedOptions).map((option) => option.value);
        return this.mutationFormChanged("write", false);
      }
      if (target.matches("[data-sac-write-conflict]")) {
        this.writeState.conflictTarget = Array.from(target.selectedOptions).map((option) => option.value);
        return this.mutationFormChanged("write", false);
      }
      if (target.matches("[data-sac-write-update-fields]")) {
        this.writeState.updateFields = Array.from(target.selectedOptions).map((option) => option.value);
        return this.mutationFormChanged("write", false);
      }
      if (target.matches("[data-sac-write-filter-field]")) {
        this.writeState.filters[Number(target.closest("[data-write-filter-index]").dataset.writeFilterIndex)].field = target.value;
        return this.mutationFormChanged("write", true);
      }
      if (target.matches("[data-sac-write-filter-op]")) {
        const filter = this.writeState.filters[Number(target.closest("[data-write-filter-index]").dataset.writeFilterIndex)];
        filter.op = target.value;
        return this.mutationFormChanged("write", true);
      }
      if (target.matches("[data-sac-action-id]")) {
        this.actionState = {id: target.value, targetIds: "", inputs: {}, groups: [], rawDirty: false, response: null};
        this.ensureActionGroups();
        return this.mutationFormChanged("action", true);
      }
      if (target.matches("[data-sac-action-input]")) {
        this.actionState.inputs[target.dataset.sacActionInput] = target.value;
        return this.mutationFormChanged("action", false);
      }
      if (target.matches("[data-sac-action-group-input]")) {
        this.actionState.groups[Number(target.dataset.groupIndex)].inputs[target.dataset.sacActionGroupInput] = target.value;
        return this.mutationFormChanged("action", false);
      }
      if (target.matches("[data-sac-mode]")) this.state.mode = target.value;
      else if (target.matches("[data-sac-projection]")) this.state.projection = target.value;
      else if (target.matches("[data-sac-view]")) this.state.view = target.value;
      else if (target.matches("[data-sac-segments]")) {
        this.setUngroupedSegments(Array.from(target.selectedOptions).map((option) => option.value));
      }
      else if (target.matches("[data-sac-segment-group]")) {
        if (!this.setSegmentGroupChoice(target.dataset.sacSegmentGroup, target.value)) return;
      }
      else if (target.matches("[data-sac-ordering]")) this.state.ordering = target.value;
      else if (target.matches("[data-sac-row-format]")) this.state.rowFormat = target.value;
      else if (target.matches("[data-sac-response-format]")) {
        const previous = this.responseFormat(this.state.responseFormat);
        this.state.responseFormat = target.value;
        const format = this.responseFormat(this.state.responseFormat);
        const oldSuffix = `.${previous.extension}`;
        this.state.responseFilename = this.state.responseFilename.toLowerCase().endsWith(oldSuffix.toLowerCase())
          ? `${this.state.responseFilename.slice(0, -oldSuffix.length)}.${format.extension}`
          : suggestedDownloadFilename(this.domain && this.domain.name, format.extension);
        this.renderResponseFileOptions();
        this.updateCurl();
        return;
      }
      else if (target.matches("[data-sac-field-format]")) {
        const selection = this.selectedFieldFor(target);
        selection.format = target.value;
      }
      else if (target.matches("[data-sac-subtable]")) {
        const values = new Set(this.state.subtables);
        if (target.checked) values.add(target.value);
        else values.delete(target.value);
        this.state.subtables = Array.from(values).sort();
      }
      else if (target.matches("[data-sac-filter-op]")) {
        const filter = this.filterFor(target);
        filter.op = target.value;
        const field = this.filterFieldMap.get(filter.field);
        if (filter.op === "date_shortcut") filter.value = "this_week";
        else if (field && field.type === "boolean") filter.value = "true";
        else filter.value = "";
        filter.end = "";
      } else if (target.matches("[data-sac-filter-value]")) {
        this.filterFor(target).value = target.multiple
          ? Array.from(target.selectedOptions).map((option) => option.value).join(", ")
          : target.value;
        this.syncRequest(true);
        return;
      } else if (target.matches("[data-sac-order-field]")) this.orderFor(target).field = target.value;
      else if (target.matches("[data-sac-order-direction]")) this.orderFor(target).direction = target.value;
      else return;
      this.changed();
    }

    onInput(event) {
      const target = event.target;
      if (target.matches("[data-sac-write-field]")) {
        this.writeState.assignments[target.dataset.sacWriteField] = target.value;
        return this.mutationFormChanged("write", false);
      }
      if (target.matches("[data-sac-write-relationship-field]")) {
        const state = this.writeState.relationships[target.dataset.sacWriteRelationshipField];
        state.assignments[target.dataset.field] = target.value;
        return this.mutationFormChanged("write", false);
      }
      if (target.matches("[data-sac-write-expected]")) {
        this.writeState.expectedCount = target.value;
        return this.mutationFormChanged("write", false);
      }
      if (target.matches("[data-sac-write-filter-value]")) {
        this.writeState.filters[Number(target.closest("[data-write-filter-index]").dataset.writeFilterIndex)].value = target.value;
        return this.mutationFormChanged("write", false);
      }
      if (target.matches("[data-sac-action-target-ids]")) {
        this.actionState.targetIds = target.value;
        return this.mutationFormChanged("action", false);
      }
      if (target.matches("[data-sac-action-group-ids]")) {
        this.actionState.groups[Number(target.dataset.sacActionGroupIds)].ids = target.value;
        return this.mutationFormChanged("action", false);
      }
      if (target.matches("[data-sac-action-input]")) {
        this.actionState.inputs[target.dataset.sacActionInput] = target.value;
        return this.mutationFormChanged("action", false);
      }
      if (target.matches("[data-sac-action-group-input]")) {
        this.actionState.groups[Number(target.dataset.groupIndex)].inputs[target.dataset.sacActionGroupInput] = target.value;
        return this.mutationFormChanged("action", false);
      }
      if (target.matches("[data-sac-write-request]")) {
        this.writeState.rawDirty = true;
        this.setMutationImportMessage("write", "", "");
        return this.syncWriteRequest();
      }
      if (target.matches("[data-sac-action-request]")) {
        this.actionState.rawDirty = true;
        this.setMutationImportMessage("action", "", "");
        return this.syncActionRequest();
      }
      if (target.matches("[data-sac-field-search]")) return this.renderFieldList();
      if (target.matches("[data-sac-filter-search]")) return this.renderFilterFieldList();
      if (target.matches("[data-sac-response-filename]")) {
        this.state.responseFilename = target.value;
        const validation = validateDownloadFilename(
          this.state.responseFilename, this.responseFormat(this.state.responseFormat),
        );
        target.setCustomValidity(validation.error);
        this.updateCurl();
        return;
      }
      if (target.matches("[data-sac-request]")) {
        this.state.rawDirty = true;
        this.root.querySelector("[data-sac-edited]").hidden = false;
        this.setImportMessage("", "");
        this.updateCurl();
        return;
      }
      if (target.matches("[data-sac-field-alias]")) {
        this.selectedFieldFor(target).alias = target.value;
      }
      else if (target.matches("[data-sac-parameter]")) this.state.parameters[target.dataset.sacParameter] = target.value;
      else if (target.matches("[data-sac-filter-value]")) this.filterFor(target).value = target.multiple
        ? Array.from(target.selectedOptions).map((option) => option.value).join(", ")
        : target.value;
      else if (target.matches("[data-sac-filter-end]")) this.filterFor(target).end = target.value;
      else if (target.matches("[data-sac-limit]")) this.state.limit = target.value;
      else if (target.matches("[data-sac-offset]")) this.state.offset = target.value;
      else if (target.matches("[data-sac-timezone]")) this.state.timezone = target.value;
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

    selectedFieldFor(target) {
      const id = target.closest("[data-selection-id]").dataset.selectionId;
      return this.state.selectedFields.find((selection) => selection.id === id);
    }

    moveField(id, action) {
      const index = this.state.selectedFields.findIndex((selection) => selection.id === id);
      if (index < 0) return;
      if (action === "configure") {
        this.state.configuredField = this.state.configuredField === id ? "" : id;
        this.renderSelectedFields();
        return;
      }
      if (action === "remove") {
        this.state.selectedFields.splice(index, 1);
        if (this.state.configuredField === id) this.state.configuredField = "";
      }
      if (action === "up" && index > 0) [this.state.selectedFields[index - 1], this.state.selectedFields[index]] = [this.state.selectedFields[index], this.state.selectedFields[index - 1]];
      if (action === "down" && index < this.state.selectedFields.length - 1) [this.state.selectedFields[index + 1], this.state.selectedFields[index]] = [this.state.selectedFields[index], this.state.selectedFields[index + 1]];
      this.changed();
    }

    changed() {
      this.state.rawDirty = false;
      this.setImportMessage("", "");
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
      const format = this.responseFormat(this.state.responseFormat);
      const filenameValidation = validateDownloadFilename(this.state.responseFilename, format);
      if (filenameValidation.error) {
        const filenameInput = this.root.querySelector("[data-sac-response-filename]");
        filenameInput.setCustomValidity(filenameValidation.error);
        if (filenameInput.reportValidity) filenameInput.reportValidity();
        this.setStatus("Invalid download filename", "error");
        this.showLocalError(filenameValidation.error);
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
        const requestPath = format.id === "json"
          ? this.queryPath : pathWithDownloadFilename(this.queryPath, filenameValidation.value);
        response = await fetch(requestPath, {
          method: "POST",
          credentials: "same-origin",
          headers: {"Content-Type": "application/json", Accept: format.mediaType, "X-CSRF-Token": this.csrfToken},
          body: JSON.stringify(request),
        });
        if (response.ok && format.id !== "json") {
          const blob = await response.blob();
          const filename = downloadFilename(
            response.headers.get("Content-Disposition"), filenameValidation.value,
          );
          this.downloadResponse(blob, filename);
          payload = {ok: true, data: {
            download: filename, format: format.id, bytes: blob.size,
          }};
        } else {
          const text = await response.text();
          try {
            payload = text ? JSON.parse(text) : null;
          } catch (_error) {
            payload = {ok: false, error: {code: "invalid_response", message: text || "Empty response", details: {}}};
          }
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

    downloadResponse(blob, filename) {
      const url = global.URL.createObjectURL(blob);
      const link = global.document.createElement("a");
      link.href = url;
      link.download = filename;
      link.hidden = true;
      global.document.body.append(link);
      link.click();
      link.remove();
      global.setTimeout(() => global.URL.revokeObjectURL(url), 0);
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
          columns.forEach((column, index) => resultRow.append(
            element("td", "", renderValue(rowValue(row, column, index)))
          ));
          body.append(resultRow);
        });
      } else {
        const tr = element("tr", "");
        const downloaded = data && data.download;
        const td = element("td", downloaded ? "" : "sac-error-cell", payload && payload.error
          ? `${payload.error.code}: ${payload.error.message}`
          : downloaded ? `Downloaded ${downloaded}` : "No tabular result.");
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
      panel.append(element("span", "sac-kicker", "API Console"), element("h1", "", "Could not load the API"), element("p", "", error.message || String(error)));
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
    version: "0.5.0",
    APIConsole,
    DATE_SHORTCUTS,
    associationIsMany,
    collectFields,
    collectFilterFields,
    operatorsForField,
    compareSemanticFields,
    discoverQueryResponseFormats,
    downloadFilename,
    initialSurfaceTab,
    pathWithDownloadFilename,
    suggestedDownloadFilename,
    validateDownloadFilename,
    normalizeCurlAuth,
    discoverCanonicalAPI,
    mountAll,
    normalizeAPIBase,
    requestPayloadFromLocation,
    operatorsForType,
    writeControlKind,
    writeFieldRequired,
    writeRequiredValueMissing,
    renderValue,
    rowValue,
    segmentParameterSpecs,
  };
  global.SelectoAPIConsole = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  if (typeof global.document !== "undefined" && global.addEventListener) {
    global.addEventListener("DOMContentLoaded", () => mountAll(global.document));
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
