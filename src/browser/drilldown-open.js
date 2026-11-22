  // A drilldown (a summary group, a pivot heading or cell, a grid cell)
  // replaces the results in place. With the platform's link modifiers it
  // opens elsewhere instead:
  //   Shift+click                       a new window
  //   Cmd+click (Mac), Ctrl+click       a new tab
  //   Cmd+Shift+click, Ctrl+Shift+click a dialog over this page
  // While a modifier is held, the drilldown under the pointer shows which
  // (data-sc-drill-open on the root element). Each sends the drilldown's own
  // form, so it works for GET and POST explorers alike.
  var drilldownFrames = 0;
  var drilldownOnMac = /mac|iphone|ipad/i.test(
    (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "");

  function drilldownOpening(event) {
    if (event.altKey) return "";
    var command = drilldownOnMac ? event.metaKey && !event.ctrlKey : event.ctrlKey && !event.metaKey;
    if (command && event.shiftKey) return canShowDialogs() ? "dialog" : "tab";
    if (command) return "tab";
    if (event.shiftKey && !event.ctrlKey && !event.metaKey) return "window";
    return "";
  }

  function canShowDialogs() {
    return typeof HTMLDialogElement === "function"
      && typeof HTMLDialogElement.prototype.showModal === "function";
  }

  function drilldownUnder(target) {
    var button = target && target.closest ? target.closest("button.sc-drilldown-value") : null;
    return button && button.form && !button.disabled ? button : null;
  }

  // A plain copy of the drilldown's form: the live one is sent over the page's
  // channel, and a results-only render is no page to open on its own.
  function sendDrilldownTo(button, target) {
    var form = button.form;
    var copy = document.createElement("form");
    copy.hidden = true;
    copy.action = form.action;
    copy.method = form.method || "get";
    copy.target = target;
    new FormData(form, button).forEach(function (value, name) {
      if (name === "render_scope" || name === "selecto_request_id" || typeof value !== "string") return;
      var input = document.createElement("input");
      input.type = "hidden";
      input.name = name;
      input.value = value;
      copy.appendChild(input);
    });
    document.body.appendChild(copy);
    copy.submit();
    copy.remove();
  }

  function openDrilldownWindow(button) {
    var name = "sc-drilldown-window-" + (++drilldownFrames);
    var width = Math.min(1280, Math.max(640, window.outerWidth - 80));
    var height = Math.min(900, Math.max(480, window.outerHeight - 80));
    var opened = window.open("", name, "popup,width=" + width + ",height=" + height);
    sendDrilldownTo(button, opened ? name : "_blank");
  }

  function openDrilldownDialog(button) {
    var title = (button.getAttribute("aria-label") || button.textContent || "").trim()
      .replace(/^Show details for /, "") || "Details";
    var name = "sc-drilldown-frame-" + (++drilldownFrames);
    var dialog = document.createElement("dialog");
    dialog.className = "sc-row-dialog sc-row-dialog-xl sc-drilldown-dialog";
    dialog.setAttribute("aria-label", "Details: " + title);
    var panel = document.createElement("section");
    panel.className = "sc-row-dialog-panel sc-drilldown-dialog-panel";
    var header = document.createElement("header");
    var heading = document.createElement("div");
    var eyebrow = document.createElement("p");
    eyebrow.className = "sc-eyebrow";
    eyebrow.textContent = "Details";
    var h3 = document.createElement("h3");
    h3.textContent = title;
    heading.append(eyebrow, h3);
    var tools = document.createElement("div");
    tools.className = "sc-drilldown-dialog-tools";
    var open = document.createElement("button");
    open.type = "button";
    open.className = "sc-button sc-secondary";
    open.textContent = "Open in new window";
    open.addEventListener("click", function () {
      dialog.close();
      if (button.isConnected) openDrilldownWindow(button);
    });
    var close = document.createElement("button");
    close.type = "button";
    close.className = "sc-action-close";
    close.setAttribute("aria-label", "Close details");
    close.textContent = "×";
    close.addEventListener("click", function () { dialog.close(); });
    tools.append(open, close);
    header.append(heading, tools);
    var shell = document.createElement("div");
    shell.className = "sc-row-dialog-frame-shell";
    var frame = document.createElement("iframe");
    frame.name = name;
    frame.title = "Details: " + title;
    shell.appendChild(frame);
    panel.append(header, shell);
    dialog.appendChild(panel);
    dialog.addEventListener("click", function (event) {
      if (event.target === dialog) dialog.close();   // the backdrop
    });
    dialog.addEventListener("close", function () {
      frame.removeAttribute("src");
      dialog.remove();
      if (button.isConnected) button.focus({preventScroll: true});
    }, {once: true});
    document.body.appendChild(dialog);
    dialog.showModal();
    sendDrilldownTo(button, name);
    close.focus({preventScroll: true});
  }

  document.addEventListener("click", function (event) {
    if (event.button !== 0) return;
    var opening = drilldownOpening(event);
    var button = opening && drilldownUnder(event.target);
    if (!button) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    markDrilldownOpening("");
    if (opening === "dialog") openDrilldownDialog(button);
    else if (opening === "window") openDrilldownWindow(button);
    else sendDrilldownTo(button, "_blank");
  }, true);

  // Shift+press would otherwise select text up to the drilldown.
  document.addEventListener("mousedown", function (event) {
    if (event.button === 0 && drilldownOpening(event) && drilldownUnder(event.target)) event.preventDefault();
  }, true);

  // What a click would do, shown on the drilldown under the pointer.
  function markDrilldownOpening(opening) {
    var root = document.documentElement;
    if (opening) root.setAttribute("data-sc-drill-open", opening);
    else root.removeAttribute("data-sc-drill-open");
  }
  function trackDrilldownModifiers(event) { markDrilldownOpening(drilldownOpening(event)); }
  document.addEventListener("keydown", trackDrilldownModifiers, true);
  document.addEventListener("keyup", trackDrilldownModifiers, true);
  document.addEventListener("mousemove", trackDrilldownModifiers, {capture: true, passive: true});
  window.addEventListener("blur", function () { markDrilldownOpening(""); });
