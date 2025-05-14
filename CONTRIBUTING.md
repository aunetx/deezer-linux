# Contributing to Deezer Linux

Thank you for considering contributing to the unofficial Deezer Linux port! This document provides guidelines for contributing to the project.

## Code of Conduct

By participating in this project, you agree to maintain a respectful and inclusive environment for everyone.

## How to Contribute

### Reporting Bugs

- Before creating an issue, please check if it hasn't been reported already
- Use the issue template if available
- Include detailed steps to reproduce the bug
- Specify your system information (OS, architecture, package type)

### Suggesting Enhancements

- Use clear and descriptive titles
- Provide a step-by-step description of the suggested enhancement
- Explain why this enhancement would be useful

### Pull Requests

1. Fork the repository
2. Create a new branch (`git checkout -b feature/your-feature`)
3. Make your changes
4. Build one or more packages
5. Commit your changes (`git commit -m 'feat: Add some feature'`)
6. Push to the branch (`git push origin feature/your-feature`)
7. Open a Pull Request
8. Provide information about the changes made and the packages built and manually tested

### Build Requirements

Ensure you have all required dependencies:

- Node.js (22 recommended)
- npm
- 7z
- make
- wget

## Development Setup

```sh
make install_deps
```

## Patching

### Creating a Patch

To create a patch, clone the repository and run:

```sh
make patch-new
```

Edit the files you want to change in the `app` directory.

> [!TIP]
> You do not need to generate a patch file to test your changes. Open the `app` folder after running `make patch-new` and make your changes. Then run `make build_{target}_{arch}` to try your changes.

When you are done, make sure that the only files you modified are the ones you want to include in the patch. You can check this by running:

```sh
git status
```

Then, generate the patch:

```sh
make patch-gen
```

> [!NOTE]
> This command will take care of pretty printing your patch and creating a patch file.

The patch will be saved in the `patches` directory. Make sure to rename the patch file to something meaningful and follow the naming convention. Add the patch to the echoed list in the `Makefile`.

> [!TIP]
> If possible, you may want to add a switch to allow the users to use the feature you added or not. Do not forget to [mention it](./README.md#usage).

You can now try your patch by building and executing the package:

```sh
make build_{target}_{arch}
```

### Applying a Patch

To manually apply a patch, run:

```sh
apply -p1 -dapp < patches/{name}.patch
```

> [!NOTE]
> Deezer does not provide all the information needed to implement some features.
>
> Deezer provides:
>
> - Player state (playing, paused)
> - Track metadata (title, artist, album, cover URL, duration, and more)
> - Shuffle and repeat state
>
> Deezer does not provide:
>
> - Track position

## Updating

### Updating the Source Executable

_This section is automated via GitHub Actions, but can be done manually._

1. Update the source executable URL:

```sh
curl -Ls -o /dev/null -w %{url_effective} https://www.deezer.com/desktop/download\?platform\=win32\&architecture\=x86
```

2. Update the source executable SHA256:

```sh
curl -Ls https://www.deezer.com/desktop/download\?platform\=win32\&architecture\=x86 | sha256sum
```

### Updating the Electron Version

_This section is not automated via GitHub Actions._

To get the Electron version used, run:

```sh
strings ./source/Deezer.exe | grep '^Chrome/[0-9.]* Electron/[0-9.]*'
```

## Legal Notes

Remember that this is an unofficial port. Any contribution must:

- Respect Deezer's intellectual property
- Not modify core Deezer functionality
- Follow software distribution best practices

## Questions?

Open an issue for any questions not covered by this guide.

Thank you for contributing!
