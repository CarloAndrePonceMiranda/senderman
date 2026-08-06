# v1.8.3

## What's Changed

- The installer now supports `--reset-secrets` so `ADMIN_PASS` can be requested again during reinstall.
- The reinstall path in the installer menu now uses the explicit secret refresh mode.
- The updater no longer overwrites its own `tools/update.sh` file while syncing a release.
- The updater now continues with a local changes warning instead of aborting on a dirty tree.

## Notes

- This is a fix release focused on reinstall secret handling and safe update behavior.
- The installer still defaults to the latest published release.