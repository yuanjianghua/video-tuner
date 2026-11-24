`engine_release.json` is a **verified snapshot of a real GitHub API reply**, captured on
2026-11-24 from:

```
GET https://api.github.com/repos/Comfy-Org/ComfyUI/releases/latest
```

It is used **only** when the live API is unreachable (DNS failures happen intermittently on
this machine). A successful live call always overwrites `runtime/engine_release.json` with
fresh data. Nothing in this file is hand-written or guessed: tag, file name, size and URL all
came from the API response.

Refresh with:

```powershell
$r = Invoke-RestMethod 'https://api.github.com/repos/Comfy-Org/ComfyUI/releases/latest'
$r | ConvertTo-Json -Depth 6 -Compress | Set-Content data\engine_release.json -Encoding ASCII
```
