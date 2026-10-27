# Privacy and network behavior

Amp Workbench has no analytics account or telemetry service. Local sounds, tone history, cached downloads, USB diagnostics, and MIDI captures are stored on your device. OpenAI and optional hosted-service credentials are stored in the device Keychain. Shared sound links include the preset, not credentials or AI traces. Review diagnostic exports before sharing them: they can include device details and tone settings.

Network activity depends on actions and build configuration:

- Importing community sounds downloads preset files from the linked third-party source. The files remain local unless you export or share them.
- Choosing **My OpenAI key** sends your description and relevant sound settings directly to OpenAI. A named-song creation request may enable OpenAI web search. OpenAI API usage is billed to your account.
- Apple Intelligence sound creation/refinement and Local rules do not send descriptions to OpenAI, Cloudflare, or another AI server.
- If a build is configured with `AmpWorkbenchServiceBaseURL`, the iPhone may refresh its read-only sound catalogue from that HTTPS service, and selecting its hosted AI mode sends requests to it. The default public source build has no such service URL.

The app uses Core MIDI to communicate with a connected THR II amplifier. It does not access the microphone or upload guitar audio.
