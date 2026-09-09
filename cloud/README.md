# Mimic encrypted voice sync

A separate Vercel project serving a private voice vault. It does not run the
speech model. The iPhone, Mac, and local browser studio continue generating
speech on the device running the engine.

## Use

Open Settings in iPhone or Mac and connect with the same 64-character pairing
key. Sync is off until connected. The native apps keep the key in Keychain;
the hosted browser keeps it only in memory until the page closes or is locked.
New voice snapshots sync when the app becomes active or you choose Sync now.

The local web studio shares the Mac engine library. Its Voices page can import
and export `.mimicvoice` files; upload or download them through the hosted vault.
Native Settings also support file import/export. Exported files are plaintext,
including reference audio, and should be shared privately.

Sync is additive: existing names are preserved and conflicts receive a separate
name. Deleting a local voice does not erase cloud snapshots or copies on other
devices. A new device receives the archived versions. Generated speech, drafts,
models, and settings are not synced.

## Hosting

Deploy only this `cloud` directory. Run `npm ci`, `npm test`, and `npm run build`,
then deploy with Vercel. `public/app.css` and `public/icon.svg` are checked-in
fallbacks so builds also work without access to the parent project. The build
copies the latest local studio assets when the parent is present.

Set `BLOB_READ_WRITE_TOKEN` for a **private** Vercel Blob store and
`SYNC_AUTH_SHA256` in production. Generate a random 32-byte pairing key; derive
32 authentication bytes with HKDF-SHA256, salt `mimic.sync.v1`, info
`authentication`, then set the environment variable to the hex SHA256 digest
of those derived bytes. Never put the pairing key in deployment variables,
source control, browser storage, logs, or uploaded assets. Back it up privately;
there is no recovery service for lost encryption keys.

The current installation uses `mimic.lyricstats.dev`, with
`mimic-umber.vercel.app` as its production fallback. If self-hosting elsewhere,
update allowed origins in `api/sync.js` and the native endpoint in
`CloudVault.swift`. Configure only the intended subdomain at the DNS provider.

## Protocol and limits

AES-256-GCM uses independently derived encryption material (HKDF info
`encryption`), a fresh random 12-byte nonce, and AAD `mimic.voice.v1`.
The serialized payload is nonce + ciphertext + 16-byte authentication tag.
Encrypted labels use AAD `mimic.name.v1`. Object IDs are keyed HMACs of canonical
voice fingerprints; names and recordings never appear in storage paths.
The server sees ciphertext sizes and request timing, plus a derived bearer
authentication credential; it cannot decrypt voices with that credential.

Archives are capped at 32 MiB, uploaded in 512 KiB parts under a random upload
ID. A manifest is published only after every part is present. Repeated complete
snapshots are no-ops. Interrupted uploads can leave unreferenced parts; there
is currently no automatic pruning or cloud-delete UI. This is a private
single-owner vault, not a public multi-tenant service.

Tests cover browser/Swift encryption compatibility, tampering, key separation,
archive validation, collisions, playback transport, and local API behavior.
Real-device microphone and pairing checks remain necessary before a release.
