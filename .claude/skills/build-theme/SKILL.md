---
name: build-theme
description: Build a new Deezer Linux theme (custom CSS) by reading the compiled app source, then verify it live via a CDP DevTools attach (source-verification + real screenshots, no X/Wayland screenshot tool needed).
disable-model-invocation: true
---

# Build a Deezer Linux theme

Every color choice is justified from source first (compiled CSS/JS, not guessing), then verified live by attaching Chrome DevTools Protocol (CDP) to the running app and pulling real screenshots + computed styles over the debug socket. This works even with no X server and no screenshot tool installed, because the screenshot comes from the browser process itself, not from capturing a window on screen.

## 1. Create the theme file

```
cp themes/template.css themes/<name>.css
```

`themes/solarized.css`, `themes/nord.css` and `themes/everforest.css` are filled-in references for the same token set.

## 2. Extract the compiled app bundle

This is your primary substitute for DevTools when reasoning about _what token to use_ — the real compiled CSS/JS Deezer ships, not source you'd have to guess at.

```
npx --yes asar extract artifacts/x64/linux-unpacked/resources/app.asar /tmp/deezer-app
```

Compiled CSS: `/tmp/deezer-app/build/assets/cache/css/sass_c/*.css`
Compiled JS: `/tmp/deezer-app/build/assets/cache/js/*.js`

## 3. Grep the CSS for a token, when template.css doesn't already cover it

`themes/template.css` already documents the known token catalog — don't re-derive what's already listed there. Only grep when chasing something new/unlisted, or if a Deezer update may have changed the tokens.

```
grep -o 'body{background-color:var([^)]*)[^}]*}' \
  /tmp/deezer-app/build/assets/cache/css/sass_c/app-web.*.css
```

## 4. Grep the JS for the token behind a specific interactive state (hover/pressed/selected)

This is the highest-value move for finding _which token_ governs a state — it's how real theming bugs get found without ever seeing the UI. Grep the component's JS bundle for its style props directly:

```
grep -o '_active:{[^}]*}' /tmp/deezer-app/build/assets/cache/js/sidebar-logged.*.js
# _active:{backgroundColor:"background.neutral.secondary.pressed",outline:"none"}
```

The dot-path (`background.neutral.secondary.pressed`) maps directly to the CSS variable `--tempo-colors-background-neutral-secondary-pressed`. Once you've picked the color for that state (step 5), confirm it rendered correctly in step 7 rather than trusting the mapping blindly.

## 5. Fill in the theme file, in this priority order

1. Section 1 — shared palette
2. Sections 2 & 3 — light/dark mode
3. Section 4 — Tempo tokens. Do not skip this: it paints most of the chrome and every interactive state. Keep `!important` on every uncommented line — the app's JS sets these at runtime and only `!important` beats that.

## 6. Sanity-check the CSS mechanically

```
python3 -c "
s = open('themes/<name>.css').read()
print('braces', s.count('{'), s.count('}'))
print('parens', s.count('('), s.count(')'))
"
```

Also scan for duplicate `--var-name:` declarations inside the same rule block — a duplicate silently overrides the earlier one and is easy to introduce when generating a lot of lines at once.

Then run prettier so the file matches the formatting of the other themes:

```
npm run prettier -- --write themes/<name>.css
```

## 7. Launch the app with a CDP DevTools attach

The unpacked binary is a Node/Electron hybrid — in this dev environment `ELECTRON_RUN_AS_NODE` is set, which makes it launch as plain Node (you'll see a `node --help`-style usage dump) instead of Electron. Unset it. Also quote `--remote-allow-origins=*` — the shell will otherwise glob-expand the bare `*` against files in the cwd and the flag silently vanishes.

```sh
env -u ELECTRON_RUN_AS_NODE nohup \
  artifacts/x64/linux-unpacked/deezer-desktop \
  --custom-theme=/absolute/path/to/themes/<name>.css \
  --no-sandbox \
  --remote-debugging-port=9222 \
  "--remote-allow-origins=*" \
  > /tmp/deezer.log 2>&1 &
disown
sleep 8
cat /tmp/deezer.log
```

Look for a `[custom-theme] Could not read theme file: ...` line — that means the path is wrong or the CSS failed to load. A clean launch just logs `Init App` and (once the port is up) `DevTools listening on ws://...`.

If copying an `Exec` line from a `.desktop` file, drop any `%U` placeholder first — it's meant to be substituted by the launcher, and left literal it crashes Electron's own bootstrap (`Cannot find module '.../%U'`).

### Get the page's debug socket

```sh
curl -s http://localhost:9222/json | python3 -c \
  "import json,sys; print([x['webSocketDebuggerUrl'] for x in json.load(sys.stdin) if x['type']=='page'])"
```

Use the `page` entry (not the `service_worker` or `worker` ones).

## 8. Verify live over CDP — computed styles, screenshots, and states

`websocket-client` (Python) is enough to drive the whole protocol — no browser-automation framework needed. Three moves cover everything:

**a. Read computed CSS values** (`Runtime.evaluate`) — proves the cascade actually resolved to your colors, not just that the file parsed:

```python
import websocket, json

def eval_js(ws_url, expr):
    ws = websocket.create_connection(ws_url, timeout=10)
    ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate",
                         "params": {"expression": expr, "returnByValue": True}}))
    while True:
        resp = json.loads(ws.recv())
        if resp.get("id") == 1:
            ws.close()
            return resp

eval_js(ws_url, '''JSON.stringify({
  bodyBg: getComputedStyle(document.body).backgroundColor,
  accent: getComputedStyle(document.documentElement)
            .getPropertyValue("--tempo-colors-background-accent-primary-default")
})''')
```

**b. Take a real screenshot** (`Page.captureScreenshot`) — this comes from the renderer itself over the CDP socket, so it works with no X server, no Wayland screenshot tool, and no window manager involvement:

```python
ws.send(json.dumps({"id": 2, "method": "Page.captureScreenshot", "params": {"format": "png"}}))
# resp["result"]["data"] is base64 PNG — decode and write to a file, then view it
```

Do **not** try `import -window ...` / `grim` / `scrot` here — there's no reliable X/Wayland capture path in this environment, and `import` will hang waiting for a window that it can't find. `Page.captureScreenshot` bypasses that entirely.

**c. Toggle light/dark and simulate hover, without touching the OS theme:**

```js
// switch mode
document.documentElement.setAttribute("data-theme", "dark");
document.body.className = document.body.className.replace(
  "chakra-ui-light",
  "chakra-ui-dark"
);
```

```python
# hover a specific point, then screenshot immediately after
ws.send(json.dumps({"id": 3, "method": "Input.dispatchMouseEvent",
                     "params": {"type": "mouseMoved", "x": x, "y": y}}))
```

Read pixel coordinates for `x`/`y` off a screenshot you already took (remember to scale if the image was downsampled for display).

Check, per theme: light mode, dark mode, and at least one hover/pressed/selected state on a real element (sidebar item, button) — confirm both the screenshot _and_ the computed `--tempo-*` value.

### Cleanup

```sh
pkill -f "deezer-desktop.*custom-theme"
```

## 9. Update the README's theme table

If this is a new ready-made theme (not a one-off for a single user), add it to the "Ready-made themes" table in `README.md` next to Solarized/Nord/Everforest, linking to `./themes/<name>.css`. Then run prettier on both files so table alignment and CSS formatting stay consistent with the rest of the repo:

```sh
npm run prettier -- --write README.md themes/<name>.css
```

## 10. Report honestly

Because step 8 gives you real screenshots and real computed values, you can now say the theme is **visually confirmed**, not just source-verified — but say exactly what you checked (which modes, which states, which elements) rather than a blanket "looks great". If you didn't get to a CDP attach for some reason (e.g. the environment truly has no `--remote-debugging-port` support), fall back to the honest source-verified framing instead of claiming visual confirmation you didn't do.

If the human comes back with a specific element that's still wrong, return to step 4 to find the right token, fix it, then go straight back to step 8 to re-verify that exact element — don't re-guess from a screenshot alone.

## Command reference

| Purpose                        | Command                                                                                                                                                                                                         |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Extract the app bundle         | `npx --yes asar extract artifacts/x64/linux-unpacked/resources/app.asar /tmp/deezer-app`                                                                                                                        |
| Find the token behind a state  | `grep -o '_active:{[^}]*}' /tmp/deezer-app/build/assets/cache/js/<component>.*.js`                                                                                                                              |
| Sanity-check generated CSS     | `python3 -c "s=open('theme.css').read(); print(s.count('{'),s.count('}'),s.count('('),s.count(')'))"`                                                                                                           |
| Format the theme/README        | `npm run prettier -- --write themes/<name>.css README.md`                                                                                                                                                       |
| Launch with theme + CDP attach | `env -u ELECTRON_RUN_AS_NODE nohup artifacts/x64/linux-unpacked/deezer-desktop --custom-theme=/path/to/theme.css --no-sandbox --remote-debugging-port=9222 "--remote-allow-origins=*" > /tmp/deezer.log 2>&1 &` |
| Check for load errors          | `cat /tmp/deezer.log` (look for `[custom-theme]` lines)                                                                                                                                                         |
| List debuggable pages          | `curl -s http://localhost:9222/json`                                                                                                                                                                            |
| Kill the themed instance       | `pkill -f "deezer-desktop.*custom-theme"`                                                                                                                                                                       |
