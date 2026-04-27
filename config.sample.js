// Copy this file to config.js before uploading the dashboard, or leave it out
// and enter these values in the dashboard UI at runtime.
// Use a read-only Table SAS for the dashboard. Do not use the tracker write SAS.
window.LabDashboardConfig = {
  storageAccountName: "copilots47e37hf4wbpe",
  tableName: "LabSessions",
  // Test-only: use accountKey to generate a read-only Table SAS in the browser.
  // Prefer sasToken for anything beyond local testing.
  accountKey: "<storage-account-key>",
  sasToken: "?<read-only-table-sas>",
  dashboardSasHours: 24,
  refreshSeconds: 5
};