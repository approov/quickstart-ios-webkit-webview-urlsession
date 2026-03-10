//
//  ShapesQuickstartPage.swift
//  WebViewShapes
//
//  This file is demo-specific presentation code.
//
//  The point of the page is to prove that ordinary web content can keep using:
//  - `fetch(...)`
//  - `<form method="...">`
//
//  while the generic bridge in `ApproovWebViewBridge.swift` reroutes those
//  requests through native Swift, attaches Approov protection when configured,
//  and returns the response back to the page.
//

import Foundation

enum ShapesQuickstartPage {
    static func html(protectedEndpoint: URL) -> String {
        #"""
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <title>Approov WebView Quickstart</title>
            <style>
              :root {
                --paper: #f8f4ea;
                --ink: #16242b;
                --muted: #556871;
                --line: rgba(22, 36, 43, 0.12);
                --accent: #d45f3a;
                --accent-deep: #9d3f1f;
                --shape: #137a7f;
                --card: rgba(255, 255, 255, 0.72);
                --card-strong: rgba(255, 255, 255, 0.88);
                --shadow: 0 18px 48px rgba(22, 36, 43, 0.14);
              }

              * {
                box-sizing: border-box;
              }

              html,
              body {
                margin: 0;
                min-height: 100%;
                font-family: "Avenir Next", "Helvetica Neue", sans-serif;
                color: var(--ink);
                background:
                  radial-gradient(circle at top left, rgba(242, 175, 95, 0.42), transparent 32%),
                  radial-gradient(circle at bottom right, rgba(19, 122, 127, 0.22), transparent 28%),
                  linear-gradient(180deg, #f3ecdc 0%, #eef3f5 100%);
              }

              body {
                padding: 20px;
              }

              .shell {
                min-height: calc(100vh - 40px);
                display: grid;
                place-items: center;
              }

              .card {
                width: min(980px, 100%);
                border: 1px solid var(--line);
                border-radius: 28px;
                padding: 28px;
                background: var(--card);
                backdrop-filter: blur(12px);
                box-shadow: var(--shadow);
              }

              .eyebrow {
                margin: 0 0 8px;
                font-size: 13px;
                font-weight: 700;
                letter-spacing: 0.18em;
                text-transform: uppercase;
                color: var(--accent-deep);
              }

              h1 {
                margin: 0;
                font-family: "Avenir Next Condensed", "Trebuchet MS", sans-serif;
                font-size: clamp(2.3rem, 6vw, 4.2rem);
                line-height: 0.95;
                letter-spacing: -0.04em;
              }

              .lede {
                max-width: 58rem;
                margin: 18px 0 22px;
                font-size: 1rem;
                line-height: 1.65;
                color: var(--muted);
              }

              .actions {
                display: grid;
                grid-template-columns: repeat(2, minmax(0, 1fr));
                gap: 16px;
                margin: 22px 0 10px;
              }

              .action-card {
                padding: 18px;
                border: 1px solid var(--line);
                border-radius: 22px;
                background: var(--card-strong);
              }

              .action-card h2 {
                margin: 0 0 8px;
                font-size: 1.05rem;
              }

              .action-card p {
                margin: 0 0 14px;
                font-size: 0.95rem;
                line-height: 1.55;
                color: var(--muted);
              }

              .inline-form {
                margin: 0;
              }

              button {
                appearance: none;
                border: 0;
                border-radius: 999px;
                padding: 14px 22px;
                font: inherit;
                font-weight: 700;
                color: white;
                background: linear-gradient(135deg, var(--accent) 0%, var(--accent-deep) 100%);
                box-shadow: 0 10px 24px rgba(212, 95, 58, 0.32);
                cursor: pointer;
                transition: transform 140ms ease, box-shadow 140ms ease, opacity 140ms ease;
              }

              button:hover {
                transform: translateY(-1px);
                box-shadow: 0 14px 28px rgba(212, 95, 58, 0.36);
              }

              button:disabled {
                opacity: 0.62;
                cursor: progress;
                transform: none;
                box-shadow: 0 8px 18px rgba(22, 36, 43, 0.12);
              }

              .bridge-status {
                margin: 12px 0 0;
                font-size: 0.92rem;
                color: var(--muted);
              }

              .result {
                display: grid;
                grid-template-columns: minmax(280px, 1fr) minmax(280px, 1.1fr);
                gap: 22px;
                margin-top: 24px;
              }

              .shape-stage,
              .details {
                border: 1px solid var(--line);
                border-radius: 24px;
                background: rgba(255, 255, 255, 0.78);
              }

              .shape-stage {
                min-height: 360px;
                padding: 26px;
                display: grid;
                place-items: center;
                position: relative;
                overflow: hidden;
              }

              .shape-stage::before {
                content: "";
                position: absolute;
                inset: 16px;
                border-radius: 20px;
                border: 1px dashed rgba(19, 122, 127, 0.28);
              }

              .shape-stage.is-empty::before {
                border-color: rgba(22, 36, 43, 0.14);
              }

              .shape {
                position: relative;
                z-index: 1;
                opacity: 0;
                transform: scale(0.82);
                transition: opacity 220ms ease, transform 220ms ease;
              }

              .shape.is-visible {
                opacity: 1;
                transform: scale(1);
              }

              .shape--circle,
              .shape--square {
                width: 170px;
                height: 170px;
                background: var(--shape);
              }

              .shape--circle {
                border-radius: 999px;
              }

              .shape--rectangle {
                width: 220px;
                height: 136px;
                background: var(--shape);
                border-radius: 24px;
              }

              .shape--triangle {
                width: 0;
                height: 0;
                border-left: 96px solid transparent;
                border-right: 96px solid transparent;
                border-bottom: 168px solid var(--shape);
              }

              #shape-placeholder {
                position: relative;
                z-index: 1;
                max-width: 16rem;
                margin: 0;
                text-align: center;
                color: var(--muted);
                line-height: 1.6;
              }

              .shape-stage:not(.is-empty) #shape-placeholder {
                display: none;
              }

              .details {
                padding: 22px;
              }

              .label {
                margin: 0 0 8px;
                font-size: 0.8rem;
                font-weight: 800;
                letter-spacing: 0.16em;
                text-transform: uppercase;
                color: var(--accent-deep);
              }

              #message {
                margin: 0 0 18px;
                font-size: 1.1rem;
                line-height: 1.5;
              }

              #payload-preview {
                margin: 0;
                padding: 18px;
                border-radius: 18px;
                background: #18282f;
                color: #f3f7f8;
                font-family: "SFMono-Regular", "Menlo", monospace;
                font-size: 0.86rem;
                line-height: 1.6;
                min-height: 208px;
                overflow: auto;
                white-space: pre-wrap;
                word-break: break-word;
              }

              @media (max-width: 760px) {
                body {
                  padding: 14px;
                }

                .shell {
                  min-height: calc(100vh - 28px);
                }

                .card {
                  padding: 22px;
                  border-radius: 24px;
                }

                .actions,
                .result {
                  grid-template-columns: 1fr;
                }

                .shape-stage {
                  min-height: 280px;
                }
              }
            </style>
          </head>
          <body>
            <main class="shell">
              <section class="card">
                <p class="eyebrow">Approov WebView Quickstart</p>
                <h1>Protect WebView API Calls, XHR, and Forms</h1>
                <p class="lede">
                  This page lives entirely inside the WebView. It proves that ordinary web code can
                  keep using <code>fetch()</code> and real HTML <code>&lt;form&gt;</code> submission
                  while the native bridge reroutes requests through Swift, injects native-only secrets,
                  tries to attach an Approov JWT on the <code>approov-token</code> header, and returns
                  the response back to the page.
                </p>

                <div class="actions">
                  <section class="action-card">
                    <h2>Fetch</h2>
                    <p>
                      Uses a standard JavaScript <code>fetch()</code> call from inside the page.
                    </p>
                    <button id="fetch-shape-button" type="button">Fetch Protected Shape</button>
                  </section>

                  <section class="action-card">
                    <h2>HTML Form</h2>
                    <p>
                      Uses a real HTML form submission. The form is marked to return its response back
                      into the page instead of navigating away from the demo.
                    </p>
                    <form
                      id="shape-form"
                      class="inline-form"
                      action="\#(protectedEndpoint.absoluteString)"
                      method="GET"
                      data-approov-submit-mode="response"
                    >
                      <button id="submit-shape-form" type="submit">Submit Protected Form</button>
                    </form>
                  </section>
                </div>

                <p id="bridge-status" class="bridge-status">Checking native bridge...</p>

                <div class="result">
                  <div id="shape-stage" class="shape-stage is-empty">
                    <div id="shape" class="shape" aria-hidden="true"></div>
                    <p id="shape-placeholder">Trigger either request path to ask the protected API for a shape.</p>
                  </div>

                  <div class="details">
                    <p class="label">Status</p>
                    <p id="message">Waiting for a protected API call.</p>

                    <p class="label">Raw Payload</p>
                    <pre id="payload-preview">No payload yet.</pre>
                  </div>
                </div>
              </section>
            </main>

            <script>
              const protectedEndpoint = "\#(protectedEndpoint.absoluteString)";
              const fetchButton = document.getElementById("fetch-shape-button");
              const formButton = document.getElementById("submit-shape-form");
              const shapeForm = document.getElementById("shape-form");
              const bridgeStatus = document.getElementById("bridge-status");
              const message = document.getElementById("message");
              const payloadPreview = document.getElementById("payload-preview");
              const shapeStage = document.getElementById("shape-stage");
              const shape = document.getElementById("shape");

              const setBridgeStatus = () => {
                if (window.__approovBridgeEnabled) {
                  const features = window.__approovBridgeFeatures || {};
                  const activeFeatures = Object.entries(features)
                    .filter(([, enabled]) => Boolean(enabled))
                    .map(([name]) => name)
                    .join(", ");
                  bridgeStatus.textContent = `Native Approov bridge is active. Covered features: ${activeFeatures}.`;
                } else {
                  bridgeStatus.textContent = "Native bridge unavailable. Requests would use the browser network stack instead.";
                }
              };

              const setBusy = (isBusy, statusText) => {
                fetchButton.disabled = isBusy;
                formButton.disabled = isBusy;

                if (statusText) {
                  message.textContent = statusText;
                }

                if (isBusy) {
                  renderShape("");
                  payloadPreview.textContent = "Waiting for JSON payload...";
                }
              };

              const renderShape = (shapeName) => {
                shape.className = "shape";
                shapeStage.classList.add("is-empty");

                if (!shapeName) {
                  return;
                }

                shape.classList.add("is-visible", `shape--${shapeName}`);
                shapeStage.classList.remove("is-empty");
              };

              const showTransportError = (error) => {
                renderShape("");
                const errorMessage = error?.message || String(error);
                message.textContent = `Request failed: ${errorMessage}`;
                payloadPreview.textContent = `The native bridge rejected the request before it reached the API.\n\nBridge error:\n${errorMessage}`;
              };

              const renderResponsePayload = (code, statusText, responseText) => {
                if (code < 200 || code >= 300) {
                  renderShape("");
                  payloadPreview.textContent = responseText || "(empty response)";
                  message.textContent = `${code}: ${statusText}`;
                  return;
                }

                let jsonObject;
                try {
                  jsonObject = responseText ? JSON.parse(responseText) : {};
                } catch (_error) {
                  renderShape("");
                  payloadPreview.textContent = responseText || "(empty response)";
                  message.textContent = `${code}: invalid JSON payload`;
                  return;
                }

                payloadPreview.textContent = JSON.stringify(jsonObject, null, 2);

                let responseMessage = jsonObject["status"] || `${code}: missing status`;
                const shapeName = (jsonObject["shape"] || "").toLowerCase();

                switch (shapeName) {
                  case "circle":
                  case "rectangle":
                  case "square":
                  case "triangle":
                    renderShape(shapeName);
                    break;
                  default:
                    renderShape("");
                    responseMessage = `${code}: unknown shape '${shapeName}'`;
                }

                message.textContent = responseMessage;
              };

              const fetchShape = async () => {
                setBusy(true, "Fetching a protected shape with fetch()...");

                try {
                  // This is an ordinary JavaScript fetch call inside the page.
                  // The quickstart proves that page code does not need a custom
                  // URL scheme or a custom fetch API to benefit from Approov.
                  const response = await fetch(protectedEndpoint, {
                    method: "GET",
                    headers: {
                      Accept: "application/json",
                    },
                  });

                  const responseText = await response.text();
                  renderResponsePayload(response.status, response.statusText, responseText);
                } catch (error) {
                  showTransportError(error);
                } finally {
                  setBusy(false);
                }
              };

              shapeForm.addEventListener("submit", () => {
                setBusy(true, "Submitting a protected HTML form...");
              });

              shapeForm.addEventListener("approov:form-response", (event) => {
                const detail = event.detail || {};
                renderResponsePayload(
                  detail.status || 0,
                  detail.statusText || "Unknown",
                  detail.bodyText || "",
                );
                setBusy(false);
              });

              shapeForm.addEventListener("approov:form-error", (event) => {
                const detail = event.detail || {};
                showTransportError(new Error(detail.message || "Unknown form bridge failure."));
                setBusy(false);
              });

              fetchButton.addEventListener("click", fetchShape);
              setBridgeStatus();
            </script>
          </body>
        </html>
        """#
    }
}
