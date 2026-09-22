import QtQuick
import Quickshell
import "services"

ShellRoot {
  id: root

  function writeResult() {
    var plugins = {}
    var untrustedCapabilities = []
    for (var id in registry.installedPlugins) {
      var manifest = registry.installedPlugins[id]
      plugins[id] = { sourceDir: manifest.__sourceDir, firstParty: manifest.__isFirstParty }
      if (!manifest.__isFirstParty)
        untrustedCapabilities = untrustedCapabilities.concat(manifest.__hostCapabilities)
    }
    var payload = JSON.stringify({
      plugins: plugins,
      untrustedCapabilities: untrustedCapabilities,
      trustedCapabilities: registry.installedPlugins["omarchy.test-auth"].__hostCapabilities
    })
    Quickshell.execDetached(["bash", "-c", "printf '%s' \"$1\" > \"$2\"", "plugin-discovery", payload, Quickshell.env("OMARCHY_QML_TEST_RESULT")])
  }

  PluginRegistry {
    id: registry
    firstPartyDir: Quickshell.env("OMARCHY_PATH") + "/shell/plugins"
    onScanFinished: root.writeResult()
  }
}
