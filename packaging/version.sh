# Sourced by the packaging scripts. MOONSEC_VERSION comes from the release workflow's
# input or the environment; otherwise from `git describe` (v-tags), else 0.0.0+<commit>.
# MOONSEC_LICENSE: the project's own licence is still undecided (open question 6 in the
# Phase 7 plan). Set it here once chosen, as an SPDX expression; every package uses it.
: "${MOONSEC_LICENSE:=LicenseRef-moonsec-undecided}"
if [ -z "${MOONSEC_VERSION:-}" ]; then
  MOONSEC_VERSION="$(git -C "$(dirname "${BASH_SOURCE[0]}")" describe --tags --match 'v[0-9]*' 2>/dev/null | sed 's/^v//')" || true
  [ -n "$MOONSEC_VERSION" ] || MOONSEC_VERSION="0.0.0+$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --short HEAD 2>/dev/null || echo local)"
fi
# Package formats disagree on what a version may hold: rpm forbids '-', Windows wants
# four numbers. Derive both from the one version.
MOONSEC_VERSION_RPM="${MOONSEC_VERSION//-/\~}"
MOONSEC_VERSION_RPM="${MOONSEC_VERSION_RPM//+/^}"
MOONSEC_VERSION_NUM="$(echo "$MOONSEC_VERSION" | sed -E 's/^([0-9]+)\.([0-9]+)\.([0-9]+).*/\1.\2.\3/')"
export MOONSEC_LICENSE MOONSEC_VERSION MOONSEC_VERSION_RPM MOONSEC_VERSION_NUM
