  function localActionResultUrl(value) {
    if (!value || typeof value !== "string") return "";
    try {
      var url = new URL(value, window.location.href);
      if (url.origin !== window.location.origin) return "";
      return url.pathname + url.search + url.hash;
    } catch (_error) {
      return "";
    }
  }

  function appendActionResultMeta(container, content) {
    if (!content) return;
    if (container.childNodes.length) {
      var separator = document.createElement("span");
      separator.className = "sc-action-built-load-separator";
      separator.textContent = "·";
      container.appendChild(separator);
    }
    if (content instanceof window.Node) container.appendChild(content);
    else {
      var text = document.createElement("span");
      text.textContent = String(content);
      container.appendChild(text);
    }
  }

  function builtLoadLink(load) {
    var loadLabel = "Load " + String(load.load_id);
    var loadUrl = localActionResultUrl(load.load_url);
    if (loadUrl) {
      var loadLink = document.createElement("a");
      loadLink.className = "sc-action-built-load-link";
      loadLink.href = loadUrl;
      loadLink.target = "_blank";
      loadLink.rel = "noopener noreferrer";
      loadLink.textContent = loadLabel;
      return loadLink;
    }
    var loadHeading = document.createElement("strong");
    loadHeading.className = "sc-action-built-load-link";
    loadHeading.textContent = loadLabel;
    return loadHeading;
  }

  function builtLoadMeta(load) {
    var meta = document.createElement("div");
    meta.className = "sc-action-built-load-meta";
    var count = Number(load.order_count);
    if (Number.isFinite(count) && count >= 0) {
      appendActionResultMeta(meta, count + (count === 1 ? " order" : " orders"));
    }
    var carrierUrl = localActionResultUrl(load.carrier_url);
    var carrierLabel = load.carrier_name
      ? String(load.carrier_name) + " (" + String(load.carrier_id || "") + ")"
      : (load.carrier_id ? "Carrier " + String(load.carrier_id) : "");
    if (carrierLabel && carrierUrl) {
      var carrierLink = document.createElement("a");
      carrierLink.href = carrierUrl;
      carrierLink.textContent = carrierLabel;
      appendActionResultMeta(meta, carrierLink);
    } else {
      appendActionResultMeta(meta, carrierLabel);
    }
    var origin = load.origin ? String(load.origin) : "";
    var destination = load.destination ? String(load.destination) : "";
    appendActionResultMeta(meta, origin && destination ? origin + " → " + destination : origin || destination);
    if (Array.isArray(load.order_ids) && load.order_ids.length) {
      appendActionResultMeta(meta, "Orders " + load.order_ids.map(String).join(", "));
    }
    return meta;
  }

  function renderBuiltLoadCard(card, load) {
    card.replaceChildren();
    card.classList.add("is-built");
    if (load.marker && load.marker.color) {
      card.style.setProperty("--sc-marker-color", String(load.marker.color));
    }

    var header = document.createElement("header");
    header.className = "sc-group-action-card-header";
    if (load.marker && typeof load.marker === "object") {
      var marker = document.createElement("span");
      marker.className = "sc-group-dialog-marker";
      marker.appendChild(markerGlyph(load.marker, true));
      header.appendChild(marker);
    }
    var heading = document.createElement("div");
    var title = document.createElement("h4");
    title.appendChild(builtLoadLink(load));
    var summary = document.createElement("p");
    var markerLabel = load.marker && load.marker.label ? String(load.marker.label) : "Grouped";
    summary.textContent = markerLabel + " load built";
    heading.append(title, summary);
    header.appendChild(heading);
    card.append(header, builtLoadMeta(load));
  }

  function renderActionResult(result, payload, succeeded, root) {
    result.replaceChildren();
    var message = document.createElement("div");
    message.className = "sc-action-result-message";
    message.textContent = payload.message || (succeeded ? "Action completed." : "Action failed.");
    result.appendChild(message);
    if (!succeeded || !Array.isArray(payload.loads) || !payload.loads.length) return;

    var unmatched = [];
    payload.loads.forEach(function (load) {
      if (!load || !/^\d+$/.test(String(load.load_id || ""))) return;
      var markerId = load.marker && load.marker.id ? String(load.marker.id) : "";
      var card = root && Array.from(root.querySelectorAll("[data-sc-group-action-card]")).find(function (candidate) {
        return candidate.dataset.scGroupActionCard === markerId;
      });
      if (card) renderBuiltLoadCard(card, load);
      else unmatched.push(load);
    });
    if (!unmatched.length) return;

    var list = document.createElement("ul");
    list.className = "sc-action-built-loads";
    unmatched.forEach(function (load) {
      var item = document.createElement("li");
      item.className = "sc-action-built-load";

      if (load.marker && typeof load.marker === "object") {
        var marker = document.createElement("span");
        marker.className = "sc-group-dialog-marker sc-action-built-load-marker";
        if (load.marker.color) marker.style.setProperty("--sc-marker-color", String(load.marker.color));
        marker.appendChild(markerGlyph(load.marker, true));
        item.appendChild(marker);
      }

      var detail = document.createElement("div");
      detail.append(builtLoadLink(load), builtLoadMeta(load));
      item.appendChild(detail);
      list.appendChild(item);
    });
    if (list.childNodes.length) result.appendChild(list);
  }

  document.addEventListener("submit", function (event) {
    var form = event.target.closest("[data-sc-action-form]");
    if (!form || typeof window.fetch !== "function") return;
    event.preventDefault();
    var root = form.closest("[data-sc-bulk-action]");
    var ids = selectedRowIds(root);
    populateActionTargets(form, ids);
    if (actionMode(root) === "groups") serializeGroupedAction(root, form);
    if (!ids.length || !form.reportValidity()) return;

    var submit = form.querySelector('button[type="submit"]');
    var result = form.querySelector("[data-sc-action-result]");
    if (submit) {
      submit.disabled = true;
      submit.textContent = actionMode(root) === "groups" ? "Building…" : "Applying…";
    }
    if (result) {
      result.hidden = true;
      result.replaceChildren();
      result.classList.remove("is-success", "is-error");
    }

    window.fetch(form.action, {
      method: "POST",
      body: new FormData(form),
      credentials: "same-origin",
      headers: {"Accept": "application/json", "X-Requested-With": "XMLHttpRequest"}
    }).then(function (response) {
      return response.json().catch(function () {
        return {ok: false, message: "The server returned an unreadable action response."};
      }).then(function (payload) {
        return {response: response, payload: payload};
      });
    }).then(function (outcome) {
      var succeeded = outcome.response.ok && outcome.payload.ok;
      if (result) {
        result.hidden = false;
        result.classList.add(succeeded ? "is-success" : "is-error");
        renderActionResult(result, outcome.payload, succeeded, root);
      }
      if (succeeded) {
        if (actionMode(root) === "groups") {
          resetGroupedAction(root);
        } else {
          actionControls(
            bulkActionResults(root), "[data-sc-row-select]:checked", actionIdFor(root)
          ).forEach(function (input) {
            input.checked = false;
          });
        }
        refreshBulkAction(root);
        if (submit) {
          if (actionMode(root) === "groups") submit.hidden = true;
          else submit.textContent = "Applied";
        }
        if (actionMode(root) === "groups") {
          var footerClose = form.querySelector("footer [data-sc-action-close]");
          if (footerClose) footerClose.textContent = "Close";
        }
      } else if (submit) {
        submit.disabled = false;
        submit.textContent = root.dataset.scActionSubmitLabel || "Apply to selected rows";
      }
    }).catch(function () {
      if (result) {
        result.hidden = false;
        result.classList.add("is-error");
        renderActionResult(result, {
          message: "The action request could not reach the server."
        }, false, root);
      }
      if (submit) {
        submit.disabled = false;
        submit.textContent = root.dataset.scActionSubmitLabel || "Apply to selected rows";
      }
    });
  });
