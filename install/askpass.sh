#!/bin/bash
# SSH_ASKPASS helper for the setup window: hands ssh the password it was given for this one
# login, through the environment of that ssh process only. Never stored or logged.
printf '%s\n' "${TB_PASSWORD:-}"
