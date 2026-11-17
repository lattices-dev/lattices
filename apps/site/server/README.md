# Email access

This is a shared code gate, with no accounts, OAuth or billing.
Cloudflare KV stores the submitted contact and Cloudflare Email Service sends
a plain-text welcome email through a native Worker binding. The
code is the first eight hex characters of SHA-256(normalized email), a hyphen,
and the first eight characters of `ACCESS_CODE_SECRET`. Only that secret portion
is checked, as requested. Codes are transferable; this does not prove identity.
The rest of the secret signs a 30-day HttpOnly cookie and is never emailed.
Rotating the secret invalidates existing codes and cookies.

Product pages and installation stay public. Overview pages and the first four
sections of each quickstart stay public. Other docs show their introduction.
`src/lib/doc-access.ts` owns this policy. The main site's `/concept` and
`/experiment` study requires the same code; the approved Hyperspace product demo
remains public. Independently hosted Studio deployments are outside this build.

## Build and preview

```sh
bun run build
bun run test:access
bun run preview:access
```

The preview listens at `http://127.0.0.1:5187`. Without the required secret,
code submission fails closed. This static preview does not connect Cloudflare
mail or KV bindings, so the email form reports that delivery is not connected.
Use `wrangler dev` to work with Cloudflare bindings. Tests mock the native email
and KV interfaces; they send no email and store no real contacts.

The browser bundle imports generated **public** excerpts only. Full Markdown,
agent bundles, the study chunk and doc JSON are in `private-dist`. The build
assembles `.worker-assets` after Pagefind indexes the public `dist` directory.
The Worker runs before every asset request, blocks `/__private/*`, and serves
private files only after cookie verification. Private responses use `no-store`.
Do not publish `.worker-assets` or `private-dist` through a static file host.

## Connect delivery

Required runtime settings and bindings in `wrangler.jsonc`:

- `EMAIL`: Cloudflare `send_email` binding, restricted to
  `welcome@lattices.dev` as sender. Recipient addresses must be unrestricted
  for visitor signup, rather than a verified-destination allowlist.
- `EMAIL_FROM`: `welcome@lattices.dev`, a non-secret sender setting.
- `ACCESS_CONTACTS`: private KV namespace. Each key uses the full SHA-256 email
  digest; values contain normalized email, `source: docs-access`, and latest
  request time. These requests do not subscribe anyone to marketing.
- `ACCESS_CODE_SECRET`: random 64-character uppercase hexadecimal secret. Never
  put it in Vite environment variables, source, chat, or generated files.

Use the local `secret` CLI to inject credentials into the preview process;
store production values with the hosting provider's secret mechanism. Configure
the two Cloudflare rate-limit bindings in `wrangler.jsonc`. Their namespace IDs
must be unique within the target account. Missing bindings fail closed.

Onboard `lattices.dev` under **Compute → Email Service → Email Sending** in
Cloudflare. This service requires an active Cloudflare DNS zone and Workers
Paid for arbitrary recipients. Configure the supplied sending DNS records,
including DKIM and the bounce subdomain, and verify the domain before sending.
Incoming email routing is a separate configuration; outbound welcome emails do
not require a recipient verification step for each signup.

## Cloudflare deployment

```sh
bun run deploy:cloudflare
```

This runs the access tests, analytics checks, static build, and protected-asset
audit before deploying the Worker and its assets together. Wrangler is pinned
in the site package. Do not use `wrangler pages deploy`: the Worker must run
before every request, including static assets.

The Worker is `lattices-site` in the configured account. Its deployment URL is
<https://lattices-site.arach.workers.dev>. The access secret is provisioned in
Cloudflare and retained in the local Keychain as
`LATTICES_SITE_ACCESS_CODE_SECRET`. To reuse it in the local preview, inject
that alias with `secret run` and map it inside the child process to
`ACCESS_CODE_SECRET`; do not print it. Do not generate another secret on deploy.

The manual `.github/workflows/pages.yml` workflow now deploys to Cloudflare,
using the repository or `cloudflare` environment's `CLOUDFLARE_API_TOKEN` secret.
That token needs access only to this site's Worker and asset deployment. Local
deployment works independently of GitHub Actions. Repository-secret access
could not be verified with the current GitHub token.

As of November 8, Cloudflare reports the `lattices.dev` zone as active. Google
Public DNS resolves its delegation to `mckenzie.ns.cloudflare.com` and
`piotr.ns.cloudflare.com`; other resolvers still have the former Namecheap
delegation cached. DNS scanning found the four GitHub Pages A records,
five Namecheap forwarding MX records, and the forwarding SPF record. These ten
records were copied into the Cloudflare zone. The four imported apex A
records were then replaced by the Worker Custom Domain. Public DNS shows no
DNSSEC DS record. A scan does not guarantee that every custom subdomain exists
in the imported records.

The user chose Cloudflare's email tools for the cutover. Namecheap's forwarding
MX records remain as an inventory of the previous setup; they do not constitute
working Cloudflare email routing. If incoming aliases are needed, configure
them with a verified destination in Cloudflare Email Routing, then replace the
old MX/SPF records with the routing records. See
[Namecheap forwarding requirements](https://www.namecheap.com/support/knowledgebase/article.aspx/308/2214/how-to-set-up-free-email-forwarding/).
`lattices.dev` and `www.lattices.dev` are attached as Worker Custom Domains in
`wrangler.jsonc`. Requests directed to Cloudflare with the production hostname
and valid TLS reject unauthorized full docs and direct private assets. Global
DNS propagation is still underway. The existing mail records were preserved
during this change.

The user completed Email Sending activation in the dashboard. Cloudflare's DNS
contains the `cf-bounce` MX/SPF, sending DKIM, and DMARC records; Google Public
DNS also resolves the sending DKIM and bounce MX. The deployment credential
still returns HTTP 403 for Email Sending administration, so the sending-domain
status API is not available to this client. No Resend account or credential is
required. No paid plan was activated by the agent. A production check must
verify one real welcome email and the code-to-guide flow with an explicitly
provided test recipient; test mocks do not establish provider or inbox delivery.

The Cloudflare deployment passed live HTTP checks for public previews,
unauthorized full-doc rejection, encoded private-path rejection, secure cookie
unlock, remembered sessions, and authorized full Markdown/JSON. The access
tests and analytics build/integration checks also passed. Those checks did not
send mail, change the registrar, or validate GitHub Actions delivery.

Email binding: [Cloudflare Workers email API](https://developers.cloudflare.com/email-service/api/send-emails/workers-api/).
Domain setup: [Cloudflare sending domains](https://developers.cloudflare.com/email-service/configuration/domains/).
Pricing: [Cloudflare Email Service](https://developers.cloudflare.com/email-service/platform/pricing/).
Asset ordering: [Cloudflare static assets](https://developers.cloudflare.com/workers/static-assets/binding/).
