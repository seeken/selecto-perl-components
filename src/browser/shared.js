  var activeBuilderTabs = Object.create(null);
  var collapsedBuilderTrays = Object.create(null);
  var connectionStatus = "Connecting";
  var chartInstances = new WeakMap();
  var chartRetryTimers = new WeakMap();
  var selectoPerformance = null;
  var selectoSwapStarted = 0;
  var selectoHistorySnapshots = new Map();
  var selectoHistoryCounter = 0;
  var selectoRequestCounter = 0;
  var activeSelectoRequestId = null;
  var selectoWebSocketRecoveryTimer = null;
  var dateFormats = [
    ["day", "Day"], ["day_hour", "Day + Hour"], ["week", "Week"],
    ["month", "Month"], ["quarter", "Quarter"], ["year", "Year"],
    ["month_of_year", "Month of Year"], ["day_of_month", "Day of Month"],
    ["day_of_week", "Day of Week"], ["hour", "Hour of Day"]
  ];

  // Requests made by an action dialog carry the page's effective host options.
  function appendQueryOptions(params, form) {
    if (!form) return;
    form.querySelectorAll("[data-sc-query-option-value]").forEach(function (input) {
      params.set(input.name, input.value);
    });
  }

  function normalizeQueryOptions(params, form) {
    form.querySelectorAll("[data-sc-query-option]").forEach(function (control) {
      var values = params.getAll(control.name);
      if (!values.length) return;
      params.delete(control.name);
      var value = values[values.length - 1];
      if (value !== control.dataset.scQueryOptionDefault) params.set(control.name, value);
    });
  }
