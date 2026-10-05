# Shine with mine

## Run the local site

Open a PowerShell terminal in this folder and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\server.ps1
```

The first run downloads the official SQLite command-line utility into `tools/`, creates `data/shine-with-mine.db`, builds its tables, and prompts you to choose a new admin password. Enter that password directly in the terminal; it is stored in the database only as a salted PBKDF2 hash. The owner username is `admin`. No admin registration is needed.

Open `http://127.0.0.1:8765/` while the PowerShell server is running. Use `/login.html` to sign in, `/account.html` for approved customer inventory requests, and `/admin.html` for the owner workspace. Stop the local server with Ctrl+C.

## Reset the admin password

In a second PowerShell terminal in this folder, run:

```powershell
.\reset-admin-password.ps1
```

Enter the new password twice at the hidden prompts. Passwords are not echoed or saved in source files. The script updates only the `admin` password hash and keeps all other shop data. The username stays `admin`.

This PowerShell server binds to loopback for local development only. Do not expose it directly to the internet.

## SQLite database

You do not need to create tables by hand. The app creates these on first startup:

- `users`: the owner admin and customer accounts, role/status, salted password hash, and account creation time. Raw passwords are never stored.
- `inventory_items`: jewelry item names, current stock count, and last update time.
- `inventory_movements`: customer stock-change requests and their approval status.
- `audit_log`: admin account decisions and inventory changes.

Approved customers can request an inventory movement from their account page. Requests remain pending until the admin approves or rejects them. Only the admin can add inventory or change an account's approval status.

Login sessions are held in server memory and expire when the server stops. The database file is `data/shine-with-mine.db`.

Install/open the DB Browser app you downloaded, choose **Open Database**, and select `data/shine-with-mine.db`. Useful read-only checks in its **Execute SQL** tab:

```sql
SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;
SELECT full_name, email, role, status FROM users;
SELECT item_name, quantity, updated_at FROM inventory_items;
SELECT action, details, created_at FROM audit_log ORDER BY created_at DESC;
```

Never inspect/share password hashes or publish the `.db` file; it contains account information.

Official links:

- [DB Browser for SQLite download](https://sqlitebrowser.org/dl/)
- [SQLite documentation](https://sqlite.org/docs.html)
- [SQLite official downloads](https://sqlite.org/download.html)
