"""Exercise the real portal with inert GTK/WebKit objects; no network or GUI.

TLS outcomes are injected at WebKit's documented signal boundary. These tests
verify application actions, not WebKit's certificate verifier or GTK lifetime
semantics. See docs/network-portal-security.md for backend evidence and gaps.
"""

import ast
import os
from pathlib import Path
import runpy
import sys
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch


SOURCE = Path(sys.argv.pop(1))


class Widget:
  def __init__(self, **kwargs):
    self.text = kwargs.get("label", "")
    self.signals = {}
    self.children = []
    self.destroyed = False

  def __getattr__(self, name):
    # Inert rendering operations (CSS, size, margin, etc.).
    return Mock(name=name)

  def connect(self, signal, callback):
    self.signals[signal] = callback

  def emit(self, signal, *args):
    if signal in self.signals:
      return self.signals[signal](self, *args)
    return False

  def pack_start(self, widget, *_args):
    self.children.append(widget)

  pack_end = pack_start
  add = pack_start

  def get_child(self):
    return self.children[0]

  def set_text(self, text):
    self.text = text

  def destroy(self):
    self.destroyed = True
    self.emit("destroy")


class View(Widget):
  def __init__(self, **kwargs):
    super().__init__()
    self.context = kwargs["web_context"]
    self.settings = Mock()
    self.load_uri = Mock()
    self.reload = Mock()
    self.uri = None

  def get_context(self):
    return self.context

  def get_settings(self):
    return self.settings

  def get_uri(self):
    return self.uri

  def tls_failure(self, uri, flags):
    certificate = object()
    handled = self.emit("load-failed-with-tls-errors", uri, certificate, flags)
    # WebKit FAIL policy: unhandled TLS errors also emit load-failed; either
    # signal's return value only controls notification, not certificate trust.
    if not handled:
      self.emit("load-failed", "started", uri,
                SimpleNamespace(message="TLS certificate validation failed"))
    self.emit("load-changed", "finished")

  def commit(self, uri):
    # The backend has already authorized this response, or it is plain HTTP.
    self.uri = uri
    self.emit("load-changed", "committed")
    self.emit("load-changed", "finished")


class PortalTLS(unittest.TestCase):
  def setUp(self):
    self.gtk = Mock()
    self.buttons = []

    def button(**kwargs):
      widget = Widget(**kwargs)
      self.buttons.append(widget)
      return widget

    self.gtk.Window.side_effect = Widget
    self.gtk.Box.side_effect = Widget
    self.gtk.Label.side_effect = Widget
    self.gtk.Button.side_effect = button
    self.webkit = Mock()
    self.webkit.WebView.side_effect = View
    self.webkit.LoadEvent.COMMITTED = "committed"
    self.context = self.webkit.WebContext.new_ephemeral.return_value
    self.gdk = SimpleNamespace(KEY_Escape=27, KEY_F5=65474, KEY_r=114,
                               ModifierType=SimpleNamespace(CONTROL_MASK=4),
                               Screen=Mock())
    gi = ModuleType("gi")
    gi.require_version = Mock()
    repository = ModuleType("gi.repository")
    for name, value in (("Gtk", self.gtk), ("Gdk", self.gdk),
                        ("WebKit2", self.webkit), ("GLib", Mock()),
                        ("GtkLayerShell", Mock())):
      setattr(repository, name, value)
    gi.repository = repository

    # Neither module startup nor any retained callback may escape the fixture.
    self.run = self.enterContext(patch("subprocess.run", return_value=
      SimpleNamespace(returncode=1, stdout="", stderr="")))
    self.popen = self.enterContext(patch("subprocess.Popen"))
    for name in ("execv", "execvp"):
      self.enterContext(patch("os." + name, side_effect=AssertionError("unexpected exec")))
    self.enterContext(patch.dict(sys.modules, {"gi": gi, "gi.repository": repository}))
    self.enterContext(patch.dict(os.environ, {"OMARCHY_PORTAL_PRELOADED": "1"}))
    self.enterContext(patch.object(sys, "argv", [str(SOURCE)]))
    self.module = runpy.run_path(str(SOURCE), run_name="portal_test")
    self.portal = self.module["Portal"](self.module["DEFAULT_URL"], "Test network", 0)
    self.view = self.portal.view

  def assert_no_bypass(self):
    self.context.allow_tls_certificate_for_host.assert_not_called()
    self.context.set_tls_errors_policy.assert_not_called()
    self.context.get_website_data_manager.return_value.set_tls_errors_policy.assert_not_called()
    self.assertNotIn("pending_certificate", vars(self.portal))
    self.assertNotIn("trust_prompt", vars(self.portal))
    self.assertFalse(hasattr(type(self.portal), "accept_certificate"))
    self.assertEqual([b.text for b in self.buttons], ["×", "Open in browser"])
    self.popen.assert_not_called()

  def test_consecutive_hosts_have_no_acceptance_action(self):
    initial_requests = list(self.view.load_uri.call_args_list)
    for host in ("gateway-a.example", "gateway-b.example", "gateway-a.example"):
      self.view.tls_failure("https://" + host + "/login", 1)
      self.assertIn(host, self.portal.footer.text)
      self.assertIn("TLS certificate validation failed", self.portal.footer.text)
      self.assert_no_bypass()
    self.assertEqual(self.view.load_uri.call_args_list, initial_requests)

  def test_every_tls_error_combination_cannot_trigger_application_bypass(self):
    # UNKNOWN_CA, BAD_IDENTITY, NOT_ACTIVATED, EXPIRED, REVOKED, INSECURE,
    # GENERIC_ERROR, all combinations, and a future flag. A TLS-failure event
    # with incomplete/empty diagnostics must not authorize anything either.
    for flags in [*range(128), 1 << 20]:
      with self.subTest(flags=flags):
        self.view.load_uri.reset_mock()
        self.view.tls_failure("https://invalid.example/login", flags)
        self.assert_no_bypass()
        self.view.load_uri.assert_not_called()
        self.view.reload.assert_not_called()
        self.assertIn("TLS certificate validation failed", self.portal.footer.text)

  def test_repeated_keyboard_actions_only_retry_with_platform_validation(self):
    for key, state in ((65474, 0), (114, 4), (65474, 0)):
      self.view.tls_failure("https://invalid.example/login", 1 | 2 | 8)
      self.view.load_uri.reset_mock()
      self.view.reload.reset_mock()
      self.assertTrue(self.portal.window.emit("key-press-event",
        SimpleNamespace(keyval=key, state=state)))
      self.view.reload.assert_called_once_with()
      self.view.load_uri.assert_not_called()
      self.assert_no_bypass()

  def test_cancellation_and_late_failure_callbacks_cannot_authorize(self):
    callback = self.view.signals["load-failed"]
    self.view.tls_failure("https://gateway-a.example/login", 1)
    self.portal.window.emit("key-press-event", SimpleNamespace(keyval=27, state=0))
    self.buttons[0].emit("clicked")
    self.portal.window.destroy()
    self.assertTrue(self.portal.window.destroyed)
    self.gtk.main_quit.assert_called()
    self.view.load_uri.reset_mock()
    # Directly replay retained callbacks, even after teardown, without relying
    # on GTK disconnecting signals or the main loop having already stopped.
    for uri in ("https://gateway-b.example/", "https://gateway-a.example/"):
      callback(self.view, "started", uri, SimpleNamespace(message="Cancelled"))
      self.view.tls_failure(uri, 2 | 8)
      self.assert_no_bypass()
    self.view.load_uri.assert_not_called()
    self.view.reload.assert_not_called()

  def test_http_discovery_and_valid_https_responses_reach_the_view(self):
    self.view.load_uri.assert_called_once_with(self.module["DEFAULT_URL"])
    self.assertTrue(self.module["DEFAULT_URL"].startswith("http://"))
    self.view.tls_failure("https://invalid.example/login", 1)
    for uri in ("http://gateway.example/login", "https://login.example/signin"):
      self.view.commit(uri)
      self.assertEqual(self.portal.address.text, uri)
      self.assertEqual(self.portal.footer.text, "Esc closes. Private session — nothing is kept.")
      self.assert_no_bypass()
    # Direct HTTPS invocation is preserved, not rewritten to the HTTP probe.
    self.buttons.clear()
    portal = self.module["Portal"]("https://login.example/signin", "Test", 0)
    portal.view.load_uri.assert_called_once_with("https://login.example/signin")

  def test_redirect_tls_failure_never_loads_an_http_fallback(self):
    self.view.commit("http://gateway.example/login")
    for uri in ("https://gateway-a.example/login", "https://gateway-b.example/login"):
      self.view.emit("load-changed", "redirected")
      self.view.tls_failure(uri, 1 | 2)
      self.assertEqual(self.portal.address.text, "http://gateway.example/login")
      self.assert_no_bypass()
    self.view.load_uri.assert_called_once_with(self.module["DEFAULT_URL"])
    self.view.reload.assert_not_called()

  def test_browser_handoff_is_explicit_and_uses_the_fixed_discovery_url(self):
    self.view.tls_failure("https://invalid.example/private", 1)
    self.assert_no_bypass()
    self.buttons[1].emit("clicked")
    self.popen.assert_called_once()
    args, kwargs = self.popen.call_args
    self.assertEqual(args, (["omarchy-launch-browser", "--new-window",
                            self.module["BROWSER_URL"]],))
    self.assertNotIn("OMARCHY_PORTAL_PRELOADED", kwargs["env"])
    self.assertNotIn(self.module["LAYER_SHELL_LIB"], kwargs["env"].get("LD_PRELOAD", ""))
    self.context.allow_tls_certificate_for_host.assert_not_called()

  def test_platform_security_defaults_are_not_weakened(self):
    self.webkit.WebContext.new_ephemeral.assert_called_once_with()
    settings = dict(c.args for c in self.view.settings.set_property.call_args_list)
    self.assertFalse(settings["allow-file-access-from-file-urls"])
    self.assertFalse(settings["allow-universal-access-from-file-urls"])
    for name in ("allow-running-of-insecure-content", "allow-display-of-insecure-content"):
      self.assertFalse(settings.get(name, False), name)
    self.assert_no_bypass()
    tree = ast.parse(SOURCE.read_text())
    # Cover dormant code as well as the exercised callbacks. TLS flag filtering
    # is unsafe: GLib may report only one of several certificate problems.
    forbidden = {"allow_tls_certificate_for_host", "TLSErrorsPolicy",
                 "TlsCertificateFlags", "set_tls_errors_policy"}
    for node in ast.walk(tree):
      if isinstance(node, ast.Attribute):
        self.assertNotIn(node.attr, forbidden)
    self.assertNotIn("load-failed-with-tls-errors", self.view.signals)


if __name__ == "__main__":
  unittest.main(verbosity=2)
