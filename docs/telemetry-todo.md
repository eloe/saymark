# Remote telemetry launch checklist

Remote analytics is not configured in current Saymark source or local builds.
The PostHog integration is intentionally dormant: no project token means the SDK
is not initialized, capture calls are inert, and the user interface reports that
diagnostics remain on the Mac.

Do not populate `TUIST_SAYMARK_POSTHOG_KEY` or enable remote telemetry in a
distributed build until every launch gate below is complete:

- Create a Saymark-owned PostHog organization and project. Never reuse Murmur's
  project, credentials, endpoints, or data.
- Choose and document the hosting region, retention period, access controls, and
  deletion procedure.
- Publish a privacy policy that names the processor, enumerates collected
  fields, explains retention, and provides an opt-out and deletion contact.
- Review the event schema. It may include coarse timings, numeric resource
  measurements, app/OS versions, model identifiers, and error categories. It
  must never include audio, transcript text, clipboard contents, selected text,
  focused-field contents, filenames, or stable device identifiers.
- Add automated tests proving analytics is off by default, no client starts
  without a token, opt-out stops transmission, and prohibited fields are absent.
- Capture no application lifecycle events before explicit consent. Confirm that
  changing consent takes effect immediately and persists correctly.
- Add a network-level integration test against a controlled endpoint and record
  the exact payloads as release evidence.
- Complete the open-source and binary-release privacy review.

After those gates pass, inject the Saymark project's write-only token at project
generation time:

```sh
TUIST_SAYMARK_POSTHOG_KEY=phc_... tuist generate
```

The token is configuration, not proof of approval. Release automation should
require the privacy and telemetry tests before accepting a non-empty value.
