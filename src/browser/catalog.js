  document.addEventListener("click", async function (event) {
    var button = event.target.closest("[data-sc-catalog-copy]");
    if (!button) return;
    var text = document.getElementById(button.dataset.scCatalogCopy);
    var status = button.parentElement.querySelector("[data-sc-catalog-copy-status]");
    if (!text || !status) return;
    try {
      await navigator.clipboard.writeText(text.textContent);
      status.textContent = button.dataset.scCopied;
    } catch (_) {
      status.textContent = button.dataset.scCopyFailed;
    }
  });
