#!/usr/bin/env bash

# Load environment variables from .env.local if it exists
# This file should be sourced by other scripts

if [[ -f .env.local ]]; then
  set -a  # automatically export all variables
  source .env.local
  set +a
fi


