  var activeBuilderTabs = Object.create(null);
  var collapsedBuilderTrays = Object.create(null);
  var connectionStatus = "Connecting";
  var chartInstances = new WeakMap();
  var selectoPerformance = null;
  var selectoSwapStarted = 0;
  var selectoHistorySnapshots = new Map();
  var selectoHistoryCounter = 0;
  var dateFormats = [
    ["day", "Day"], ["day_hour", "Day + Hour"], ["week", "Week"],
    ["month", "Month"], ["quarter", "Quarter"], ["year", "Year"],
    ["month_of_year", "Month of Year"], ["day_of_month", "Day of Month"],
    ["day_of_week", "Day of Week"], ["hour", "Hour of Day"]
  ];
