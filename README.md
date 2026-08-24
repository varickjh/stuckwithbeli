# stuckwithfood

stuckwithfood groups meal photos, matches them to nearby restaurants, and helps add them to Beli.

This only runs on a Mac with iPhone Mirroring set up against your own iPhone — there's no hosted or mobile-app version, since the automation drives iPhone Mirroring and Beli directly on your machine.

## Requirements

- A Mac with iPhone Mirroring set up
- Beli installed and signed in on the connected iPhone
- Node.js 22 or newer
- pnpm 10.15.1
- A Google Maps API key with Places API (New) enabled
- One of these options for photo labeling:
  - Codex CLI 0.144.0 or newer, installed and signed in
  - An OpenRouter API key

## Quick setup

1. Clone the repository and run the setup script — it installs Node/pnpm, project dependencies, the Xcode command-line tools, walks you through the API keys above, and opens the two System Settings panes it needs permissions in.

   ```bash
   git clone <repository-url>
   cd auto-beli
   ./setup.sh
   ```

2. Grant the **Accessibility** and **Screen & System Audio Recording** permissions to your terminal app in the System Settings panes the script opens, then restart your terminal app.
3. Run `pnpm dev` and open [http://localhost:3000](http://localhost:3000).

The manual steps below are what `setup.sh` automates — use them if you'd rather do it by hand, or if the script gets stuck on something.

## Manual setup

1. Clone the repository.

   ```bash
   git clone <repository-url>
   cd auto-beli
   ```

2. Install and select the correct Node.js version.

   ```bash
   nvm install
   nvm use
   ```

3. Enable pnpm.

   ```bash
   corepack enable
   corepack prepare pnpm@10.15.1 --activate
   ```

4. Install the project packages.

   ```bash
   pnpm install
   ```

5. Create a `.env.local` file in the project folder.

   ```bash
   touch .env.local
   ```

6. Add your Google Maps API key to `.env.local`.

   ```bash
   GOOGLE_MAPS_PLACES_API_KEY=your_google_maps_api_key
   ```

7. Set up photo labeling.

   - To use Codex CLI:

     ```bash
     codex --version
     codex login
     ```

   - Or add an OpenRouter API key to `.env.local`:

     ```bash
     OPENROUTER_API_KEY=your_openrouter_api_key
     ```

   - You can configure both. OpenRouter is used as a fallback if Codex fails.

8. Install the Xcode command-line tools for the Beli automation.

   ```bash
   xcode-select --install
   ```

9. Give the terminal app that runs stuckwithfood these macOS permissions:

   - Open **System Settings → Privacy & Security**.
   - Enable **Accessibility**.
   - Enable **Screen & System Audio Recording**.
   - Restart the terminal app after changing the permissions.

## Run the project

1. Start the development server.

   ```bash
   pnpm dev
   ```

2. Open [http://localhost:3000](http://localhost:3000).

3. Stop the server when you are done.

   ```text
   Control+C
   ```

## Run a production build

1. Build the project.

   ```bash
   pnpm build
   ```

2. Start the production server.

   ```bash
   pnpm start
   ```

3. Open [http://localhost:3000](http://localhost:3000).

## Logs

- Each labeling run creates a folder inside `logs/`.
- Logs include Places results, the selected labeling provider, model results, and errors.
- Photo data is not written to the logs.
