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

  function actionResultLink(record) {
    var url = localActionResultUrl(record.url);
    var title = document.createElement(url ? "a" : "strong");
    title.className = "sc-action-built-record-link";
    if (url) {
      title.href = url;
      title.target = "_blank";
      title.rel = "noopener noreferrer";
    }
    title.textContent = record.label || "Record " + String(record.id);
    return title;
  }

  function actionResultDetails(record) {
    var meta = document.createElement("p");
    meta.className = "sc-action-built-record-meta";
    (Array.isArray(record.details) ? record.details : []).forEach(function (detail) {
      if (!detail || typeof detail.text !== "string") return;
      if (meta.childNodes.length) {
        var separator = document.createElement("span");
        separator.className = "sc-action-built-record-separator";
        separator.textContent = "·";
        meta.appendChild(separator);
      }
      var url = localActionResultUrl(detail.url);
      var item = document.createElement(url ? "a" : "span");
      if (url) item.href = url;
      item.textContent = detail.text;
      meta.appendChild(item);
    });
    return meta;
  }

  function renderActionResultCard(card, record) {
    card.replaceChildren();
    card.classList.add("is-built");
    if (record.marker && record.marker.color) {
      card.style.setProperty("--sc-marker-color", String(record.marker.color));
    }
    var header = document.createElement("header");
    header.className = "sc-group-action-card-header";
    if (record.marker && typeof record.marker === "object") {
      var marker = document.createElement("span");
      marker.className = "sc-group-dialog-marker";
      marker.appendChild(markerGlyph(record.marker, true));
      header.appendChild(marker);
    }
    var heading = document.createElement("div");
    var title = document.createElement("h4");
    title.appendChild(actionResultLink(record));
    var summary = document.createElement("p");
    summary.textContent = record.summary || "Group completed";
    heading.append(title, summary);
    header.appendChild(heading);
    card.append(header, actionResultDetails(record));
  }

  function renderActionResult(result, payload, succeeded, root) {
    result.replaceChildren();
    var message = document.createElement("div");
    message.className = "sc-action-result-message";
    message.textContent = payload.message || (succeeded ? "Action completed." : "Action failed.");
    result.appendChild(message);
    if (!succeeded || !Array.isArray(payload.records)) return;
    var list = document.createElement("ul");
    list.className = "sc-action-built-records";
    payload.records.forEach(function (record) {
      if (!record || !/^\d+$/.test(String(record.id || ""))) return;
      var markerId = record.marker && record.marker.id ? String(record.marker.id) : "";
      var card = root && Array.from(root.querySelectorAll("[data-sc-group-action-card]")).find(function (candidate) {
        return candidate.dataset.scGroupActionCard === markerId;
      });
      if (card) renderActionResultCard(card, record);
      else {
        var item = document.createElement("li");
        item.className = "sc-group-action-card";
        renderActionResultCard(item, record);
        list.appendChild(item);
      }
    });
    if (list.childNodes.length) result.appendChild(list);
  }

  document.addEventListener("submit", function (event) {
    var form = event.target.closest("[data-sc-action-form]");
    if (!form || typeof window.fetch !== "function") return;
    if (form.matches("[data-sc-record-editor-action-form]")) return;
    event.preventDefault();
    if (form.dataset.scActionFormUrl && form.dataset.scActionFormReady !== "1") return;
    var root = form.closest("[data-sc-bulk-action]");
    var ids = selectedRowIds(root);
    populateActionTargets(form, ids);
    if (actionMode(root) === "groups") serializeGroupedAction(root, form);
    if (!ids.length || !form.reportValidity()) return;

    var submit = form.querySelector('button[type="submit"]');
    var result = form.querySelector("[data-sc-action-result]");
    if (submit) {
      submit.disabled = true;
      submit.textContent = "Applying…";
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
        document.dispatchEvent(new CustomEvent("selecto:records-changed"));
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
