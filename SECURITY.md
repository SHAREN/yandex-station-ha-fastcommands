# Security

## Webhook IDs

Home Assistant webhooks do not use bearer authentication. Treat the webhook ID as a secret, generate a unique non-guessable value for every installation, keep the Blueprint trigger `local_only: true`, and do not commit a real `config.json`.

## Scope

This project intentionally accepts only local `aliced` events whose source is `command`. It does not capture microphone audio and it ignores ordinary `voice` transcripts. Only normalized phrases listed in `allowed_commands` are forwarded to Home Assistant.

## Dangerous actions

Do not route this unauthenticated webhook to safety-critical or destructive actions such as unlocking doors, opening gates, disabling alarms, or changing security controls.

## Reporting

For a security issue, use GitHub's private vulnerability reporting if it is enabled for the repository. Otherwise contact the repository owner privately rather than opening a public issue with exploit details.
