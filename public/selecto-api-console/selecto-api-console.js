(function(global) {
global.SelectoCanonicalClient = (function() {
/** Strict transport validation; host authorization and query policy stay on the host. */
class CanonicalWireError extends Error {
  constructor(path, message, validationReason) {
    super(`${path}: ${message}`);
    this.name = "CanonicalWireError";
    this.code = "invalid_response";
    this.path = path;
    if (validationReason !== undefined) this.validationReason = validationReason;
  }
}

class CanonicalHttpError extends Error {
  constructor(status, envelope) {
    super(envelope.error.message);
    this.name = "CanonicalHttpError";
    this.status = status;
    this.code = envelope.error.code;
    this.details = envelope.error.details;
    this.requestId = envelope.meta?.request_id;
    this.envelope = envelope;
  }
}

// Public local-refusal metadata is independent of wire error codes/messages.
// Only duplicate slots have a broader family; the remaining pairs are exact.
const nestedRefusalFamilies = Object.freeze(Object.assign(Object.create(null), {
  "nested-unavailable": "nested-unavailable",
  "authentication-required": "authentication-required",
  "stale-nested-context": "stale-nested-context",
  "invalid-nested-intent": "invalid-nested-intent",
  "unpublished-field-id": "unpublished-field-id",
  "closed-intent-violation": "closed-intent-violation",
  "duplicate-state-slot": "invalid-nested-state",
  "invalid-nested-state": "invalid-nested-state",
  "state-limit": "state-limit",
  "invalid-selected-raw": "invalid-selected-raw"
}));

function nestedDetailRefusal(error) {
  try {
    const reason = error?.nestedDetailRefusalReason, family = error?.nestedDetailRefusalFamily;
    return typeof reason === "string" && Object.hasOwn(nestedRefusalFamilies, reason) && family === nestedRefusalFamilies[reason] ? {reason, family} : null;
  } catch { return null; }
}

/** Trusted validation branches attach scalar metadata without replacing errors. */
function markNestedDetailRefusal(error, reason) {
  if (!Object.hasOwn(nestedRefusalFamilies, reason)) throw new TypeError("Unknown nested refusal reason");
  if (!(error instanceof Error) || nestedDetailRefusal(error) || !Object.isExtensible(error) || Object.hasOwn(error, "nestedDetailRefusalReason") || Object.hasOwn(error, "nestedDetailRefusalFamily")) return error;
  Object.defineProperties(error, {
    nestedDetailRefusalReason: {value: reason},
    nestedDetailRefusalFamily: {value: nestedRefusalFamilies[reason]}
  });
  return error;
}

function safePath(value) {
  if (typeof value !== "string" || !/^\/(?!\/)[A-Za-z0-9._~!$&'()*+,;=:@%/-]+$/.test(value) || value.includes("//")) {
    throw new CanonicalWireError("path", "expected an absolute same-origin path");
  }
  for (const segment of value.split("/")) {
    let decoded;
    try { decoded = segment; for (let pass = 0; pass < 16; pass++) { const next = decodeURIComponent(decoded); if (next === decoded) break; decoded = next; if (pass === 15) throw new Error("escaping depth"); } } catch { throw new CanonicalWireError("path", "invalid escaping"); }
    // Encoded separators can be interpreted differently by a proxy or host.
    if (decoded === "." || decoded === ".." || /[\\/\u0000-\u0020]/.test(decoded)) {
      throw new CanonicalWireError("path", "unsafe path segment");
    }
  }
  return value;
}

function record(value, path) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new CanonicalWireError(path, "expected an object");
  return value;
}
function nonEmptyString(value, path) {
  if (typeof value !== "string" || !value.length) throw new CanonicalWireError(path, "expected a non-empty string");
  return value;
}
function integer(value, path, minimum = 0) {
  if (!Number.isSafeInteger(value) || value < minimum) throw new CanonicalWireError(path, `expected an integer >= ${minimum}`);
  return value;
}
function bool(value, path) {
  if (typeof value !== "boolean") throw new CanonicalWireError(path, "expected a boolean");
}
function oneOf(value, allowed, path) {
  if (!allowed.includes(value)) throw new CanonicalWireError(path, `expected one of ${allowed.join(", ")}`);
}
function keys(value, allowed, path) {
  record(value, path);
  const extra = Object.keys(value).filter((key) => !allowed.includes(key));
  if (extra.length) throw new CanonicalWireError(path, `unsupported members: ${extra.join(", ")}`);
}
function array(value, path) {
  if (!Array.isArray(value)) throw new CanonicalWireError(path, "expected an array");
  return value;
}
function format(value, expected, path) {
  record(value, path);
  if (value.format !== expected || value.format_version !== 1) throw new CanonicalWireError(path, `expected ${expected} version 1`);
}

function assertCatalog(value) {
  format(value, "selecto.domain-catalog", "catalog");
  const ids = new Set();
  array(value.domains, "catalog.domains").forEach((entry, i) => {
    record(entry, `catalog.domains.${i}`);
    nonEmptyString(entry.id, "catalog.domain.id");
    nonEmptyString(entry.label, "catalog.domain.label");
    nonEmptyString(entry.publication, "catalog.domain.publication");
    safePath(entry.manifest);
    safePath(entry.explorer_metadata);
    if (ids.has(entry.id)) throw new CanonicalWireError("catalog.domains", "duplicate domain id");
    ids.add(entry.id);
  });
  return value;
}

function assertManifest(value) {
  format(value, "selecto.canonical-domain-api", "manifest");
  record(value.domain, "manifest.domain");
  nonEmptyString(value.domain.fingerprint, "manifest.domain.fingerprint");
  const operations = new Set();
  array(value.routes, "manifest.routes").forEach((route) => {
    record(route, "manifest.route");
    nonEmptyString(route.operation_id, "manifest.route.operation_id");
    nonEmptyString(route.method, "manifest.route.method");
    // Parameterized write/action routes are outside the read client.
    if (["queryDomain", "getDomain", "getOpenApi", "getExplorerMetadata", "getDomainCatalog", "getRootPredicateFeatures", "getNestedDetailFeatures"].includes(route.operation_id)) safePath(route.path);
    if (operations.has(route.operation_id)) throw new CanonicalWireError("manifest.routes", "duplicate operation id");
    operations.add(route.operation_id);
  });
  array(value.profiles, "manifest.profiles").forEach((profile) => nonEmptyString(profile, "manifest.profile"));
  if (!value.profiles.includes("remote_query.v1")) throw new CanonicalWireError("manifest.profiles", "remote_query.v1 is required");
  routePath(value, "queryDomain", "POST");
  return value;
}

function routePath(manifest, operation, method) {
  const route = manifest.routes.find((entry) => entry.operation_id === operation && entry.method.toUpperCase() === method);
  if (!route) throw new CanonicalWireError("manifest.routes", `missing ${method} ${operation}`);
  return safePath(route.path);
}

function assertDomain(value, fingerprint) {
  record(value, "domain");
  if (value.domain_fingerprint !== fingerprint) throw new CanonicalWireError("domain.domain_fingerprint", "differs from manifest fingerprint");
  record(value.source, "domain.source");
  record(value.source.columns, "domain.source.columns");
  array(value.source.fields, "domain.source.fields").forEach((field) => nonEmptyString(field, "domain.source.field"));
  return value;
}

function assertError(value) {
  record(value, "error response");
  if (value.ok !== false) throw new CanonicalWireError("error response.ok", "expected false");
  record(value.error, "error response.error");
  nonEmptyString(value.error.code, "error.code");
  nonEmptyString(value.error.message, "error.message");
  record(value.error.details, "error.details");
  if (value.meta !== undefined) {
    record(value.meta, "error.meta");
    if (value.meta.request_id !== undefined) nonEmptyString(value.meta.request_id, "error.meta.request_id");
  }
  return value;
}

const columnTypes = ["integer", "decimal", "string", "boolean", "date", "time", "datetime", "uuid", "binary", "json", "unknown"];
const encodings = ["json", "string", "decimal-string", "rfc3339", "base64"];
function assertColumn(value, path = "column") {
  record(value, path);
  nonEmptyString(value.id, `${path}.id`);
  nonEmptyString(value.label, `${path}.label`);
  oneOf(value.type, columnTypes, `${path}.type`);
  oneOf(value.encoding, encodings, `${path}.encoding`);
  bool(value.nullable, `${path}.nullable`);
  return value;
}

function validDate(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
}
function jsonScalar(value) {
  if (typeof value === "number") return Number.isFinite(value) && (!Number.isInteger(value) || Number.isSafeInteger(value));
  if (value === null || ["string", "boolean"].includes(typeof value)) return true;
  if (Array.isArray(value)) return value.every(jsonScalar);
  return value && typeof value === "object" && Object.values(value).every(jsonScalar);
}
function assertScalar(value, column, path) {
  if (value === null) {
    if (!column.nullable) throw new CanonicalWireError(path, "null in non-nullable column");
    return;
  }
  let valid = false;
  if (column.encoding === "decimal-string") {
    valid = typeof value === "string" && (column.type === "integer" ? /^-?(0|[1-9]\d*)$/ : /^-?(0|[1-9]\d*)(\.\d+)?$/).test(value);
  } else if (column.type === "integer") valid = Number.isSafeInteger(value);
  else if (column.type === "decimal") valid = typeof value === "number" && Number.isFinite(value);
  else if (column.type === "boolean") valid = typeof value === "boolean";
  else if (column.type === "date") valid = typeof value === "string" && validDate(value);
  else if (column.type === "time") valid = typeof value === "string" && /^(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?$/.test(value);
  else if (column.type === "datetime") valid = typeof value === "string" && /^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$/.test(value) && validDate(value.slice(0, 10));
  else if (column.type === "uuid") valid = typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
  else if (column.type === "binary") valid = typeof value === "string" && column.encoding === "base64" && /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value);
  else if (["json", "unknown"].includes(column.type)) valid = jsonScalar(value);
  else valid = typeof value === "string";
  if (!valid) throw new CanonicalWireError(path, `invalid ${column.type}/${column.encoding} value`);
}

function assertQueryResult(value, fingerprint, query = {}) {
  record(value, "response");
  if (value.ok !== true) throw new CanonicalWireError("response.ok", "expected true");
  const data = record(value.data, "response.data");
  format(data, "selecto.remote-query-result", "response.data");
  if (record(data.domain, "response.data.domain").fingerprint !== fingerprint) throw new CanonicalWireError("response.data.domain", "Domain fingerprint drift");
  const columns = array(data.columns, "response.data.columns");
  const ids = new Set();
  columns.forEach((column, i) => {
    assertColumn(column, `columns.${i}`);
    if (ids.has(column.id)) throw new CanonicalWireError("columns", "duplicate column id");
    ids.add(column.id);
  });
  const rowFormat = data.row_format ?? "arrays";
  oneOf(rowFormat, ["arrays", "objects"], "response.data.row_format");
  if (rowFormat !== (query.row_format ?? "arrays")) throw new CanonicalWireError("response.data.row_format", "does not match request");
  const rows = array(data.rows, "response.data.rows");
  rows.forEach((row, i) => {
    if (rowFormat === "arrays") {
      if (!Array.isArray(row) || row.length !== columns.length) throw new CanonicalWireError(`rows.${i}`, "row width differs from columns");
    } else {
      record(row, `rows.${i}`);
      if (Object.keys(row).length !== ids.size || Object.keys(row).some((key) => !ids.has(key))) throw new CanonicalWireError(`rows.${i}`, "row keys differ from columns");
    }
    columns.forEach((column, j) => assertScalar(rowFormat === "arrays" ? row[j] : row[column.id], column, `rows.${i}.${column.id}`));
  });
  if (integer(data.row_count, "response.data.row_count") !== rows.length) throw new CanonicalWireError("row_count", "differs from returned rows");
  record(data.page, "response.data.page");
  integer(data.page.limit, "page.limit", 1);
  integer(data.page.offset, "page.offset");
  bool(data.page.has_more, "page.has_more");
  if (rows.length > data.page.limit || (query.limit !== undefined && query.limit !== data.page.limit) || (query.offset !== undefined && query.offset !== data.page.offset)) throw new CanonicalWireError("page", "does not match requested page");
  return value;
}

function buildRemoteRequest(fingerprint, query, requestId) {
  nonEmptyString(fingerprint, "domain.fingerprint");
  keys(query, ["select", "projection", "view", "filters", "group_by", "segments", "parameters", "order_by", "ordering", "limit", "offset", "timezone", "row_format"], "query");
  if (["select", "projection", "view"].filter((key) => Object.hasOwn(query, key)).length !== 1) throw new CanonicalWireError("query", "exactly one authoring mode is required");
  if (query.select !== undefined) {
    const selected = array(query.select, "query.select");
    if (!selected.length) throw new CanonicalWireError("query.select", "selection cannot be empty");
  }
  if (query.limit !== undefined) { integer(query.limit, "query.limit", 1); if (query.limit > 10000) throw new CanonicalWireError("query.limit", "exceeds protocol maximum"); }
  if (query.offset !== undefined) integer(query.offset, "query.offset");
  if (query.row_format !== undefined) oneOf(query.row_format, ["arrays", "objects"], "query.row_format");
  if (query.timezone !== undefined) nonEmptyString(query.timezone, "query.timezone");
  if (!jsonScalar(query)) throw new CanonicalWireError("query", "must contain finite JSON values");
  const result = {format: "selecto.remote-query", format_version: 1, domain: {fingerprint}, query};
  if (requestId !== undefined) { nonEmptyString(requestId, "request_id"); if (requestId.length > 128) throw new CanonicalWireError("request_id", "too long"); result.request_id = requestId; }
  return result;
}

function createCanonicalClient(options = {}) {
  const baseUrl = safePath((options.baseUrl ?? "/api/v1/selecto").replace(/\/+$/, ""));
  const transport = options.fetch ?? globalThis.fetch;
  async function request(path, init = {}, selected = undefined) {
    const headers = new Headers(typeof options.headers === "function" ? options.headers() : options.headers);
    headers.set("accept", "application/json");
    if (init.body !== undefined) headers.set("content-type", "application/json");
    new Headers(init.headers).forEach((value, key) => headers.set(key, value));
    const response = await transport(safePath(path), {...init, headers, credentials: "same-origin", redirect: "error"});
    const payload = await response.arrayBuffer().then((bytes) => parseStrictJSON(new TextDecoder("utf-8", {fatal:true,ignoreBOM:!!selected}).decode(bytes), {maxBytes: selected ? (response.ok ? 262144 : 8192) : Number.POSITIVE_INFINITY, tokens: !!selected})).catch((error) => {
      if (error?.name === "AbortError") throw error;
      throw new CanonicalWireError("response", "server did not return JSON");
    });
    const decoded = selected ? payload.value : payload;
    if (!response.ok) {
      if (selected?.context) assertNestedDetailError(decoded, selected.context, response.status);
      throw new CanonicalHttpError(response.status, assertError(decoded));
    }
    return {payload:decoded, ...(selected ? {numberTokens:payload.numberTokens} : {}), status: response.status, statusText: response.statusText, headers: response.headers};
  }
  return {
    baseUrl,
    async catalog(signal) { return assertCatalog((await request(options.catalogPath ?? `${baseUrl}/catalog`, {signal})).payload); },
    async manifest(path = `${baseUrl}/`, signal) { return assertManifest((await request(path, {signal})).payload); },
    async domain(manifest, signal) { return assertDomain((await request(routePath(manifest, "getDomain", "GET"), {signal})).payload, manifest.domain.fingerprint); },
    async metadata(path, signal) { return (await request(path, {signal})).payload; },
    async query(manifest, query, requestOptions = {}) {
      assertManifest(manifest);
      const envelope = buildRemoteRequest(requestOptions.fingerprint ?? manifest.domain.fingerprint, query, requestOptions.requestId);
      const result = await request(routePath(manifest, "queryDomain", "POST"), {method: "POST", body: JSON.stringify(envelope), signal: requestOptions.signal});
      assertQueryResult(result.payload, envelope.domain.fingerprint, query);
      return result.payload;
    },
    async nestedDetailFeatures(manifest, signal) {
      assertManifest(manifest);
      if (!manifest.profiles.includes("remote_query.v1")) throw new CanonicalWireError("manifest.profiles", "nested detail unavailable");
      const result = await request(routePath(manifest, "getNestedDetailFeatures", "GET"), {signal}, {featuresOnly:true});
      for (const path of ["/format_version","/request_format_version","/result/format_version"]) if (result.numberTokens.get(path) !== "1") throw new CanonicalWireError("nested.features", "lexical version1 required");
      return assertNestedDetailFeatures(result.payload);
    },
    async queryNestedDetail(manifest, query, requestOptions = {}) {
      const envelope = buildNestedDetailRequest(requestOptions.context?.fingerprint, query, requestOptions);
      return this.queryNestedDetailText(manifest, JSON.stringify(envelope), requestOptions);
    },
    async queryNestedDetailText(manifest, text, requestOptions = {}) {
      assertManifest(manifest);
      if (!manifest.profiles.includes("remote_query.v1") || manifest.domain.fingerprint !== requestOptions.context?.fingerprint) throw new CanonicalWireError("manifest", "nested profile/binding unavailable");
      routePath(manifest, "getNestedDetailFeatures", "GET");
      const parsed = parseNestedDetailRequestText(text, requestOptions);
      const context = nestedDetailContext(requestOptions.features);
      const result = await request(routePath(manifest, "queryDomain", "POST"), {method:"POST",body:parsed.raw,signal:requestOptions.signal,headers:{"Selecto-Nested-Detail-Context":encodeNestedDetailContext(context)}}, {context});
      assertNestedDetailResult(result.payload, {features:requestOptions.features,context,query:parsed.request.query,numberTokens:result.numberTokens});
      if (result.payload.meta.request_id !== parsed.request.request_id) throw new CanonicalWireError("nested.meta.request_id", "request ID echo mismatch");
      return result.payload;
    },
    async rootPredicateFeatures(manifest, signal) {
      if (!manifest.profiles.includes("remote_query.v2")) throw new CanonicalWireError("manifest.profiles", "remote_query.v2 unavailable");
      return assertRootPredicateFeatures((await request(routePath(manifest,"getRootPredicateFeatures","GET"), {signal})).payload);
    },
    async queryRootPredicate(manifest, query, requestOptions = {}) {
      const envelope = buildRootPredicateRequest(requestOptions.fingerprint ?? manifest.domain.fingerprint,query,requestOptions);
      return this.queryText(manifest,JSON.stringify(envelope),requestOptions);
    },
    async queryText(manifest, text, requestOptions = {}) {
      const parsed = parseCanonicalRequestText(text,{manifest,features:requestOptions.features});
      const result = await request(routePath(manifest,"queryDomain","POST"),{method:"POST",body:parsed.raw,signal:requestOptions.signal});
      if (parsed.request.format_version === 2) assertRootPredicateResult(result.payload,{fingerprint:parsed.request.domain.fingerprint,query:parsed.request.query,features:requestOptions.features});
      else assertQueryResult(result.payload,parsed.request.domain.fingerprint,parsed.request.query);
      return result.payload;
    },
    request,
  };
}

/** Unicode scalar validation, without replacing malformed UTF-16. */
function assertUnicode(value, path = "string", maximum = Infinity, allowNul = false) {
  if (typeof value !== "string") throw new CanonicalWireError(path, "expected a string");
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(++i);
      if (!(next >= 0xdc00 && next <= 0xdfff)) throw new CanonicalWireError(path, "unpaired UTF-16 surrogate");
    } else if (code >= 0xdc00 && code <= 0xdfff) throw new CanonicalWireError(path, "unpaired UTF-16 surrogate");
  }
  if (!allowNul && value.includes("\0")) throw new CanonicalWireError(path, "NUL is unavailable");
  if (new TextEncoder().encode(value).length > maximum) throw new CanonicalWireError(path, "UTF-8 byte limit exceeded", "utf8-byte-limit");
  return value;
}

/** Parse structure once, reject decoded duplicate keys, and retain numeric lexemes. */
function parseStrictJSON(text, options = {}) {
  assertUnicode(text, "JSON", options.maxBytes ?? 1048576, true);
  let at = 0;
  const numberTokens = new Map();
  const fail = (message) => { throw new CanonicalWireError("JSON", `${message} at character ${at}`); };
  const space = () => { while (/[\t\n\r ]/.test(text[at] ?? "x")) at++; };
  function string() {
    const start = at++;
    while (at < text.length) {
      const c = text[at++];
      if (c === '"') {
        let value;
        try { value = JSON.parse(text.slice(start, at)); } catch { fail("invalid string"); }
        assertUnicode(value, "JSON string", Infinity, true);
        return value;
      }
      if (c === "\\") at++;
    }
    fail("unterminated string");
  }
  function value(path, depth) {
    if (depth > 128) fail("JSON nesting limit exceeded");
    space(); const c = text[at];
    if (c === '"') return string();
    if (c === "{") {
      at++; space(); const result = {}; const seen = new Set();
      if (text[at] === "}") {at++; return result;}
      while (true) {
        space(); if (text[at] !== '"') fail("object key required");
        const key = string(); if (seen.has(key)) fail(`duplicate key ${JSON.stringify(key)}`); seen.add(key);
        space(); if (text[at++] !== ":") fail("colon required");
        Object.defineProperty(result, key, {value: value(`${path}/${key.replace(/~/g,"~0").replace(/\//g,"~1")}`, depth + 1), enumerable:true, writable:true, configurable:true});
        space(); const next = text[at++]; if (next === "}") return result; if (next !== ",") fail("comma required");
      }
    }
    if (c === "[") {
      at++; space(); const result = []; if (text[at] === "]") {at++; return result;}
      while (true) {
        result.push(value(`${path}/${result.length}`, depth + 1)); space(); const next = text[at++];
        if (next === "]") return result; if (next !== ",") fail("comma required");
      }
    }
    for (const [literal, decoded] of [["true",true],["false",false],["null",null]]) if (text.startsWith(literal, at)) {at += literal.length; return decoded;}
    const token = text.slice(at).match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/);
    if (!token) fail("value required");
    at += token[0].length; numberTokens.set(path, token[0]);
    const decoded = Number(token[0]); if (!Number.isFinite(decoded)) fail("non-finite number"); return decoded;
  }
  const decoded = value("", 0); space(); if (at !== text.length) fail("unexpected trailing input");
  return options.tokens ? {value: decoded, numberTokens} : decoded;
}

const rootOps = ["eq", "ne", "gt", "gte", "lt", "lte", "is_null", "is_not_null"];
const rootLimits = {max_limit:100, default_limit:100, max_offset:100000, default_offset:0, max_nodes:20, max_depth:4, root_depth:1, max_select:100, max_orders:10, max_string_utf8_bytes:16384, max_raw_request_bytes:1048576};
const rootSupports = {where:true, and:true, or:true, flat_filters:false, nested:false, not:false, ranges:false, named_definitions:false, analytics:false};
function exactKeys(value, required, path) {
  keys(value, required, path);
  if (required.some((key) => !Object.hasOwn(value, key))) throw new CanonicalWireError(path, "missing required member");
}
function rootPair(field, path) {
  const allowed = {integer:["json","decimal-string"],decimal:["decimal-string"],string:["string"],boolean:["json"],date:["string"]};
  if (!allowed[field.type]?.includes(field.encoding)) throw new CanonicalWireError(path, "unsupported type/encoding pair");
  if (typeof field.nullable !== "boolean") throw new CanonicalWireError(path, "nullable must be boolean");
}
function canonicalRootFields(domain) {
  record(domain?.source?.columns, "domain.source.columns");
  return array(domain.source.fields, "domain.source.fields").map((path) => {
    const column = record(domain.source.columns[path], `domain.source.columns.${path}`);
    const type = ({int:"integer",bigint:"integer",text:"string",varchar:"string",numeric:"decimal",bool:"boolean"})[column.type] ?? column.type;
    return {path, type, encoding: column.encoding ?? ({integer:"json",decimal:"decimal-string",boolean:"json",string:"string",date:"string"})[type], nullable: column.nullable ?? false};
  });
}

function assertRootPredicateFeatures(value, context) {
  exactKeys(value, ["format","format_version","domain","profile","revision","wire_profile","request_format_version","result","fields","default_select","limits","supports"], "features");
  format(value, "selecto.root-predicate-features", "features");
  if (value.profile !== "canonical_root_predicates.v1" || value.wire_profile !== "remote_query.v2" || value.request_format_version !== 2) throw new CanonicalWireError("features.profile", "unsupported root predicate profile");
  assertUnicode(nonEmptyString(value.revision, "features.revision"), "features.revision");
  exactKeys(value.domain, ["id","fingerprint","publication"], "features.domain");
  Object.values(value.domain).forEach((item) => assertUnicode(nonEmptyString(item,"features.domain"),"features.domain"));
  exactKeys(value.result, ["format","format_version"], "features.result"); format(value.result,"selecto.remote-query-result","features.result");
  for (const [name, expected] of [["limits",rootLimits],["supports",rootSupports]]) {
    exactKeys(value[name],Object.keys(expected),`features.${name}`);
    for (const [key, wanted] of Object.entries(expected)) if (value[name][key] !== wanted) throw new CanonicalWireError(`features.${name}.${key}`, "unsupported capability or bound");
  }
  const ids = new Set(), paths = new Set();
  const fields = array(value.fields,"features.fields"); if (!fields.length) throw new CanonicalWireError("features.fields","empty fields");
  fields.forEach((field, i) => {
    const path = `features.fields.${i}`;
    exactKeys(field,["id","path","label","type","encoding","nullable","operators"],path);
    assertUnicode(nonEmptyString(field.id,`${path}.id`),`${path}.id`,16384);
    assertUnicode(nonEmptyString(field.label,`${path}.label`),`${path}.label`,16384);
    if (typeof field.path !== "string" || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(field.path)) throw new CanonicalWireError(`${path}.path`,"expected public root path");
    rootPair(field,path);
    const ops = array(field.operators,`${path}.operators`);
    const supported = field.type === "boolean" ? ["eq","ne","is_null","is_not_null"] : rootOps;
    if (!ops.length || new Set(ops).size !== ops.length || ops.some((op) => !supported.includes(op))) throw new CanonicalWireError(`${path}.operators`,"unsupported operators");
    if (ids.has(field.id) || paths.has(field.path)) throw new CanonicalWireError(path,"duplicate field ID or path"); ids.add(field.id); paths.add(field.path);
  });
  const selected = array(value.default_select,"features.default_select");
  if (!selected.length || selected.length > 100 || new Set(selected).size !== selected.length || selected.some((id) => !ids.has(id))) throw new CanonicalWireError("features.default_select","unresolved or duplicate default selection");
  if (context) {
    const expected = context.domain ?? context.metadata?.domain;
    if (!expected || ["id","fingerprint","publication"].some((key) => expected[key] !== value.domain[key])) throw new CanonicalWireError("features.domain","publication binding mismatch");
    if ((context.profile !== undefined && context.profile !== value.profile) || (context.revision !== undefined && context.revision !== value.revision)) throw new CanonicalWireError("features.revision","active feature binding mismatch");
    if (context.manifest && (!context.manifest.profiles.includes("remote_query.v2") || context.manifest.domain.fingerprint !== value.domain.fingerprint)) throw new CanonicalWireError("features.domain","manifest binding mismatch");
    const published = context.canonical_fields ?? (context.canonicalDomain ? canonicalRootFields(context.canonicalDomain) : undefined);
    if (!published) throw new CanonicalWireError("features.fields","canonical field context required");
    const byPath = new Map(published.map((field) => [field.path,field]));
    fields.forEach((field) => {
      const actual = byPath.get(field.path);
      if (!actual || ["type","encoding","nullable"].some((key) => actual[key] !== field[key])) throw new CanonicalWireError("features.fields","canonical path/type/codec binding mismatch");
    });
  }
  return value;
}

function assertRootScalar(value, field, path = "value", author = false) {
  rootPair(field,path);
  if (typeof value === "string") assertUnicode(value,path,16384);
  if (author && typeof value !== "string" && typeof value !== "boolean") throw new CanonicalWireError(path,"author scalar must be typed text or boolean");
  let valid = false;
  if (field.type === "integer") {
    if (typeof value === "number") valid = Number.isSafeInteger(value);
    else if (typeof value === "string" && /^(?:0|[1-9]\d*|-[1-9]\d*)$/.test(value)) {
      const exact = BigInt(value); valid = exact >= -9223372036854775808n && exact <= 9223372036854775807n;
    }
  } else if (field.type === "decimal") valid = typeof value === "number" ? Number.isSafeInteger(value) : typeof value === "string" && /^-?(?:0|[1-9]\d*)(?:\.\d+)?$/.test(value);
  else if (field.type === "boolean") valid = typeof value === "boolean";
  else if (field.type === "string") valid = typeof value === "string";
  else if (field.type === "date") valid = typeof value === "string" && !value.startsWith("0000-") && validDate(value);
  if (!valid) throw new CanonicalWireError(path,`invalid exact ${field.type} scalar`);
  return value;
}

function assertRootPredicateQuery(query, features, options = {}) {
  assertRootPredicateFeatures(features);
  keys(query,["select","where","order_by","limit","offset","timezone","row_format"],"query");
  const byPath = new Map(features.fields.map((field) => [field.path,field]));
  const selected = array(query.select,"query.select");
  if (!selected.length || selected.length > 100 || new Set(selected).size !== selected.length || selected.some((path) => !byPath.has(path))) throw new CanonicalWireError("query.select","unresolved, duplicate or excessive root selection");
  let count = 0;
  function node(value, depth, path) {
    record(value,path); if (++count > 20 || depth > 4) throw new CanonicalWireError(path,"predicate node/depth bound exceeded");
    const group = ["and","or"].filter((key) => Object.hasOwn(value,key));
    if (group.length) {
      exactKeys(value,group.length === 1 ? group : [],path);
      const children = array(value[group[0]],path); if (!children.length) throw new CanonicalWireError(path,"empty executable group");
      children.forEach((child,i) => node(child,depth+1,`${path}/${group[0]}/${i}`)); return;
    }
    const nullOp = ["is_null","is_not_null"].includes(value.op);
    exactKeys(value,nullOp ? ["field","op"] : ["field","op","value"],path);
    const field = byPath.get(value.field); if (!field) throw new CanonicalWireError(path,"unresolved root field");
    if (!field.operators.includes(value.op)) throw new CanonicalWireError(path,"operator unavailable for field");
    if (!nullOp) {
      assertRootScalar(value.value,field,`${path}/value`);
      const token = options.numberTokens?.get(`${path}/value`);
      if (token && !/^-?(?:0|[1-9]\d*)$/.test(token)) throw new CanonicalWireError(path,"fraction/exponent numeric token unavailable");
    }
  }
  if (Object.hasOwn(query,"where")) node(query.where,1,"/query/where");
  if (Object.hasOwn(query,"order_by")) {
    const orders = array(query.order_by,"query.order_by"); if (orders.length > 10) throw new CanonicalWireError("query.order_by","order bound exceeded");
    const seen = new Set(); orders.forEach((order) => {exactKeys(order,["field","direction"],"order"); if (!byPath.has(order.field) || seen.has(order.field) || !["asc","desc"].includes(order.direction)) throw new CanonicalWireError("order","invalid or duplicate root order"); seen.add(order.field);});
  }
  for (const [key,max,min] of [["limit",100,1],["offset",100000,0]]) if (Object.hasOwn(query,key)) {
    integer(query[key],`query.${key}`,min); if (query[key] > max) throw new CanonicalWireError(`query.${key}`,"paging bound exceeded");
    const token = options.numberTokens?.get(`/query/${key}`); if (token && !/^(?:0|[1-9]\d*)$/.test(token)) throw new CanonicalWireError(`query.${key}`,"integer token required");
  }
  if (Object.hasOwn(query,"row_format")) oneOf(query.row_format,["arrays","objects"],"query.row_format");
  if (Object.hasOwn(query,"timezone")) assertTimezone(query.timezone);
  return query;
}
function assertTimezone(value) {
  assertUnicode(nonEmptyString(value,"timezone"),"timezone",16384);
  try { new Intl.DateTimeFormat("en-US",{timeZone:value}); } catch { throw new CanonicalWireError("timezone","unknown IANA timezone"); }
  return value;
}
function assertRootRequestId(value) {
  assertUnicode(nonEmptyString(value,"request_id"),"request_id",128);
  if (/[\r\n]/.test(value)) throw new CanonicalWireError("request_id","line breaks unavailable");
}
function buildRootPredicateRequest(fingerprint, query, options = {}) {
  assertUnicode(nonEmptyString(fingerprint,"domain.fingerprint"),"domain.fingerprint");
  if (!options.features) throw new CanonicalWireError("features","root feature context required");
  assertRootPredicateQuery(query,options.features);
  const request = {format:"selecto.remote-query",format_version:2,domain:{fingerprint},query};
  if (options.requestId !== undefined) {assertRootRequestId(options.requestId); request.request_id = options.requestId;}
  parseStrictJSON(JSON.stringify(request));
  return request;
}
function parseCanonicalRequestText(text, context) {
  const {value,numberTokens} = parseStrictJSON(text,{tokens:true});
  exactKeys(value,Object.hasOwn(value,"request_id") ? ["format","format_version","domain","query","request_id"] : ["format","format_version","domain","query"],"request");
  if (value.format !== "selecto.remote-query") throw new CanonicalWireError("request.format","remote envelope required");
  exactKeys(value.domain,["fingerprint"],"request.domain"); assertUnicode(nonEmptyString(value.domain.fingerprint,"request.domain.fingerprint"),"request.domain.fingerprint");
  if (value.request_id !== undefined) assertRootRequestId(value.request_id);
  if (value.format_version === 2) {
    if (numberTokens.get("/format_version") !== "2" || !context.manifest?.profiles.includes("remote_query.v2")) throw new CanonicalWireError("request.format_version","root v2 unavailable or noninteger token");
    if (!context.features) throw new CanonicalWireError("features","root features unavailable");
    assertRootPredicateQuery(value.query,context.features,{numberTokens});
  } else if (value.format_version === 1) buildRemoteRequest(value.domain.fingerprint,value.query,value.request_id);
  else throw new CanonicalWireError("request.format_version","unsupported protocol version");
  return {request:value,raw:text};
}
function assertRootPredicateResult(value, context) {
  const {fingerprint,query,features} = context;
  assertQueryResult(value,fingerprint,query);
  const byPath = new Map(features.fields.map((field) => [field.path,field]));
  if (value.data.columns.length !== query.select.length) throw new CanonicalWireError("response.columns","selection width mismatch");
  value.data.columns.forEach((column,i) => {
    const field = byPath.get(query.select[i]);
    if (!field || column.id !== field.path || column.field !== field.path || column.label !== field.label || column.type !== field.type || column.nullable !== field.nullable || !(column.encoding === field.encoding || (field.type === "integer" && field.encoding === "json" && column.encoding === "decimal-string"))) throw new CanonicalWireError("response.columns","selection/type/codec binding mismatch");

  });
  if (value.data.page.limit !== (query.limit ?? 100) || value.data.page.offset !== (query.offset ?? 0)) throw new CanonicalWireError("response.page","effective page mismatch");
  return value;
}

// Selected complete typed nested detail is separate from generic v1 and root v2.
const nestedLimits = {max_request_bytes:1048576,max_header_ascii_bytes:8192,max_context_token_utf8_bytes:1024,max_field_id_path_label_utf8_bytes:256,max_request_id_utf8_bytes:128,default_parent_limit:25,min_parent_limit:1,max_parent_limit:25,max_offset:100000,max_root_fields:20,max_child_fields:20,max_filters:20,max_orders:10,max_collections:1,max_children_per_parent:20,max_returned_children:500,max_scalar_utf8_bytes:16384,max_preaggregate_projected_json_bytes:1048576,max_response_entity_bytes:262144};
const nestedSupports = {row_formats:["arrays","objects"],complete_children:true,root_filters:"flat-and",child_filtering:false,child_ordering:"fixed-public-pk-asc",root_required_order:false,root_boolean:false,partial_children:false};
function nestedText(value, path, max = 1024) {
  assertUnicode(nonEmptyString(value,path),path,max);
  if (/[\r\n]/.test(value)) throw new CanonicalWireError(path,"line breaks unavailable");
  return value;
}
function nestedField(field,path,child=false) {
  exactKeys(field,child ? ["id","path","label","type","encoding","nullable"] : ["id","path","label","type","encoding","nullable","operators"],path);
  for (const key of ["id","path","label"]) nestedText(field[key],`${path}.${key}`,256);
  if (!(child ? /^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*$/ : /^[A-Za-z_][A-Za-z0-9_]*$/).test(field.path)) throw new CanonicalWireError(path,"invalid public path");
  rootPair(field,path);
  if (!child) {
    const expected = field.type === "boolean" ? ["eq","ne","is_null","is_not_null"] : rootOps;
    if (JSON.stringify(field.operators) !== JSON.stringify(expected)) throw new CanonicalWireError(path,"unsupported operator inventory");
  }
}
function assertNestedDetailFeatures(value, discovered) {
  exactKeys(value,["format","format_version","profile","revision","wire_profile","request_format_version","result","domain","root_primary_key","root_fields","collections","defaults","limits","supports"],"nested.features");
  format(value,"selecto.nested-detail-features","nested.features");
  if (value.profile !== "canonical_nested_detail.v1" || value.wire_profile !== "remote_query.v1" || value.request_format_version !== 1) throw new CanonicalWireError("nested.features","unsupported selected profile");
  nestedText(value.revision,"nested.features.revision");
  exactKeys(value.domain,["id","fingerprint","publication"],"nested.features.domain");
  for (const key of Object.keys(value.domain)) nestedText(value.domain[key],`nested.features.domain.${key}`);
  exactKeys(value.result,["format","format_version"],"nested.features.result");format(value.result,"selecto.remote-query-result","nested.features.result");
  for (const [key,expected] of [["limits",nestedLimits],["supports",nestedSupports]]) {
    exactKeys(value[key],Object.keys(expected),`nested.features.${key}`);
    for (const [name,wanted] of Object.entries(expected)) if (Array.isArray(wanted) ? JSON.stringify(value[key][name])!==JSON.stringify(wanted) : value[key][name]!==wanted) throw new CanonicalWireError(`nested.features.${key}.${name}`,"unsupported bound/capability");
  }
  const roots=array(value.root_fields,"nested.root_fields"), collections=array(value.collections,"nested.collections");
  if (!roots.length || roots.length>20 || collections.length!==1) throw new CanonicalWireError("nested.features","root/collection bounds");
  const ids=new Set(),paths=new Set();
  const add=(field,path,child=false)=> {nestedField(field,path,child); if(ids.has(field.id)||paths.has(field.path)) throw new CanonicalWireError(path,"duplicate ID/path");ids.add(field.id);paths.add(field.path);};
  roots.forEach((f,i)=>add(f,`nested.root_fields.${i}`));
  const rootPK=roots.find(f=>f.path===value.root_primary_key);
  if (!rootPK || rootPK.type!=="integer" || rootPK.nullable) throw new CanonicalWireError("nested.root_primary_key","published nonnull integer PK required");
  const collection=collections[0];exactKeys(collection,["id","path","result_id","label","primary_key","order_by","fields","default_select","limit","complete"],"nested.collection");
  for (const key of ["id","path","result_id","label","primary_key"]) nestedText(collection[key],`nested.collection.${key}`,256);
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(collection.path)||collection.result_id!==collection.path||paths.has(collection.path)||ids.has(collection.id)||collection.limit!==20||collection.complete!==true) throw new CanonicalWireError("nested.collection","invalid complete collection");
  ids.add(collection.id);paths.add(collection.path);
  const children=array(collection.fields,"nested.collection.fields");if(!children.length||children.length>20) throw new CanonicalWireError("nested.collection.fields","child field bound");
  children.forEach((f,i)=>{add(f,`nested.collection.fields.${i}`,true);if(f.path.split(".")[0]!==collection.path) throw new CanonicalWireError("nested.collection.fields","foreign child scope");});
  const childPK=children.find(f=>f.path===collection.primary_key);
  const fixedOrder=array(collection.order_by,"nested.collection.order_by");
  if(fixedOrder.length!==1) throw new CanonicalWireError("nested.collection.order_by","one fixed child order required");
  exactKeys(fixedOrder[0],["field","direction"],"nested.collection.order_by.0");
  if(!childPK||childPK.type!=="integer"||childPK.nullable||fixedOrder[0].field!==collection.primary_key||fixedOrder[0].direction!=="asc") throw new CanonicalWireError("nested.collection.primary_key","published nonnull integer PK/fixed order required");
  const childPaths=new Set(children.map(f=>f.path));const defaults=array(collection.default_select,"nested.collection.default_select");
  if(!defaults.length||defaults.length>20||new Set(defaults).size!==defaults.length||defaults.some(p=>!childPaths.has(p))) throw new CanonicalWireError("nested.collection.default_select","unpublished/duplicate default");
  exactKeys(value.defaults,["select","limit","offset","row_format"],"nested.defaults");
  if(value.defaults.limit!==25||value.defaults.offset!==0||value.defaults.row_format!=="arrays") throw new CanonicalWireError("nested.defaults","unsupported default page/format");
  nestedSelection(value.defaults.select,value);
  // A valid sidecar must be selectable within the whole context-header bound.
  encodeNestedDetailContext({profile:value.profile,fingerprint:value.domain.fingerprint,publication:value.domain.publication,revision:value.revision});
  if (discovered) {
    const domain=discovered.domain ?? (discovered.entry && {id:discovered.entry.id,publication:discovered.entry.publication,fingerprint:discovered.manifest?.domain.fingerprint});
    if (!domain || ["id","publication","fingerprint"].some(k=>domain[k]!==value.domain[k])) throw new CanonicalWireError("nested.features.domain","current publication mismatch");
    const manifest=discovered.manifest;
    if (!manifest || !manifest.profiles.includes("remote_query.v1") || manifest.domain.fingerprint!==value.domain.fingerprint) throw new CanonicalWireError("nested.features","manifest binding required");
    assertManifest(manifest);routePath(manifest,"getNestedDetailFeatures","GET");
    const canonicalDomain=discovered.canonicalDomain;assertDomain(canonicalDomain,value.domain.fingerprint);
    const published=canonicalRootFields(canonicalDomain);const map=new Map(published.map(f=>[f.path,f]));
    for(const field of roots){const actual=map.get(field.path);if(!actual||["type","encoding","nullable"].some(k=>actual[k]!==field[k])) throw new CanonicalWireError("nested.root_fields","canonical path/type/codec mismatch");}
  }
  return value;
}
function nestedSelection(selected,features) {
  array(selected,"nested.select");const rootPaths=new Set(features.root_fields.map(f=>f.path));const childPaths=new Set(features.collections[0].fields.map(f=>f.path));const roots=new Set();let child=null;
  for(const slot of selected){
    if(Array.isArray(slot)) {if(child!==null||!slot.length||slot.length>20||new Set(slot).size!==slot.length||slot.some(p=>!childPaths.has(p))) throw new CanonicalWireError("nested.select","invalid child selection");child=slot;}
    else {if(!rootPaths.has(slot)||roots.has(slot)) throw new CanonicalWireError("nested.select","unpublished/duplicate root selection");roots.add(slot);}
  }
  if(!roots.size||roots.size>20||child===null) throw new CanonicalWireError("nested.select","root and exactly one collection required");
  return child;
}
function nestedDetailContext(features) {
  assertNestedDetailFeatures(features);
  return {profile:features.profile,fingerprint:features.domain.fingerprint,publication:features.domain.publication,revision:features.revision};
}
function assertNestedContext(context,features) {
  exactKeys(context,["profile","fingerprint","publication","revision"],"nested.context");for(const key of Object.keys(context))nestedText(context[key],`nested.context.${key}`);
  const expected=nestedDetailContext(features);if(Object.keys(expected).some(k=>context[k]!==expected[k])) throw new CanonicalWireError("nested.context","stale nested detail context");
}
function encodeNestedDetailContext(context) {
  exactKeys(context,["profile","fingerprint","publication","revision"],"nested.context");
  if(context.profile!=="canonical_nested_detail.v1") throw new CanonicalWireError("nested.context","unknown profile");
  for(const key of Object.keys(context))nestedText(context[key],`nested.context.${key}`);
  const bytes=new TextEncoder().encode(JSON.stringify(context));let binary="";for(const byte of bytes)binary+=String.fromCharCode(byte);
  const encoded=btoa(binary).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");if(encoded.length>8192)throw new CanonicalWireError("nested.context","header limit");return encoded;
}
function nestedIntegerText(value) {return typeof value==="string"&&/^(?:0|[1-9]\d*|-[1-9]\d*)$/.test(value)&&value.length<=20&&BigInt(value)>=-9223372036854775808n&&BigInt(value)<=9223372036854775807n;}
function assertNestedDetailScalar(value,field,path="nested.scalar",options={}) {
  rootPair(field,path);
  if(value===null){if(options.author||!field.nullable)throw new CanonicalWireError(path,"unexpected null");return value;}
  if(typeof value==="string")assertUnicode(value,path,16384);
  let valid=false;
  if(field.type==="integer") {
    valid=options.author ? nestedIntegerText(value) : field.encoding==="json" ? Number.isSafeInteger(value) : nestedIntegerText(value);
    if(typeof value==="number"&&options.numberToken!==undefined&&!/^-?(?:0|[1-9]\d*)$/.test(options.numberToken))valid=false;
  } else if(field.type==="decimal") {
    const pattern=options.author ? /^-?(?:0|[1-9]\d{0,31})(?:\.\d{1,6})?$/ : /^-?(?:0|[1-9]\d{0,31})\.\d{6}$/;
    valid=typeof value==="string"&&pattern.test(value);
  } else if(field.type==="boolean")valid=typeof value==="boolean";
  else if(field.type==="date")valid=typeof value==="string"&&!value.startsWith("0000-")&&validDate(value);
  else if(field.type==="string")valid=typeof value==="string";
  if(!valid)throw new CanonicalWireError(path,`invalid nested ${field.type}/${field.encoding}`);return value;
}
function assertNestedDetailQuery(query,features,options={}) {
  assertNestedDetailFeatures(features);keys(query,["select","filters","order_by","limit","offset","row_format","timezone"],"nested.query");nestedSelection(query.select,features);
  const byPath=new Map(features.root_fields.map(f=>[f.path,f]));
  if(Object.hasOwn(query,"filters")) {
    const filters=array(query.filters,"nested.filters");if(filters.length>20)throw new CanonicalWireError("nested.filters","filter bound");
    filters.forEach((f,i)=>{const nullOp=["is_null","is_not_null"].includes(f?.op);exactKeys(f,nullOp?["field","op"]:["field","op","value"],`nested.filters.${i}`);const field=byPath.get(f.field);if(!field||!field.operators.includes(f.op))throw new CanonicalWireError("nested.filters","unpublished field/operator");
      if(!nullOp){if(typeof f.value==="number"){if(!["integer","decimal"].includes(field.type)||!Number.isSafeInteger(f.value))throw new CanonicalWireError("nested.filters","unsafe/nonnumeric integer");const token=options.numberTokens?.get(`/query/filters/${i}/value`);if(token!==undefined&&!/^-?(?:0|[1-9]\d*)$/.test(token))throw new CanonicalWireError("nested.filters","noninteger numeric token");}else assertNestedDetailScalar(f.value,field,`nested.filters.${i}.value`,{author:true});}});
  }
  if(Object.hasOwn(query,"order_by")) {const orders=array(query.order_by,"nested.order_by"),seen=new Set();if(orders.length>10)throw new CanonicalWireError("nested.order_by","order bound");orders.forEach(o=>{exactKeys(o,["field","direction"],"nested.order");if(!byPath.has(o.field)||seen.has(o.field)||!["asc","desc"].includes(o.direction))throw new CanonicalWireError("nested.order","invalid/duplicate root order");seen.add(o.field);});}
  for(const [key,min,max] of [["limit",1,25],["offset",0,100000]])if(Object.hasOwn(query,key)){integer(query[key],`nested.query.${key}`,min);if(query[key]>max)throw new CanonicalWireError(key,"page bound");const token=options.numberTokens?.get(`/query/${key}`);if(token!==undefined&&!/^(?:0|[1-9]\d*)$/.test(token))throw new CanonicalWireError(key,"noninteger page token");}
  if(Object.hasOwn(query,"row_format"))oneOf(query.row_format,["arrays","objects"],"nested.row_format");if(Object.hasOwn(query,"timezone"))assertTimezone(query.timezone);return query;
}
function nestedRequestId(value){nestedText(value,"nested.request_id",128);if(/[\u0000-\u001f\u007f]/.test(value))throw new CanonicalWireError("nested.request_id","control unavailable");}
function buildNestedDetailRequest(fingerprint,query,options={}) {
  assertNestedContext(options.context,options.features);if(fingerprint!==options.context.fingerprint)throw new CanonicalWireError("nested.fingerprint","context/body mismatch");assertNestedDetailQuery(query,options.features);
  const request={format:"selecto.remote-query",format_version:1,domain:{fingerprint},query};if(options.requestId!==undefined){nestedRequestId(options.requestId);request.request_id=options.requestId;}parseStrictJSON(JSON.stringify(request));return request;
}
function parseNestedDetailRequestText(text,options) {
  const {value,numberTokens}=parseStrictJSON(text,{tokens:true,maxBytes:1048576});
  exactKeys(value,Object.hasOwn(value,"request_id")?["format","format_version","domain","query","request_id"]:["format","format_version","domain","query"],"nested.request");
  if(value.format!=="selecto.remote-query"||value.format_version!==1||numberTokens.get("/format_version")!=="1")throw new CanonicalWireError("nested.request","lexical version1 required");
  exactKeys(value.domain,["fingerprint"],"nested.request.domain");assertNestedContext(options.context,options.features);
  if(value.domain.fingerprint!==options.context.fingerprint)throw new CanonicalWireError("nested.request.domain","stale context/body binding");if(Object.hasOwn(value,"request_id"))nestedRequestId(value.request_id);
  assertNestedDetailQuery(value.query,options.features,{numberTokens});return {request:value,raw:text,numberTokens};
}
function nestedEcho(meta,context,required) {
  if(meta===undefined){if(required)throw new CanonicalWireError("nested.meta","context required");return;}
  keys(meta,["selecto_nested_detail","request_id"],"nested.meta");if(Object.hasOwn(meta,"request_id"))nestedRequestId(meta.request_id);
  if(Object.hasOwn(meta,"selecto_nested_detail")){exactKeys(meta.selecto_nested_detail,["profile","fingerprint","publication","revision"],"nested.meta.context");if(Object.keys(context).some(k=>meta.selecto_nested_detail[k]!==context[k]))throw new CanonicalWireError("nested.meta.context","context drift");}
  else if(required)throw new CanonicalWireError("nested.meta.context","missing admitted context");
}
function assertNestedDetailError(value,context,status) {
  exactKeys(value,Object.hasOwn(value,"meta")?["ok","error","meta"]:["ok","error"],"nested.error");assertError(value);exactKeys(value.error,["code","message","details"],"nested.error.error");exactKeys(value.error.details,[],"nested.error.details");oneOf(value.error.code,["malformed_request","operation_unsupported","stale_domain_fingerprint","stale_nested_detail_context","invalid_query","internal_failure","authentication_required","hidden_field"],"nested.error.code");assertUnicode(value.error.message,"nested.error.message",512);
  const codeStatus={malformed_request:400,operation_unsupported:501,stale_domain_fingerprint:409,stale_nested_detail_context:409,invalid_query:422,internal_failure:500,authentication_required:401,hidden_field:403};if(status!==codeStatus[value.error.code])throw new CanonicalWireError("nested.error.status","code/status mismatch");nestedEcho(value.meta,context,false);
}
function assertNestedDetailResult(value,{query,features,context,numberTokens}={}) {
  assertNestedDetailQuery(query,features);assertNestedContext(context,features);exactKeys(value,["ok","data","meta"],"nested.response");if(value.ok!==true)throw new CanonicalWireError("nested.response","success required");nestedEcho(value.meta,context,true);
  const d=value.data;exactKeys(d,["format","format_version","domain","columns","rows","row_count","page","row_format","subtables"],"nested.data");format(d,"selecto.remote-query-result","nested.data");exactKeys(d.domain,["fingerprint"],"nested.data.domain");if(d.domain.fingerprint!==context.fingerprint)throw new CanonicalWireError("nested.data.domain","fingerprint drift");
  const lexical=(path)=>{const t=numberTokens?.get(path);if(t!==undefined&&!/^(?:0|[1-9]\d*)$/.test(t))throw new CanonicalWireError(path,"lexical integer required");};
  for(const path of ["/data/format_version","/data/row_count","/data/page/limit","/data/page/offset","/data/subtables/"+features.collections[0].result_id+"/limit"])lexical(path);
  const collection=features.collections[0],children=nestedSelection(query.select,features);const roots=new Map(features.root_fields.map(f=>[f.path,f]));
  const cols=array(d.columns,"nested.columns");if(cols.length!==query.select.length)throw new CanonicalWireError("nested.columns","selection width");
  const childFields=children.map(p=>collection.fields.find(f=>f.path===p));
  cols.forEach((c,i)=>{exactKeys(c,["id","field","label","type","encoding","nullable"],`nested.columns.${i}`);const f=Array.isArray(query.select[i])?{path:collection.result_id,label:collection.label,type:"json",encoding:"json",nullable:false}:roots.get(query.select[i]);if(c.id!==f.path||c.field!==f.path||["label","type","encoding","nullable"].some(k=>c[k]!==f[k]))throw new CanonicalWireError("nested.columns","descriptor binding drift");});
  exactKeys(d.subtables,[collection.result_id],"nested.subtables");const sub=d.subtables[collection.result_id];exactKeys(sub,["columns","limit","complete"],"nested.subtable");if(JSON.stringify(sub.columns)!==JSON.stringify(children)||sub.limit!==20||sub.complete!==true)throw new CanonicalWireError("nested.subtable","selection/completeness drift");
  if(d.row_format!==(query.row_format??"arrays"))throw new CanonicalWireError("nested.row_format","request mismatch");
  const rows=array(d.rows,"nested.rows");integer(d.row_count,"nested.row_count");if(d.row_count!==rows.length)throw new CanonicalWireError("nested.row_count","row count mismatch");exactKeys(d.page,["limit","offset","has_more"],"nested.page");integer(d.page.limit,"nested.page.limit",1);integer(d.page.offset,"nested.page.offset");bool(d.page.has_more,"nested.page.has_more");if(d.page.limit!==(query.limit??25)||d.page.offset!==(query.offset??0)||rows.length>d.page.limit||rows.length>25)throw new CanonicalWireError("nested.page","request/page mismatch");
  const rowShape=(r,descs,path)=>{if(d.row_format==="arrays"){if(!Array.isArray(r)||r.length!==descs.length)throw new CanonicalWireError(path,"row width");}else exactKeys(r,descs.map(f=>f.path),path);};
  let total=0;
  rows.forEach((r,i)=>{rowShape(r,cols.map(c=>({path:c.id})),`nested.rows.${i}`);cols.forEach((c,j)=>{const v=d.row_format==="arrays"?r[j]:r[c.id],pointer=`/data/rows/${i}/${d.row_format==="arrays"?j:c.id}`;
    if(Array.isArray(query.select[j])){const childRows=array(v,"nested.children");if(childRows.length>20||(total+=childRows.length)>500)throw new CanonicalWireError("nested.children","complete child bound");childRows.forEach((cr,k)=>{rowShape(cr,childFields,`nested.children.${k}`);childFields.forEach((f,l)=>assertNestedDetailScalar(d.row_format==="arrays"?cr[l]:cr[f.path],f,`nested.children.${k}.${f.path}`,{numberToken:numberTokens?.get(`${pointer}/${k}/${d.row_format==="arrays"?l:f.path}`)}));});}
    else assertNestedDetailScalar(v,roots.get(c.field),`nested.rows.${i}.${c.id}`,{numberToken:numberTokens?.get(pointer)});
  });});return value;
}

return {CanonicalWireError,CanonicalHttpError,nestedDetailRefusal,markNestedDetailRefusal,safePath,record,nonEmptyString,integer,keys,assertCatalog,assertManifest,routePath,assertDomain,assertError,assertColumn,assertScalar,assertQueryResult,buildRemoteRequest,createCanonicalClient,assertUnicode,parseStrictJSON,canonicalRootFields,assertRootPredicateFeatures,assertRootScalar,assertRootPredicateQuery,assertTimezone,buildRootPredicateRequest,parseCanonicalRequestText,assertRootPredicateResult,assertNestedDetailFeatures,nestedDetailContext,encodeNestedDetailContext,assertNestedDetailScalar,assertNestedDetailQuery,buildNestedDetailRequest,parseNestedDetailRequestText,assertNestedDetailResult};
})();
global.SelectoExplorerClient = (function() {
const canonical = global.SelectoCanonicalClient;

const operatorMap = {equals: "eq", not_equals: "ne", greater_than: "gt", greater_than_or_equal: "gte", less_than: "lt", less_than_or_equal: "lte", is_null: "is_null", is_not_null: "is_not_null"};
const reverseOperators = Object.fromEntries(Object.entries(operatorMap).map(([key, value]) => [value, key]));
const {record, nonEmptyString, integer, keys, safePath, CanonicalWireError} = canonical;

class ExplorerIntentError extends Error {
  constructor(path, message, code = "operation_unsupported") {
    super(`${path}: ${message}`);
    this.name = "ExplorerIntentError";
    this.path = path;
    this.code = code;
    this.details = {path};
  }
}
function refuse(path, message, code) { throw new ExplorerIntentError(path, message, code); }
function nestedValidationFailure(error, reason) {
  return error instanceof ExplorerIntentError || error instanceof CanonicalWireError ? canonical.markNestedDetailRefusal(error, reason) : error;
}
function nestedRefuse(path, message, code, reason) {
  throw canonical.markNestedDetailRefusal(new ExplorerIntentError(path, message, code), reason);
}
function isEmpty(value) { return value === undefined || value === null || value === false || (Array.isArray(value) && !value.length) || (typeof value === "object" && !Object.keys(value).length); }

function assertExplorerMetadata(value, manifest, entry, domain) {
  record(value, "metadata");
  if (value.format !== "selecto.explorer-metadata" || value.format_version !== 1) throw new CanonicalWireError("metadata", "expected selecto.explorer-metadata version 1");
  record(value.domain, "metadata.domain");
  nonEmptyString(value.domain.id, "metadata.domain.id");
  nonEmptyString(value.domain.fingerprint, "metadata.domain.fingerprint");
  nonEmptyString(value.domain.publication, "metadata.domain.publication");
  if (manifest && manifest.domain.fingerprint !== value.domain.fingerprint) throw new CanonicalWireError("metadata.domain.fingerprint", "differs from manifest fingerprint");
  if (entry && (entry.id !== value.domain.id || entry.publication !== value.domain.publication)) throw new CanonicalWireError("metadata.domain", "differs from catalog publication");
  nonEmptyString(value.label, "metadata.label");
  if (!Array.isArray(value.fields) || !value.fields.length) throw new CanonicalWireError("metadata.fields", "expected non-empty fields");
  const ids = new Set();
  const paths = new Set();
  value.fields.forEach((field, i) => {
    canonical.assertColumn(field, `metadata.fields.${i}`);
    nonEmptyString(field.path, `metadata.fields.${i}.path`);
    if (domain && (!domain.source.fields.includes(field.path) || !Object.hasOwn(domain.source.columns, field.path))) throw new CanonicalWireError(`metadata.fields.${i}.path`, "field absent from canonical publication");
    if (ids.has(field.id) || paths.has(field.path)) throw new CanonicalWireError("metadata.fields", "duplicate field id or path");
    ids.add(field.id); paths.add(field.path);
  });
  if (!Array.isArray(value.default_select) || value.default_select.some((id) => !ids.has(id)) || new Set(value.default_select).size !== value.default_select.length) throw new CanonicalWireError("metadata.default_select", "expected unique published field IDs");
  record(value.query, "metadata.query");
  if (value.query.profile !== "remote_query.v1") throw new CanonicalWireError("metadata.query.profile", "requires remote_query.v1");
  if (!Array.isArray(value.query.operators) || value.query.operators.some((op) => typeof op !== "string")) throw new CanonicalWireError("metadata.query.operators", "expected operator IDs");
  record(value.query.supports, "metadata.query.supports");
  for (const key of ["detail", "nested", "recursive_filters", "aggregates"]) if (typeof value.query.supports[key] !== "boolean") throw new CanonicalWireError(`metadata.query.supports.${key}`, "expected boolean");
  if (!value.query.supports.detail) throw new CanonicalWireError("metadata.query.supports.detail", "Detail profile unavailable");
  record(value.query.limits, "metadata.query.limits");
  integer(value.query.limits.max_limit, "metadata.query.limits.max_limit", 1);
  integer(value.query.limits.max_offset, "metadata.query.limits.max_offset");
  integer(value.query.limits.max_filters, "metadata.query.limits.max_filters");
  record(value.services, "metadata.services");
  if (value.links !== undefined) {
    record(value.links, "metadata.links");
    if (value.links.api_console !== undefined) {
      nonEmptyString(value.links.api_console, "metadata.links.api_console");
      safePath(value.links.api_console.split("?")[0]);
      if (value.links.api_console.includes("#")) throw new CanonicalWireError("metadata.links.api_console", "fragments are reserved for request handoff");
    }
  }
  return value;
}

function toExplorerDescriptor(metadata) {
  assertExplorerMetadata(metadata);
  return {
    schema: "selecto.spa.domain-descriptor/v1", schemaVersion: 1,
    id: metadata.domain.id, name: metadata.label, source: metadata.label,
    capabilities: ["detail"], protocolFeatures: metadata.links?.api_console ? ["api_console"] : [],
    fields: metadata.fields.map((field) => ({id: field.id, label: field.label, type: field.type === "string" ? "text" : field.type === "binary" ? "text" : field.type, encoding: field.encoding, selectable: true, sortable: true, groupable: false, aggregatable: false,
      filterOperators: metadata.query.operators.map((op) => reverseOperators[op]).filter(Boolean)})),
    views: [{id: "detail", kind: "detail", label: "Detail"}],
    defaults: {selected: metadata.default_select.slice(), orderBy: [], groupBy: [], aggregates: [], rollup: true, preventDenormalization: true},
    release: {schema: "selecto.domain-publication/v1", id: metadata.domain.publication, version: metadata.domain.fingerprint, fingerprint: metadata.domain.fingerprint, status: "published"},
    ...(metadata.links?.api_console ? {artifacts: {apiConsole: metadata.links.api_console}} : {}),
    metadata: {canonical: {profile: metadata.query.profile, fingerprint: metadata.domain.fingerprint, publication: metadata.domain.publication, supports: {...metadata.query.supports}, limits: {...metadata.query.limits}}},
  };
}

/** Translate the bounded Detail profile; never discard unsupported semantics. */
function toCanonicalQuery(request, metadata) {
  assertExplorerMetadata(metadata);
  keys(request, ["schema", "domainId", "view", "state", "filters", "page", "presentation", "publication", "exportShape"], "request");
  if (request.schema !== "selecto.spa.query-request/v1") refuse("request.schema", "unknown SPA request version", "invalid_query");
  if (request.domainId !== metadata.domain.id) refuse("request.domainId", "does not match publication", "invalid_query");
  if (request.view !== "detail") refuse("request.view", "only Detail is supported");
  if (request.publication !== undefined) {
    keys(request.publication, ["fingerprint", "publication"], "request.publication");
    if (request.publication.fingerprint !== metadata.domain.fingerprint || (request.publication.publication !== undefined && request.publication.publication !== metadata.domain.publication)) refuse("request.publication", "publication changed; reload the domain", "stale_domain_fingerprint");
  }
  if (request.exportShape !== undefined) refuse("request.exportShape", "export is not available");
  const state = record(request.state, "request.state");
  keys(state, ["selected", "preventDenormalization", "rowClickAction", "fieldConfigs", "orderBy", "groupBy", "groupConfigs", "rollup", "aggregateGrid", "aggregateGridColorize", "aggregateGridColorScale", "columns", "aggregates", "graph", "queryLibrary"], "request.state");
  for (const key of ["groupBy", "groupConfigs", "aggregates", "graph", "queryLibrary", "aggregateGrid", "aggregateGridColorize", "aggregateGridColorScale"]) if (!isEmpty(state[key])) refuse(`request.state.${key}`, "requires a richer profile");
  if (state.preventDenormalization !== undefined && state.preventDenormalization !== true) refuse("request.state.preventDenormalization", "denormalization is unavailable");
  if (state.rowClickAction && state.rowClickAction !== "__default_modal__") refuse("request.state.rowClickAction", "configured row actions are unavailable");
  if (state.columns !== undefined && !isEmpty(state.columns)) refuse("request.state.columns", "repeated/formatted columns require a richer profile");
  if (!isEmpty(state.fieldConfigs)) refuse("request.state.fieldConfigs", "formatted columns require a richer profile");
  const byId = new Map(metadata.fields.map((field) => [field.id, field]));
  function field(id, path) {
    const value = byId.get(id);
    if (!value) refuse(path, `unresolved field ${JSON.stringify(id)}`, "invalid_field");
    return value;
  }
  if (!Array.isArray(state.selected) || !state.selected.length || new Set(state.selected).size !== state.selected.length) refuse("request.state.selected", "expected unique non-empty fields", "invalid_query");
  const query = {select: state.selected.map((id) => field(id, "request.state.selected").path)};
  const filters = record(request.filters, "request.filters");
  keys(filters, ["conjunction", "items"], "request.filters");
  if (filters.conjunction !== "and" || !Array.isArray(filters.items)) refuse("request.filters", "only flat AND filters are supported");
  if (filters.items.length > metadata.query.limits.max_filters) refuse("request.filters", "exceeds advertised filter limit", "invalid_query");
  query.filters = filters.items.map((filter, index) => {
    const path = `request.filters.items.${index}`;
    if (filter?.items !== undefined || filter?.conjunction !== undefined) refuse(path, "recursive filters require a richer profile");
    keys(filter, ["id", "field", "operator", "value", "valueTo", "promoted", "groupConfig"], path);
    if (filter.valueTo !== undefined || !isEmpty(filter.groupConfig)) refuse(path, "range/grouping semantics require a richer profile");
    const op = operatorMap[filter.operator];
    if (!op || !metadata.query.operators.includes(op)) refuse(`${path}.operator`, "operator not supported by this profile");
    const result = {field: field(filter.field, `${path}.field`).path, op};
    if (!["is_null", "is_not_null"].includes(op)) {
      if (!Object.hasOwn(filter, "value")) refuse(`${path}.value`, "a value is required", "invalid_query");
      result.value = filter.value;
    } else if (filter.value !== undefined && filter.value !== null && filter.value !== "") refuse(`${path}.value`, "null test cannot carry a value", "invalid_query");
    return result;
  });
  if (!Array.isArray(state.orderBy)) refuse("request.state.orderBy", "expected an array", "invalid_query");
  query.order_by = state.orderBy.map((order, index) => {
    keys(order, ["field", "direction"], `request.state.orderBy.${index}`);
    if (!["asc", "desc"].includes(order.direction)) refuse("request.state.orderBy", "invalid direction", "invalid_query");
    return {field: field(order.field, "request.state.orderBy").path, direction: order.direction};
  });
  keys(request.page, ["number", "size"], "request.page");
  integer(request.page.number, "request.page.number", 1); integer(request.page.size, "request.page.size", 1);
  query.limit = request.page.size;
  query.offset = (request.page.number - 1) * request.page.size;
  if (!Number.isSafeInteger(query.offset) || query.limit > metadata.query.limits.max_limit || query.offset > metadata.query.limits.max_offset) refuse("request.page", "exceeds advertised paging limits", "invalid_query");
  if (request.presentation !== undefined) {
    keys(request.presentation, ["timezone", "locale"], "request.presentation");
    if (request.presentation.timezone !== undefined) {
      nonEmptyString(request.presentation.timezone, "request.presentation.timezone");
      query.timezone = request.presentation.timezone;
    }
    if (request.presentation.locale !== undefined) nonEmptyString(request.presentation.locale, "request.presentation.locale");
  }
  canonical.buildRemoteRequest(metadata.domain.fingerprint, query);
  return query;
}

function toExplorerResult(envelope, request, metadata) {
  const query = toCanonicalQuery(request, metadata);
  canonical.assertQueryResult(envelope, metadata.domain.fingerprint, query);
  const byPath = new Map(metadata.fields.map((field) => [field.path, field]));
  const columns = envelope.data.columns.map((column) => {
    const field = byPath.get(column.field ?? column.id);
    if (!field) throw new CanonicalWireError("response.columns", "unresolved canonical field");
    return {id: field.id, label: column.label, type: column.type === "string" ? "text" : column.type === "binary" ? "text" : column.type, encoding: column.encoding};
  });
  if (columns.length !== query.select.length || columns.some((column, i) => column.id !== request.state.selected[i])) throw new CanonicalWireError("response.columns", "selection differs from requested fields");
  const rows = envelope.data.rows.map((row) => Object.fromEntries(envelope.data.columns.map((column, i) => [columns[i].id, Array.isArray(row) ? row[i] : row[column.id]])));
  return {schema: "selecto.spa.query-response/v1", columns, rows,
    page: {number: request.page.number, size: request.page.size},
    metadata: {canonical: {fingerprint: metadata.domain.fingerprint, publication: metadata.domain.publication, hasMore: envelope.data.page.has_more}},
  };
}

function createExplorerClient(options = {}) {
  const client = canonical.createCanonicalClient(options);
  // Discovery is refreshed before every query. No authenticated publication is
  // reused across a changed cookie/session or across client instances.
  async function publication(id, signal) {
    const catalog = await client.catalog(signal);
    const entry = catalog.domains.find((domain) => domain.id === id);
    if (!entry) refuse("domainId", "domain is unavailable in the current publication", "operation_forbidden");
    const [manifest, value] = await Promise.all([client.manifest(entry.manifest, signal), client.metadata(entry.explorer_metadata, signal)]);
    const domain = await client.domain(manifest, signal);
    return {entry, manifest, canonicalDomain:domain, metadata: assertExplorerMetadata(value, manifest, entry, domain)};
  }
  async function rootPublication(id, signal) {
    const context = await publication(id,signal);
    const features = await client.rootPredicateFeatures(context.manifest,signal);
    canonical.assertRootPredicateFeatures(features,{...context,domain:context.metadata.domain});
    return {...context,features,binding:rootPredicateBinding(features)};
  }
  async function nestedPublication(id, signal) {
    try {
    const catalog = await client.catalog(signal);
    const entry = catalog.domains.find(domain => domain.id === id);
    if (!entry) refuse("domainId", "domain unavailable in current publication", "operation_forbidden");
    const manifest = await client.manifest(entry.manifest, signal);
    const canonicalDomain = await client.domain(manifest, signal);
    const features = await client.nestedDetailFeatures(manifest, signal);
    canonical.assertNestedDetailFeatures(features, {entry,manifest,canonicalDomain});
    return {entry,manifest,canonicalDomain,features,binding:nestedDetailBinding(features)};
    } catch (error) {
      if (error instanceof canonical.CanonicalHttpError && error.status === 401 && error.code === "authentication_required") throw canonical.markNestedDetailRefusal(error, "authentication-required");
      throw nestedValidationFailure(error, "nested-unavailable");
    }
  }
  return {
    async getNestedDetailContext(id, requestOptions = {}) { return nestedPublication(id, requestOptions.signal); },
    async executeNestedDetailIntent(intent, requestOptions = {}) {
      // Execution uses the 1MiB request bound; the 64KiB share cap is separate.
      const retained = canonical.parseStrictJSON(JSON.stringify(intent));
      nestedIntentShape(retained);
      const context = await nestedPublication(retained.binding.domain_id, requestOptions.signal);
      const query = toNestedDetailQuery(retained, context);
      const result = await client.queryNestedDetail(context.manifest, query, {...requestOptions,features:context.features,context:canonical.nestedDetailContext(context.features)});
      return toNestedDetailExplorerResult(result, retained, context);
    },
    async getRootPredicateContext(id, requestOptions = {}) {return rootPublication(id,requestOptions.signal);},
    async executeRootPredicateIntent(intent, requestOptions = {}) {
      const retained = canonical.parseStrictJSON(JSON.stringify(intent));
      const context = await rootPublication(retained.binding.domain_id,requestOptions.signal);
      const query = toRootPredicateQuery(retained,context);
      const result = await client.queryRootPredicate(context.manifest,query,{...requestOptions,features:context.features,fingerprint:retained.binding.fingerprint});
      return toRootPredicateExplorerResult(result,retained,context);
    },
    async listDomains() {
      const catalog = await client.catalog();
      return Promise.all(catalog.domains.map(async (entry) => {
        const [manifest, value] = await Promise.all([client.manifest(entry.manifest), client.metadata(entry.explorer_metadata)]);
        const domain = await client.domain(manifest);
        return toExplorerDescriptor(assertExplorerMetadata(value, manifest, entry, domain));
      }));
    },
    async getDomain(id) { return toExplorerDescriptor((await publication(id)).metadata); },
    async execute(request, requestOptions = {}) {
      const {manifest, metadata} = await publication(request.domainId, requestOptions.signal);
      const query = toCanonicalQuery(request, metadata);
      const result = await client.query(manifest, query, requestOptions);
      return toExplorerResult(result, request, metadata);
    },
  };
}

function requiredKeys(value, required, path) {
  keys(value, required, path);
  if (required.some((key) => !Object.hasOwn(value,key))) refuse(path,"missing required member","invalid_query");
}
function rootPredicateBinding(features) {
  canonical.assertRootPredicateFeatures(features);
  return {domain_id:features.domain.id, fingerprint:features.domain.fingerprint, publication:features.domain.publication,
    wire_profile:features.wire_profile, feature_profile:features.profile, feature_revision:features.revision};
}
function assertIntentShape(intent) {
  requiredKeys(intent,["format","format_version","mode","binding","select","predicate","order_by","limit","offset","presentation"],"intent");
  if (intent.format !== "selecto.root-predicate-ui-intent" || intent.format_version !== 1 || intent.mode !== "recursive") refuse("intent","unknown root intent format/version/mode","invalid_query");
  requiredKeys(intent.binding,["domain_id","fingerprint","publication","wire_profile","feature_profile","feature_revision"],"intent.binding");
  Object.values(intent.binding).forEach((value) => canonical.assertUnicode(nonEmptyString(value,"intent.binding"),"intent.binding",16384));
  if (intent.binding.wire_profile !== "remote_query.v2" || intent.binding.feature_profile !== "canonical_root_predicates.v1") refuse("intent.binding","unsupported bound profile","invalid_query");
  if (!Array.isArray(intent.select) || !intent.select.length || intent.select.length > 100 || new Set(intent.select).size !== intent.select.length) refuse("intent.select","unique nonempty selection required","invalid_query");
  intent.select.forEach((id) => canonical.assertUnicode(nonEmptyString(id,"intent.select"),"intent.select",16384));
  requiredKeys(intent.predicate,intent.predicate?.kind === "absent" ? ["kind"] : ["kind","tree"],"intent.predicate");
  if (!["absent","tree"].includes(intent.predicate.kind)) refuse("intent.predicate","unknown predicate kind","invalid_query");
  let count = 0;
  function visit(node,depth) {
    record(node,"intent.predicate.tree"); if (++count > 20 || depth > 4) refuse("intent.predicate.tree","node/depth bound exceeded","invalid_query");
    const groups = ["and","or"].filter((key) => Object.hasOwn(node,key));
    if (groups.length) {
      if (groups.length !== 1) refuse("intent.predicate.tree","mixed group kinds","invalid_query");
      requiredKeys(node,groups,"intent.predicate.tree");
      if (!Array.isArray(node[groups[0]]) || !node[groups[0]].length) refuse("intent.predicate.tree","empty executable group","invalid_query");
      node[groups[0]].forEach((child) => visit(child,depth+1)); return;
    }
    const nullTest = ["is_null","is_not_null"].includes(node.op);
    requiredKeys(node,nullTest ? ["field","op"] : ["field","op","value"],"intent.predicate.tree");
    if (!["eq","ne","gt","gte","lt","lte","is_null","is_not_null"].includes(node.op)) refuse("intent.predicate.tree.op","unsupported operator");
    canonical.assertUnicode(nonEmptyString(node.field,"intent.predicate.tree.field"),"intent.predicate.tree.field",16384);
    if (!nullTest && typeof node.value !== "string" && typeof node.value !== "boolean") refuse("intent.predicate.tree.value","typed text or boolean required","invalid_query");
    if (typeof node.value === "string") canonical.assertUnicode(node.value,"intent.predicate.tree.value",16384);
  }
  if (intent.predicate.kind === "tree") visit(intent.predicate.tree,1);
  if (!Array.isArray(intent.order_by) || intent.order_by.length > 10) refuse("intent.order_by","order bound exceeded","invalid_query");
  const ordered = new Set(); intent.order_by.forEach((order) => {
    requiredKeys(order,["field","direction"],"intent.order_by");
    canonical.assertUnicode(nonEmptyString(order.field,"intent.order_by.field"),"intent.order_by.field",16384);
    if (ordered.has(order.field) || !["asc","desc"].includes(order.direction)) refuse("intent.order_by","duplicate or invalid order","invalid_query"); ordered.add(order.field);
  });
  integer(intent.limit,"intent.limit",1); integer(intent.offset,"intent.offset");
  if (intent.limit > 100 || intent.offset > 100000) refuse("intent","paging bound exceeded","invalid_query");
  requiredKeys(intent.presentation,["timezone","locale"],"intent.presentation");
  canonical.assertTimezone(intent.presentation.timezone);
  canonical.assertUnicode(nonEmptyString(intent.presentation.locale,"intent.presentation.locale"),"intent.presentation.locale",16384);
  try {new Intl.NumberFormat(intent.presentation.locale);} catch {refuse("intent.presentation.locale","unknown locale","invalid_query");}
  return intent;
}
function rootContextFeatures(context) {
  const features = context?.features;
  if (!features) refuse("features","recursive mode unavailable");
  const trusted = context.canonical_fields ? context : {domain:context.metadata?.domain ?? features.domain, manifest:context.manifest, canonicalDomain:context.canonicalDomain};
  canonical.assertRootPredicateFeatures(features,trusted);
  return features;
}
function assertRootPredicateIntent(intent, context) {
  assertIntentShape(intent);
  const features = rootContextFeatures(context);
  const binding = rootPredicateBinding(features);
  if (Object.keys(binding).some((key) => intent.binding[key] !== binding[key])) refuse("intent.binding","publication or feature revision changed; retain state and reload","stale_domain_fingerprint");
  const byId = new Map(features.fields.map((field) => [field.id,field]));
  const field = (id) => {const value = byId.get(id); if (!value) refuse("intent.field","unresolved opaque field ID","invalid_field"); return value;};
  intent.select.forEach(field); intent.order_by.forEach((order) => field(order.field));
  function visit(node) {
    if (Object.hasOwn(node,"and") || Object.hasOwn(node,"or")) { (node.and ?? node.or).forEach(visit); return; }
    const selected = field(node.field);
    if (!selected.operators.includes(node.op)) refuse("intent.predicate.tree.op","operator unavailable for field");
    if (!["is_null","is_not_null"].includes(node.op)) canonical.assertRootScalar(node.value,selected,"intent.predicate.tree.value",true);
  }
  if (intent.predicate.kind === "tree") visit(intent.predicate.tree);
  return intent;
}
function toRootPredicateQuery(intent, context) {
  assertRootPredicateIntent(intent,context);
  const byId = new Map(context.features.fields.map((field) => [field.id,field]));
  function translate(node) {
    if (Object.hasOwn(node,"and")) return {and:node.and.map(translate)};
    if (Object.hasOwn(node,"or")) return {or:node.or.map(translate)};
    const result = {field:byId.get(node.field).path,op:node.op};
    if (Object.hasOwn(node,"value")) result.value = node.value;
    return result;
  }
  const query = {select:intent.select.map((id) => byId.get(id).path),order_by:intent.order_by.map((order) => ({field:byId.get(order.field).path,direction:order.direction})),limit:intent.limit,offset:intent.offset,timezone:intent.presentation.timezone};
  if (intent.predicate.kind === "tree") query.where = translate(intent.predicate.tree);
  canonical.assertRootPredicateQuery(query,context.features);
  return query;
}
function parseRootPredicateState(text, context) {
  const {value,numberTokens} = canonical.parseStrictJSON(text,{tokens:true,maxBytes:65536});
  requiredKeys(value,["format","format_version","intent"],"state");
  if (value.format !== "selecto.root-predicate-state" || value.format_version !== 1 || numberTokens.get("/format_version") !== "1" || numberTokens.get("/intent/format_version") !== "1") refuse("state","unknown/noninteger root state version","invalid_query");
  assertIntentShape(value.intent);
  if (context) assertRootPredicateIntent(value.intent,context);
  return value;
}
function encodeRootPredicateState(state) {
  const text = JSON.stringify(state); parseRootPredicateState(text);
  const encoded = encodeURIComponent(text);
  if (encoded.length > 65536) refuse("state","encoded state exceeds 64KiB","invalid_query");
  return encoded;
}
function decodeRootPredicateState(encodedOrRaw, context) {
  if (typeof encodedOrRaw !== "string" || encodedOrRaw.length > 65536) refuse("state","encoded state exceeds 64KiB","invalid_query");
  let text = encodedOrRaw;
  if (!text.trimStart().startsWith("{")) {
    try {text = decodeURIComponent(text);} catch {refuse("state","invalid URI escaping","invalid_query");}
  }
  return parseRootPredicateState(text,context);
}
/** Transparent facade for independently supplied local validator inputs. */
function validateRootPredicateFeaturesAndMap(features, context, authorSelect, authorTree) {
  const validated_features = canonical.assertRootPredicateFeatures(features,context);
  const intent = {format:"selecto.root-predicate-ui-intent",format_version:1,mode:"recursive",binding:rootPredicateBinding(features),select:authorSelect,predicate:{kind:"tree",tree:authorTree},order_by:[],limit:100,offset:0,presentation:{timezone:"UTC",locale:"en-US"}};
  const query = toRootPredicateQuery(intent,{...context,features});
  return {validated_features,translated_select:query.select,translated_where:query.where};
}
function toRootPredicateExplorerResult(envelope,intent,context) {
  const query = toRootPredicateQuery(intent,context);
  canonical.assertRootPredicateResult(envelope,{fingerprint:intent.binding.fingerprint,query,features:context.features});
  const byPath = new Map(context.features.fields.map((field) => [field.path,field]));
  const columns = envelope.data.columns.map((column) => ({id:byPath.get(column.field).id,label:column.label,type:column.type === "string" ? "text" : column.type,encoding:column.encoding}));
  const rows = envelope.data.rows.map((row) => Object.fromEntries(envelope.data.columns.map((column,i) => [columns[i].id,Array.isArray(row) ? row[i] : row[column.id]])));
  return {schema:"selecto.spa.query-response/v1",columns,rows,page:{number:Math.floor(intent.offset/intent.limit)+1,size:intent.limit},metadata:{canonical:{fingerprint:intent.binding.fingerprint,publication:intent.binding.publication,hasMore:envelope.data.page.has_more}}};
}

/** Read the existing closed flat snapshot without upgrading its request profile. */
function flatSnapshotToRequest(snapshot) {
  keys(snapshot,["version","domainId","view","state","filters","page","publication","presentation"],"snapshot");
  if (snapshot.version !== 2) refuse("snapshot.version","unknown flat snapshot version","invalid_query");
  for (const key of ["domainId","view","state","filters","page"]) if (!Object.hasOwn(snapshot,key)) refuse(`snapshot.${key}`,"missing required member","invalid_query");
  const {version,...request} = snapshot;
  return {schema:"selecto.spa.query-request/v1",...request};
}

/** Explicit complete nested mode: IDs are authoring keys, paths are wire keys. */
function nestedDetailBinding(features) {
  canonical.assertNestedDetailFeatures(features);
  return {domain_id:features.domain.id,fingerprint:features.domain.fingerprint,publication:features.domain.publication,wire_profile:"remote_query.v1",feature_profile:"canonical_nested_detail.v1",feature_revision:features.revision};
}
function nestedID(value,path,max=256) {
  canonical.assertUnicode(nonEmptyString(value,path),path,max);
  if (/[\r\n]/.test(value)) refuse(path,"line breaks unavailable","invalid_query");return value;
}
function nestedIntentShape(intent) {
  try {
    requiredKeys(intent,["format","format_version","mode","binding","collection_id","select","filters","order_by","limit","offset","row_format","presentation"],"nested.intent");
  } catch (error) {
    if (intent && typeof intent === "object" && !Array.isArray(intent) && ["where", "child_order_by", "formatter"].some(key => Object.hasOwn(intent, key))) throw nestedValidationFailure(error, "closed-intent-violation");
    throw error;
  }
  if(intent.format!=="selecto.nested-detail-ui-intent"||intent.format_version!==1||intent.mode!=="nested")refuse("nested.intent","unknown nested mode/version","invalid_query");
  requiredKeys(intent.binding,["domain_id","fingerprint","publication","wire_profile","feature_profile","feature_revision"],"nested.intent.binding");
  for(const value of Object.values(intent.binding))nestedID(value,"nested.intent.binding",1024);
  if(intent.binding.wire_profile!=="remote_query.v1"||intent.binding.feature_profile!=="canonical_nested_detail.v1")refuse("nested.intent.binding","unsupported bound profile");
  nestedID(intent.collection_id,"nested.intent.collection_id");
  if(!Array.isArray(intent.select)||intent.select.length<2||intent.select.length>21)refuse("nested.intent.select","selection bound","invalid_query");
  const rootIDs=new Set();let children=0;
  intent.select.forEach(slot=>{if(Array.isArray(slot)){children++;if(!slot.length||slot.length>20||new Set(slot).size!==slot.length)refuse("nested.intent.select","child selection bound/duplicate","invalid_query");slot.forEach(id=>nestedID(id,"nested.intent.child"));}else{nestedID(slot,"nested.intent.select");if(rootIDs.has(slot))refuse("nested.intent.select","duplicate root ID","invalid_query");rootIDs.add(slot);}});
  if(children!==1||!rootIDs.size||rootIDs.size>20)refuse("nested.intent.select","one collection and root selection required","invalid_query");
  if(!Array.isArray(intent.filters)||intent.filters.length>20)refuse("nested.intent.filters","filter bound","invalid_query");const filterIDs=new Set();
  intent.filters.forEach(f=>{const nullOp=["is_null","is_not_null"].includes(f?.op);requiredKeys(f,nullOp?["id","field","op"]:["id","field","op","value"],"nested.intent.filter");nestedID(f.id,"nested.intent.filter.id",128);if(/[\u0000-\u001f\u007f]/.test(f.id)||filterIDs.has(f.id))refuse("nested.intent.filter.id","control/duplicate filter ID","invalid_query");filterIDs.add(f.id);nestedID(f.field,"nested.intent.filter.field");if(!["eq","ne","gt","gte","lt","lte","is_null","is_not_null"].includes(f.op))refuse("nested.intent.filter.op","unknown operator");if(!nullOp){if(typeof f.value!=="string"&&typeof f.value!=="boolean")refuse("nested.intent.filter.value","typed text/boolean required","invalid_query");if(typeof f.value==="string")canonical.assertUnicode(f.value,"nested.intent.filter.value",16384);}});
  if(!Array.isArray(intent.order_by)||intent.order_by.length>10)refuse("nested.intent.order_by","order bound","invalid_query");const seen=new Set();intent.order_by.forEach(o=>{requiredKeys(o,["field","direction"],"nested.intent.order");nestedID(o.field,"nested.intent.order.field");if(seen.has(o.field)||!["asc","desc"].includes(o.direction))refuse("nested.intent.order","duplicate/direction","invalid_query");seen.add(o.field);});
  integer(intent.limit,"nested.intent.limit",1);integer(intent.offset,"nested.intent.offset");if(intent.limit>25||intent.offset>100000)refuse("nested.intent.page","page bound","invalid_query");if(!["arrays","objects"].includes(intent.row_format))refuse("nested.intent.row_format","unknown format","invalid_query");requiredKeys(intent.presentation,["timezone","locale"],"nested.intent.presentation");if(intent.presentation.timezone!=="UTC"||intent.presentation.locale!=="en-US")refuse("nested.intent.presentation","first browser presentation is UTC/en-US");return intent;
}
function createNestedDetailIntent(features) {
  const binding=nestedDetailBinding(features),collection=features.collections[0],roots=new Map(features.root_fields.map(f=>[f.path,f.id])),children=new Map(collection.fields.map(f=>[f.path,f.id]));
  return {format:"selecto.nested-detail-ui-intent",format_version:1,mode:"nested",binding,collection_id:collection.id,select:features.defaults.select.map(s=>Array.isArray(s)?s.map(p=>children.get(p)):roots.get(s)),filters:[],order_by:[],limit:25,offset:0,row_format:"arrays",presentation:{timezone:"UTC",locale:"en-US"}};
}
function assertNestedDetailIntent(intent,context,options={}) {
  try { return validateNestedDetailIntent(intent, context); }
  catch (error) { throw nestedValidationFailure(error, options.origin === "state" ? "invalid-nested-state" : "invalid-nested-intent"); }
}
function validateNestedDetailIntent(intent,context) {
  nestedIntentShape(intent);const features=context?.features;if(!features)nestedRefuse("nested.features","nested detail unavailable","operation_unsupported","nested-unavailable");
  try { canonical.assertNestedDetailFeatures(features,context); }
  catch (error) { throw nestedValidationFailure(error, "nested-unavailable"); }
  const binding=nestedDetailBinding(features);
  if(Object.keys(binding).some(k=>intent.binding[k]!==binding[k]))nestedRefuse("nested.intent.binding","publication/revision changed; retain state","stale_nested_detail_context","stale-nested-context");
  const collection=features.collections[0],roots=new Map(features.root_fields.map(f=>[f.id,f])),children=new Map(collection.fields.map(f=>[f.id,f]));
  if(intent.collection_id!==collection.id)nestedRefuse("nested.intent.collection_id","unpublished collection","invalid_field","unpublished-field-id");
  const field=(id,map)=>{const f=map.get(id);if(!f)nestedRefuse("nested.intent.field","unpublished opaque ID","invalid_field","unpublished-field-id");return f;};
  intent.select.forEach(s=>Array.isArray(s)?s.forEach(id=>field(id,children)):field(s,roots));
  intent.order_by.forEach(o=>field(o.field,roots));intent.filters.forEach(f=>{const descriptor=field(f.field,roots);if(!descriptor.operators.includes(f.op))refuse("nested.intent.filter.op","unavailable operator");if(Object.hasOwn(f,"value"))canonical.assertNestedDetailScalar(f.value,descriptor,"nested.intent.filter.value",{author:true});});return intent;
}
function toNestedDetailQuery(intent,context) {
  assertNestedDetailIntent(intent,context);const collection=context.features.collections[0],roots=new Map(context.features.root_fields.map(f=>[f.id,f])),children=new Map(collection.fields.map(f=>[f.id,f]));
  const query={select:intent.select.map(s=>Array.isArray(s)?s.map(id=>children.get(id).path):roots.get(s).path),filters:intent.filters.map(f=>({field:roots.get(f.field).path,op:f.op,...(Object.hasOwn(f,"value")?{value:f.value}:{})})),order_by:intent.order_by.map(o=>({field:roots.get(o.field).path,direction:o.direction})),limit:intent.limit,offset:intent.offset,row_format:intent.row_format,timezone:intent.presentation.timezone};canonical.assertNestedDetailQuery(query,context.features);return query;
}
function parseNestedDetailState(raw,context) {
  try {
  const {value,numberTokens}=canonical.parseStrictJSON(raw,{tokens:true,maxBytes:65536});requiredKeys(value,["format","format_version","intent"],"nested.state");
  if(value.format!=="selecto.nested-detail-state"||value.format_version!==1||numberTokens.get("/format_version")!=="1"||numberTokens.get("/intent/format_version")!=="1")refuse("nested.state","unknown/noninteger version","invalid_query");
  for(const key of ["limit","offset"])if(!/^(?:0|[1-9]\d*)$/.test(numberTokens.get(`/intent/${key}`)??""))refuse("nested.state","noninteger page token","invalid_query");
  nestedIntentShape(value.intent);if(context)assertNestedDetailIntent(value.intent,context,{origin:"state"});return value;
  } catch (error) { throw nestedValidationFailure(error, error instanceof CanonicalWireError && error.path === "JSON" && error.validationReason === "utf8-byte-limit" ? "state-limit" : "invalid-nested-state"); }
}
function encodeNestedDetailState(state) {
  const raw=JSON.stringify(state);parseNestedDetailState(raw);const encoded=encodeURIComponent(raw);if(encoded.length>65536)nestedRefuse("nested.state","encoded state exceeds64KiB","invalid_query","state-limit");return encoded;
}
function decodeNestedDetailState(rawOrEncoded,context) {
  if(typeof rawOrEncoded!=="string")nestedRefuse("nested.state","state exceeds64KiB","invalid_query","invalid-nested-state");
  if(rawOrEncoded.length>65536)nestedRefuse("nested.state","state exceeds64KiB","invalid_query","state-limit");let raw=rawOrEncoded;
  if(!raw.trimStart().startsWith("{")){try{raw=decodeURIComponent(raw);}catch{nestedRefuse("nested.state","invalid URI layer","invalid_query","invalid-nested-state");}}return parseNestedDetailState(raw,context);
}
function nestedDetailConsoleHref(path,state) {
  nonEmptyString(path,"nested.console.path");if(path.includes("#"))refuse("nested.console.path","fragment reserved for nested handoff");safePath(path.split("?")[0]);
  const fragment=new URLSearchParams();fragment.set("nested_request",encodeNestedDetailState(state));return `${path}#${fragment}`;
}
function toNestedDetailExplorerResult(envelope,intent,context) {
  const query=toNestedDetailQuery(intent,context),features=context.features;canonical.assertNestedDetailResult(envelope,{query,features,context:canonical.nestedDetailContext(features)});
  const collection=features.collections[0],roots=new Map(features.root_fields.map(f=>[f.path,f])),children=new Map(collection.fields.map(f=>[f.path,f]));
  const scalar=f=>({id:f.id,key:f.id,path:f.path,label:f.label,type:f.type==="string"?"text":f.type,encoding:f.encoding,nullable:f.nullable});
  const childPaths=query.select.find(Array.isArray),childFields=childPaths.map(p=>children.get(p));
  const columns=query.select.map(s=>Array.isArray(s)?{id:collection.id,path:collection.path,label:collection.label,type:"nested",encoding:"json",nullable:false,nestedFields:childFields.map(scalar),complete:true,limit:20}:scalar(roots.get(s)));
  const rows=envelope.data.rows.map(row=>Object.fromEntries(columns.map((column,i)=>{const wire=envelope.data.columns[i],value=Array.isArray(row)?row[i]:row[wire.id];return[column.id,column.type==="nested"?value.map(child=>Object.fromEntries(childFields.map((f,j)=>[f.id,Array.isArray(child)?child[j]:child[f.path]]))):value];})));
  return {schema:"selecto.spa.query-response/v1",columns,rows,page:{number:Math.floor(intent.offset/intent.limit)+1,size:intent.limit},metadata:{canonical:{profile:"canonical_nested_detail.v1",fingerprint:intent.binding.fingerprint,publication:intent.binding.publication,hasMore:envelope.data.page.has_more,nestedContext:canonical.nestedDetailContext(features),completeChildren:true}}};
}

return {ExplorerIntentError,assertExplorerMetadata,toExplorerDescriptor,toCanonicalQuery,toExplorerResult,createExplorerClient,rootPredicateBinding,assertRootPredicateIntent,toRootPredicateQuery,parseRootPredicateState,encodeRootPredicateState,decodeRootPredicateState,validateRootPredicateFeaturesAndMap,toRootPredicateExplorerResult,flatSnapshotToRequest,nestedDetailBinding,createNestedDetailIntent,assertNestedDetailIntent,toNestedDetailQuery,parseNestedDetailState,encodeNestedDetailState,decodeNestedDetailState,nestedDetailConsoleHref,toNestedDetailExplorerResult};
})();
})(typeof globalThis !== 'undefined' ? globalThis : this);
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
    if (global.SelectoCanonicalClient) {try {global.SelectoCanonicalClient.safePath(candidate);} catch {throw new Error("The API console requires an absolute same-origin API path.");}}
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
      payload = global.SelectoCanonicalClient ? global.SelectoCanonicalClient.parseStrictJSON(encoded, {maxBytes: 65536}) : JSON.parse(encoded);
    } catch (error) {
      throw new Error(`The Explorer request in this URL is not valid JSON: ${error.message}`);
    }
    if (!isPlainObject(payload)) throw new Error("The Explorer request in this URL must be a JSON object.");
    if (payload.format === "selecto.root-predicate-state") {
      const part = hash.split("&").find((part) => new URLSearchParams(part).has("request"));
      const originalEncoded = part.slice(part.indexOf("=") + 1).replace(/\+/g,"%20");
      return global.SelectoExplorerClient.decodeRootPredicateState(originalEncoded);
    }
    return payload;
  }

  function nestedError(message, reason) {
    return global.SelectoCanonicalClient.markNestedDetailRefusal(new Error(message), reason);
  }

  function setNestedRefusal(target, error) {
    if (!target) return;
    const refusal = global.SelectoCanonicalClient?.nestedDetailRefusal(error);
    if (refusal) {
      target.dataset.selectoRefusalReason = refusal.reason;
      target.dataset.selectoRefusalFamily = refusal.family;
    } else {
      delete target.dataset.selectoRefusalReason;
      delete target.dataset.selectoRefusalFamily;
    }
  }

  function nestedStateFromLocation(locationLike) {
    const slots = new URLSearchParams(String(locationLike && locationLike.hash || "").replace(/^#/, ""));
    const values = slots.getAll("nested_request");
    if (!values.length) return null;
    if (values.length !== 1 || slots.has("request") || [...slots.keys()].some(key => key !== "nested_request")) {
      throw nestedError("Nested URL state requires exactly one isolated nested_request slot.", values.length !== 1 ? "duplicate-state-slot" : "invalid-nested-state");
    }
    return {raw: values[0], state: global.SelectoExplorerClient.decodeNestedDetailState(values[0])};
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

  // The resource GET's date_format values, from its OpenAPI query parameter:
  // {values, defaultValue}; no values when the API does not offer it.
  function discoverResourceDateFormats(openapi, resourcePath) {
    const paths = openapi && isPlainObject(openapi.paths) ? openapi.paths : {};
    const operations = Object.values(paths).map((pathSpec) => pathSpec && pathSpec.get).filter(isPlainObject);
    const operation = (paths[resourcePath] && paths[resourcePath].get)
      || operations.find((item) => ["getResource", "getCustomerResourceVersion"].includes(item.operationId));
    const parameters = [
      ...(paths[resourcePath] && Array.isArray(paths[resourcePath].parameters) ? paths[resourcePath].parameters : []),
      ...(operation && Array.isArray(operation.parameters) ? operation.parameters : []),
    ];
    const parameter = parameters.find((item) => isPlainObject(item) && item.in === "query" && item.name === "date_format");
    const schema = parameter && isPlainObject(parameter.schema) ? parameter.schema : {};
    const values = Array.isArray(schema.enum)
      ? schema.enum.filter((value) => typeof value === "string" && /^[a-z0-9_]+$/.test(value)) : [];
    return {values, defaultValue: values.includes(schema.default) ? schema.default : ""};
  }

  // Names for the date formats a resource GET may advertise; others show their own name.
  const DATE_FORMAT_LABELS = {
    iso8601: "ISO 8601",
    rfc3339_millis: "RFC 3339 with milliseconds",
    epoch_seconds: "Seconds since 1970",
    epoch_milliseconds: "Milliseconds since 1970",
  };
  function dateFormatLabel(value) {
    return DATE_FORMAT_LABELS[value] || value;
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

  function safeResourcePathTemplate(value, base) {
    const template = String(value || "");
    if (!template.startsWith(`${base}/`) || (template.match(/\{id\}/g) || []).length !== 1) return "";
    try {
      normalizeAPIBase(template.replace("{id}", "1"));
      return template;
    } catch (_error) {
      return "";
    }
  }

  function resourceRequestPath(template, id, fields, dateFormat) {
    const resourceId = String(id || "").trim();
    if (!template || !resourceId) return "";
    const path = template.replace("{id}", encodeURIComponent(resourceId));
    const selected = Array.from(new Set((fields || []).map((field) => String(field || "").trim()).filter(Boolean)));
    const query = [];
    if (selected.length) query.push(`fields=${selected.map(encodeURIComponent).join(",")}`);
    if (dateFormat) query.push(`date_format=${encodeURIComponent(dateFormat)}`);
    return query.length ? `${path}?${query.join("&")}` : path;
  }

  function fieldTraversesMany(domain, path) {
    const segments = String(path || "").split(".").filter(Boolean);
    if (segments.length < 2) return false;
    const schemas = domain && domain.schemas || {};
    let relation = domain && domain.source || {};
    for (const segment of segments.slice(0, -1)) {
      const association = relation && relation.associations && relation.associations[segment];
      if (!association) return false;
      if (associationIsMany(association, schemas)) return true;
      relation = schemas[association.queryable] || {};
    }
    return false;
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
    // getResource is the canonical resource read; getCustomerResourceVersion
    // is the customer API's earlier name for the same route.
    const resourceRoute = ["getResource", "getCustomerResourceVersion"]
      .map((operationId) => routes.find((item) => item
        && item.operation_id === operationId
        && String(item.method || "GET").toUpperCase() === "GET"))
      .find(Boolean);
    const resourcePath = safeResourcePathTemplate(
      resourceRoute && resourceRoute.path, normalizedBase,
    );
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
    const resourceDateFormats = discoverResourceDateFormats(openapi, resourcePath);
    return {base: normalizedBase, manifest, domain, openapi, queryPath, resourcePath, writePath, actionPath, access, queryResponseFormats, resourceDateFormats};
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

  function pickTone(path) {
    let hash = 2166136261;
    for (const character of String(path || "")) {
      hash = Math.imul(hash ^ character.charCodeAt(0), 16777619);
    }
    hash ^= hash >>> 16;
    return (hash >>> 0) % 8;
  }

  function markPicked(node, path) {
    node.classList.add("sac-is-picked", `sac-pick-tone-${pickTone(path)}`);
  }

  function fieldSignature(field) {
    return `${field.path} - ${field.type}`;
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
        leafLabel: fieldLabel,
        type: String(column.type || "string").toLowerCase(),
        relation: prefix || "Root",
        groupKey: prefix ? prefix.split(".")[0] : "",
        groupLabel: prefix ? relationshipLabel(prefix.split(".")[0], joins) : "",
        filterable: fieldRoleAllowed(column, "filter"),
        sortable: fieldRoleAllowed(column, "sort"),
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
    const source = domain && domain.source || {};
    // Identifiers users know (client or account numbers) stay visible only
    // when the domain lists them in components.picker_visible_id_paths.
    const visible = new Set((domain && domain.components && domain.components.picker_visible_id_paths) || []);
    const referenceKeys = new Set();
    Object.values(source.associations || {}).forEach((association) => {
      if (!association || !association.owner_key || association.owner_key === (source.primary_key || "id")) return;
      referenceKeys.add(association.owner_key);
    });
    const starKeys = new Set();
    Object.entries(domain && domain.joins || {}).forEach(([path, join]) => {
      if (!join || join.type !== "star_dimension") return;
      const parent = path.split(".").slice(0, -1).join(".");
      starKeys.add(parent ? `${parent}.${join.dimension_key}` : join.dimension_key);
    });
    output.forEach((field) => {
      const segments = field.path.split(".");
      const name = segments.at(-1);
      const root = segments.length === 1;
      field.pickerHidden = !visible.has(field.path) && (
        starKeys.has(field.path)
        || (root && referenceKeys.has(name))
        || ((name === "id" || name.endsWith("_id"))
          && !(root && name === (source.primary_key || "id")))
      );
    });
    return output.sort(compareSemanticFields);
  }

  function collectFilterFields(domain, fields) {
    const components = domain && domain.components || {};
    const hidden = Array.isArray(components.filter_picker_hidden_paths)
      ? components.filter_picker_hidden_paths : [];
    const choices = components.filter_choices || {};
    // Fields published filterable: false are refused by the API, so they are not offered.
    const available = fields.filter((field) => field.filterable !== false).map((field) => {
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

  // Choice filters offer the choice operators their field type accepts (not_in wherever in
  // is): a boolean Yes/No choice gets equals and does not equal, never one of.
  function operatorsForField(field) {
    if (!Array.isArray(field && field.filterChoices)) return operatorsForType(field.type);
    const accepted = new Set(operatorsForType(field.type));
    return ["eq", "ne", "in", "not_in", "is_null", "not_null"].filter((op) =>
      accepted.has(op) || (op === "not_in" && accepted.has("in")));
  }

  // A new filter starts on one of for choices whose type accepts it, else on equals.
  function initialFilterOperator(field) {
    return field && field.filterChoices && operatorsForField(field).includes("in") ? "in" : "eq";
  }

  // Explicit field roles (as the API enforces them): the first of the flags present decides,
  // and a field without any is allowed.
  const FIELD_ROLE_FLAGS = {
    filter: ["filterable", "filterable?", "query_filterable", "query_filterable?"],
    sort: ["sortable", "sortable?"],
  };
  function fieldRoleAllowed(column, role) {
    const flag = FIELD_ROLE_FLAGS[role].find((name) => Object.prototype.hasOwnProperty.call(column || {}, name));
    return flag === undefined || Boolean(column[flag]);
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
    if (["string", "text"].includes(type)) return [
      ...common, "not_in", "text_contains_ci", "starts_with_ci", "ends_with_ci",
      "text_contains", "starts_with", "ends_with",
    ];
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
      text_contains_ci: "contains (ignore case)",
      starts_with_ci: "starts with (ignore case)",
      ends_with_ci: "ends with (ignore case)",
      text_contains: "contains (match case)",
      starts_with: "starts with (match case)",
      ends_with: "ends with (match case)",
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

  // Result columns are typed descriptors ({id, label, type, ...}) under the
  // remote query profile, or bare id strings from hosts that predate it.
  function columnId(column) {
    if (isPlainObject(column)) return String(column.id ?? column.field ?? "");
    return column === null || column === undefined ? "" : String(column);
  }

  function columnLabel(column) {
    const label = isPlainObject(column) ? column.label : undefined;
    return typeof label === "string" && label !== "" ? label : columnId(column);
  }

  function rowValue(row, column, index) {
    if (Array.isArray(row)) return row[index];
    return row && typeof row === "object" ? row[columnId(column)] : undefined;
  }

  function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  }

  function onlyKeys(value, allowed) {
    return Object.keys(value).filter((key) => !allowed.includes(key));
  }

  function operationHeaderSpecs(openapi, path, method = "post") {
    const pathSpec = openapi && openapi.paths && openapi.paths[path];
    if (!isPlainObject(pathSpec)) return [];
    const operation = pathSpec[String(method).toLowerCase()];
    const parameters = [
      ...(Array.isArray(pathSpec.parameters) ? pathSpec.parameters : []),
      ...(operation && Array.isArray(operation.parameters) ? operation.parameters : []),
    ];
    const byName = new Map();
    parameters.forEach((parameter) => {
      if (!isPlainObject(parameter) || parameter.in !== "header"
        || typeof parameter.name !== "string"
        || !/^[A-Za-z][A-Za-z0-9-]*$/.test(parameter.name)) return;
      byName.set(parameter.name.toLowerCase(), {
        name: parameter.name,
        required: parameter.required === true,
        description: typeof parameter.description === "string" ? parameter.description : "",
      });
    });
    return Array.from(byName.values());
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
      this.resourcePath = "";
      this.writePath = `${this.base}/write`;
      this.actionPath = `${this.base}/actions/{action}`;
      this.access = {read: true, write: true, action: true, importer: false};
      this.queryResponseFormats = [Object.assign({}, QUERY_RESPONSE_FORMATS[0])];
      this.resourceDateFormats = {values: [], defaultValue: ""};
      this.fields = [];
      this.fieldMap = new Map();
      this.filterFields = [];
      this.filterFieldMap = new Map();
      this.availableGroupOpen = {field: new Map(), filter: new Map()};
      this.availableSearch = {field: "", filter: ""};
      this.nextSelectedFieldId = 1;
      this.postQueryFieldState = null;
      this.resourceQueryFieldState = null;
      this.state = {
        queryMethod: "post",
        resourceId: "",
        dateFormat: "",
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
      this.queryProfile = "flat";
      this.profileDrafts = {};
      this.nestedState = null;
      this.nextNestedFilterId = 1;
      this.writeState = {
        operation: "", assignments: {}, included: {}, filters: [],
        expectedCount: 1, returning: [], conflictTarget: [], updateFields: [],
        relationships: {}, headers: {},
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
        this.resourcePath = discovery.resourcePath;
        this.writePath = discovery.writePath;
        this.actionPath = discovery.actionPath;
        this.access = discovery.access;
        this.queryResponseFormats = discovery.queryResponseFormats;
        this.remoteMode = Array.isArray(this.manifest.profiles) && this.manifest.profiles.includes("remote_query.v1");
        if (this.remoteMode) {
          global.SelectoCanonicalClient.assertManifest(this.manifest);
          global.SelectoCanonicalClient.assertDomain(this.domain, this.manifest.domain.fingerprint);
          const catalogRoute = this.manifest.routes.find((route) => route.operation_id === "getDomainCatalog" && route.method === "GET");
          this.canonicalClient = global.SelectoCanonicalClient.createCanonicalClient({
            baseUrl: this.base,
            ...(catalogRoute ? {catalogPath: catalogRoute.path} : {}),
            headers: () => ({"X-CSRF-Token": this.csrfToken}),
          });
          const metadataRoute = this.manifest.routes.find((route) => route.operation_id === "getExplorerMetadata" && route.method === "GET");
          if (metadataRoute) {
            this.explorerMetadata = global.SelectoExplorerClient.assertExplorerMetadata(
              await this.canonicalClient.metadata(metadataRoute.path), this.manifest, undefined, this.domain,
            );
            if (catalogRoute) {
              const catalog = await this.canonicalClient.catalog();
              const entry = catalog.domains.find((domain) => domain.id === this.explorerMetadata.domain.id);
              if (!entry) throw new Error("This domain is not in the current authenticated catalog.");
              global.SelectoExplorerClient.assertExplorerMetadata(this.explorerMetadata, this.manifest, entry);
            }
          }
          // Remote v1 results have one JSON envelope. Legacy downloads retain
          // their existing explicit bare-query mode on hosts without the profile.
          this.queryResponseFormats = [Object.assign({}, QUERY_RESPONSE_FORMATS[0])];
        }
        if (this.remoteMode) {
          const catalogRoute = this.manifest.routes.find((route) => route.operation_id === "getDomainCatalog" && route.method === "GET");
          this.explorerClient = global.SelectoExplorerClient.createExplorerClient({baseUrl:this.base,
            ...(catalogRoute ? {catalogPath:catalogRoute.path} : {}),headers:() => ({"X-CSRF-Token":this.csrfToken})});
          if (this.explorerMetadata && this.manifest.profiles.includes("remote_query.v2")) this.rootPredicateContext = await this.explorerClient.getRootPredicateContext(this.explorerMetadata.domain.id);
          if (this.manifest.routes.some(route => route.operation_id === "getNestedDetailFeatures" && route.method === "GET")) {
            try {
              const features = await this.canonicalClient.nestedDetailFeatures(this.manifest);
              this.nestedDomainId = features.domain.id;
              this.nestedDetailContext = await this.explorerClient.getNestedDetailContext(this.nestedDomainId);
            } catch (error) { this.nestedAvailabilityError = error.message; this.nestedAvailabilityRefusal = this.nestedDiscoveryFailure(error); }
          }
        }
        this.resourceDateFormats = discovery.resourceDateFormats || {values: [], defaultValue: ""};
        this.state.responseFormat = this.queryResponseFormats[0].id;
        this.state.responseFilename = suggestedDownloadFilename(
          this.domain.name, this.responseFormat(this.state.responseFormat).extension,
        );
        this.fields = collectFields(discovery.domain);
        this.fieldMap = new Map(this.fields.map((field) => [field.path, field]));
        this.filterFields = collectFilterFields(discovery.domain, this.fields);
        this.filterFieldMap = new Map(this.filterFields.map((field) => [field.path, field]));
        this.seedState();
        const initialRequestRaw = new URLSearchParams(String(global.location.hash || "").replace(/^#/, "")).get("request");
        let initialRequest = null;
        let initialRequestError = null;
        let initialNested = null;
        try {
          initialNested = nestedStateFromLocation(global.location);
          if (!initialNested) initialRequest = requestPayloadFromLocation(global.location);
          if (initialRequest && initialRequest.format !== "selecto.root-predicate-state") this.loadPayloadIntoChooser(initialRequest);
        } catch (error) {
          initialRequestError = error;
          this.blockedInitialRequestText = initialRequestRaw;
          if (new URLSearchParams(String(global.location.hash || "").replace(/^#/, "")).has("nested_request")) {
            this.blockedInitialRequestText = new URLSearchParams(String(global.location.hash || "").replace(/^#/, "")).get("nested_request");
            this.nestedInitialError = error;
          }
        }
        this.render();
        if (initialNested) {
          await this.restoreNestedState(initialNested.raw);
        } else if (this.nestedInitialError) {
          this.queryProfile = "nested";
          this.nestedBlocked = true;
          this.root.querySelector("[data-sac-request]").value = this.blockedInitialRequestText || "";
          const stateEditor = this.root.querySelector("[data-sac-nested-state]");
          if (stateEditor) stateEditor.value = this.blockedInitialRequestText || "";
          this.applyQueryProfile();
          this.setImportMessage(`Nested state blocked: ${this.nestedInitialError.message}`, "error", this.nestedInitialError);
        } else if (initialRequest?.format === "selecto.root-predicate-state") {
          const raw = new URLSearchParams(String(global.location.hash || "").replace(/^#/, "")).get("request");
          await this.restoreRootState(raw);
        } else if (initialRequestError) {
          if (initialRequest || initialRequestRaw) {
            const stateEditor = this.root.querySelector("[data-sac-root-state]"); if (stateEditor) stateEditor.value = initialRequestRaw;
            const editor = this.root.querySelector("[data-sac-request]");
            editor.value = initialRequestRaw || JSON.stringify(initialRequest, null, 2);
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
        if (global.SelectoCanonicalClient && payload?.ok === false && payload.error?.code && payload.error?.details) {
          throw new global.SelectoCanonicalClient.CanonicalHttpError(response.status,global.SelectoCanonicalClient.assertError(payload));
        }
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

    setQueryMethod(value) {
      const nextMethod = value === "get" && this.resourcePath ? "get" : "post";
      if (nextMethod === "get" && this.state.queryMethod !== "get") {
        this.postQueryFieldState = {
          selectedFields: this.state.selectedFields.map((selection) => ({...selection})),
          subtables: this.state.subtables.slice(),
          configuredField: this.state.configuredField,
        };
        const saved = this.resourceQueryFieldState;
        this.state.selectedFields = saved
          ? saved.selectedFields.map((selection) => ({...selection}))
          : this.state.selectedFields
              .filter((selection) => !fieldTraversesMany(this.domain, selection.field))
              .map((selection) => ({...selection, alias: "", format: ""}));
        this.state.subtables = [];
        this.state.configuredField = "";
      } else if (nextMethod === "post" && this.state.queryMethod === "get") {
        this.resourceQueryFieldState = {
          selectedFields: this.state.selectedFields.map((selection) => ({...selection})),
        };
        if (this.postQueryFieldState) {
          this.state.selectedFields = this.postQueryFieldState.selectedFields
            .map((selection) => ({...selection}));
          this.state.subtables = this.postQueryFieldState.subtables.slice();
          this.state.configuredField = this.postQueryFieldState.configuredField;
        }
      }
      this.state.queryMethod = nextMethod;
      this.state.rawDirty = false;
      return nextMethod;
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
                <fieldset class="sac-method-choice" data-sac-query-method-group hidden>
                  <legend class="sac-label">Request method</legend>
                  <label class="sac-method-option"><input type="radio" name="sac-query-method" value="post" data-sac-query-method> POST query</label>
                  <label class="sac-method-option"><input type="radio" name="sac-query-method" value="get" data-sac-query-method> GET resource</label>
                </fieldset>
                <div data-sac-resource-id-wrap hidden>
                  <label class="sac-label" for="sac-resource-id">Resource ID</label>
                  <input id="sac-resource-id" type="text" inputmode="numeric" placeholder="7001" data-sac-resource-id>
                  <p class="sac-help">The resource GET always returns the ID. Selected fields are added through <code>fields=</code>; choose Aggregate Version, when the domain publishes it, for the resource version and its ETag.</p>
                  <div data-sac-date-format-wrap hidden>
                    <label class="sac-label" for="sac-date-format">Date format</label>
                    <select id="sac-date-format" data-sac-date-format></select>
                    <p class="sac-help">Applies to every date and time field of the resource, in UTC (<code>date_format=</code>).</p>
                  </div>
                </div>
                <div data-sac-post-source>
                  <label class="sac-label" for="sac-source-mode">Query source</label>
                  <select id="sac-source-mode" data-sac-mode>
                    <option value="select">Choose fields</option>
                    <option value="projection">Named projection</option>
                    <option value="view">Named view</option>
                  </select>
                </div>
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
              <section class="sac-card" data-sac-post-query-card>
                <div class="sac-card-heading"><div><span class="sac-step">2</span><h2>Constrain</h2></div></div>
                <div data-sac-segment-list>
                  <span class="sac-label">Named segments</span>
                  <div class="sac-segment-options" data-sac-segments></div>
                </div>
                <div class="sac-segment-groups" data-sac-segment-groups></div>
                <div class="sac-parameters" data-sac-parameters></div>
                <div class="sac-filter-list" data-sac-filters></div>
                <label class="sac-label" for="sac-filter-search">Available filters</label>
                <input id="sac-filter-search" type="search" placeholder="Search filter fields" data-sac-filter-search>
                <div class="sac-field-list sac-filter-field-list" data-sac-filter-field-list></div>
              </section>
              <section class="sac-card" data-sac-post-query-card>
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
                  <div><span class="sac-method" data-sac-query-method-badge>POST</span><code data-sac-query-path></code></div>
                  <div class="sac-compact-actions"><span class="sac-edited" data-sac-edited hidden>Manually edited</span><span data-sac-post-editor-actions><button type="button" class="sac-text-button" data-sac-load-json>Load into chooser</button><button type="button" class="sac-text-button" data-sac-reset-json>Reset JSON</button></span><button type="button" class="sac-text-button" data-sac-copy-request>Copy</button></div>
                </div>
                <div class="sac-import-message" data-sac-import-message hidden></div>
                ${this.remoteMode ? `<div class="sac-root-controls">
                  <label>Query profile<select aria-label="Query profile" data-sac-root-mode><option value="flat">Flat Detail (v1)</option><option value="root" ${this.rootPredicateContext ? "" : "disabled"}>Recursive root predicates (v2)</option><option value="nested" ${this.nestedDetailContext ? "" : "disabled"}>Complete nested Detail (v1)</option></select></label>
                  <p data-sac-root-availability>${this.rootPredicateContext ? "Recursive root predicates available; opt in explicitly." : "Recursive root predicates unavailable on this publication."}</p>
                  <p data-sac-nested-availability></p>
                  <details><summary>Root predicate state</summary><label>Root predicate state<textarea aria-label="Root predicate state" data-sac-root-state spellcheck="false"></textarea></label>
                    <button type="button" data-sac-root-restore>Restore root state</button><button type="button" data-sac-root-link>Copy root state link</button>
                    <button type="button" data-sac-root-save>Save private root state</button><button type="button" data-sac-root-private>Restore private root state</button>
                  </details>
                  <details data-sac-nested-state-controls><summary>Nested Detail state</summary><label>Nested Detail state<textarea aria-label="Nested Detail state" data-sac-nested-state spellcheck="false"></textarea></label>
                    <button type="button" data-sac-nested-restore>Restore nested state</button><button type="button" data-sac-nested-link>Copy nested state link</button>
                    <button type="button" data-sac-nested-save>Save private nested state</button><button type="button" data-sac-nested-private>Restore private nested state</button>
                  </details>
                </div>` : ""}
                <section class="sac-nested-builder" data-sac-nested-builder hidden></section>
                <textarea class="sac-request-editor" spellcheck="false" aria-label="Query request" data-sac-request></textarea>
                <div class="sac-run-row"><p>All fields and identifiers are validated against the published domain.</p><button type="button" class="sac-button" data-sac-cancel-query hidden>Cancel query</button><button type="button" class="sac-button sac-primary" data-sac-run><span data-sac-run-label>Run query</span></button></div>
              </section>
              <section class="sac-response-card">
                <div class="sac-response-heading">
                  <div><h2>Response</h2><span class="sac-response-status" data-sac-response-status>Ready</span><p data-sac-page-info hidden></p></div>
                  <div class="sac-result-tabs" role="tablist">
                    <button type="button" class="is-active" data-sac-result-tab="table">Table</button>
                    <button type="button" data-sac-result-tab="json">JSON</button>
                    <button type="button" data-sac-result-tab="curl">cURL</button>
                  </div>
                </div>
                <div class="sac-page-info" data-sac-legacy-page-info hidden>
                  <span data-sac-page-text></span>
                  <button type="button" class="sac-text-button" data-sac-previous-page>← Previous page</button>
                  <button type="button" class="sac-text-button" data-sac-next-page>Next page →</button>
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
      // The method choice appears only when the API offers resource GET.
      this.root.querySelector("[data-sac-query-method-group]").hidden = !this.resourcePath;
      this.root.querySelector("[data-sac-write-path]").textContent = this.writePath;
      this.root.querySelector("[data-sac-domain-link]").href = `${this.base}/domain`;
      this.root.querySelector("[data-sac-openapi-link]").href = `${this.base}/openapi.json`;
      const importerLink = this.root.querySelector("[data-sac-importer-link]");
      importerLink.href = `${this.base}/import`;
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
      const nestedAvailability = this.root.querySelector("[data-sac-nested-availability]");
      if (nestedAvailability) nestedAvailability.textContent = this.nestedDetailContext
        ? "Complete nested Detail available; opt in explicitly."
        : `Complete nested Detail unavailable on this publication.${this.nestedAvailabilityError ? ` ${this.nestedAvailabilityError}` : ""}`;
      setNestedRefusal(nestedAvailability, this.nestedDetailContext ? null : this.nestedAvailabilityRefusal || nestedError("Complete nested Detail unavailable on this publication.", "nested-unavailable"));
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
      const library = this.domain.query_library || {};
      const segments = library.segments || {};
      const inherited = this.state.mode === "view"
        ? (((library.views || {})[this.state.view] || {}).segments || []) : [];
      const grouped = new Set(this.segmentGroups().flatMap((group) => group.choices.map((choice) => choice.segment)));
      return Object.entries(segments)
        .filter(([id, spec]) => !grouped.has(id) && (!(spec && spec.picker_hidden)
          || this.state.segments.includes(id) || inherited.includes(id)))
        .map(([id, spec]) => ({value: id, label: (spec && spec.label) || humanize(id),
          description: spec && spec.description || ""}));
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

    renderSegments(options) {
      const container = this.root.querySelector("[data-sac-segments]");
      container.replaceChildren();
      const library = this.domain.query_library || {};
      const inherited = this.state.mode === "view"
        ? (((library.views || {})[this.state.view] || {}).segments || []) : [];
      options.forEach((option) => {
        const label = element("label", "sac-segment-option");
        const checkbox = element("input");
        checkbox.type = "checkbox";
        checkbox.value = option.value;
        checkbox.dataset.sacSegmentChoice = "";
        checkbox.checked = this.state.segments.includes(option.value) || inherited.includes(option.value);
        checkbox.disabled = inherited.includes(option.value);
        const copy = element("span");
        copy.append(element("strong", "", option.label));
        if (option.description) copy.append(element("small", "sac-help", option.description));
        label.append(checkbox, copy);
        container.append(label);
      });
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

    writeHeaderSpecs() {
      return operationHeaderSpecs(this.openapi, this.writePath);
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

      const headerSpecs = this.writeHeaderSpecs();
      if (headerSpecs.length) {
        container.append(element("span", "sac-label", "Request headers"));
        const headers = element("div", "sac-mutation-fields");
        headerSpecs.forEach((spec) => {
          const row = element("label", "sac-mutation-field");
          const copy = element("span", "");
          copy.append(
            element("strong", "", `${spec.name}${spec.required ? " *" : ""}`),
            element("code", "", "header"),
          );
          if (spec.description) copy.append(element("small", "sac-help", spec.description));
          const input = this.valueControl("text", this.writeState.headers[spec.name], {
            dataset: {sacWriteHeader: spec.name}, required: spec.required,
          });
          row.append(copy, input);
          headers.append(row);
        });
        container.append(headers);
      }

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
      const resourceGet = this.state.queryMethod === "get" && Boolean(this.resourcePath);
      const mode = this.state.mode;
      this.root.querySelectorAll("[data-sac-query-method]").forEach((radio) => {
        radio.checked = radio.value === (resourceGet ? "get" : "post");
      });
      this.root.querySelector("[data-sac-resource-id-wrap]").hidden = !resourceGet;
      this.root.querySelector("[data-sac-resource-id]").value = this.state.resourceId;
      this.renderDateFormats();
      this.root.querySelector("[data-sac-post-source]").hidden = resourceGet;
      this.root.querySelectorAll("[data-sac-post-query-card]").forEach((card) => (card.hidden = resourceGet));
      this.root.querySelector("[data-sac-post-editor-actions]").hidden = resourceGet;
      this.root.querySelector("[data-sac-query-method-badge]").textContent = resourceGet ? "GET" : "POST";
      this.root.querySelector("[data-sac-run-label]").textContent = resourceGet ? "Run GET" : "Run query";
      this.root.querySelector("[data-sac-mode]").value = mode;
      this.root.querySelector("[data-sac-select-mode]").hidden = !resourceGet && mode !== "select";
      this.root.querySelector("[data-sac-projection-mode]").hidden = resourceGet || mode !== "projection";
      this.root.querySelector("[data-sac-view-mode]").hidden = resourceGet || mode !== "view";
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
      this.renderSegments(segmentOptions);
      this.renderSegmentGroups();
      this.renderSelectedFields();
      this.renderNormalization();
      if (resourceGet) this.root.querySelector("[data-sac-normalization]").hidden = true;
      this.renderFieldList();
      this.renderViewHelp();
      this.renderParameters();
      this.renderFilters();
      this.renderFilterFieldList();
      this.renderOrders();
      this.syncRequest();
    }

    renderDateFormats() {
      const {values, defaultValue} = this.resourceDateFormats;
      this.root.querySelector("[data-sac-date-format-wrap]").hidden = !values.length;
      const select = this.root.querySelector("[data-sac-date-format]");
      select.replaceChildren();
      appendOptions(select, [
        {value: "", label: defaultValue ? `Default (${dateFormatLabel(defaultValue)})` : "Default"},
        ...values.filter((value) => value !== defaultValue).map((value) => ({value, label: dateFormatLabel(value)})),
      ], this.state.dateFormat);
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
        container.append(element(
          "p", "sac-muted",
          this.state.queryMethod === "get"
            ? "No additional fields selected; the baseline resource fields will still be returned."
            : "Choose at least one field.",
        ));
        return;
      }
      this.state.selectedFields.forEach((selection, index) => {
        const path = selection.field;
        const field = this.fieldMap.get(path) || {path, label: path, type: "field"};
        const row = element("div", "sac-selected-field");
        markPicked(row, path);
        row.dataset.field = path;
        row.dataset.selectionId = selection.id;
        const handle = element("span", "sac-drag", "⋮⋮");
        handle.setAttribute("aria-hidden", "true");
        const copy = element("div", "sac-selected-copy");
        copy.append(element("strong", "", field.label), element("code", "", fieldSignature(field)));
        const configured = [selection.alias && `as ${selection.alias}`, selection.format].filter(Boolean).join(" · ");
        if (configured) copy.append(element("small", "sac-field-config-summary", configured));
        const actions = element("div", "sac-field-actions");
        const actionsAvailable = this.state.queryMethod === "get"
          ? [["up", "↑", "Move up"], ["down", "↓", "Move down"], ["remove", "×", "Remove"]]
          : [["configure", "Configure", "Configure"], ["up", "↑", "Move up"], ["down", "↓", "Move down"], ["remove", "×", "Remove"]];
        actionsAvailable.forEach(([action, text, label]) => {
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
      this.renderAvailableFields("field", this.fields.filter((field) =>
        !field.pickerHidden
          && (this.state.queryMethod !== "get" || !fieldTraversesMany(this.domain, field.path))
      ));
    }

    renderAvailableFields(kind, fields) {
      const query = (this.root.querySelector(kind === "field" ? "[data-sac-field-search]" : "[data-sac-filter-search]").value || "").trim().toLowerCase();
      const container = this.root.querySelector(kind === "field" ? "[data-sac-field-list]" : "[data-sac-filter-field-list]");
      const selected = new Set(kind === "field"
        ? this.state.selectedFields.map((selection) => selection.field)
        : this.state.filters.map((filter) => filter.field));
      if (!this.availableSearch[kind]) container.querySelectorAll("[data-sac-available-group]").forEach((group) => {
        this.availableGroupOpen[kind].set(group.dataset.sacAvailableGroup, group.open);
      });
      container.replaceChildren();
      const groups = new Map();
      fields.forEach((field) => {
        const key = field.groupKey || "";
        if (!groups.has(key)) groups.set(key, {label: field.groupLabel || this.domain.name || "Main record", fields: []});
        groups.get(key).fields.push(field);
      });
      const ordered = [...groups].sort(([a, left], [b, right]) =>
        !a ? -1 : !b ? 1 : left.label.localeCompare(right.label));
      let shown = 0;
      ordered.forEach(([key, group]) => {
        const headingMatches = query && `${group.label} ${key}`.toLowerCase().includes(query);
        const matches = group.fields.filter((field) => !query || headingMatches
          || `${field.path} ${field.label} ${field.type}`.toLowerCase().includes(query));
        if (!matches.length) return;
        shown += matches.length;
        const details = element("details", "sac-available-group");
        details.dataset.sacAvailableGroup = key;
        details.open = query ? true : (this.availableGroupOpen[kind].get(key) ?? !key);
        details.append(element("summary", "", `${group.label} (${matches.length})`));
        matches.forEach((field) => {
          const button = element("button", "sac-available-field");
          button.type = "button";
          if (kind === "field") button.dataset.sacAddField = field.path;
          else button.dataset.sacAddFilter = field.path;
          if (selected.has(field.path)) {
            markPicked(button, field.path);
            button.setAttribute("aria-label", `Add another ${field.label} ${kind === "field" ? "column" : "filter"}`);
          }
          const copy = element("span");
          copy.append(element("strong", "", field.groupKey ? field.leafLabel || field.label : field.label));
          copy.append(element("code", "", fieldSignature(field)));
          button.append(copy, element("b", "", "+"));
          details.append(button);
        });
        container.append(details);
      });
      if (!shown) container.append(element("p", "sac-muted", `No matching available ${kind === "field" ? "fields" : "filters"}.`));
      this.availableSearch[kind] = query;
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
        markPicked(row, field.path);
        row.dataset.filterId = filter.id;
        const heading = element("div", "sac-filter-heading");
        const copy = element("span", "sac-selected-copy");
        copy.append(element("strong", "", field.label));
        copy.append(element("code", "", fieldSignature(field)));
        const remove = element("button", "sac-icon-button", "×");
        remove.type = "button";
        remove.dataset.sacRemoveFilter = filter.id;
        remove.setAttribute("aria-label", `Remove ${field.label} filter`);
        heading.append(copy, remove);
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
      this.renderAvailableFields("filter", this.filterFields.filter((field) =>
        !field.pickerHidden));
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
        appendOptions(field, this.sortFields().map((item) => ({value: item.path, label: `${item.label} — ${item.path}`})), order.field);
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

    // Fields that can be sorted on: the API refuses sortable: false.
    sortFields() {
      return this.fields.filter((field) => field.sortable !== false);
    }

    filterPayloads(filter) {
      const field = this.filterFieldMap.get(filter.field);
      const payload = {field: filter.field, op: this.remoteMode && filter.op === "not_null" ? "is_not_null" : filter.op};
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
      if (this.queryProfile === "nested") {
        if (this.nestedBlocked || !this.nestedState) throw new Error("Nested state remains blocked; restore valid bound state or explicitly start a new draft.");
        const context = this.nestedDetailContext;
        const query = global.SelectoExplorerClient.toNestedDetailQuery(this.nestedState.intent, context);
        return global.SelectoCanonicalClient.buildNestedDetailRequest(this.nestedState.intent.binding.fingerprint, query,
          {features: context.features, context: global.SelectoCanonicalClient.nestedDetailContext(context.features)});
      }
      if (this.rootMode && !this.rootState) throw new Error("Root state remains blocked; restore valid bound state or explicitly select Flat Detail.");
      if (this.rootState && this.rootMode) {
        const query = global.SelectoExplorerClient.toRootPredicateQuery(this.rootState.intent,this.rootPredicateContext);
        return global.SelectoCanonicalClient.buildRootPredicateRequest(this.rootState.intent.binding.fingerprint,query,{features:this.rootPredicateContext.features});
      }
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
      if (this.state.filters.length || this.remoteMode) payload.filters = this.state.filters.flatMap((filter) => this.filterPayloads(filter));
      if (this.state.ordering) payload.ordering = this.state.ordering;
      else if (this.state.orders.length || this.remoteMode) payload.order_by = this.state.orders.map((order) => ({field: order.field, direction: order.direction}));
      if (String(this.state.timezone || "").trim()) payload.timezone = String(this.state.timezone).trim();
      // The shared Detail adapter uses the protocol's array default. Keep
      // handoff intent identical while retaining the explicit object choice.
      if (!this.remoteMode || this.state.rowFormat !== "arrays") payload.row_format = this.state.rowFormat;
      payload.limit = Number.parseInt(this.state.limit, 10) || 0;
      payload.offset = Number.parseInt(this.state.offset, 10) || 0;
      return this.remoteMode
        ? global.SelectoCanonicalClient.buildRemoteRequest(this.manifest.domain.fingerprint, payload)
        : payload;
    }

    buildResourceRequest() {
      const errors = [];
      const id = String(this.state.resourceId || "").trim();
      const source = this.domain && this.domain.source || {};
      const primaryKey = source.primary_key || "id";
      const primaryType = source.columns && source.columns[primaryKey]
        && source.columns[primaryKey].type || "string";
      if (!id) errors.push("Resource ID is required.");
      else if (["integer", "int", "bigint"].includes(String(primaryType).toLowerCase())
        && !/^[1-9]\d*$/.test(id)) errors.push("Resource ID must be a positive integer.");
      const baseline = new Set(["id", "customer_reference", "aggregate_version"]);
      const fields = [];
      const seen = new Set();
      this.state.selectedFields.forEach((selection) => {
        const field = String(selection.field || "");
        if (!field || baseline.has(field) || seen.has(field)) return;
        seen.add(field);
        if (fieldTraversesMany(this.domain, field)) {
          errors.push(`${field} crosses a to-many relationship; use POST query.`);
          return;
        }
        fields.push(field);
      });
      if (fields.length > 50) errors.push("GET resource allows at most 50 additional fields.");
      const dateFormat = String(this.state.dateFormat || "");
      if (dateFormat && !this.resourceDateFormats.values.includes(dateFormat)) {
        errors.push(`The API does not offer the date format ${dateFormat}.`);
      }
      return {
        path: errors.length ? "" : resourceRequestPath(this.resourcePath, id, fields, dateFormat),
        fields,
        errors,
      };
    }

    chooserStateFromPayload(payload) {
      if (!isPlainObject(payload)) throw new Error("The request must be a JSON object.");
      if (payload.version === 2 && payload.domainId) payload = global.SelectoExplorerClient.flatSnapshotToRequest(payload);
      if (payload.schema === "selecto.spa.query-request/v1") {
        if (!this.explorerMetadata) throw new Error("This host does not advertise Explorer metadata for handoff.");
        payload = global.SelectoExplorerClient.toCanonicalQuery(payload, this.explorerMetadata);
      } else if (payload.format === "selecto.remote-query") {
        if (payload.format_version !== 1 || !payload.domain || payload.domain.fingerprint !== this.manifest.domain.fingerprint) throw new Error("The request targets a different Domain fingerprint.");
        payload = payload.query;
      }
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
          if (this.remoteMode && filter.op === "is_not_null") filter = {...filter, op: "not_null"};
          const extra = onlyKeys(filter, ["field", "op", "value", "end"]);
          if (extra.length) throw new Error(`Unsupported filter properties: ${extra.join(", ")}.`);
          const field = this.filterFieldMap.get(filter.field);
          if (!field && this.fieldMap.has(filter.field)) throw new Error(`${filter.field} cannot be used in filters.`);
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
          if (this.fieldMap.get(order.field).sortable === false) throw new Error(`${order.field} cannot be used for sorting.`);
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

    setImportMessage(message, kind, error) {
      const target = this.root.querySelector("[data-sac-import-message]");
      if (!target) return;
      target.textContent = message || "";
      target.dataset.kind = kind || "";
      target.hidden = !message;
      setNestedRefusal(target, message && kind === "error" ? error : null);
    }

    nestedDiscoveryFailure(error) {
      const client = global.SelectoCanonicalClient;
      if (error instanceof client.CanonicalHttpError && error.status === 401 && error.code === "authentication_required") return client.markNestedDetailRefusal(error, "authentication-required");
      if (error instanceof client.CanonicalWireError) return client.markNestedDetailRefusal(error, "nested-unavailable");
      return error;
    }

    async freshNestedContext(signal, domainId = this.nestedState?.intent.binding.domain_id || this.nestedDomainId) {
      if (!this.explorerClient || !domainId) throw nestedError("Complete nested Detail unavailable on this publication.", "nested-unavailable");
      if (this.nestedDomainId && domainId !== this.nestedDomainId) throw nestedError("Nested state belongs to a different Console domain.", "stale-nested-context");
      return this.explorerClient.getNestedDetailContext(domainId, {signal});
    }

    retainProfileDraft() {
      const editor = this.root.querySelector("[data-sac-request]");
      this.profileDrafts[this.queryProfile] = {raw: editor?.value || "", rawDirty: this.state.rawDirty,
        ...(this.queryProfile === "flat" ? {state: structuredClone(this.state)} : {})};
    }

    applyQueryProfile() {
      const nested = this.queryProfile === "nested";
      this.rootMode = this.queryProfile === "root";
      const selector = this.root.querySelector("[data-sac-root-mode]"); if (selector) selector.value = this.queryProfile;
      const method = this.root.querySelector("[data-sac-query-method-badge]"); if (method && nested) method.textContent = "POST";
      const builder = this.root.querySelector(".sac-builder"); if (builder) builder.hidden = this.queryProfile !== "flat";
      const panel = this.root.querySelector("[data-sac-nested-builder]"); if (panel) panel.hidden = !nested;
      const actions = this.root.querySelector("[data-sac-post-editor-actions]"); if (actions) actions.hidden = this.queryProfile === "root";
      if (nested) this.renderNestedBuilder();
    }

    async selectQueryProfile(value, fresh = false) {
      if (!["flat", "root", "nested"].includes(value)) throw new Error("Unknown query profile.");
      this.retainProfileDraft();
      if (fresh) delete this.profileDrafts[value];
      if (fresh && value === "nested") this.nestedInitialError = null;
      this.cancelQuery();
      this.rootRestoreSequence = (this.rootRestoreSequence || 0) + 1;
      const sequence = this.nestedRestoreSequence = (this.nestedRestoreSequence || 0) + 1;
      this.queryProfile = value;
      this.blockedInitialRequestText = null;
      this.state.response = null; this.nestedResult = null;
      this.clearQueryResult();
      this.applyQueryProfile();
      const saved = this.profileDrafts[value];
      if (value === "flat") {
        if (saved?.state) Object.assign(this.state, saved.state, {response: null});
        this.state.rawDirty = Boolean(saved?.rawDirty);
        this.renderAll();
        if (saved) {
          this.root.querySelector("[data-sac-request]").value = saved.raw;
          this.state.rawDirty = saved.rawDirty;
          const edited = this.root.querySelector("[data-sac-edited]"); if (edited) edited.hidden = !saved.rawDirty;
        }
        this.setImportMessage("Flat Detail draft restored.", "success");
        this.updateCurl(); return;
      }
      if (value === "root") {
        if (saved) {
          this.root.querySelector("[data-sac-request]").value = saved.raw;
          this.state.rawDirty = saved.rawDirty;
          this.updateCurl(); return;
        }
        return this.selectRootMode("root");
      }
      if (saved) {
        this.root.querySelector("[data-sac-request]").value = saved.raw;
        this.state.rawDirty = saved.rawDirty;
        this.renderNestedBuilder(); this.updateCurl(); return;
      }
      try {
        const context = await this.freshNestedContext();
        if (sequence !== this.nestedRestoreSequence || this.queryProfile !== "nested") return;
        this.nestedDetailContext = context;
        this.nestedState = {format: "selecto.nested-detail-state", format_version: 1,
          intent: global.SelectoExplorerClient.createNestedDetailIntent(context.features)};
        this.nestedBlocked = false; this.nestedInitialError = null;
        this.syncNestedRequest(); this.renderNestedBuilder();
        this.setImportMessage("New nested draft uses the current authenticated publication.", "success");
      } catch (error) {
        if (sequence !== this.nestedRestoreSequence || this.queryProfile !== "nested") return;
        this.nestedBlocked = true;
        this.setImportMessage(`Nested mode blocked: ${error.message}`, "error", error);
      }
    }

    async restoreNestedState(raw) {
      this.retainProfileDraft();
      this.cancelQuery();
      this.rootRestoreSequence = (this.rootRestoreSequence || 0) + 1;
      const sequence = this.nestedRestoreSequence = (this.nestedRestoreSequence || 0) + 1;
      this.queryProfile = "nested"; this.nestedState = null; this.nestedBlocked = true;
      this.nestedInitialError = null;
      const editor = this.root.querySelector("[data-sac-request]"); editor.value = raw;
      const stateEditor = this.root.querySelector("[data-sac-nested-state]"); if (stateEditor) stateEditor.value = raw;
      this.state.rawDirty = true;
      this.state.response = null; this.nestedResult = null; this.clearQueryResult();
      this.applyQueryProfile();
      try {
        const state = global.SelectoExplorerClient.decodeNestedDetailState(raw);
        const context = await this.freshNestedContext(undefined, state.intent.binding.domain_id);
        if (sequence !== this.nestedRestoreSequence || this.queryProfile !== "nested") return false;
        global.SelectoExplorerClient.assertNestedDetailIntent(state.intent, context, {origin:"state"});
        this.nestedDetailContext = context; this.nestedDomainId = state.intent.binding.domain_id;
        this.nestedState = state; this.nestedBlocked = false; this.blockedInitialRequestText = null; this.nestedInitialError = null;
        while (state.intent.filters.some(filter=>filter.id === `nested-filter-${this.nextNestedFilterId}`)) this.nextNestedFilterId++;
        this.syncNestedRequest(); this.renderNestedBuilder();
        this.setImportMessage("Nested state restored. Selection, filters, page and exact presentation retained; Run is explicit.", "success");
        return true;
      } catch (error) {
        if (sequence !== this.nestedRestoreSequence || this.queryProfile !== "nested") return false;
        this.nestedInitialError = error;
        this.setImportMessage(`Nested state blocked: ${error.message}`, "error", error);
        this.setStatus(error.message, "error", error); return false;
      }
    }

    syncNestedRequest() {
      const payload = this.buildPayload();
      const editor = this.root.querySelector("[data-sac-request]");
      editor.value = JSON.stringify(payload, null, 2); editor.readOnly = false;
      this.nestedStateRequestText = editor.value;
      const stateEditor = this.root.querySelector("[data-sac-nested-state]");
      if (stateEditor) stateEditor.value = JSON.stringify(this.nestedState);
      this.state.rawDirty = false;
      const edited = this.root.querySelector("[data-sac-edited]"); if (edited) edited.hidden = true;
      const run = this.root.querySelector("[data-sac-run]"); if (run) run.disabled = false;
      this.updateCurl();
    }

    nestedChanged(mutator, renderBuilder = true) {
      if (!this.nestedState || this.nestedBlocked) return;
      // Invalid partial builder edits stay visible. Only Run/Save requires a complete intent.
      mutator(this.nestedState.intent);
      this.nestedRestoreSequence = (this.nestedRestoreSequence || 0) + 1;
      this.cancelQuery(); this.nestedResult = null; this.state.response = null;
      this.clearQueryResult();
      const stateEditor = this.root.querySelector("[data-sac-nested-state]");
      if (stateEditor) stateEditor.value = JSON.stringify(this.nestedState);
      try { this.syncNestedRequest(); this.setImportMessage("", ""); }
      catch (error) {
        this.root.querySelector("[data-sac-run]").disabled = true;
        this.setImportMessage(`Nested draft incomplete: ${error.message}`, "error", error);
      }
      if (renderBuilder) this.renderNestedBuilder();
    }

    nestedStateStorageKey() { return `selecto.console.nested-state:${this.base}`; }
    async nestedStateAction(action) {
      const stateEditor = this.root.querySelector("[data-sac-nested-state]");
      try {
        if (action === "restore") return this.restoreNestedState(stateEditor.value);
        if (action === "private") {
          const saved = global.localStorage.getItem(this.nestedStateStorageKey());
          if (!saved) throw nestedError("No private nested state saved.", "invalid-nested-state");
          return this.restoreNestedState(saved);
        }
        if (this.queryProfile !== "nested" || this.nestedBlocked || !this.nestedState) throw nestedError("Restore a complete nested draft first.", "invalid-nested-state");
        const state = global.SelectoExplorerClient.decodeNestedDetailState(stateEditor.value);
        const editor = this.root.querySelector("[data-sac-request]");
        const stateText = stateEditor.value;
        const matches = () => this.queryProfile === "nested" && stateEditor.value === stateText && editor.value === this.nestedStateRequestText && JSON.stringify(state) === JSON.stringify(this.nestedState);
        if (!matches()) throw nestedError("State and query editor differ. Restore the complete intended nested state before saving or sharing.", "invalid-nested-state");
        const context = await this.freshNestedContext();
        if (!matches()) throw new Error("Nested draft changed during discovery.");
        global.SelectoExplorerClient.assertNestedDetailIntent(state.intent, context, {origin:"state"});
        const encoded = global.SelectoExplorerClient.encodeNestedDetailState(state);
        if (action === "save") {
          global.localStorage.setItem(this.nestedStateStorageKey(), JSON.stringify(state));
          // A private action never leaves this payload in a share URL.
          const url = new URL(global.location.href); const slots = new URLSearchParams(url.hash.slice(1));
          slots.delete("nested_request"); url.hash = slots.toString();
          global.history?.replaceState(global.history.state, "", url.href);
          this.setImportMessage("Private nested state saved in this browser.", "success");
        } else {
          const url = new URL(global.location.href); const slots = new URLSearchParams(); slots.set("nested_request", encoded); url.hash = slots.toString();
          await this.copy(url.href, this.root.querySelector("[data-sac-nested-link]"));
          this.setImportMessage("Nested state URL copied.", "success");
        }
      } catch (error) { this.setImportMessage(`Nested state blocked: ${error.message}`, "error", error); }
    }

    renderNestedBuilder() {
      const target = this.root.querySelector("[data-sac-nested-builder]");
      if (!target) return;
      target.replaceChildren();
      const restart = element("button", "sac-text-button", "Start new nested draft"); restart.type = "button";
      restart.dataset.sacNestedNew = ""; target.append(restart);
      if (!this.nestedState || this.nestedBlocked) {
        target.append(element("p", "sac-help", "Nested draft is blocked. Restore valid state or start a new current-publication draft."));
        return;
      }
      const intent = this.nestedState.intent, features = this.nestedDetailContext.features, collection = features.collections[0];
      const roots = new Map(features.root_fields.map(f => [f.id, f])), children = new Map(collection.fields.map(f => [f.id, f]));
      target.append(element("h2", "", "Complete nested Detail"), element("p", "sac-help", "Choose parent fields and one complete collection. UTC · en-US · exact scalar text."));
      const button = (text, action, index, group) => {
        const node = element("button", "sac-text-button", text); node.type = "button";
        node.dataset.sacNestedAction = action; node.dataset.index = String(index); node.dataset.group = group;
        return node;
      };
      const selector = (label, name, values, selected, index) => {
        const wrapper = element("label", "", label), select = element("select", "");
        select.setAttribute("aria-label", label); select.dataset.sacNestedControl = name;
        if (index !== undefined) select.dataset.index = String(index);
        appendOptions(select, values, selected); wrapper.append(select); return wrapper;
      };
      const choices = [...roots.values()].map(f => ({value:f.id,label:f.label}));
      target.append(selector("Add parent field", "add-root", [{value:"",label:"Choose parent field"}, ...choices.filter(f => !intent.select.includes(f.value))], ""));
      const selected = element("ol", "sac-nested-selected");
      intent.select.forEach((item, i) => {
        const row = element("li", "", Array.isArray(item) ? collection.label : roots.get(item)?.label || item);
        row.append(button("Up", "up", i, "select"), button("Down", "down", i, "select"));
        if (!Array.isArray(item)) row.append(button("Remove", "remove", i, "select"));
        selected.append(row);
      }); target.append(selected);
      const childIds = intent.select.find(Array.isArray);
      target.append(element("h3", "", collection.label), selector("Add child field", "add-child", [{value:"",label:"Choose child field"}, ...collection.fields.filter(f=>!childIds.includes(f.id)).map(f=>({value:f.id,label:f.label}))], ""));
      const childList = element("ol", "sac-nested-selected");
      childIds.forEach((id,i) => {const row=element("li","",children.get(id)?.label || id); row.append(button("Up","up",i,"children"),button("Down","down",i,"children"),button("Remove","remove",i,"children"));childList.append(row);}); target.append(childList);
      target.append(element("h3", "", "Parent filters (AND)"), button("Add filter", "add-filter", 0, "filters"));
      intent.filters.forEach((filter,i) => {
        const field = roots.get(filter.field), row = element("div", "sac-nested-filter");
        row.append(selector("Filter field", "filter-field", choices, filter.field, i), selector("Operator", "filter-op", field.operators.map(op=>({value:op,label:optionLabel(op)})), filter.op, i));
        if (!["is_null","is_not_null"].includes(filter.op)) {
          if (field.type === "boolean") row.append(selector("Filter value", "filter-value", [{value:"true",label:"true"},{value:"false",label:"false"}], String(filter.value), i));
          else {const label=element("label","","Exact filter value"),input=element("input","");input.type="text";input.value=filter.value;input.dataset.sacNestedControl="filter-value";input.dataset.index=String(i);input.setAttribute("aria-label","Exact filter value");label.append(input);row.append(label);}
        }
        row.append(button("Remove", "remove", i, "filters")); target.append(row);
      });
      target.append(element("h3", "", "Parent ordering"), button("Add sort", "add-order", 0, "orders"));
      intent.order_by.forEach((order,i)=>{const row=element("div","sac-nested-filter");row.append(selector("Sort field","order-field",choices,order.field,i),selector("Direction","order-direction",[{value:"asc",label:"Ascending"},{value:"desc",label:"Descending"}],order.direction,i),button("Remove","remove",i,"orders"));target.append(row);});
      const paging=element("div","sac-inline-controls");
      for (const [name,min,max] of [["limit",1,25],["offset",0,100000]]) {const label=element("label","",name === "limit" ? "Parent limit" : "Parent offset"),input=element("input","");input.type="number";input.min=String(min);input.max=String(max);input.value=String(intent[name]);input.dataset.sacNestedControl=name;input.setAttribute("aria-label",name === "limit" ? "Parent limit" : "Parent offset");label.append(input);paging.append(label);}
      paging.append(selector("Row shape","row-format",[{value:"arrays",label:"Ordered arrays"},{value:"objects",label:"JSON objects"}],intent.row_format));
      paging.append(button("Previous page","previous",0,"page"),button("Next page","next",0,"page"));target.append(paging);
    }

    nestedControl(target) {
      const name = target.dataset.sacNestedControl, index = Number(target.dataset.index);
      this.nestedChanged(intent => {
        const roots = new Map(this.nestedDetailContext.features.root_fields.map(f=>[f.id,f]));
        if (name === "add-root" && target.value) intent.select.push(target.value);
        if (name === "add-child" && target.value) intent.select.find(Array.isArray).push(target.value);
        if (name === "filter-field") {const f=intent.filters[index];f.field=target.value;f.op="eq";f.value=roots.get(f.field).type === "boolean" ? false : "";}
        if (name === "filter-op") {const f=intent.filters[index];f.op=target.value;if(["is_null","is_not_null"].includes(f.op))delete f.value;else if(!Object.hasOwn(f,"value"))f.value=roots.get(f.field).type === "boolean" ? false : "";}
        if (name === "filter-value") {const f=intent.filters[index];f.value=roots.get(f.field).type === "boolean" ? target.value === "true" : target.value;}
        if (name === "order-field") intent.order_by[index].field=target.value;
        if (name === "order-direction") intent.order_by[index].direction=target.value;
        if (["limit","offset"].includes(name)) intent[name]=/^(?:0|[1-9]\d*)$/.test(target.value) ? Number(target.value) : NaN;
        if (name === "row-format") intent.row_format=target.value;
      // Committing a text/number input on blur must not replace the button
      // receiving the same pointer gesture before its click can be dispatched.
      }, target.tagName !== "INPUT");
    }

    nestedAction(target) {
      const action=target.dataset.sacNestedAction,index=Number(target.dataset.index),group=target.dataset.group;
      if (group === "page" && (this.queryProfile !== "nested" || this.nestedBlocked || !this.nestedState)) {this.setImportMessage("Restore a complete nested draft before using builder paging.","error");return;}
      if (group === "page" && this.state.rawDirty) {this.setImportMessage("Reset the manual JSON to the complete nested draft before using builder paging.","error");return;}
      if (group === "page" && action === "next" && (this.nestedResult?.metadata.canonical.hasMore !== true || this.nestedState.intent.offset + this.nestedState.intent.limit > 100000)) {this.setImportMessage("Run the current page before advancing to available rows within the page bound.","error");return;}
      if (group === "page" && action === "previous" && this.nestedState.intent.offset === 0) return;
      this.nestedChanged(intent=>{
        const items=group === "children" ? intent.select.find(Array.isArray) : group === "select" ? intent.select : group === "filters" ? intent.filters : intent.order_by;
        if (action === "remove") items.splice(index,1);
        if (action === "up" && index>0) [items[index-1],items[index]]=[items[index],items[index-1]];
        if (action === "down" && index<items.length-1) [items[index+1],items[index]]=[items[index],items[index+1]];
        if (action === "add-filter" && intent.filters.length<20) {const f=this.nestedDetailContext.features.root_fields[0];while(intent.filters.some(filter=>filter.id===`nested-filter-${this.nextNestedFilterId}`))this.nextNestedFilterId++;intent.filters.push({id:`nested-filter-${this.nextNestedFilterId++}`,field:f.id,op:"eq",value:f.type==="boolean" ? false : ""});}
        if (action === "add-order" && intent.order_by.length<10) {const f=this.nestedDetailContext.features.root_fields.find(f=>!intent.order_by.some(o=>o.field===f.id));if(f)intent.order_by.push({field:f.id,direction:"asc"});}
        if (group === "page") intent.offset=action === "previous" ? Math.max(0,intent.offset-intent.limit) : intent.offset+intent.limit;
      });
      if (group === "page") return this.run();
    }

    async freshRootContext(signal) {
      if (!this.explorerClient || !this.explorerMetadata) throw new Error("Recursive root predicates unavailable on this publication.");
      const context = await this.explorerClient.getRootPredicateContext(this.explorerMetadata.domain.id,{signal});
      this.rootPredicateContext = context;
      return context;
    }

    async restoreRootState(raw) {
      this.queryProfile = "root";
      this.nestedRestoreSequence = (this.nestedRestoreSequence || 0) + 1;
      const nestedBuilder = this.root.querySelector("[data-sac-nested-builder]"); if (nestedBuilder) nestedBuilder.hidden = true;
      const sequence = this.rootRestoreSequence = (this.rootRestoreSequence || 0) + 1;
      const stateEditor = this.root.querySelector("[data-sac-root-state]");
      if (stateEditor) stateEditor.value = raw;
      const editor = this.root.querySelector("[data-sac-request]");
      // Retain the input before asynchronous discovery or refusal.
      editor.value = raw;
      this.state.rawDirty = true;
      this.rootState = null;
      this.rootMode = true;
      this.rootStateRequestText = null;
      try {
        const state = global.SelectoExplorerClient.parseRootPredicateState(raw);
        const context = await this.freshRootContext();
        if (sequence !== this.rootRestoreSequence) return false;
        global.SelectoExplorerClient.assertRootPredicateIntent(state.intent,context);
        this.blockedInitialRequestText = null;
        this.rootState = state; this.rootMode = true;
        const builder = this.root.querySelector(".sac-builder"); if (builder) builder.hidden = true;
        const selector = this.root.querySelector("[data-sac-root-mode]"); if (selector) selector.value = "root";
        editor.value = JSON.stringify(this.buildPayload(),null,2);
        this.rootStateRequestText = editor.value;
        this.root.querySelector("[data-sac-edited]").hidden = false;
        this.setImportMessage("Bound root state restored. Tree and presentation retained.","success");
        this.updateCurl(); return true;
      } catch (error) {
        if (sequence !== this.rootRestoreSequence) return false;
        this.setImportMessage(`Root state blocked: ${error.message}`,"error");
        this.setStatus(error.message,"error"); return false;
      }
    }

    async selectRootMode(value) {
      if (value === "flat") {
        this.queryProfile = "flat";
        this.rootRestoreSequence = (this.rootRestoreSequence || 0) + 1;
        this.blockedInitialRequestText = null;
        const builder = this.root.querySelector(".sac-builder"); if (builder) builder.hidden = false;
        this.rootMode = false; this.rootState = null; this.rootStateRequestText = null;
        this.state.rawDirty = false; this.syncRequest(true); return;
      }
      const sequence = this.rootRestoreSequence = (this.rootRestoreSequence || 0) + 1;
      try {
        const context = await this.freshRootContext();
        if (sequence !== this.rootRestoreSequence) return;
        const intent = {format:"selecto.root-predicate-ui-intent",format_version:1,mode:"recursive",binding:{...context.binding},select:context.features.default_select.slice(),predicate:{kind:"absent"},order_by:[],limit:100,offset:0,presentation:{timezone:this.state.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone,locale:navigator.language || "en-US"}};
        await this.restoreRootState(JSON.stringify({format:"selecto.root-predicate-state",format_version:1,intent}));
      } catch (error) {this.setImportMessage(error.message,"error");}
    }

    rootStateStorageKey() {return `selecto.console.root-state:${this.base}`;}
    async rootStateAction(action) {
      const stateEditor = this.root.querySelector("[data-sac-root-state]");
      try {
        if (action === "restore") return this.restoreRootState(stateEditor.value);
        if (action === "private") {
          const saved = global.localStorage.getItem(this.rootStateStorageKey());
          if (!saved) throw new Error("No private root state saved.");
          return this.restoreRootState(saved);
        }
        // Save only a complete bound state. Never infer a binding from raw text.
        const state = global.SelectoExplorerClient.parseRootPredicateState(stateEditor.value);
        const queryEditor = this.root.querySelector("[data-sac-request]");
        const editorsMatch = () => this.rootState && queryEditor.value === this.rootStateRequestText && JSON.stringify(state) === JSON.stringify(this.rootState);
        if (!editorsMatch()) throw new Error("State and query editor differ. Restore the complete intended root state before saving or sharing.");
        const context = await this.freshRootContext();
        if (!editorsMatch()) throw new Error("State and query editor differ. Restore the complete intended root state before saving or sharing.");
        global.SelectoExplorerClient.assertRootPredicateIntent(state.intent,context);
        const encoded = global.SelectoExplorerClient.encodeRootPredicateState(state);
        if (action === "save") {
          global.localStorage.setItem(this.rootStateStorageKey(),JSON.stringify(state));
          this.setImportMessage("Private root state saved in this browser.","success");
        } else {
          const url = new URL(global.location.href); url.hash = `request=${encoded}`;
          await this.copy(url.href,this.root.querySelector("[data-sac-root-link]"));
          this.setImportMessage("Root state URL copied.","success");
        }
      } catch (error) {this.setImportMessage(`Root state blocked: ${error.message}`,"error");}
    }

    loadRequestIntoChooser() {
      const editor = this.root.querySelector("[data-sac-request]");
      if (this.queryProfile === "nested") {
        this.setImportMessage("The nested chooser uses its complete bound state. Restore nested state to change it; the manual query editor remains available.", "error");
        return false;
      }
      let payload;
      try {
        payload = this.remoteMode ? global.SelectoCanonicalClient.parseStrictJSON(editor.value) : JSON.parse(editor.value);
        if (payload.format === "selecto.root-predicate-state") return this.restoreRootState(editor.value);
        if (payload.format === "selecto.remote-query" && payload.format_version === 2) throw new Error("Recursive v2 stays in the raw editor; this chooser is unavailable for the complete tree.");
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
      if (this.queryProfile === "nested") {
        if (this.state.rawDirty && !force) return;
        try { this.syncNestedRequest(); }
        catch (error) { this.setImportMessage(error.message, "error"); }
        return;
      }
      if (this.state.queryMethod === "get" && this.resourcePath) {
        const model = this.buildResourceRequest();
        const editor = this.root.querySelector("[data-sac-request]");
        editor.value = model.path || this.resourcePath;
        editor.readOnly = true;
        this.root.querySelector("[data-sac-query-path]").textContent = model.path || this.resourcePath;
        this.root.querySelector("[data-sac-run]").disabled = Boolean(model.errors.length);
        this.state.rawDirty = false;
        this.root.querySelector("[data-sac-edited]").hidden = true;
        this.setImportMessage(model.errors.join(" "), model.errors.length ? "error" : "");
        this.updateCurl();
        return;
      }
      this.root.querySelector("[data-sac-request]").readOnly = false;
      this.root.querySelector("[data-sac-query-path]").textContent = this.queryPath;
      this.root.querySelector("[data-sac-run]").disabled = false;
      if (this.state.rawDirty && !force) return;
      try {
        this.root.querySelector("[data-sac-request]").value = JSON.stringify(this.buildPayload(), null, 2);
      } catch (error) {
        this.root.querySelector("[data-sac-run]").disabled = true;
        this.setImportMessage(error.message, "error");
        return;
      }
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
      if (this.queryProfile !== "nested" && this.state.queryMethod === "get" && this.resourcePath) {
        const model = this.buildResourceRequest();
        const target = this.root.querySelector("[data-sac-curl]");
        if (target) target.textContent = model.path
          ? this.getCurlCommand(model.path) : model.errors.join(" ");
        return;
      }
      const editor = this.root.querySelector("[data-sac-request]");
      const body = editor ? editor.value : JSON.stringify(this.buildPayload(), null, 2);
      const command = this.curlCommand(
        this.queryPath, body, this.state.responseFormat, this.state.responseFilename,
        this.queryProfile === "nested" && this.nestedDetailContext && !this.nestedBlocked
          ? {"Selecto-Nested-Detail-Context": global.SelectoCanonicalClient.encodeNestedDetailContext(global.SelectoCanonicalClient.nestedDetailContext(this.nestedDetailContext.features))} : {},
      );
      const target = this.root.querySelector("[data-sac-curl]");
      if (target) target.textContent = command;
    }

    responseFormat(formatId) {
      return this.queryResponseFormats.find((format) => format.id === formatId)
        || QUERY_RESPONSE_FORMATS.find((format) => format.id === formatId)
        || QUERY_RESPONSE_FORMATS[0];
    }

    curlCommand(path, body, responseFormat = "json", responseFilename = "", extraHeaders = {}) {
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
        ...Object.entries(extraHeaders).filter(([_name, value]) => String(value || "").trim())
          .map(([name, value]) => `  -H ${shellEscape(`${name}: ${value}`)}`),
        `  --data-binary ${shellEscape(body)}`,
      ];
      if (format.id !== "json") command.push(`  --output ${shellEscape(filename)}`);
      return command.join(" \\\n");
    }

    getCurlCommand(path) {
      const auth = curlAuthConfiguration(this.curlAuth);
      const url = `${window.location.origin}${path}`;
      return [
        `curl -X GET ${shellEscape(url)}`,
        ...auth.args,
        "  -H 'Accept: application/json'",
      ].join(" \\\n");
    }

    updateMutationCurl(kind, path) {
      const editor = this.root.querySelector(`[data-sac-${kind}-request]`);
      const target = this.root.querySelector(`[data-sac-${kind}-curl]`);
      const headers = kind === "write" ? this.writeState.headers : {};
      if (editor && target) target.textContent = this.curlCommand(
        path, editor.value, "json", "", headers,
      );
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
        headers: Object.assign({}, this.writeState.headers || {}),
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
      this.writeHeaderSpecs().forEach((spec) => {
        if (spec.required && !String(this.writeState.headers[spec.name] || "").trim()) {
          errors.push(`${spec.name} request header is required.`);
        }
      });
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
        const headers = {
          "Content-Type": "application/json", Accept: "application/json",
          "X-CSRF-Token": this.csrfToken,
        };
        if (isWrite) Object.entries(this.writeState.headers || {}).forEach(([name, value]) => {
          if (String(value || "").trim()) headers[name] = String(value);
        });
        const response = await fetch(path, {
          method: "POST", credentials: "same-origin",
          headers,
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
      const nestedAction = event.target.closest("[data-sac-nested-action]");
      if (nestedAction) return this.nestedAction(nestedAction);
      if (event.target.closest("[data-sac-nested-new]")) {
        this.nestedState = null; return this.selectQueryProfile("nested", true);
      }
      for (const action of ["restore", "link", "save", "private"]) {
        if (event.target.closest(`[data-sac-nested-${action}]`)) return this.nestedStateAction(action);
      }
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
        if (!initialField) return;
        this.state.filters.push({
          id: String(this.nextFilterId++),
          field: initialField.path,
          op: initialFilterOperator(initialField),
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
        const sortable = this.sortFields();
        if (!sortable.length || this.state.ordering) return;
        this.state.orders.push({id: String(this.nextOrderId++), field: sortable[0].path, direction: "asc"});
        this.changed();
        return;
      }
      const removeOrder = event.target.closest("[data-sac-remove-order]");
      if (removeOrder) {
        this.state.orders = this.state.orders.filter((order) => order.id !== removeOrder.dataset.sacRemoveOrder);
        this.changed();
        return;
      }
      if (event.target.closest("[data-sac-root-restore]")) return this.rootStateAction("restore");
      if (event.target.closest("[data-sac-root-link]")) return this.rootStateAction("link");
      if (event.target.closest("[data-sac-root-save]")) return this.rootStateAction("save");
      if (event.target.closest("[data-sac-root-private]")) return this.rootStateAction("private");
      if (event.target.closest("[data-sac-load-json]")) return this.loadRequestIntoChooser();
      if (event.target.closest("[data-sac-reset-json]")) return this.syncRequest(true);
      if (event.target.closest("[data-sac-run]")) return this.run();
      if (event.target.closest("[data-sac-cancel-query]")) return this.cancelQuery();
      if (event.target.closest("[data-sac-next-page]")) return this.goToPage("next");
      if (event.target.closest("[data-sac-previous-page]")) return this.goToPage("previous");
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
      if (target.matches("[data-sac-nested-control]")) return this.nestedControl(target);
      if (target.matches("[data-sac-query-method]")) {
        this.setQueryMethod(target.value);
        return this.renderAll();
      }
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
      if (target.matches("[data-sac-date-format]")) {
        this.state.dateFormat = target.value;
        return this.syncRequest(true);
      }
      if (target.matches("[data-sac-mode]")) this.state.mode = target.value;
      else if (target.matches("[data-sac-projection]")) this.state.projection = target.value;
      else if (target.matches("[data-sac-view]")) this.state.view = target.value;
      else if (target.matches("[data-sac-segment-choice]")) {
        this.setUngroupedSegments(Array.from(this.root.querySelectorAll("[data-sac-segment-choice]:checked"))
          .filter((choice) => !choice.disabled).map((choice) => choice.value));
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
      if (target.matches("[data-sac-nested-control]") && target.tagName === "INPUT") return this.nestedControl(target);
      if (target.matches("[data-sac-resource-id]")) {
        this.state.resourceId = target.value;
        return this.syncRequest(true);
      }
      if (target.matches("[data-sac-write-field]")) {
        this.writeState.assignments[target.dataset.sacWriteField] = target.value;
        return this.mutationFormChanged("write", false);
      }
      if (target.matches("[data-sac-write-header]")) {
        this.writeState.headers[target.dataset.sacWriteHeader] = target.value;
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
      if (target.matches("[data-sac-root-mode]")) return this.selectQueryProfile(target.value);
      if (target.matches("[data-sac-root-state]")) { this.rootRestoreSequence = (this.rootRestoreSequence || 0) + 1; return; }
      if (target.matches("[data-sac-nested-state]")) {
        this.nestedRestoreSequence = (this.nestedRestoreSequence || 0) + 1;
        this.nestedBlocked = true;
        this.nestedInitialError = null;
        if (this.queryProfile === "nested") {
          this.cancelQuery(); this.nestedResult = null; this.state.response = null;
          this.clearQueryResult(); this.renderNestedBuilder();
          this.root.querySelector("[data-sac-run]").disabled = true;
          this.setImportMessage("Nested state edited. Restore valid state or explicitly start a new draft before Run.", "error");
        }
        return;
      }
      if (target.matches("[data-sac-request]")) {
        this.nestedRestoreSequence = (this.nestedRestoreSequence || 0) + 1;
        this.rootRestoreSequence = (this.rootRestoreSequence || 0) + 1;
        this.nestedInitialError = null;
        this.state.rawDirty = true;
        if (this.queryProfile === "nested" && !this.nestedBlocked) this.root.querySelector("[data-sac-run]").disabled = false;
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
      if (this.queryProfile !== "nested" && this.state.queryMethod === "get" && this.resourcePath) {
        return this.runResource();
      }
      const editor = this.root.querySelector("[data-sac-request]");
      let request;
      if (this.queryProfile === "nested" && this.nestedBlocked && this.nestedInitialError && !(this.blockedInitialRequestText && editor.value === this.blockedInitialRequestText)) {
        const refusal = global.SelectoCanonicalClient.nestedDetailRefusal(this.nestedInitialError);
        const error = refusal ? nestedError("Nested state remains blocked. Restore valid state or start a new draft.", refusal.reason) : this.nestedInitialError;
        this.setStatus(error.message, "error", error);
        this.showLocalError(error.message, error);
        return;
      }
      try {
        if (this.blockedInitialRequestText && editor.value === this.blockedInitialRequestText) throw this.queryProfile === "nested" ? nestedError("URL state remains blocked. Restore valid bound state or explicitly start a new query.", global.SelectoCanonicalClient.nestedDetailRefusal(this.nestedInitialError)?.reason || "invalid-nested-state") : new Error("URL state remains blocked. Restore valid bound state or explicitly start a new query.");
        request = this.remoteMode ? global.SelectoCanonicalClient.parseStrictJSON(editor.value) : JSON.parse(editor.value);
      } catch (error) {
        if (this.queryProfile === "nested") global.SelectoCanonicalClient.markNestedDetailRefusal(error, "invalid-selected-raw");
        this.setStatus("Invalid request JSON", "error", error);
        this.showLocalError(error.message, error);
        return;
      }
      const rawRequestText = editor.value;
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
      this.queryController?.abort();
      const sequence = this.querySequence = (this.querySequence || 0) + 1;
      const controller = this.queryController = new AbortController();
      const cancel = this.root.querySelector("[data-sac-cancel-query]");
      if (cancel) cancel.hidden = false;
      let response;
      let payload;
      let nestedResult = null;
      try {
        if (this.queryProfile === "nested") {
          if (this.nestedBlocked || !this.nestedState) throw nestedError("Nested state remains blocked. Restore valid state or start a new draft.", global.SelectoCanonicalClient.nestedDetailRefusal(this.nestedInitialError)?.reason || "invalid-nested-state");
          const retained = structuredClone(this.nestedState);
          const context = await this.freshNestedContext(controller.signal);
          if (sequence !== this.querySequence || this.queryProfile !== "nested") return;
          const binding = global.SelectoExplorerClient.nestedDetailBinding(context.features);
          if (Object.keys(binding).some(key => retained.intent.binding[key] !== binding[key])) throw nestedError("Nested publication or revision changed; retain the draft and explicitly start a new one.", "stale-nested-context");
          if (!this.state.rawDirty) global.SelectoExplorerClient.assertNestedDetailIntent(retained.intent, context);
          const selectedContext = global.SelectoCanonicalClient.nestedDetailContext(context.features);
          let parsed;
          try {
            parsed = global.SelectoCanonicalClient.parseNestedDetailRequestText(rawRequestText, {features:context.features,context:selectedContext});
            if (parsed.request.query.timezone !== "UTC") throw new Error("This nested browser mode requires explicit timezone UTC; retain the raw query or reset to the complete draft.");
          } catch (error) { throw global.SelectoCanonicalClient.markNestedDetailRefusal(error, "invalid-selected-raw"); }
          payload = await this.canonicalClient.queryNestedDetailText(context.manifest, rawRequestText,
            {features:context.features,context:selectedContext,signal:controller.signal});
          // The strict selected transport has validated raw numeric tokens first.
          // This mapping uses only the selected column/shape intent, never raw filters as saved UI state.
          const renderIntent = global.SelectoExplorerClient.createNestedDetailIntent(context.features);
          const collection = context.features.collections[0], roots = new Map(context.features.root_fields.map(f=>[f.path,f.id])), children = new Map(collection.fields.map(f=>[f.path,f.id]));
          renderIntent.select = parsed.request.query.select.map(item=>Array.isArray(item)?item.map(path=>children.get(path)):roots.get(item));
          renderIntent.limit = parsed.request.query.limit ?? context.features.defaults.limit;
          renderIntent.offset = parsed.request.query.offset ?? context.features.defaults.offset;
          renderIntent.row_format = parsed.request.query.row_format || "arrays";
          nestedResult = global.SelectoExplorerClient.toNestedDetailExplorerResult(payload, renderIntent, context);
          response = {status:200,statusText:"OK",ok:true};
        } else if (this.remoteMode && (request.format === "selecto.root-predicate-state" || request.format === "selecto.remote-query" && request.format_version === 2)) {
          const context = await this.freshRootContext(controller.signal);
          if (request.format === "selecto.root-predicate-state") {
            const state = global.SelectoExplorerClient.parseRootPredicateState(rawRequestText,context);
            const query = global.SelectoExplorerClient.toRootPredicateQuery(state.intent,context);
            payload = await this.canonicalClient.queryRootPredicate(context.manifest,query,{features:context.features,signal:controller.signal,fingerprint:state.intent.binding.fingerprint});
          } else {
            if (this.rootState) global.SelectoExplorerClient.assertRootPredicateIntent(this.rootState.intent,context);
            payload = await this.canonicalClient.queryText(context.manifest,rawRequestText,{features:context.features,signal:controller.signal});
          }
          response = {status:200,statusText:"OK",ok:true};
        } else if (this.remoteMode) {
          if (this.explorerClient && this.explorerMetadata) {
            const descriptor = await this.explorerClient.getDomain(this.explorerMetadata.domain.id);
            if (descriptor.release.fingerprint !== this.manifest.domain.fingerprint || descriptor.release.id !== this.explorerMetadata.domain.publication) throw new Error("Publication changed; retain the request and reload.");
          }
          let query;
          let fingerprint = this.manifest.domain.fingerprint;
          let requestId;
          if (request.version === 2 && request.domainId) request = global.SelectoExplorerClient.flatSnapshotToRequest(request);
          if (request.schema === "selecto.spa.query-request/v1") {
            if (!this.explorerMetadata) throw new Error("This host does not advertise Explorer metadata for handoff.");
            query = global.SelectoExplorerClient.toCanonicalQuery(request, this.explorerMetadata);
          } else if (request.format === "selecto.remote-query") {
            global.SelectoCanonicalClient.keys(request, ["format", "format_version", "domain", "query", "request_id"], "request");
            if (request.format_version !== 1) throw new Error("Unsupported remote query version.");
            global.SelectoCanonicalClient.keys(request.domain, ["fingerprint"], "request.domain");
            fingerprint = request.domain.fingerprint;
            query = request.query;
            requestId = request.request_id;
          } else {
            query = request;
          }
          payload = await this.canonicalClient.query(this.manifest, query, {fingerprint, requestId, signal: controller.signal});
          response = {status: 200, statusText: "OK", ok: true};
        } else {
        const requestPath = format.id === "json"
          ? this.queryPath : pathWithDownloadFilename(this.queryPath, filenameValidation.value);
        response = await fetch(requestPath, {
          method: "POST",
          credentials: "same-origin",
          headers: {"Content-Type": "application/json", Accept: format.mediaType, "X-CSRF-Token": this.csrfToken},
          body: JSON.stringify(request),
          signal: controller.signal,
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
        }
        if (sequence !== this.querySequence) return;
        const elapsed = Math.round(performance.now() - started);
        this.state.response = payload;
        this.nestedResult = nestedResult;
        this.renderResponse(payload);
        this.setStatus(`${response.status} ${response.statusText} · ${elapsed} ms`, response.ok ? "success" : "error");
      } catch (error) {
        if (sequence !== this.querySequence) return;
        this.nestedResult = null;
        this.state.response = error.envelope || {ok: false, error: {code: error.name === "AbortError" ? "cancelled" : error.code || "network_error", message: error.message, details: error.details || {}}};
        this.renderResponse(this.state.response);
        this.setStatus(error.status ? `${error.status} · ${error.code}` : error.message, "error", error);
      } finally {
        if (sequence !== this.querySequence) return;
        button.disabled = this.queryProfile === "nested" && this.nestedBlocked;
        button.classList.remove("is-running");
        this.root.querySelector("[data-sac-run-label]").textContent = "Run query";
        if (cancel) cancel.hidden = true;
      }
    }

    cancelQuery() {
      this.querySequence = (this.querySequence || 0) + 1;
      this.queryController?.abort();
      const button = this.root.querySelector("[data-sac-run]");
      button.disabled = false;
      button.classList.remove("is-running");
      this.root.querySelector("[data-sac-run-label]").textContent = "Run query";
      this.root.querySelector("[data-sac-cancel-query]").hidden = true;
      this.setStatus("Query cancelled in this browser", "error");
    }

    async runResource() {
      const model = this.buildResourceRequest();
      if (model.errors.length) {
        this.setStatus("Invalid resource request", "error");
        this.showLocalError(model.errors.join(" "));
        return;
      }
      const button = this.root.querySelector("[data-sac-run]");
      button.disabled = true;
      button.classList.add("is-running");
      this.root.querySelector("[data-sac-run-label]").textContent = "Running…";
      this.setStatus("Running resource GET", "running");
      const started = performance.now();
      try {
        const response = await fetch(model.path, {
          method: "GET",
          credentials: "same-origin",
          headers: {Accept: "application/json"},
        });
        const text = await response.text();
        let payload;
        try {
          payload = text ? JSON.parse(text) : null;
        } catch (_error) {
          payload = {ok: false, error: {code: "invalid_response", message: text || "Empty response", details: {}}};
        }
        this.state.response = payload;
        this.renderResponse(payload);
        this.setStatus(
          `${response.status} ${response.statusText} · ${Math.round(performance.now() - started)} ms`,
          response.ok ? "success" : "error",
        );
      } catch (error) {
        this.state.response = {ok: false, error: {code: "network_error", message: error.message, details: {}}};
        this.renderResponse(this.state.response);
        this.setStatus("Network error", "error");
      } finally {
        button.classList.remove("is-running");
        button.disabled = Boolean(this.buildResourceRequest().errors.length);
        this.root.querySelector("[data-sac-run-label]").textContent = "Run GET";
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

    setStatus(text, kind, error) {
      const status = this.root.querySelector("[data-sac-response-status]");
      status.textContent = text;
      status.dataset.kind = kind || "";
      setNestedRefusal(status, kind === "error" ? error : null);
    }

    showLocalError(message, error) {
      setNestedRefusal(this.root.querySelector("[data-sac-response-status]"), error);
      this.state.response = {ok: false, error: {code: "invalid_request_json", message, details: {}}};
      this.renderResponse(this.state.response);
    }

    clearQueryResult() {
      setNestedRefusal(this.root.querySelector("[data-sac-response-status]"), null);
      for (const selector of ["[data-sac-result-head]", "[data-sac-result-body]"]) this.root.querySelector(selector)?.replaceChildren();
      const json = this.root.querySelector("[data-sac-response-json]"); if (json) json.textContent = "";
      const empty = this.root.querySelector("[data-sac-empty-response]"); if (empty) empty.hidden = false;
      const page = this.root.querySelector("[data-sac-page-info]"); if (page) {page.hidden = true;page.textContent = "";}
      const pager = this.root.querySelector("[data-sac-legacy-page-info]"); if (pager) pager.hidden = true;
      this.page = null;
    }

    renderNestedResponse(result, head, body) {
      const scalar = value => value === null ? "NULL" : String(value);
      const childHeader = fields => {
        const tr = element("tr", ""); fields.forEach(field=>tr.append(element("th","",field.label))); return tr;
      };
      const header = element("tr", "");
      result.columns.forEach(column=>{
        const th=element("th","sac-nested-header",column.label);
        if(column.type === "nested") {
          const schema=element("table","sac-nested-schema"),thead=element("thead","");
          schema.setAttribute("aria-label",`${column.label} selected child columns`);
          thead.append(childHeader(column.nestedFields));schema.append(thead);th.append(schema);
        }
        header.append(th);
      });head.append(header);
      if(!result.rows.length) {const tr=element("tr",""),td=element("td","","No rows");td.colSpan=result.columns.length;tr.append(td);body.append(tr);}
      result.rows.forEach(row=>{
        const tr=element("tr","");
        result.columns.forEach(column=>{
          const td=element("td","sac-nested-scalar"),value=row[column.id];
          if(column.type !== "nested") td.textContent=scalar(value);
          else if(!value.length) td.textContent="No children";
          else {
            const table=element("table","sac-nested-results"),thead=element("thead",""),tbody=element("tbody","");
            table.setAttribute("aria-label",`${column.label} complete children`);thead.append(childHeader(column.nestedFields));
            value.forEach(child=>{const cr=element("tr","");column.nestedFields.forEach(field=>cr.append(element("td","",scalar(child[field.id]))));tbody.append(cr);});
            table.append(thead,tbody);td.append(table);
          }tr.append(td);
        });body.append(tr);
      });
      const info=this.root.querySelector("[data-sac-page-info]");
      if(info) {info.hidden=false;info.textContent=result.metadata.canonical.hasMore ? "More rows available" : "No more rows";}
    }

    renderResponse(payload) {
      this.root.querySelector("[data-sac-empty-response]").hidden = true;
      this.root.querySelector("[data-sac-response-json]").textContent = JSON.stringify(payload, null, 2);
      this.updateCurl();
      const head = this.root.querySelector("[data-sac-result-head]");
      const body = this.root.querySelector("[data-sac-result-body]");
      head.replaceChildren();
      body.replaceChildren();
      if (this.queryProfile === "nested" && this.nestedResult) {
        this.renderNestedResponse(this.nestedResult, head, body);
        this.switchResultTab("table"); return;
      }
      const data = payload && payload.data;
      const pageInfo = this.root.querySelector("[data-sac-page-info]");
      if (pageInfo) {
        pageInfo.hidden = typeof data?.page?.has_more !== "boolean";
        pageInfo.textContent = data?.page?.has_more ? "More rows available" : "No more rows";
      }
      let columns = data && Array.isArray(data.columns) ? data.columns : [];
      let rows = data && Array.isArray(data.rows) ? data.rows : [];
      if (this.state.queryMethod === "get" && payload && payload.ok && isPlainObject(data)) {
        columns = Object.keys(data);
        rows = [data];
      }
      if (columns.length) {
        const tr = element("tr", "");
        columns.forEach((column) => {
          const th = element("th", "", columnLabel(column));
          if (th.textContent !== columnId(column)) th.title = columnId(column);
          tr.append(th);
        });
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
      this.renderPageInfo(payload);
      this.switchResultTab(columns.length ? "table" : "json");
    }

    // A query page: which rows it holds and, from the API's has_more, whether more follow.
    pageInfo(payload) {
      const data = payload && payload.ok && payload.data;
      if (this.state.queryMethod === "get" || !isPlainObject(data)) return null;
      const canonical = data.format === "selecto.remote-query-result";
      const page = canonical ? data.page : data;
      if (!isPlainObject(page) || typeof page.has_more !== "boolean") return null;
      if (canonical && (data.format_version !== 1 || this.state.rawDirty || this.rootMode || this.queryProfile !== "flat" ||
          !Number.isInteger(page.offset) || page.offset < 0 || !Number.isInteger(page.limit) || page.limit < 1 ||
          !Number.isInteger(data.row_count) || data.row_count < 0 || data.row_count > page.limit ||
          !Array.isArray(data.rows) || data.row_count !== data.rows.length)) return null;
      const offset = Number.isInteger(page.offset) ? page.offset : Number.parseInt(this.state.offset, 10) || 0;
      const limit = Number.isInteger(page.limit) ? page.limit : Number.parseInt(this.state.limit, 10) || 0;
      const returned = canonical ? data.row_count : Number.isInteger(data.returned) ? data.returned : (Array.isArray(data.rows) ? data.rows.length : 0);
      const text = returned
        ? `Rows ${offset + 1}–${offset + returned}${page.has_more ? "; more rows follow" : "; no more rows"}`
        : (offset ? `No rows after row ${offset}` : "No rows");
      return {offset, limit, returned, hasMore: page.has_more, text};
    }

    renderPageInfo(payload) {
      const container = this.root.querySelector("[data-sac-legacy-page-info]");
      if (!container) return;
      const info = this.pageInfo(payload);
      this.page = info;
      container.hidden = !info;
      if (!info) return;
      container.querySelector("[data-sac-page-text]").textContent = info.text;
      // Paging changes the chooser's offset, so it is not offered for manually edited JSON.
      const editable = !this.state.rawDirty && !this.rootMode && this.queryProfile === "flat" && info.limit > 0;
      container.querySelector("[data-sac-next-page]").hidden = !(editable && info.hasMore);
      container.querySelector("[data-sac-previous-page]").hidden = !(editable && info.offset > 0);
    }

    // Runs the next or previous page of the query just run.
    goToPage(direction) {
      const info = this.page;
      if (!info || this.state.rawDirty || this.rootMode || this.queryProfile !== "flat" || !info.limit) return;
      this.state.limit = info.limit;
      this.state.offset = direction === "next" ? info.offset + info.limit : Math.max(0, info.offset - info.limit);
      this.changed();
      return this.run();
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
      setNestedRefusal(panel, error);
      panel.append(element("span", "sac-kicker", "API Console"), element("h1", "", "Could not load the API"), element("p", "", error.status ? `${error.status} ${error.code}: ${error.message}` : error.message || String(error)));
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
    fieldSignature,
    pickTone,
    operatorsForField,
    compareSemanticFields,
    discoverQueryResponseFormats,
    discoverResourceDateFormats,
    fieldRoleAllowed,
    initialFilterOperator,
    operationHeaderSpecs,
    downloadFilename,
    initialSurfaceTab,
    pathWithDownloadFilename,
    safeResourcePathTemplate,
    resourceRequestPath,
    fieldTraversesMany,
    suggestedDownloadFilename,
    validateDownloadFilename,
    normalizeCurlAuth,
    discoverCanonicalAPI,
    mountAll,
    normalizeAPIBase,
    requestPayloadFromLocation,
    nestedStateFromLocation,
    operatorsForType,
    writeControlKind,
    writeFieldRequired,
    writeRequiredValueMissing,
    renderValue,
    columnId,
    columnLabel,
    rowValue,
    segmentParameterSpecs,
  };
  global.SelectoAPIConsole = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  if (typeof global.document !== "undefined" && global.addEventListener) {
    global.addEventListener("DOMContentLoaded", () => mountAll(global.document));
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
