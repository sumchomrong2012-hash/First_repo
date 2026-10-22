# អុកចត្រង្គ Khmer Chess — Online (GitHub Pages + Supabase)

Files (upload all of them to the **same folder** of your GitHub repo):

| File | What it is |
|---|---|
| `index.html` | The game (your v19 game + online mode) |
| `online.js` | Online layer: sign-in, lobby, rooms, live moves, chat |
| `config.js` | **Your Supabase URL + key — the only file you edit** |
| `schema.sql` | Database (run once in Supabase) |

## 1. Supabase (≈5 minutes)
1. supabase.com → **New project** (any region near your players, e.g. Singapore).
2. **SQL Editor → New query** → paste all of `schema.sql` → **Run**. (Safe to run again.)
3. **Authentication → Providers → Email**: enabled.
   *For quick testing, turn **Confirm email** OFF* — otherwise each new player must click a link in an email before signing in.
4. **Authentication → URL Configuration**: set **Site URL** to your GitHub Pages address (step 2 below) and add the same address under **Redirect URLs**. (Needed for confirmation / password-reset emails.)
5. **Database → Publications → supabase_realtime**: `rooms`, `moves`, `room_messages` should be listed (the schema adds them; if not, switch them on).
6. **Project Settings → API**: copy **Project URL** and the **anon / publishable key** into `config.js`.
   Never use the `service_role` / secret key.

## 2. GitHub Pages
1. Create a repo, upload the 4 files above (keep them in the repo root).
2. **Settings → Pages → Build from branch → main / (root)** → Save.
3. After a minute the game is live at `https://YOUR-NAME.github.io/REPO-NAME/` (HTTPS, works on iPhone, Android and PC).

## 3. Test
Open the link in two different browsers (or one normal + one private window), create two accounts, create a room in one and join in the other with the 6-letter code (or the public lobby list / invite link).

On phones: Share → **Add to Home Screen** gives a full-screen app icon (iOS and Android).

## How it works
* Accounts: Supabase Auth (email + password). A profile (display name, wins/losses/draws) is created automatically.
* Rooms: `create_room` → 6-letter code, optional public listing, colour, first mover, clock (none–60 min).
* Moves are written by database functions only; both screens receive them live (Realtime). A 5-second safety poll and “resume on wake” cover phones whose screen sleeps.
* Clocks are checked on the **server** from move timestamps.
* Close the browser any time: **Lobby → My games → Open** rebuilds the game from the saved moves.
* Resign, draw offer/accept, in-game chat, counting rule (auto-started, same as before).

## Known limits
* **Chess-rule legality is checked in the players' browsers**, not in the database (the schema says so too). Fine among friends; a modified client could cheat. Upgrade path: validate moves in a Supabase Edge Function.
* Online games use the **standard starting position** (the old P2P "custom setup" negotiation was not carried over — the schema stores moves only). Training and AI modes are unchanged.
* Only the two players can see a room (no spectators).
* Free Supabase projects pause after ~1 week without activity (open the dashboard to resume) and have a cap on simultaneous Realtime connections.
* The old PeerJS (P2P) mode is replaced by this online mode.
