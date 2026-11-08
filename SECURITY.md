# Security policy

## Reporting a vulnerability

Please don't open a public issue for a security problem. Report it privately through GitHub
instead: on the repository's **Security** tab, choose **Report a vulnerability**. You'll get a reply
within a week. Once a fix is out, the report is published as an advisory, with credit to you
if you'd like it.

Useful things to include: the platform and OS version, the plugin version, what an attacker could
do, and the steps or code that show it.

## Supported versions

Until 1.0, only the latest `0.x` release gets security fixes.

## Scope

The plugin moves files between the app's storage and URLs the app hands it. Problems in scope
include: reading or writing files outside what the app asked for, sending headers or credentials
somewhere the app didn't send them, and keeping secrets on the device longer than documented.
Bugs in the servers you upload to, or in how your app creates presigned URLs, are out of scope.
