# Read one complete state file while the fixture atomically replaces it. Windows
# readers must allow deletion/rename; default ReadAllText sharing can race Replace.
function Read-WindowsFixtureState([string]$Path) {
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
            try {
                $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
                try { $json = $reader.ReadToEnd() } finally { $reader.Dispose() }
            } finally { $stream.Dispose() }
            return $json | ConvertFrom-Json
        } catch {
            if ($attempt -eq 19) { throw }
            Start-Sleep -Milliseconds 10
        }
    }
}
