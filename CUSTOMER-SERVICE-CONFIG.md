# Customer Service Configuration

Add `customerService` beside `urls` and `updates` in the existing GitCode
`config.json`. Keep your existing `updates` and `releaseNotes` fields unchanged.

```json
{
  "urls": [
    "https://ap.swywl.com",
    "https://mt1.swywl.com"
  ],
  "customerService": {
    "url": "https://chat.swywl.com/widget?website_token=8SpSTtNMSfp64U8wevUS7wZ7#/"
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

Clients must first install a build containing this feature. Later URL changes
only require editing the remote configuration, not repackaging the app.
