  function rowClickIsInteractive(target) {
    return !!target.closest(
      "a,button,input,select,textarea,label,summary,[role=button],[contenteditable=true]"
    );
  }

  function openResultRow(row) {
    var url = row && row.dataset.scRowClickUrl;
    if (!url) return;
    if (row.dataset.scRowClickType === "iframe_modal") {
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
    return Array.from(root.querySelectorAll('[data-sc-row-click-type="iframe_modal"]')).filter(
      function (row) { return row.dataset.scRowDialogId === dialog.id; }
    );
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
    var current = Number(dialog.dataset.scRowDialogIndex || 0);
    setRowDialogIndex(dialog, current + offset);
  }

  function clearRowDialog(dialog) {
    if (!dialog) return;
    var frame = dialog.querySelector("[data-sc-row-dialog-frame]");
    var loading = dialog.querySelector("[data-sc-row-dialog-loading]");
    if (frame) {
      frame.removeAttribute("src");
      frame.classList.remove("is-loading");
    }
    if (loading) loading.hidden = true;
    delete dialog.dataset.scRowDialogIndex;
  }

  function closeRowDialog(dialog) {
    if (!dialog) return;
    clearRowDialog(dialog);
    if (typeof dialog.close === "function") dialog.close();
    else dialog.removeAttribute("open");
  }
