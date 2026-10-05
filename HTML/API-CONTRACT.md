# Shine with mine account service contract

The local PowerShell service in `server.ps1` implements these same-origin `/api/v1` endpoints and stores accounts, inventory, movements, and audit events in `data/shine-with-mine.db`. Do not put passwords, admin roles, or authorization decisions in browser code.

## Session and request security

- Use HTTPS in production and a server-side session store. Set the session cookie `HttpOnly`, `Secure`, and `SameSite=Lax` or stricter. Never store access tokens or passwords in `localStorage`.
- The local service hashes passwords with PBKDF2-HMAC-SHA256, a random 16-byte salt, and 310,000 iterations. It enforces a 12-character registration minimum.
- The local service applies an in-memory login rate limit and generic invalid-credential errors. CSRF validation is required for state-changing requests; the browser obtains a token from the CSRF endpoint and sends it in `X-CSRF-Token`.
- Session records currently live in process memory and expire when the local server stops. Production deployment needs a persistent session store, HTTPS, hardened host configuration, and production-grade monitoring.
- Assign `customer` and `pending` on public registration. Ignore/reject any role supplied by the browser. Only an already-authorized admin can approve a customer. Do not allow public registration to create admins.
- Enforce the admin role on every admin endpoint on the server, not just by hiding the admin page. Log approval decisions and stock changes with actor and timestamp.

## Endpoints used by these pages

- `GET /api/v1/auth/csrf` returns `{ "csrfToken": "..." }` and sets/uses the server session.
- `POST /api/v1/auth/register` accepts `{ "fullName": "...", "email": "...", "password": "..." }`. Return `202` after creating a pending customer request. Do not create an authenticated session yet.
- `POST /api/v1/auth/login` accepts `{ "identifier": "username or email", "password": "...", "rememberMe": false }`. Return `200` and `{ "user": { "role": "admin" | "customer", "status": "approved" } }` only for an approved account. Return the same generic `401` response for wrong username and wrong password; use `403` with `{ "error": "account_pending" }` for pending accounts. The server may use `rememberMe` to choose a longer bounded session expiry; it must not create a persistent bearer token in browser storage.
- `GET /api/v1/auth/session` returns `{ "user": null }` or the authenticated user. The server must expire and rotate sessions appropriately.
- `POST /api/v1/auth/logout` invalidates the server-side session.
- `GET /api/v1/admin/dashboard` returns pending `accountApprovals`, pending `movementApprovals`, and `inventorySummary` with the item count and stock list. Require an authenticated admin session.
- `POST /api/v1/admin/inventory/items` accepts `{ "itemName": "...", "quantity": 0 }` and adds or updates stock. Require an authenticated admin session and record the change in the audit log.
- `POST /api/v1/admin/accounts/:id/decision` accepts `{ "decision": "approve" | "reject" }`. Only an admin may approve/reject; approval grants customer access only.
- `POST /api/v1/admin/movements/:id/decision` accepts `{ "decision": "approve" | "reject" }`. Require an admin session, validate the stock change, and record an audit entry.
- `GET /api/v1/inventory` lists stock items to an approved customer or admin.
- `GET /api/v1/inventory/movements/mine` lists movement requests for the authenticated user.
- `POST /api/v1/inventory/movements` accepts `{ "itemName": "...", "direction": "in" | "out", "quantity": 1, "reason": "..." }`. Only an approved customer or admin can submit; it creates a pending request without changing stock.

The supplied `admin` / `123@1` pair is not embedded in this project. It is too weak for an internet-facing admin account. Provision the owner account privately on the server with a unique password and keep the password out of source control and client files.
