#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command python3

signin="$ROOT/bin/omarchy-network-portal-signin"
panel="$ROOT/shell/plugins/panels/network/Panel.qml"
model="$ROOT/shell/plugins/panels/network/Model.js"

# The sign-in view follows a redirect from a network nobody controls, so the
# thing it is pointed at must never be something that network chose. The panel
# passes the fixed probe endpoint; these two checks are what stop that quietly
# becoming a scraped Location header.
grep -q 'omarchy-network-portal-signin", Model.captivePortalUrl' "$panel" ||
  fail "the network panel opens the sign-in view at the fixed probe URL"
pass "the network panel opens the sign-in view at the fixed probe URL"

model_url=$(sed -n 's/^var captivePortalUrl = "\(.*\)"$/\1/p' "$model")
signin_url=$(sed -n 's/^DEFAULT_URL = "\(.*\)"$/\1/p' "$signin")
[[ -n $model_url && $model_url == "$signin_url" ]] ||
  fail "the sign-in view's default URL tracks Model.js" "Model.js=$model_url signin=$signin_url"
pass "the sign-in view's default URL tracks Model.js"

# A URL reaching this command from anywhere but the panel still cannot be a
# file:, javascript: or data: payload.
for hostile in 'file:///etc/passwd' 'javascript:alert(1)' 'data:text/html,x'; do
  if "$signin" "$hostile" >/dev/null 2>&1; then
    fail "the sign-in view refuses a non-http(s) URL" "$hostile was accepted"
  fi
done
pass "the sign-in view refuses non-http(s) URLs"

grep -qx 'gtk-layer-shell' "$ROOT/install/omarchy-base.packages" ||
  fail "gtk-layer-shell is declared, so the sign-in view is a layer surface and not a window"
pass "gtk-layer-shell is declared"

# The layer-shell library has to beat libwayland-client into the process or its
# init quietly no-ops and the surface comes up as an ordinary tiled window.
grep -q 'LD_PRELOAD' "$signin" ||
  fail "the sign-in view preloads gtk-layer-shell"
pass "the sign-in view preloads gtk-layer-shell"

grep -q 'set_exclusive_zone(self.window, 0)' "$signin" ||
  fail "the sign-in view reserves no space, so opening it moves nothing"
pass "the sign-in view reserves no space"

grep -q 'WebContext.new_ephemeral()' "$signin" ||
  fail "the sign-in view uses an ephemeral session, so the gateway sees no real profile"
pass "the sign-in view uses an ephemeral session"
