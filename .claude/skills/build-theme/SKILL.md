---
name: build-theme
description: Build a new Deezer Linux theme (custom CSS) by reading the compiled app source instead of DevTools/screenshots, since neither is available in this environment.
disable-model-invocation: true
---

# Build a Deezer Linux theme

You have no display and no working DevTools attach in this environment (Wayland, no screenshot tool, `--remote-debugging-port` unreliable). Every step below verifies via source, not via eyes. When you report progress, say explicitly that the theme is source-verified, not visually confirmed — never claim a color "looks right."

## 1. Create the theme file

```
cp themes/template.css themes/<name>.css
```

`themes/solarized.css` and `themes/nord.css` are filled-in references for the same token set.

## 2. Extract the compiled app bundle

This is your substitute for DevTools — the real compiled CSS/JS Deezer ships, not source you'd have to guess at.

```
npx --yes asar extract artifacts/x64/linux-unpacked/resources/app.asar /tmp/deezer-app
```

Compiled CSS: `/tmp/deezer-app/build/assets/cache/css/sass_c/*.css`
Compiled JS: `/tmp/deezer-app/build/assets/cache/js/*.js`

## 3. Grep the CSS for a token, when template.css doesn't already cover it

`themes/template.css` already documents the known token catalog — don't re-derive what's already listed there. Only grep when chasing something new/unlisted, or if a Deezer update may have changed the tokens (full method: `CONTRIBUTING.md` → "Creating a New Theme" → "How the token catalog was discovered").

```
grep -o 'body{background-color:var([^)]*)[^}]*}' \
  /tmp/deezer-app/build/assets/cache/css/sass_c/app-web.*.css
```

## 4. Grep the JS for the token behind a specific interactive state (hover/pressed/selected)

This is the highest-value move — it's how real theming bugs get found without ever seeing the UI. Grep the component's JS bundle for its style props directly:

```
grep -o '_active:{[^}]*}' /tmp/deezer-app/build/assets/cache/js/sidebar-logged.*.js
# _active:{backgroundColor:"background.neutral.secondary.pressed",outline:"none"}
```

The dot-path (`background.neutral.secondary.pressed`) maps directly to the CSS variable `--tempo-colors-background-neutral-secondary-pressed`. Trust this over guessing from a screenshot — it's the literal source of truth for that state.

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

## 7. Launch the app to catch load errors

Even with no visual feedback, a launch still surfaces real errors.

```
deezer-desktop --custom-theme=/absolute/path/to/themes/<name>.css --no-sandbox > /tmp/deezer.log 2>&1 &
disown
sleep 5
cat /tmp/deezer.log
```

Look for a `[custom-theme] Could not read theme file: ...` line — that means the path is wrong or the CSS failed to load.

If copying an `Exec` line from a `.desktop` file, drop any `%U` placeholder first — it's meant to be substituted by the launcher, and left literal it crashes Electron's own bootstrap (`Cannot find module '.../%U'`).

## 8. Report honestly and hand off visual verification

Tell the human directly: theme built and mapped from source; not visually confirmed in this environment — they should launch it and check light/dark mode plus hover/pressed/selected states on a few elements before merging. Don't say "done" or "looks great."

If they come back with a specific element that's still wrong, return to step 4 and grep that component's JS directly rather than guessing again.

## Command reference

| Purpose                       | Command                                                                                               |
| ----------------------------- | ----------------------------------------------------------------------------------------------------- |
| Extract the app bundle        | `npx --yes asar extract artifacts/x64/linux-unpacked/resources/app.asar /tmp/deezer-app`              |
| Find the token behind a state | `grep -o '_active:{[^}]*}' /tmp/deezer-app/build/assets/cache/js/<component>.*.js`                    |
| Launch with theme             | `deezer-desktop --custom-theme=/path/to/theme.css --no-sandbox > /tmp/deezer.log 2>&1 &`              |
| Check for load errors         | `cat /tmp/deezer.log` (look for `[custom-theme]` lines)                                               |
| Sanity-check generated CSS    | `python3 -c "s=open('theme.css').read(); print(s.count('{'),s.count('}'),s.count('('),s.count(')'))"` |
