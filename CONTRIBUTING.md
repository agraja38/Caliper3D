# Contributing

Read PROJECT_SPEC.md, IMPLEMENTATION_STATUS.md and NEXT_STEPS.md before starting. Work on development or a topic branch based on it; never rewrite shared history. Keep changes native Swift/SwiftUI and local-first.

Run `./Scripts/verify.sh` before proposing changes. Regenerate the checked-in Xcode project with `xcodegen generate` after changing project.yml. Record actual build/test results and physical-device gaps honestly. Add meaningful tests for storage, security boundaries and state transitions. Keep UI separate from services and use injected mocks for demo behavior.

Never commit scans, credentials, signing identities, provisioning profiles or private keys. Use static/private OSLog fields. Do not add networking or installer behavior without the security controls described in PROJECT_SPEC.md. Update the handover files with each milestone.
