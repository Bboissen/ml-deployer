# Dataset ingestion (M4)

Local files/trees, same-region S3 objects/prefixes and public HTTPS files are
explicit adapters. They hash bounded streams before upload, pin source identity,
recheck the complete source after transfer and seal a versioned immutable manifest
only after native object/version/checksum readback. Local ancestry is opened
without following symlinks. HTTPS requires a declared size and strong ETag;
redirects and connected peers must be public, credential-free TLS endpoints.
Private/signed URLs, cross-region S3 and special files are unsupported.

Multipart transfers use one part at a time (8–64 MiB, at most 10,000 parts;
640 GiB per object). Completed objects carry exact version IDs and SHA256 hashes.
Reuse re-reads those exact versions, including the manifest, rather than trusting
ETags or metadata alone. Transfer scope includes hashing/download and verification
reads as well as upload bytes. A configured maximum_bytes further limits the
selected dataset; the M6 reviewed operation pins the discovered total.

Each upload has a unique operation-owned key and an intent before creation.
The controller records multipart IDs/parts and aborts only its exact incomplete
uploads on errors. Reconciliation can find a lost create response using that
unique key. It never sweeps unrelated bucket uploads or removes retained completed
versions. Interrupted transfers can reuse verified completed manifests; unsealed
parts are aborted and restarted, never advertised as blind multipart resume.
Failed ingestion yields no manifest and must launch no compute.

Offline checks cover >8 MiB multipart data, spaces, empty files/trees, symlinks,
source changes, restricted HTTPS, expired access, checksum corruption, exact
version reuse and interrupted/lost-response cleanup. No dataset was uploaded to
AWS. Native >1 MiB upload, remote adapters and retained bucket reuse need a
separately authorized non-sensitive acceptance run.
