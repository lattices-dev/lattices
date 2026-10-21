// The service worker owns the native messaging connection. This page is status-only.
const statusElement = document.getElementById("status");
if (statusElement) statusElement.textContent = "Action connects privately through Chrome native messaging.";
export {};
