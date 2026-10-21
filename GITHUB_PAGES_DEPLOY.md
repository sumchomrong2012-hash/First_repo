# Deploy OUK KHMER Chess Online Connection

1. Unzip this package.
2. Upload `www/index.html` to the root of your GitHub Pages repository as `index.html` (or upload the contents of `www/` into the folder your Pages site serves).
3. Commit and push the change.
4. Open the site on both devices and hard-refresh with Ctrl+F5.
5. On device A choose Online > Host Room and wait until it says `Hosting — Code: ...`. Keep that tab open.
6. On device B choose Online > Join Room and enter the complete code exactly.

This room feature uses PeerJS signaling and WebRTC directly. Supabase Realtime is not required for Host/Join Room in this build. Both devices need internet access. Some restrictive networks may block direct WebRTC connections. The UI now reports clearer PeerJS errors in the status line and console.
