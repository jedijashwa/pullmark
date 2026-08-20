# Rendering GitHub attachment images

Closes the investigation in #86: images attached to GitHub comments and
docs (`github.com/user-attachments/assets/<uuid>` and the older
`github.com/<owner>/<repo>/assets/<user-id>/<uuid>` form) render as
broken images in PullMark whenever the content is private, because the
URLs are gated behind GitHub's own auth and the WKWebView's ephemeral
session carries none.

## Motivation

Pasted screenshots in PR bodies, review comments, and issue comments are
almost always attachment URLs — the PR cockpit and review discussion
meet them constantly. Browsed remote Markdown and local files reference
them too. Today a private attachment is a silent broken-image glyph.

## Investigated behavior (2026-08-20, all verified live)

| Fetch | Public attachment | Private attachment |
|---|---|---|
| Raw URL, anonymous | 302 → presigned S3 → 200 | 404 |
| Raw URL, `Authorization: Bearer <PAT>` | 302 → S3 → 200 | 302 → S3 → 200 |
| API `body_html` / GraphQL `bodyHTML` | signed URL (5-min JWT) | signed URL (5-min JWT) |

- The raw attachment URL **honors token auth** — contrary to the
  issue's belief. That collapses the design: no `body_html`
  harvesting, no JWT-expiry bookkeeping.
- The presigned S3 URL is the complete credential (fetches anonymously
  even for private attachments) but expires in ~5 minutes — another
  reason to cache bytes, never URLs.
- **Trap (verified):** S3 returns 400 if the request carries both the
  presigned signature and an `Authorization` header. URLSession copies
  headers across redirects by default, so the header must be dropped
  when a redirect leaves github.com. curl strips it automatically,
  which hides the trap from naive testing.
- **Trap (verified):** the presigned URL is signed for GET; HEAD gets
  403.
- Legacy `<owner>/<repo>/assets/…` URLs use the same redirect
  machinery, including a 301 hop through repo renames before leaving
  github.com.

## Design

One mechanism covers PR pages, remote docs, and local files: rewrite
attachment image URLs to an app scheme at render time and serve them
through a scheme handler that fetches with the user's token.

### app.js rewrite

A `rewriteAttachmentImages(root)` pass, gated on a new
`githubAttachments` payload flag, maps `<img src>` values matching
either attachment form onto the new scheme:

    https://github.com/user-attachments/assets/<uuid>
    https://github.com/<owner>/<repo>/assets/<digits>/<uuid>
      → pullmark-attachment:///<path under github.com>

Only images. Plain links to attachments stay untouched — they open in
the browser, which has the session. The flag is stamped centrally in
`HTMLBuilder.page(payload:)` for every non-preview page, like width and
line numbers; Quick Look has its own renderer and is unaffected.

### AttachmentSchemeHandler

A third scheme handler beside the local and remote ones, registered on
every MarkdownWebView. It validates the path against the two allowed
forms exactly (the scheme must not become a general github.com proxy
riding the user's token), then asks GitHubClient for the bytes and
serves them with the response's content type.

Cache: bounded in-memory `NSCache` keyed by the attachment path,
shared across web views. Bytes only — nothing touches disk, matching
the privacy posture, and JWT/S3 expiry never matters after the first
fetch. No negative caching: a failed image costs one request per
render.

### GitHubClient.attachmentData

- Demo-mode guard like every other network call.
- One GET of `https://github.com/<path>` with `Authorization: Bearer`
  when a token is on hand, anonymous otherwise (public attachments
  work without any connection).
- A redirect delegate that keeps the header while redirects stay on
  github.com and strips it the moment the chain leaves (the S3 400
  trap). Auto-following continues either way.

### Honest failure (issue lead 5)

When a `pullmark-attachment:` image errors (no token for private
content, deleted attachment, offline, demo mode), app.js replaces the
broken glyph with a labeled placeholder: alt text when the author
wrote any, a "Couldn't load this image from GitHub" line, and an
"Open on GitHub" link carrying the original URL — the browser session
can render what the app cannot. Styled in app.css for all themes.

### Interactions

- **HTML export**: `inliningImages` learns the new scheme and embeds
  cached bytes like remote images; a `restoringAttachmentURLs` pass
  afterwards rewrites any still-unfetched `pullmark-attachment:` src
  back to its original `https://github.com/…` URL so exports never
  contain dead app-scheme references.
- **Lightbox / save image** (`WebViewProxy.originalImageBytes`): serves
  from the attachment cache like the remote case.
- **CSP**: `pullmark-attachment:` joins `img-src`.
- **Demo mode**: the client guard throws, the placeholder renders; the
  demo fixtures reference no attachments.
- **Link-status pill, remote link policy**: untouched — attachment
  rewriting applies to images only.

## Out of scope

- Video attachments (GitHub renders bare attachment URLs as `<video>`;
  PullMark renders them as links today — separate feature if ever).
- Cookie import from browsers, persistent caching of fetched assets
  (issue non-goals).
- Quick Look (own renderer, no GitHub client in the extension).

## Open questions

- Fine-grained PATs were not separately tested (the verified token was
  classic). The mechanism is the same Authorization header the rest of
  the app lives on, so a token that can read the PR can read its
  attachments; if a scoped token ever can't, the placeholder is the
  graceful floor.

## Test fixtures

`jedijashwa/pullmark-livetest` (private) carries the durable fixtures:
an attachment comment on issue #6 and `ATTACH_TEST.md` referencing the
same private attachment.
