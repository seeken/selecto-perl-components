  function rowClickIsInteractive(target) {
    return !!target.closest(
      "a,button,input,select,textarea,label,summary,[role=button],[contenteditable=true]"
    );
  }

  function openResultRow(row) {
    var url = row && row.dataset.scRowClickUrl;
    if (!url) return;
    if (row.dataset.scRowClickType === "iframe_modal"
        || row.dataset.scRowClickType === "record_editor") {
      openRowDialog(row);
      return;
    }
    var target = row.dataset.scRowClickTarget || "_self";
    if (target === "_blank") {
      window.open(url, "_blank", "noopener,noreferrer");
      return;
    }
    if (target === "_parent") {
      window.parent.location.assign(url);
      return;
    }
    if (target === "_top") {
      window.top.location.assign(url);
      return;
    }
    window.location.assign(url);
  }

  function rowDialogRows(dialog) {
    if (!dialog) return [];
    var root = dialog.closest(".sc-results") || document;
    var kind = dialog.dataset.scRowDialogKind || "iframe_modal";
    return Array.from(root.querySelectorAll("[data-sc-row-click-type]")).filter(
      function (row) {
        return row.dataset.scRowClickType === kind
          && row.dataset.scRowDialogId === dialog.id
          && row.dataset.scRowRetired !== "1";
      }
    );
  }

  function replaceEditorBody(body, html) {
    if (!body) return;
    var parsed = new DOMParser().parseFromString(String(html || ""), "text/html");
    var nodes = Array.from(parsed.body.childNodes).map(function (node) {
      return document.importNode(node, true);
    });
    body.replaceChildren.apply(body, nodes);
  }

  function recordEditorSignature(form) {
    var values = [];
    new FormData(form).forEach(function (value, name) {
      if (name.indexOf("editor_field_") === 0) values.push([name, String(value)]);
    });
    values.sort(function (left, right) {
      return left[0] === right[0] ? left[1].localeCompare(right[1]) : left[0].localeCompare(right[0]);
    });
    return JSON.stringify(values);
  }

  function updateRecordEditorDirty(form) {
    if (!form) return false;
    var dirty = recordEditorSignature(form) !== (form.dataset.scInitialValues || "[]");
    form.dataset.scRecordEditorDirty = dirty ? "1" : "0";
    var save = form.querySelector("[data-sc-record-editor-save]");
    if (save) save.disabled = !dirty;
    return dirty;
  }

  function initializeRecordEditor(form) {
    if (!form) return;
    form.dataset.scInitialValues = recordEditorSignature(form);
    updateRecordEditorDirty(form);
  }

  function recordEditorIsDirty(dialog) {
    var form = dialog && dialog.querySelector("[data-sc-record-editor-form]");
    return form ? updateRecordEditorDirty(form) : false;
  }

  function confirmEditorDiscard(dialog) {
    return !recordEditorIsDirty(dialog)
      || window.confirm("Discard the unsaved changes to this record?");
  }

  function loadRecordEditor(dialog, url) {
    var body = dialog.querySelector("[data-sc-row-editor-body]");
    var loading = dialog.querySelector("[data-sc-row-dialog-loading]");
    if (!body) return;
    if (dialog._scEditorAbort) dialog._scEditorAbort.abort();
    var abort = typeof AbortController === "function" ? new AbortController() : null;
    dialog._scEditorAbort = abort;
    body.replaceChildren();
    if (loading) loading.hidden = false;
    window.fetch(url, {
      credentials: "same-origin",
      headers: {"X-Requested-With": "XMLHttpRequest"},
      signal: abort ? abort.signal : undefined
    }).then(function (response) {
      return response.text().then(function (html) {
        if (!response.ok) throw new Error(html.replace(/<[^>]*>/g, " ").trim()
          || "The editor could not be loaded.");
        return html;
      });
    }).then(function (html) {
      if (dialog._scEditorAbort !== abort) return;
      replaceEditorBody(body, html);
      initializeRecordEditor(body.querySelector("[data-sc-record-editor-form]"));
      var first = body.querySelector("input:not([type=hidden]),textarea,select,button");
      if (first) first.focus();
    }).catch(function (error) {
      if (error && error.name === "AbortError") return;
      body.replaceChildren();
      var message = document.createElement("div");
      message.className = "sc-record-editor-error-panel";
      message.setAttribute("role", "alert");
      message.textContent = error && error.message || "The editor could not be loaded.";
      body.appendChild(message);
    }).finally(function () {
      if (dialog._scEditorAbort === abort && loading) loading.hidden = true;
    });
  }

  function setRowDialogIndex(dialog, index) {
    var rows = rowDialogRows(dialog);
    if (!rows.length) return;
    var nextIndex = Math.max(0, Math.min(Number(index) || 0, rows.length - 1));
    var row = rows[nextIndex];
    var url = row.dataset.scRowClickUrl || "";
    var title = row.dataset.scRowClickTitle || "Details";
    var heading = dialog.querySelector("[data-sc-row-dialog-title]");
    var frame = dialog.querySelector("[data-sc-row-dialog-frame]");
    var loading = dialog.querySelector("[data-sc-row-dialog-loading]");
    var fullPage = dialog.querySelector("[data-sc-row-dialog-open]");
    var position = dialog.querySelector("[data-sc-row-dialog-position]");
    var previous = dialog.querySelector('[data-sc-row-dialog-nav="previous"]');
    var next = dialog.querySelector('[data-sc-row-dialog-nav="next"]');
    dialog.dataset.scRowDialogIndex = String(nextIndex);
    if (heading) heading.textContent = title;
    if (fullPage) fullPage.href = url;
    if (position) position.textContent = "Row " + (nextIndex + 1) + " of " + rows.length + " on this page";
    if (previous) previous.disabled = nextIndex === 0;
    if (next) next.disabled = nextIndex === rows.length - 1;
    if (dialog.dataset.scRowDialogKind === "record_editor") {
      loadRecordEditor(dialog, url);
      return;
    }
    if (frame) {
      frame.title = title;
      if (frame.getAttribute("src") !== url) {
        if (loading) loading.hidden = false;
        frame.classList.add("is-loading");
        frame.setAttribute("src", url);
      }
    }
  }

  function openRowDialog(row) {
    var dialog = document.getElementById(row && row.dataset.scRowDialogId || "");
    if (!dialog) return;
    if (dialog.open && !confirmEditorDiscard(dialog)) return;
    var rows = rowDialogRows(dialog);
    var index = rows.indexOf(row);
    if (index < 0) return;
    setRowDialogIndex(dialog, index);
    if (!dialog.open) {
      if (typeof dialog.showModal === "function") dialog.showModal();
      else dialog.setAttribute("open", "");
    }
  }

  function moveRowDialog(dialog, offset) {
    if (!dialog) return;
    if (!confirmEditorDiscard(dialog)) return;
    var current = Number(dialog.dataset.scRowDialogIndex || 0);
    setRowDialogIndex(dialog, current + offset);
  }

  function clearRowDialog(dialog) {
    if (!dialog) return;
    if (dialog._scEditorAbort) {
      dialog._scEditorAbort.abort();
      dialog._scEditorAbort = null;
    }
    var frame = dialog.querySelector("[data-sc-row-dialog-frame]");
    var editorBody = dialog.querySelector("[data-sc-row-editor-body]");
    var loading = dialog.querySelector("[data-sc-row-dialog-loading]");
    if (frame) {
      frame.removeAttribute("src");
      frame.classList.remove("is-loading");
    }
    if (editorBody) editorBody.replaceChildren();
    if (loading) loading.hidden = true;
    delete dialog.dataset.scRowDialogIndex;
  }

  function closeRowDialog(dialog) {
    if (!dialog) return;
    var retiredFocus = dialog._scRetiredFocus;
    dialog._scRetiredFocus = null;
    clearRowDialog(dialog);
    if (typeof dialog.close === "function") dialog.close();
    else dialog.removeAttribute("open");
    if (retiredFocus && retiredFocus.isConnected) retiredFocus.focus();
  }

  function retireEditedRow(row, minimal) {
    if (!row) return null;
    if (row.dataset.scRowRetired === "1") {
      var existingNotice = row.nextElementSibling;
      return row.querySelector(".sc-row-retired-badge")
        || existingNotice && existingNotice.matches(".sc-row-retired-notice")
          && existingNotice.querySelector(".sc-row-retired-badge");
    }
    row.dataset.scRowRetired = "1";
    row.classList.add("sc-row-retired");
    row.setAttribute("aria-disabled", "true");
    row.removeAttribute("tabindex");
    row.removeAttribute("data-sc-row-click");
    row.removeAttribute("data-sc-row-click-url");
    row.querySelectorAll("a,button,input,select,textarea").forEach(function (control) {
      if ("disabled" in control) control.disabled = true;
      if ("checked" in control) control.checked = false;
      control.setAttribute("tabindex", "-1");
    });
    var cells = Array.from(row.children).filter(function (cell) {
      return cell.matches("td,th");
    });
    if (!cells.length) return null;
    var statusHost;
    if (minimal) {
      var first = cells[0];
      first.colSpan = cells.length;
      first.replaceChildren();
      cells.slice(1).forEach(function (cell) { cell.remove(); });
      var identity = document.createElement("span");
      identity.className = "sc-row-retired-identity";
      identity.textContent = "Record " + (row.dataset.scRecordId || "");
      first.appendChild(identity);
      statusHost = first;
    } else {
      var noticeRow = document.createElement("tr");
      noticeRow.className = "sc-row-retired-notice";
      noticeRow.dataset.scRowRetiredNotice = row.dataset.scRecordId || "";
      var noticeCell = document.createElement("td");
      noticeCell.colSpan = cells.length;
      statusHost = document.createElement("div");
      statusHost.className = "sc-row-retired-notice-content";
      noticeCell.appendChild(statusHost);
      noticeRow.appendChild(noticeCell);
      row.insertAdjacentElement("afterend", noticeRow);
    }
    var badge = document.createElement("span");
    badge.className = "sc-row-retired-badge";
    badge.textContent = minimal
      ? "Updated — no longer available"
      : "Updated — no longer matches this result";
    badge.setAttribute("role", "status");
    badge.setAttribute("tabindex", "-1");
    statusHost.appendChild(document.createTextNode(" "));
    statusHost.appendChild(badge);
    var refresh = document.createElement("button");
    refresh.type = "button";
    refresh.className = "sc-button sc-secondary sc-row-retired-refresh";
    refresh.dataset.scRefreshResults = "1";
    refresh.textContent = "Refresh results";
    statusHost.appendChild(refresh);
    var results = row.closest(".sc-results");
    if (results) {
      var total = results.querySelector(".sc-result-meta strong");
      var count = total && Number(String(total.textContent).replace(/,/g, ""));
      if (total && Number.isFinite(count) && count > 0) total.textContent = String(count - 1);
      results.querySelectorAll("[data-sc-bulk-action]").forEach(function (root) {
        refreshBulkAction(root);
      });
    }
    return badge;
  }

  function synchronizeEditedRow(dialog, payload) {
    var currentRows = rowDialogRows(dialog);
    var current = currentRows[Number(dialog.dataset.scRowDialogIndex || 0)];
    var rowId = String(payload.row_id || current && current.dataset.scRecordId || "");
    if (!current || !rowId) return Promise.resolve();
    if (!payload.authorized) {
      dialog._scRetiredFocus = retireEditedRow(current, true);
      return Promise.resolve();
    }
    var returnUrl = new URL(payload.return_to || window.location.href, window.location.href);
    var ordered = returnUrl.searchParams.getAll("order");
    if ((payload.changed_fields || []).some(function (field) { return ordered.includes(field); })) {
      window.location.assign(returnUrl.pathname + returnUrl.search + returnUrl.hash);
      return Promise.resolve();
    }
    return window.fetch(payload.return_to || window.location.href, {
      credentials: "same-origin",
      headers: {"X-Requested-With": "XMLHttpRequest"}
    }).then(function (response) {
      if (!response.ok) throw new Error("The updated result could not be refreshed.");
      return response.text();
    }).then(function (html) {
      var parsed = new DOMParser().parseFromString(html, "text/html");
      var replacement = Array.from(parsed.querySelectorAll("[data-sc-record-id]")).find(
        function (candidate) { return candidate.dataset.scRecordId === rowId; }
      );
      if (!replacement) {
        dialog._scRetiredFocus = retireEditedRow(current, false);
        return;
      }
      current.replaceWith(document.importNode(replacement, true));
    }).catch(function () {
      window.location.assign(payload.return_to || window.location.href);
    });
  }

  document.addEventListener("submit", function (event) {
    var form = event.target.closest && event.target.closest("[data-sc-record-editor-form]");
    if (!form || typeof window.fetch !== "function") return;
    event.preventDefault();
    if (!form.reportValidity()) return;
    var dialog = form.closest("[data-sc-row-dialog]");
    var submit = form.querySelector('button[type="submit"]');
    var result = form.querySelector("[data-sc-record-editor-result]");
    form.querySelectorAll("[data-sc-record-editor-error]").forEach(function (node) {
      node.hidden = true;
      node.textContent = "";
    });
    if (submit) {
      submit.disabled = true;
      submit.dataset.scOriginalLabel = submit.textContent;
      submit.textContent = "Saving…";
    }
    if (result) {
      result.hidden = true;
      result.textContent = "";
      result.classList.remove("is-success", "is-error");
    }
    window.fetch(form.action, {
      method: "POST", body: new FormData(form), credentials: "same-origin",
      headers: {"Accept": "application/json", "X-Requested-With": "XMLHttpRequest"}
    }).then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (payload) {
        payload._responseOk = response.ok;
        return payload;
      });
    }).then(function (payload) {
      if (!payload._responseOk || !payload.ok) {
        Object.keys(payload.field_errors || {}).forEach(function (field) {
          var wrapper = form.querySelector('[data-sc-record-editor-field="' +
            (window.CSS && CSS.escape ? CSS.escape(field) : field) + '"]');
          var error = wrapper && wrapper.querySelector("[data-sc-record-editor-error]");
          if (error) {
            error.textContent = payload.field_errors[field];
            error.hidden = false;
          }
        });
        throw new Error(payload.message || "The record could not be saved.");
      }
      if (result) {
        result.textContent = payload.message || "The record was updated.";
        result.hidden = false;
        result.classList.add("is-success");
      }
      form.dataset.scInitialValues = recordEditorSignature(form);
      form.dataset.scRecordEditorDirty = "0";
      return synchronizeEditedRow(dialog, payload).then(function () { closeRowDialog(dialog); });
    }).catch(function (error) {
      if (result) {
        result.textContent = error && error.message || "The record could not be saved.";
        result.hidden = false;
        result.classList.add("is-error");
      }
    }).finally(function () {
      if (submit && submit.isConnected) {
        submit.disabled = false;
        submit.textContent = submit.dataset.scOriginalLabel || "Save changes";
      }
    });
  });

  document.addEventListener("input", function (event) {
    var form = event.target.closest && event.target.closest("[data-sc-record-editor-form]");
    if (form) updateRecordEditorDirty(form);
  });

  document.addEventListener("change", function (event) {
    var form = event.target.closest && event.target.closest("[data-sc-record-editor-form]");
    if (form) updateRecordEditorDirty(form);
  });

  document.addEventListener("click", function (event) {
    var open = event.target.closest
      && event.target.closest("[data-sc-record-editor-action-open]");
    var close = event.target.closest
      && event.target.closest("[data-sc-record-editor-action-close]");
    if (!open && !close) return;
    var actions = (open || close).closest(".sc-record-editor-actions");
    if (!actions) return;
    var panels = Array.from(actions.querySelectorAll("[data-sc-record-editor-action-panel]"));
    var buttons = Array.from(actions.querySelectorAll("[data-sc-record-editor-action-open]"));
    panels.forEach(function (panel) { panel.hidden = true; });
    buttons.forEach(function (button) { button.setAttribute("aria-expanded", "false"); });
    actions.classList.remove("is-action-open");
    if (close) {
      var owner = buttons.find(function (button) {
        return button.dataset.scRecordEditorActionOpen === close.closest("form").id;
      });
      if (owner) owner.focus();
      return;
    }
    var panelId = open.dataset.scRecordEditorActionOpen;
    var panel = panels.find(function (candidate) { return candidate.id === panelId; });
    if (!panel) return;
    panel.hidden = false;
    open.setAttribute("aria-expanded", "true");
    actions.classList.add("is-action-open");
    var firstInput = panel.querySelector("input:not([type=hidden]),select,textarea,button[type=submit]");
    if (firstInput) firstInput.focus();
  });

  document.addEventListener("submit", function (event) {
    var form = event.target.closest && event.target.closest("[data-sc-record-editor-action-form]");
    if (!form || typeof window.fetch !== "function") return;
    event.preventDefault();
    if (!form.reportValidity()) return;
    var dialog = form.closest("[data-sc-row-dialog]");
    var submit = form.querySelector('button[type="submit"]');
    var result = form.querySelector("[data-sc-action-result]");
    if (submit) {
      submit.disabled = true;
      submit.dataset.scOriginalLabel = submit.textContent;
      submit.textContent = "Applying…";
    }
    if (result) {
      result.hidden = true;
      result.textContent = "";
      result.classList.remove("is-success", "is-error");
    }
    window.fetch(form.action, {
      method: "POST", body: new FormData(form), credentials: "same-origin",
      headers: {"Accept": "application/json", "X-Requested-With": "XMLHttpRequest"}
    }).then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (payload) {
        payload._responseOk = response.ok;
        return payload;
      });
    }).then(function (payload) {
      if (!payload._responseOk || !payload.ok) {
        throw new Error(payload.message || "The action could not be completed.");
      }
      if (result) {
        result.textContent = payload.message || "The action was completed.";
        result.hidden = false;
        result.classList.add("is-success");
      }
      return synchronizeEditedRow(dialog, {
        row_id: form.dataset.scRecordId, return_to: form.dataset.scReturnTo,
        authorized: 1, changed_fields: []
      }).then(function () { closeRowDialog(dialog); });
    }).catch(function (error) {
      if (result) {
        result.textContent = error && error.message || "The action could not be completed.";
        result.hidden = false;
        result.classList.add("is-error");
      }
    }).finally(function () {
      if (submit && submit.isConnected) {
        submit.disabled = false;
        submit.textContent = submit.dataset.scOriginalLabel || "Apply";
      }
    });
  });
