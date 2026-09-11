# Privacy

Caliper3D is local-first. It has no accounts, analytics, telemetry, advertisements, subscriptions, cloud backend or remote processing.

Current main activates Apple Object Capture only after New Scan, hardware support and camera permission. It does not activate network discovery. The published v1.0.0 foundation remains demo-only. Demo captures and transfers are synthetic and never send data. Mac demo projects persist locally; iPhone demo records last for the current app session only.

Imported photos are copied into local .caliper3d packages. Their original metadata is preserved, including any location information present in the source. Treat packages as private and inspect them before sharing. No scans are included in the repository. Data created by the Mac app lives under its Application Support/Caliper3D directory (inside the app container when sandboxed), with separate Projects and DemoProjects folders.

OSLog categories are prepared for diagnostics. Current logging uses static operation messages; filenames, device identifiers, image content, tokens and credentials must not be logged publicly. Future opt-in diagnostic export must be reviewed for sensitive data.

Camera access requires system permission and an explicit scan action. Real datasets stay in the iPhone app container until explicitly deleted. Future LAN transfer will require explicit pairing and authenticated encrypted connections. Discovery must never imply trust. There is no automatic upload.

Delete a local package in Finder to delete its stored capture and derived data. Normal filesystem deletion does not promise forensic erasure. Removing the app does not necessarily remove its Application Support data.
