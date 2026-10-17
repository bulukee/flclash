# Customer Service Configuration

Add `customerService` beside `urls` and `updates` in the existing GitCode
`config.json`. Keep your existing `updates` and `releaseNotes` fields unchanged.

```json
{
  "urls": [
    "https://swy.yuxwu.com",
    "https://aallpp.sanweny.com",
    "https://aakkpp.sanweny.com",
    "https://mt1.swyyy.com"
  ],
  "customerService": {
    "url": "https://chat.swywl.com/widget?website_token=8SpSTtNMSfp64U8wevUS7wZ7#/"
  },
  "invitation": {
    "url": "https://swy1.sanweny.com/register?code=NoEYnmwU"
  }
}
```

- GitCode hosts the configuration, not the running customer service backend.
- The URL must use HTTPS and must not contain embedded credentials.
- For Chatwoot, copy the full widget URL, including `website_token` and `#/`.
  The conversation API derives its server and inbox from that URL.
- Remote configuration is cached for five minutes. Reopening customer service
  after the cache expires checks the remote configuration again.
- If a fetch fails, or the field is missing or invalid, the last valid URL is
  retained. Without a saved URL, the built-in customer service URL is used.
- Reopening the same URL reuses the embedded browser and its cookies. The URL
  changing causes navigation, without clearing browser storage.
- Changing to another server or inbox does not migrate chat history. The API
  session is scoped to its server and inbox so old IDs are not sent elsewhere.
- Do not put administrator credentials or private API keys in this public file.

The registration form reads the invitation code from `invitation.url` and
prefills it automatically. The rebate page uses the same configured URL as its
base, replacing only the `code` parameter with each signed-in user's own code.
Changing the invitation URL in GitCode does not require a new app build. The
client caches remote configuration for up to five minutes.
Keep the backup configuration source in sync too; it is used if the GitCode
configuration cannot be reached.

## macOS Update Packages

Publish both architecture-specific DMGs and checksums in `updates.macos`:

```json
"macos": {
  "versionCode": 2026101701,
  "versionName": "1.2.25",
  "force": false,
  "arm64Url": "https://client.sanweny.com/swywl/Salmon-macOS-arm64-1.2.25.dmg",
  "arm64Sha256": "<ARM64_DMG_SHA256>",
  "x64Url": "https://client.sanweny.com/swywl/Salmon-macOS-x64-1.2.25.dmg",
  "x64Sha256": "<X64_DMG_SHA256>"
}
```

The client selects `arm64Url`/`arm64Sha256` on Apple Silicon and
`x64Url`/`x64Sha256` on Intel Macs. Calculate each SHA256 from its own final
uploaded DMG; the two packages have different hashes. Keep the same
`versionCode` and `versionName` for both architecture builds.
Set `versionCode` to the build number in `pubspec.yaml` for each release. After
the release artifacts are built and uploaded, publish that same build number in
the platform's update configuration. The in-app updater trusts the GitCode
primary configuration only; it intentionally does not fall back to a mirrored
update manifest that could advertise an unpublished version.

Clients must first install a build containing this feature. Later URL changes
only require editing the remote configuration, not repackaging the app.
