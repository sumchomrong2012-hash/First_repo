# OUK KHMER Chess — improved online room connection

This package preserves the existing chess interface and game code while improving Host Room / Join Room handling:
- checks that PeerJS loaded before starting
- creates a longer room code
- closes old peers before a new attempt
- validates and normalizes pasted room codes
- reports specific PeerJS error types instead of a generic message
- waits for the host connection and gives a useful timeout status
- uses PeerJS signaling + WebRTC; Supabase is not required for room join

## Files
- `www/index.html` — application
- `www/online-config.js` — optional unused Supabase placeholder for this room workflow
- `GITHUB_PAGES_DEPLOY.md` — deployment steps

## Important limitation
PeerJS uses a public signaling service and WebRTC for direct peer connections. A successful signaling WebSocket (`101`) does not guarantee the direct connection will succeed on every network. The updated app should now show a more specific error if it fails.
