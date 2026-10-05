$ErrorActionPreference = "Stop"
$databasePath = Join-Path $PSScriptRoot "data\shine-with-mine.db"
$sqlitePath = Join-Path $PSScriptRoot "tools\sqlite3.exe"
$iterations = 310000

if (!(Test-Path $databasePath)) {
	Write-Host "Shop database not found. Start server.ps1 once first." -ForegroundColor Red
	exit 1
}
if (!(Test-Path $sqlitePath)) {
	Write-Host "SQLite tool not found. Start server.ps1 once first." -ForegroundColor Red
	exit 1
}

Write-Host "ADMIN PASSWORD RESET" -ForegroundColor Cyan
Write-Host "Type only after the numbered prompt appears. Password characters will not be shown." -ForegroundColor Yellow
$first = Read-Host "1/2 New admin password (12+ characters)" -AsSecureString
if ($first.Length -lt 12) {
	Write-Host "Password must be at least 12 characters. No changes were made." -ForegroundColor Red
	exit 1
}
$confirmation = Read-Host "2/2 Type the same password again to confirm" -AsSecureString
$firstPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($first)
$confirmPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmation)
try {
	$password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($firstPointer)
	$confirmedPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($confirmPointer)
} finally {
	[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstPointer)
	[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($confirmPointer)
}
if ($password -cne $confirmedPassword) {
	$password = $null
	$confirmedPassword = $null
	Write-Host "Passwords did not match. No changes were made." -ForegroundColor Red
	exit 1
}
$confirmedPassword = $null

$salt = New-Object byte[] 16
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
$derive = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($password, $salt, $iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
try { $hash = $derive.GetBytes(32) } finally { $derive.Dispose() }
$password = $null
$saltText = [Convert]::ToBase64String($salt)
$hashText = [Convert]::ToBase64String($hash)
$sql = "UPDATE users SET salt='$saltText', password_hash='$hashText', password_iterations=$iterations WHERE username='admin' AND role='admin'; SELECT changes();"
$result = & $sqlitePath -batch -bail -noheader -separator '|' $databasePath $sql 2>&1
if ($LASTEXITCODE -ne 0) {
	Write-Host "Could not update the admin password. SQLite returned an error." -ForegroundColor Red
	exit 1
}
if (($result -join '').Trim() -ne "1") {
	Write-Host "No admin account was updated. No other data was changed." -ForegroundColor Red
	exit 1
}
Write-Host "Admin password updated. Username remains: admin. Other database records were not changed." -ForegroundColor Green
