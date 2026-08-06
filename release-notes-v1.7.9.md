# v1.7.9

## What's Changed

- Added a real interactive launcher in `tools/menu.sh` that switches behavior depending on whether the application is already installed.
- The menu now offers install options when the app is not present, and update/reinstall/uninstall options when it is present.
- Added uninstall subflows, including a "keep config" path that preserves `.env`, the registry database, and backups.
- Replaced the Pillow-based icon conversion in `install.sh` with a dependency-free SVG icon generation path.

## Notes

- This release focuses on install, update, reinstall, and uninstall workflow clarity.
- The desktop launcher now points to the new interactive menu.