$ErrorActionPreference = "Stop"
$script:Root = $PSScriptRoot
$script:DataDirectory = Join-Path $PSScriptRoot "data"
$script:DatabasePath = Join-Path $script:DataDirectory "shine-with-mine.db"
$script:SqlitePath = Join-Path $PSScriptRoot "tools\sqlite3.exe"
$script:Sessions = @{}
$script:LoginAttempts = @{}
$script:Iterations = 310000

function New-RandomToken {
	$bytes = New-Object byte[] 32
	$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
	try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
	return [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function Convert-SecureStringToPlainText([Security.SecureString] $SecureValue) {
	$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
	try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
	finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function New-PasswordRecord([string] $Password) {
	$salt = New-Object byte[] 16
	$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
	try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
	$derive = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password, $salt, $script:Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
	try { $hash = $derive.GetBytes(32) } finally { $derive.Dispose() }
	return [pscustomobject]@{ Salt = [Convert]::ToBase64String($salt); Hash = [Convert]::ToBase64String($hash); Iterations = $script:Iterations }
}

function Test-Password([string] $Password, $Record) {
	$salt = [Convert]::FromBase64String($Record.Salt)
	$derive = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password, $salt, [int]$Record.Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
	try { $actual = $derive.GetBytes(32) } finally { $derive.Dispose() }
	$expected = [Convert]::FromBase64String($Record.Hash)
	if ($actual.Length -ne $expected.Length) { return $false }
	$difference = 0
	for ($index = 0; $index -lt $actual.Length; $index++) { $difference = $difference -bor ($actual[$index] -bxor $expected[$index]) }
	return $difference -eq 0
}

function Install-SqliteCli {
	if (Test-Path $script:SqlitePath) { return }
	$toolsDirectory = Split-Path -Parent $script:SqlitePath
	if (!(Test-Path $toolsDirectory)) { New-Item -ItemType Directory -Path $toolsDirectory | Out-Null }
	$architecture = if ([IntPtr]::Size -eq 8) { "x64" } else { "x86" }
	$downloadUrl = "https://sqlite.org/2026/sqlite-tools-win-$architecture-3530400.zip"
	$archivePath = Join-Path $env:TEMP ("sqlite-tools-" + [guid]::NewGuid().ToString("N") + ".zip")
	Write-Host "Downloading the official SQLite $architecture command-line tool…" -ForegroundColor Cyan
	try {
		[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
		Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing
		Add-Type -AssemblyName System.IO.Compression.FileSystem
		$archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
		try {
			$entry = $archive.GetEntry("sqlite3.exe")
			if ($null -eq $entry) { throw "The SQLite tools archive did not contain sqlite3.exe." }
			$inputStream = $entry.Open()
			$outputStream = [IO.File]::Create($script:SqlitePath)
			try { $inputStream.CopyTo($outputStream) }
			finally { $outputStream.Dispose(); $inputStream.Dispose() }
		} finally { $archive.Dispose() }
	} finally {
		if (Test-Path $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
	}
}

function ConvertTo-SqlLiteral($Value) {
	if ($null -eq $Value) { return "NULL" }
	return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Invoke-Sqlite([string] $Sql) {
	$securedSql = "PRAGMA foreign_keys = ON;`n$Sql"
	$output = & $script:SqlitePath -batch -bail $script:DatabasePath $securedSql 2>&1
	if ($LASTEXITCODE -ne 0) { throw "SQLite command failed: $($output -join ' ')" }
	return ($output -join [Environment]::NewLine)
}

function Invoke-SqliteQuery([string] $Sql) {
	$output = & $script:SqlitePath -batch -bail -json $script:DatabasePath $Sql 2>&1
	if ($LASTEXITCODE -ne 0) { throw "SQLite query failed: $($output -join ' ')" }
	$text = ($output -join [Environment]::NewLine).Trim()
	if ([string]::IsNullOrWhiteSpace($text) -or $text -eq "[]") { return }
	return $text | ConvertFrom-Json
}

function Save-Store {
	$statements = New-Object System.Collections.Generic.List[string]
	$statements.Add("BEGIN IMMEDIATE;")
	$statements.Add("DELETE FROM inventory_movements; DELETE FROM audit_log; DELETE FROM inventory_items; DELETE FROM users;")
	$allUsers = @()
	if ($null -ne $script:Store.Admin) { $allUsers += $script:Store.Admin }
	$allUsers += @($script:Store.Users)
	foreach ($user in $allUsers) {
		$username = if ($user.Username) { ConvertTo-SqlLiteral $user.Username } else { "NULL" }
		$statements.Add("INSERT INTO users (id, username, full_name, email, role, status, salt, password_hash, password_iterations, created_at) VALUES ($(ConvertTo-SqlLiteral $user.Id), $username, $(ConvertTo-SqlLiteral $user.FullName), $(ConvertTo-SqlLiteral $user.Email), $(ConvertTo-SqlLiteral $user.Role), $(ConvertTo-SqlLiteral $user.Status), $(ConvertTo-SqlLiteral $user.Salt), $(ConvertTo-SqlLiteral $user.Hash), $([int]$user.Iterations), $(ConvertTo-SqlLiteral $user.CreatedAt));")
	}
	foreach ($item in @($script:Store.Inventory)) {
		$statements.Add("INSERT INTO inventory_items (id, item_name, quantity, updated_at) VALUES ($(ConvertTo-SqlLiteral $item.Id), $(ConvertTo-SqlLiteral $item.ItemName), $([int]$item.Quantity), $(ConvertTo-SqlLiteral $item.UpdatedAt));")
	}
	foreach ($movement in @($script:Store.Movements)) {
		$item = $script:Store.Inventory | Where-Object { $_.Id -eq $movement.ItemId -or $_.ItemName -ieq $movement.ItemName } | Select-Object -First 1
		$itemId = if ($null -ne $item) { $item.Id } else { $movement.ItemId }
		$decidedAt = if ($movement.DecidedAt) { ConvertTo-SqlLiteral $movement.DecidedAt } else { "NULL" }
		$decidedBy = if ($movement.DecidedBy) { ConvertTo-SqlLiteral $movement.DecidedBy } else { "NULL" }
		$statements.Add("INSERT INTO inventory_movements (id, item_id, direction, quantity, requested_by_id, requested_by, reason, status, created_at, decided_at, decided_by) VALUES ($(ConvertTo-SqlLiteral $movement.Id), $(ConvertTo-SqlLiteral $itemId), $(ConvertTo-SqlLiteral $movement.Direction), $([int]$movement.Quantity), $(ConvertTo-SqlLiteral $movement.RequestedById), $(ConvertTo-SqlLiteral $movement.RequestedBy), $(ConvertTo-SqlLiteral $movement.Reason), $(ConvertTo-SqlLiteral $movement.Status), $(ConvertTo-SqlLiteral $movement.CreatedAt), $decidedAt, $decidedBy);")
	}
	foreach ($entry in @($script:Store.Audit)) {
		$statements.Add("INSERT INTO audit_log (id, actor_id, action, details, created_at) VALUES ($(ConvertTo-SqlLiteral $entry.Id), $(ConvertTo-SqlLiteral $entry.ActorId), $(ConvertTo-SqlLiteral $entry.Action), $(ConvertTo-SqlLiteral $entry.Details), $(ConvertTo-SqlLiteral $entry.CreatedAt));")
	}
	$statements.Add("COMMIT;")
	Invoke-Sqlite ($statements -join [Environment]::NewLine) | Out-Null
}

function Initialize-Store {
	if (!(Test-Path $script:DataDirectory)) { New-Item -ItemType Directory -Path $script:DataDirectory | Out-Null }
	Install-SqliteCli
	$schema = @"
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS users (
	 id TEXT PRIMARY KEY,
	 username TEXT COLLATE NOCASE UNIQUE,
	 full_name TEXT NOT NULL,
	 email TEXT COLLATE NOCASE NOT NULL UNIQUE,
	 role TEXT NOT NULL CHECK (role IN ('admin', 'customer')),
	 status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'rejected')),
	 salt TEXT NOT NULL,
	 password_hash TEXT NOT NULL,
	 password_iterations INTEGER NOT NULL,
	 created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS inventory_items (
	 id TEXT PRIMARY KEY,
	 item_name TEXT COLLATE NOCASE NOT NULL UNIQUE,
	 quantity INTEGER NOT NULL CHECK (quantity >= 0),
	 updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS inventory_movements (
	 id TEXT PRIMARY KEY,
	 item_id TEXT NOT NULL REFERENCES inventory_items(id),
	 direction TEXT NOT NULL CHECK (direction IN ('in', 'out')),
	 quantity INTEGER NOT NULL CHECK (quantity > 0),
	 requested_by_id TEXT NOT NULL REFERENCES users(id),
	 requested_by TEXT NOT NULL,
	 reason TEXT NOT NULL DEFAULT '',
	 status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'rejected')),
	 created_at TEXT NOT NULL,
	 decided_at TEXT,
	 decided_by TEXT REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS audit_log (
	 id TEXT PRIMARY KEY,
	 actor_id TEXT NOT NULL REFERENCES users(id),
	 action TEXT NOT NULL,
	 details TEXT NOT NULL,
	 created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_users_status ON users(status, role);
CREATE INDEX IF NOT EXISTS idx_movements_status ON inventory_movements(status);
CREATE INDEX IF NOT EXISTS idx_audit_created_at ON audit_log(created_at);
"@
	Invoke-Sqlite $schema | Out-Null

	$users = @(Invoke-SqliteQuery "SELECT id, username, full_name, email, role, status, salt, password_hash, password_iterations, created_at FROM users;")
	$script:Store = [pscustomobject]@{
		Admin = $null
		Users = @()
		Inventory = @()
		Movements = @()
		Audit = @()
	}
	foreach ($row in $users) {
		$user = [pscustomobject]@{ Id = $row.id; Username = $row.username; FullName = $row.full_name; Email = $row.email; Role = $row.role; Status = $row.status; Salt = $row.salt; Hash = $row.password_hash; Iterations = [int]$row.password_iterations; CreatedAt = $row.created_at }
		if ($user.Role -eq "admin") { $script:Store.Admin = $user } else { $script:Store.Users += $user }
	}
	$script:Store.Inventory = @(Invoke-SqliteQuery "SELECT id, item_name, quantity, updated_at FROM inventory_items;" | ForEach-Object { [pscustomobject]@{ Id = $_.id; ItemName = $_.item_name; Quantity = [int]$_.quantity; UpdatedAt = $_.updated_at } })
	$script:Store.Movements = @(Invoke-SqliteQuery "SELECT m.id, m.item_id, i.item_name, m.direction, m.quantity, m.requested_by_id, m.requested_by, m.reason, m.status, m.created_at, m.decided_at, m.decided_by FROM inventory_movements m JOIN inventory_items i ON i.id = m.item_id;" | ForEach-Object { [pscustomobject]@{ Id = $_.id; ItemId = $_.item_id; ItemName = $_.item_name; Direction = $_.direction; Quantity = [int]$_.quantity; RequestedById = $_.requested_by_id; RequestedBy = $_.requested_by; Reason = $_.reason; Status = $_.status; CreatedAt = $_.created_at; DecidedAt = $_.decided_at; DecidedBy = $_.decided_by } })
	$script:Store.Audit = @(Invoke-SqliteQuery "SELECT id, actor_id, action, details, created_at FROM audit_log;" | ForEach-Object { [pscustomobject]@{ Id = $_.id; ActorId = $_.actor_id; Action = $_.action; Details = $_.details; CreatedAt = $_.created_at } })

	if ($null -eq $script:Store.Admin) {
		Write-Host "First start: create the shop owner's admin password. It will be saved only as a salted PBKDF2 hash." -ForegroundColor Cyan
		$plainPassword = $null
		do {
			$securePassword = Read-Host "Choose a NEW password (12+ characters; do not reuse the password shared in chat)" -AsSecureString
			if ($securePassword.Length -lt 12) { Write-Host "Use at least 12 characters." -ForegroundColor Yellow; continue }
			$plainPassword = Convert-SecureStringToPlainText $securePassword
		} while ($null -eq $plainPassword)
		$record = New-PasswordRecord $plainPassword
		$plainPassword = $null
		$script:Store.Admin = [pscustomobject]@{
			Id = [guid]::NewGuid().ToString("N")
			Username = "admin"
			FullName = "Shop owner"
			Email = "ochiengreagan244@gmail.com"
			Role = "admin"
			Status = "approved"
			Salt = $record.Salt
			Hash = $record.Hash
			Iterations = $record.Iterations
			CreatedAt = [DateTime]::UtcNow.ToString("o")
		}
		Save-Store
		Write-Host "Owner account created. Username: admin. Password is stored as a salted hash." -ForegroundColor Green
	}
}

function Get-RequestSession($Request) {
	$cookie = $Request.Cookies["swm_session"]
	if ($null -eq $cookie -or [string]::IsNullOrWhiteSpace($cookie.Value)) { return $null }
	$sessionId = $cookie.Value
	if (!$script:Sessions.ContainsKey($sessionId)) { return $null }
	$session = $script:Sessions[$sessionId]
	if ($session.Expires -lt [DateTime]::UtcNow) { $script:Sessions.Remove($sessionId); return $null }
	return $session
}

function Set-SessionCookie($Response, [string] $SessionId, [int] $MaxAge = 28800) {
	$Response.AppendHeader("Set-Cookie", "swm_session=$SessionId; Path=/; HttpOnly; SameSite=Strict; Max-Age=$MaxAge")
}

function New-AnonymousSession($Response) {
	$sessionId = New-RandomToken
	$session = @{ UserId = $null; Role = $null; Csrf = New-RandomToken; Expires = [DateTime]::UtcNow.AddMinutes(30) }
	$script:Sessions[$sessionId] = $session
	Set-SessionCookie $Response $sessionId 1800
	return $session
}

function Get-SessionUser($Session) {
	if ($null -eq $Session -or $null -eq $Session.UserId) { return $null }
	if ($script:Store.Admin.Id -eq $Session.UserId) { return $script:Store.Admin }
	return $script:Store.Users | Where-Object { $_.Id -eq $Session.UserId } | Select-Object -First 1
}

function Get-PublicUser($User) {
	if ($null -eq $User) { return $null }
	return @{ id = $User.Id; fullName = $User.FullName; email = $User.Email; role = $User.Role; status = $User.Status }
}

function Send-Json($Response, [int] $Status, $Value) {
	$Response.StatusCode = $Status
	$Response.ContentType = "application/json; charset=utf-8"
	$Response.Headers["Cache-Control"] = "no-store"
	$Response.Headers["X-Content-Type-Options"] = "nosniff"
	$Response.Headers["Content-Security-Policy"] = "default-src 'self'; img-src 'self' https://images.unsplash.com data:; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
	$bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 15 -Compress))
	$Response.ContentLength64 = $bytes.Length
	$Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Read-JsonBody($Request) {
	if ($Request.ContentLength64 -gt 32768) { throw "payload_too_large" }
	$reader = New-Object IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
	try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
	if ([string]::IsNullOrWhiteSpace($raw)) { return [pscustomobject]@{} }
	return $raw | ConvertFrom-Json
}

function Test-Csrf($Request, $Session) {
	if ($null -eq $Session) { return $false }
	$provided = $Request.Headers["X-CSRF-Token"]
	return ![string]::IsNullOrEmpty($provided) -and $provided -ceq $Session.Csrf
}

function Add-AuditEntry([string] $ActorId, [string] $Action, [string] $Details) {
	$entry = [pscustomobject]@{ Id = [guid]::NewGuid().ToString("N"); ActorId = $ActorId; Action = $Action; Details = $Details; CreatedAt = [DateTime]::UtcNow.ToString("o") }
	$script:Store.Audit = @($script:Store.Audit) + $entry
}

function Get-MimeType([string] $Extension) {
	switch ($Extension.ToLowerInvariant()) {
		".html" { return "text/html; charset=utf-8" }
		".css" { return "text/css; charset=utf-8" }
		".js" { return "text/javascript; charset=utf-8" }
		".svg" { return "image/svg+xml" }
		default { return "application/octet-stream" }
	}
}

function Send-StaticFile($Response, [string] $Path) {
	if ([string]::IsNullOrWhiteSpace($Path) -or $Path -eq "/") { $Path = "/index.html" }
	$relativePath = $Path.TrimStart("/").Replace("/", [IO.Path]::DirectorySeparatorChar)
	$fullPath = [IO.Path]::GetFullPath((Join-Path $script:Root $relativePath))
	$rootPath = [IO.Path]::GetFullPath($script:Root) + [IO.Path]::DirectorySeparatorChar
	$publicFiles = @("index.html", "login.html", "admin.html", "account.html", "styles.css", "script.js", "login.js", "admin.js", "account.js")
	if (!$fullPath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase) -or $relativePath -notin $publicFiles) {
		Send-Json $Response 404 @{ error = "not_found" }
		return
	}
	if (!(Test-Path -LiteralPath $fullPath -PathType Leaf)) { Send-Json $Response 404 @{ error = "not_found" }; return }
	$Response.StatusCode = 200
	$Response.ContentType = Get-MimeType ([IO.Path]::GetExtension($fullPath))
	$Response.Headers["Cache-Control"] = "no-store"
	$Response.Headers["X-Content-Type-Options"] = "nosniff"
	$Response.Headers["X-Frame-Options"] = "DENY"
	$Response.Headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
	$Response.Headers["Content-Security-Policy"] = "default-src 'self'; img-src 'self' https://images.unsplash.com data:; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
	$bytes = [IO.File]::ReadAllBytes($fullPath)
	$Response.ContentLength64 = $bytes.Length
	$Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Handle-ApiRequest($Context) {
	$request = $Context.Request
	$response = $Context.Response
	$method = $request.HttpMethod
	$path = [Uri]::UnescapeDataString($request.Url.AbsolutePath)
	$session = Get-RequestSession $request

	if ($method -eq "GET" -and $path -eq "/api/v1/auth/csrf") {
		if ($null -eq $session) { $session = New-AnonymousSession $response }
		Send-Json $response 200 @{ csrfToken = $session.Csrf }
		return
	}
	if ($method -eq "GET" -and $path -eq "/api/v1/auth/session") {
		$user = Get-SessionUser $session
		Send-Json $response 200 @{ user = (Get-PublicUser $user) }
		return
	}
	if ($method -eq "POST") {
		if (!(Test-Csrf $request $session)) { Send-Json $response 403 @{ error = "csrf_failed" }; return }
		try { $body = Read-JsonBody $request } catch { Send-Json $response 400 @{ error = "invalid_request" }; return }
	}

	if ($method -eq "POST" -and $path -eq "/api/v1/auth/login") {
		$remote = $request.RemoteEndPoint.Address.ToString()
		if (!$script:LoginAttempts.ContainsKey($remote) -or $script:LoginAttempts[$remote].Since -lt [DateTime]::UtcNow.AddMinutes(-15)) {
			$script:LoginAttempts[$remote] = @{ Count = 0; Since = [DateTime]::UtcNow }
		}
		$attempt = $script:LoginAttempts[$remote]
		if ($attempt.Count -ge 8) { Send-Json $response 429 @{ error = "try_later" }; return }
		$identifier = ([string]$body.identifier).Trim()
		$account = $null
		if ($null -ne $script:Store.Admin -and ($script:Store.Admin.Username -ieq $identifier -or $script:Store.Admin.Email -ieq $identifier)) { $account = $script:Store.Admin }
		if ($null -eq $account) { $account = $script:Store.Users | Where-Object { $_.Email -ieq $identifier } | Select-Object -First 1 }
		$passwordValid = $false
		if ($null -ne $account) { $passwordValid = Test-Password ([string]$body.password) $account }
		if (!$passwordValid -or $null -eq $account) {
			$attempt.Count++
			Send-Json $response 401 @{ error = "invalid_credentials" }
			return
		}
		if ($account.Status -ne "approved") {
			Send-Json $response 403 @{ error = "account_pending" }
			return
		}
		if ($null -ne $session) {
			$oldCookie = $request.Cookies["swm_session"]
			if ($null -ne $oldCookie) { $script:Sessions.Remove($oldCookie.Value) }
		}
		$newId = New-RandomToken
		$newSession = @{ UserId = $account.Id; Role = $account.Role; Csrf = New-RandomToken; Expires = [DateTime]::UtcNow.AddHours(8) }
		$script:Sessions[$newId] = $newSession
		$maxAge = 28800
		if ($body.rememberMe -eq $true) { $newSession.Expires = [DateTime]::UtcNow.AddDays(7); $maxAge = 604800 }
		Set-SessionCookie $response $newId $maxAge
		$script:LoginAttempts.Remove($remote)
		Send-Json $response 200 @{ user = (Get-PublicUser $account); csrfToken = $newSession.Csrf }
		return
	}
	if ($method -eq "POST" -and $path -eq "/api/v1/auth/register") {
		$fullName = ([string]$body.fullName).Trim()
		$email = ([string]$body.email).Trim()
		$password = [string]$body.password
		if ($fullName.Length -lt 2 -or $email -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$' -or $password.Length -lt 12) { Send-Json $response 400 @{ error = "invalid_registration" }; return }
		if (($null -ne $script:Store.Admin -and $script:Store.Admin.Email -ieq $email) -or (@($script:Store.Users) | Where-Object { $_.Email -ieq $email })) { Send-Json $response 409 @{ error = "account_exists" }; return }
		$record = New-PasswordRecord $password
		$user = [pscustomobject]@{ Id = [guid]::NewGuid().ToString("N"); FullName = $fullName; Email = $email; Role = "customer"; Status = "pending"; Salt = $record.Salt; Hash = $record.Hash; Iterations = $record.Iterations; CreatedAt = [DateTime]::UtcNow.ToString("o") }
		$script:Store.Users = @($script:Store.Users) + $user
		Save-Store
		Send-Json $response 202 @{ status = "pending" }
		return
	}
	if ($method -eq "POST" -and $path -eq "/api/v1/auth/logout") {
		$cookie = $request.Cookies["swm_session"]
		if ($null -ne $cookie) { $script:Sessions.Remove($cookie.Value) }
		$response.AppendHeader("Set-Cookie", "swm_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0")
		Send-Json $response 200 @{ ok = $true }
		return
	}

	$currentUser = Get-SessionUser $session
	if ($method -eq "GET" -and $path -eq "/api/v1/admin/dashboard") {
		if ($null -eq $currentUser -or $currentUser.Role -ne "admin") { Send-Json $response 403 @{ error = "admin_required" }; return }
		$accounts = @($script:Store.Users | Where-Object { $_.Status -eq "pending" } | ForEach-Object { @{ id = $_.Id; fullName = $_.FullName; email = $_.Email; createdAt = $_.CreatedAt } })
		$movements = @($script:Store.Movements | Where-Object { $_.Status -eq "pending" } | ForEach-Object { @{ id = $_.Id; itemName = $_.ItemName; direction = $_.Direction; quantity = $_.Quantity; requestedBy = $_.RequestedBy; reason = $_.Reason; createdAt = $_.CreatedAt } })
		Send-Json $response 200 @{ accountApprovals = $accounts; movementApprovals = $movements; inventorySummary = @{ items = @($script:Store.Inventory).Count; stockItems = @($script:Store.Inventory | ForEach-Object { @{ id = $_.Id; itemName = $_.ItemName; quantity = $_.Quantity; updatedAt = $_.UpdatedAt } }) } }
		return
	}
	if ($method -eq "GET" -and $path -eq "/api/v1/inventory") {
		if ($null -eq $currentUser -or ($currentUser.Role -ne "admin" -and $currentUser.Status -ne "approved")) { Send-Json $response 403 @{ error = "account_not_approved" }; return }
		$items = @($script:Store.Inventory | ForEach-Object { @{ id = $_.Id; itemName = $_.ItemName; quantity = $_.Quantity } })
		Send-Json $response 200 @{ items = $items }
		return
	}
	if ($method -eq "GET" -and $path -eq "/api/v1/inventory/movements/mine") {
		if ($null -eq $currentUser -or ($currentUser.Role -ne "admin" -and $currentUser.Status -ne "approved")) { Send-Json $response 403 @{ error = "account_not_approved" }; return }
		$movements = @($script:Store.Movements | Where-Object { $_.RequestedById -eq $currentUser.Id } | ForEach-Object { @{ id = $_.Id; itemName = $_.ItemName; direction = $_.Direction; quantity = $_.Quantity; reason = $_.Reason; status = $_.Status; createdAt = $_.CreatedAt } })
		Send-Json $response 200 @{ movements = $movements }
		return
	}
	if ($method -eq "POST" -and $path -eq "/api/v1/admin/inventory/items") {
		if ($null -eq $currentUser -or $currentUser.Role -ne "admin") { Send-Json $response 403 @{ error = "admin_required" }; return }
		$itemName = ([string]$body.itemName).Trim()
		$quantity = 0
		if ($itemName.Length -lt 2 -or $itemName.Length -gt 100 -or ![int]::TryParse([string]$body.quantity, [ref]$quantity) -or $quantity -lt 0) { Send-Json $response 400 @{ error = "invalid_item" }; return }
		$item = $script:Store.Inventory | Where-Object { $_.ItemName -ieq $itemName } | Select-Object -First 1
		if ($null -eq $item) {
			$item = [pscustomobject]@{ Id = [guid]::NewGuid().ToString("N"); ItemName = $itemName; Quantity = $quantity; UpdatedAt = [DateTime]::UtcNow.ToString("o") }
			$script:Store.Inventory = @($script:Store.Inventory) + $item
		} else { $item.Quantity = $quantity; $item.UpdatedAt = [DateTime]::UtcNow.ToString("o") }
		Add-AuditEntry $currentUser.Id "inventory_set" "$itemName = $quantity"
		Save-Store
		Send-Json $response 200 @{ item = @{ id = $item.Id; itemName = $item.ItemName; quantity = $item.Quantity; updatedAt = $item.UpdatedAt } }
		return
	}
	if ($method -eq "POST" -and $path -match '^/api/v1/admin/accounts/([^/]+)/decision$') {
		if ($null -eq $currentUser -or $currentUser.Role -ne "admin") { Send-Json $response 403 @{ error = "admin_required" }; return }
		$user = $script:Store.Users | Where-Object { $_.Id -eq $Matches[1] } | Select-Object -First 1
		if ($null -eq $user -or $user.Status -ne "pending" -or $body.decision -notin @("approve", "reject")) { Send-Json $response 404 @{ error = "request_not_found" }; return }
		$user.Status = if ($body.decision -eq "approve") { "approved" } else { "rejected" }
		Add-AuditEntry $currentUser.Id "account_$($body.decision)" $user.Email
		Save-Store
		Send-Json $response 200 @{ status = $user.Status }
		return
	}
	if ($method -eq "POST" -and $path -match '^/api/v1/admin/movements/([^/]+)/decision$') {
		if ($null -eq $currentUser -or $currentUser.Role -ne "admin") { Send-Json $response 403 @{ error = "admin_required" }; return }
		$movement = $script:Store.Movements | Where-Object { $_.Id -eq $Matches[1] } | Select-Object -First 1
		if ($null -eq $movement -or $movement.Status -ne "pending" -or $body.decision -notin @("approve", "reject")) { Send-Json $response 404 @{ error = "request_not_found" }; return }
		if ($body.decision -eq "approve") {
			$item = $script:Store.Inventory | Where-Object { $_.ItemName -ieq $movement.ItemName } | Select-Object -First 1
			if ($null -eq $item) { Send-Json $response 409 @{ error = "inventory_item_missing" }; return }
			$newQuantity = [int]$item.Quantity + [int]$movement.Quantity * $(if ($movement.Direction -eq "in") { 1 } else { -1 })
			if ($newQuantity -lt 0) { Send-Json $response 409 @{ error = "insufficient_stock" }; return }
			$item.Quantity = $newQuantity
			$item.UpdatedAt = [DateTime]::UtcNow.ToString("o")
		}
		$movement.Status = if ($body.decision -eq "approve") { "approved" } else { "rejected" }
		$movement.DecidedAt = [DateTime]::UtcNow.ToString("o")
		$movement.DecidedBy = $currentUser.Id
		Add-AuditEntry $currentUser.Id "movement_$($body.decision)" "$($movement.Direction) $($movement.Quantity) $($movement.ItemName)"
		Save-Store
		Send-Json $response 200 @{ status = $movement.Status }
		return
	}
	if ($method -eq "POST" -and $path -eq "/api/v1/inventory/movements") {
		if ($null -eq $currentUser -or ($currentUser.Role -ne "admin" -and $currentUser.Status -ne "approved")) { Send-Json $response 403 @{ error = "account_not_approved" }; return }
		$itemName = ([string]$body.itemName).Trim()
		$quantity = 0
		if ($itemName.Length -lt 2 -or $itemName.Length -gt 100 -or ([string]$body.reason).Length -gt 500 -or ![int]::TryParse([string]$body.quantity, [ref]$quantity) -or $quantity -lt 1 -or $quantity -gt 10000 -or $body.direction -notin @("in", "out")) { Send-Json $response 400 @{ error = "invalid_movement" }; return }
		$inventoryItem = $script:Store.Inventory | Where-Object { $_.ItemName -ieq $itemName } | Select-Object -First 1
		if ($null -eq $inventoryItem) { Send-Json $response 404 @{ error = "inventory_item_missing" }; return }
		$movement = [pscustomobject]@{ Id = [guid]::NewGuid().ToString("N"); ItemName = $inventoryItem.ItemName; Direction = $body.direction; Quantity = $quantity; RequestedBy = $currentUser.FullName; RequestedById = $currentUser.Id; Reason = ([string]$body.reason).Trim(); Status = "pending"; CreatedAt = [DateTime]::UtcNow.ToString("o") }
		$script:Store.Movements = @($script:Store.Movements) + $movement
		Save-Store
		Send-Json $response 202 @{ status = "pending" }
		return
	}
	Send-Json $response 404 @{ error = "not_found" }
}

Initialize-Store
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:8765/")
try {
	$listener.Start()
} catch {
	Write-Error "Could not start the local shop server on http://127.0.0.1:8765/. The port may already be in use. $($_.Exception.Message)"
	exit 1
}
Write-Host "Shine with mine is running at http://127.0.0.1:8765/" -ForegroundColor Green
Write-Host "Local development only. Do not expose this HTTP server to the internet." -ForegroundColor Yellow

while ($listener.IsListening) {
	$context = $null
	try { $context = $listener.GetContext() } catch [System.Net.HttpListenerException] { break }
	try {
		if ($context.Request.Url.AbsolutePath.StartsWith("/api/")) {
			Handle-ApiRequest $context
		} else {
			Send-StaticFile $context.Response $context.Request.Url.AbsolutePath
		}
	} catch {
		try { Send-Json $context.Response 500 @{ error = "server_error" } } catch { }
		Write-Warning "Request failed: $($_.Exception.GetType().Name)"
	} finally {
		try { $context.Response.Close() } catch { }
	}
}

$listener.Stop()
$listener.Close()