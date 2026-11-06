# Pinned App Stylr source archive

This repository installs App Stylr 1.4.1 from `app-stylr-1.4.1.tgz`.
It is the exact original archive from [https://github.com/kylbutlr/app-stylr/archive/refs/tags/v1.4.1.tar.gz](https://github.com/kylbutlr/app-stylr/archive/refs/tags/v1.4.1.tar.gz), copied without repacking.
The package version, files and npm SHA-512 integrity are unchanged. No sibling
checkout, network request to App Stylr, or new hosting service is required.

`app-stylr-source.json` records the original URL, source commit, SHA-256 and npm
integrity. Existing sourceRevision values describe the original snapshot; they
are not rewritten to claim the bytes came from a later cleanup commit.

For future upgrades, adopt one explicit release, verify the downloaded archive,
replace the versioned tarball, update package.json and package-lock.json together,
and run the existing style/reference checks and application validations.

The archived upstream source includes its original license files.
