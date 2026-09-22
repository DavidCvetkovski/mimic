# Mimic encrypted accounts

Mimic uses Clerk for email sign-up, sign-in, verification and account-access
recovery. Each verified session resolves to a server-selected private Blob
namespace. Clients never select a user ID or storage prefix.

## User flow

1. Sign in at https://mimic.davidcvetkovski.com and create your encrypted library.
2. Generate and save the recovery file before confirming library creation.
3. Unlock the library with the recovery key on another browser.
4. In Connected devices, name an iPhone or Mac and create its pairing code.
   Paste it into the native app's Settings → Encrypted voice sync.
5. Disconnect a device from the website to block future sync. Previously
   downloaded copies remain on that device.

The browser keeps encryption keys in memory. Native apps store pairing codes
in Keychain and can export a recovery file. Email-account recovery does not
recover encryption keys: use a saved recovery file or a paired device. Without
either, existing ciphertext cannot be decrypted. Device pairing codes contain
the encryption key and must be shared privately; they are not public invites.
They remain valid until the corresponding connection is revoked.

## Compatibility

The original owner's 64-character pairing key still accesses the original
private namespace through the existing `SYNC_AUTH_SHA256` configuration.
New accounts use separate namespaces. No existing cloud files are moved or
re-encrypted automatically. To move to a new account, create it, pair the app
containing your local voices, and sync. The new device journal starts separately
so the local voices are uploaded to the new account.

Speech generation stays local. This website does not run the speech model.
The local web studio shares the Mac engine's voices; `.mimicvoice` files can
also be imported/exported through the vault. Those exported files are plaintext
and include reference recordings.

## Deploy

Deploy this directory as the Vercel project root. Run `npm ci`, `npm test`, and
`npm run build` first. The build copies studio assets from the parent when
available and uses the checked-in copies when deployed independently.

Production environment variables:

- `BLOB_READ_WRITE_TOKEN`: a **private** Vercel Blob store.
- `CLERK_SECRET_KEY`: production Clerk backend key.
- `CLERK_PUBLISHABLE_KEY` (or `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY`): matching public key.
- `SYNC_AUTH_SHA256`: keep the existing value to retain original-library access.

Configure the Clerk production domain as `mimic.davidcvetkovski.com`, complete the
provider's DNS setup, enable email verification, and disable any social login
that has not been configured for production. Allowed origins and Clerk script
hosts are explicit in `lib/accounts.js`, `public/cloud.js`, and `vercel.json`.
Update all three when hosting under another domain. The Vercel alias continues
to serve the legacy library, but Clerk production login requires the custom
domain. If Clerk is absent, the website explains that email accounts are not
yet configured and keeps the original library available.

## Security and limits

Encryption remains AES-256-GCM with independently derived HKDF authentication
and encryption keys. The raw recovery key is never sent to the API. Account
metadata contains a one-way verification digest. Native credentials contain an
independent random secret, stored only as a digest on the server; revocation is
checked on every sync request. Browser requests require verified Clerk session
tokens with an allowed `azp`, a subject, and a session ID.

Each account can connect 16 devices and reserve up to 100 snapshots / 256 MiB.
Incomplete uploads count against the limit. Upload reservations are atomic
conditional Blob writes. Upload requests expire after 50 minutes; unfinished
uploads older than one hour can be cleared from Account. This delay allows
in-flight requests to drain before cleanup. Each archive is at most 32 MiB and
uses 512 KiB parts; manifests are published only after all parts exist.

Sync remains additive. Local deletions do not propagate and conflicting names
are installed as separate copies. Completed cloud snapshots do not currently
have a deletion UI. Original-owner access retains its existing storage behavior.
Revocation cannot withdraw plaintext or recovery keys already copied from a
previously authorized device.

Tests cover encryption compatibility, account isolation, invalid origins,
device revocation, quota accounting, incomplete uploads and legacy access.
Provider sign-in and actual-device behavior also require live validation.
