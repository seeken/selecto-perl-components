  // Keep only the last acknowledged form snapshot. A new connection starts
  // with a full form; subsequent messages may send revisioned differences.
  var explorerSessions = new WeakMap();
  var explorerMutationGeneration = 0;

  function explorerChannel(event) {
    var target = event.target;
    var channel = target && target.closest && target.closest('[hx-ws\\:connect]');
    return channel && channel.querySelector('[data-sc-builder]') ? channel : null;
  }

  function explorerSession(channel) {
    var state = explorerSessions.get(channel);
    if (!state) {
      state = {input: null, revision: null, pending: new Map(), generation: explorerMutationGeneration};
      explorerSessions.set(channel, state);
    }
    return state;
  }

  document.addEventListener("selecto:records-changed", function () {
    explorerMutationGeneration++;
  });

  document.addEventListener("htmx:ws:after:connection", function (event) {
    var channel = explorerChannel(event);
    if (!channel) return;
    var state = explorerSession(channel);
    state.input = null;
    state.revision = null;
  });

  document.addEventListener("htmx:ws:before:message:outgoing", function (event) {
    var channel = explorerChannel(event);
    var message = event.detail && event.detail.message;
    if (!channel || !message || !message.values) return;
    var full = JSON.parse(JSON.stringify(message.values));
    var requestId = full.selecto_request_id;
    if (!requestId) return;
    var state = explorerSession(channel);
    var input = Object.assign({}, full);
    delete input.selecto_request_id;
    delete input.selecto_refresh;
    delete input.selecto_session;
    if (state.generation !== explorerMutationGeneration) full.selecto_refresh = 1;
    var outgoing = full;
    if (state.input && !state.pending.size) {
      var set = {};
      var remove = [];
      Object.keys(input).forEach(function (key) {
        if (JSON.stringify(input[key]) !== JSON.stringify(state.input[key])) set[key] = input[key];
      });
      Object.keys(state.input).forEach(function (key) {
        if (!Object.prototype.hasOwnProperty.call(input, key)) remove.push(key);
      });
      outgoing = {selecto_request_id: requestId, selecto_refresh: full.selecto_refresh || 0,
        selecto_session: {revision: state.revision, set: set, remove: remove}};
    }
    state.latest = requestId;
    state.pending.set(requestId, {full: full, input: input, headers: message.headers,
      generation: explorerMutationGeneration});
    while (state.pending.size > 8) state.pending.delete(state.pending.keys().next().value);
    message.data = JSON.stringify(Object.assign({}, outgoing, {headers: message.headers || {}}));
  });

  document.addEventListener("htmx:ws:before:message:incoming", function (event) {
    var channel = explorerChannel(event);
    var detail = event.detail;
    if (!channel || !detail || !detail.message || typeof detail.waitUntil !== "function") return;
    detail.waitUntil(detail.message.json().then(function (message) {
      var response = message && message.selecto;
      if (!response || !response.session) return;
      var state = explorerSession(channel);
      var pending = state.pending.get(response.request_id);
      if (response.session.resync) {
        detail.cancelled = true;
        state.input = null;
        state.revision = null;
        // Reconnects and concurrent submissions can lose the patch base.
        // Retry the latest request once with the original complete form.
        var socket = detail.connection && detail.connection.socket;
        if (pending && state.latest === response.request_id && !pending.retried
            && socket && socket.readyState === WebSocket.OPEN) {
          pending.retried = true;
          socket.send(JSON.stringify(Object.assign({}, pending.full, {headers: pending.headers || {}})));
        }
        if (state.latest !== response.request_id) state.pending.delete(response.request_id);
        return;
      }
      state.pending.delete(response.request_id);
      if (state.latest === response.request_id) state.pending.clear();
      if (pending && state.latest === response.request_id && response.session.accepted) {
        state.input = pending.input;
        state.revision = response.session.revision;
        state.generation = pending.generation;
      }
    }));
  });
