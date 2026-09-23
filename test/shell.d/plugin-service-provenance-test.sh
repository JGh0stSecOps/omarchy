#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const vm = require('vm')
const source = fs.readFileSync(path.join(root, 'shell/shell.qml'), 'utf8')
const auth = {}
vm.createContext(auth)
vm.runInContext(fs.readFileSync(path.join(root, 'shell/services/AuthServiceStore.js'), 'utf8'), auth)

const created = []
const pending = []
let delayedUrl = ''
const trustedApi = { trusted: true }
const scopedApi = { trusted: false }
const host = {
  console,
  AuthServiceStore: auth,
  _services: {},
  _serviceProvenance: {},
  serviceHost: {},
  omarchyPath: '/checkout',
  Component: { Ready: 1, Loading: 2, PreferSynchronous: 0 },
  pluginRegistry: {
    installedPlugins: {},
    isEnabled() { return true },
    entryPointUrl(manifest) { return manifest.__sourceDir + '/' + manifest.entryPoints.service }
  },
  pluginShellFor(manifest) { return manifest.__isFirstParty ? trustedApi : scopedApi },
  _pluginRegistryApis: {},
  _pluginRegistryApiSources: {},
  _pluginShellApis: {},
  _pluginShellApiDescriptors: {},
  _pluginBarWidgetRegistryApis: {},
  _pluginAppLibraryApis: {},
  _pluginBarStateApis: {},
  _pluginFirstPartyServiceApis: {},
  _pluginBarEntryShellApis: {},
  pluginShellApiComponent: { createObject(_parent, properties) {
    return { ...properties, destroyed: false, destroy() { this.destroyed = true } }
  } },
  pluginBarStateFor() { return {} },
  publicBarConfig() { return {} },
  publicIdleConfigFor() { return {} },
  manifestHasKind(value, kind) { return value.kinds.includes(kind) },
  pluginHasBarCapabilities(value) { return !!value && value.kinds.includes('bar') },
  pluginServiceFor(_owner, requestedId) { return host._services[requestedId] || null },
  pluginBarWidgetRegistryFor() { return {} },
  pluginRegistryFor() { return {} },
  Qt: {
    createComponent(url) {
      const component = {
        status: url === delayedUrl ? 2 : 1,
        statusChanged: { connect(callback) { pending.push(() => { component.status = 1; callback() }) } },
        createObject(parent) {
          const service = {
            url, parent, manifest: null, destroyed: false, everTrusted: false,
            destroy() { this.destroyed = true }
          }
          Object.defineProperty(service, 'shell', {
            set(value) { this.everTrusted ||= value.trusted },
            get() { return null }
          })
          created.push(service)
          return service
        }
      }
      return component
    }
  }
}
host.shell = host
vm.createContext(host)
for (const name of ['publicPluginManifest', 'pluginShellCapabilityProfile', 'cacheWithoutKey', 'cacheWithoutPrefix', 'revokePluginShellApi', 'createScopedPluginShell', 'pluginApiActive', 'prunePluginApis', 'syncPluginApis', 'isAuthenticationService', 'serviceProvenance', 'ensureService', '_syncServices', 'serviceKeepLoaded', 'unloadPluginServices']) {
  const match = source.match(new RegExp('  function ' + name + '\\([^]*?\\n  \\}'))
  assert(!!match, `host defines ${name}`)
  vm.runInContext(match[0], host)
}

function manifest(id, sourceDir, trusted, entryPoint = 'Service.qml', authentication = false) {
  return {
    id, __sourceDir: sourceDir, __isFirstParty: trusted,
    __hostCapabilities: authentication ? ['authentication'] : [],
    kinds: ['service'], entryPoints: { service: entryPoint }, keepLoaded: true
  }
}
function select(value) {
  host.pluginRegistry.installedPlugins[value.id] = value
  host._syncServices()
  return host._services[value.id]
}

const id = 'omacom.demo'
const personalManifest = manifest(id, '/home/plugins/demo', false)
const home = select(personalManifest)
const oldApi = host.createScopedPluginShell(personalManifest, id, true, false)
const staleLookup = oldApi._serviceLookup
assert(staleLookup(id) === home, 'personal service can look up its own instance while selected')
home.manifest.__sourceDir = '/data/plugins/demo'
home.manifest.__isFirstParty = true
host.unloadPluginServices()
const facade = { pluginId: id, destroyed: false, destroy() { this.destroyed = true } }
Object.defineProperty(facade, 'manifest', {
  set(value) { if (value) value.__sourceDir = '/home/plugins/demo' }
})
host._pluginRegistryApis[id] = facade
host._pluginRegistryApiSources[id] = '/home/plugins/demo'
const packagedManifest = manifest(id, '/data/plugins/demo', true)
host.pluginRegistry.installedPlugins[id] = packagedManifest
host.syncPluginApis()
host._syncServices()
const packaged = host._services[id]
assert(facade.destroyed && !host._pluginRegistryApis[id],
  'personal registry facade is revoked before trusted replacement is published')
assertEqual(packagedManifest.__sourceDir, '/data/plugins/demo',
  'old facade callback cannot rewrite the trusted replacement source')
assert(packaged !== home && home.destroyed && !home.everTrusted,
  'kept HOME service is replaced before packaged host privileges are assigned')
assert(staleLookup(id) === null,
  'old service callback cannot resolve the trusted replacement after source and trust change')
assertEqual(packaged.url, '/data/plugins/demo/Service.qml', 'replacement loads packaged implementation')
assert(packaged.everTrusted, 'packaged replacement receives trusted host APIs')
host.unloadPluginServices()
assert(select(manifest(id, '/data/plugins/demo', true)) === packaged,
  'unchanged packaged keepLoaded service survives rescan')
const restored = select(manifest(id, '/home/plugins/demo', false))
assert(restored !== packaged && packaged.destroyed && !restored.everTrusted,
  'HOME override replaces the packaged service with an untrusted instance')
const trustOnly = select(manifest(id, '/home/plugins/demo', true))
assert(trustOnly !== restored && restored.destroyed && !restored.everTrusted,
  'trust change recreates a service even when its source URL is unchanged')
const entryPoint = select(manifest(id, '/home/plugins/demo', true, 'Other.qml'))
assert(entryPoint !== trustOnly && trustOnly.destroyed,
  'entrypoint change recreates a kept service within the same source directory')

const plainId = 'acme.transition'
const plainHome = select(manifest(plainId, '/home/plugins/plain', false))
const plainFacade = { pluginId: plainId, destroyed: false, destroy() { this.destroyed = true } }
host._pluginRegistryApis[plainId] = plainFacade
host._pluginRegistryApiSources[plainId] = '/home/plugins/plain'
host.syncPluginApis()
assert(!plainFacade.destroyed, 'unchanged personal registry facade survives rescan')
host.pluginRegistry.installedPlugins[plainId] = manifest(plainId, '/data/plugins/plain', false)
host.syncPluginApis()
host._syncServices()
assert(plainFacade.destroyed && !host._pluginRegistryApis[plainId]
  && host._services[plainId] !== plainHome && plainHome.destroyed,
  'an untrusted source change revokes the old registry facade and service')

const removedId = 'acme.removed'
const spoofedFacade = { pluginId: id, destroyed: false, destroy() { this.destroyed = true } }
host._pluginRegistryApis[removedId] = spoofedFacade
host._pluginRegistryApiSources[removedId] = '/home/plugins/removed'
host.syncPluginApis()
assert(spoofedFacade.destroyed && !host._pluginRegistryApis[removedId],
  'a changed facade pluginId cannot prevent reconciliation of a removed plugin')

for (const builtin of ['omarchy.idle', 'omarchy.lock', 'omarchy.polkit']) {
  const authentication = builtin !== 'omarchy.idle'
  select(manifest(builtin, '/checkout/' + builtin, true, 'Service.qml', authentication))
  const original = created[created.length - 1]
  host.unloadPluginServices()
  select(manifest(builtin, '/checkout/' + builtin, true, 'Service.qml', authentication))
  assert(!original.destroyed && created[created.length - 1] === original,
    `unchanged ${builtin} keepLoaded service survives reload`)
  if (authentication) {
    assert(auth.has(builtin) && !host._services[builtin] && original.parent === null,
      `${builtin} remains outside the public service map and host tree`)
    select(manifest(builtin, '/replacement/' + builtin, true, 'Service.qml', true))
    assert(original.destroyed && auth.has(builtin) && !host._services[builtin],
      `${builtin} provenance change recreates its isolated instance`)
  }
}

const beforeAsync = created.length
const asyncId = 'omacom.async'
delayedUrl = '/old/Service.qml'
select(manifest(asyncId, '/old', false))
assertEqual(pending.length, 1, 'test queues an asynchronous component load')
delayedUrl = '/new/Service.qml'
select(manifest(asyncId, '/new', true))
assertEqual(pending.length, 2, 'replacement remains pending while the old load completes')
pending[0]()
assert(created.length === beforeAsync && !host._services[asyncId],
  'stale asynchronous completion cannot publish the old implementation')
pending[1]()
assert(created.length === beforeAsync + 1 && host._services[asyncId].url === '/new/Service.qml',
  'current asynchronous completion publishes only the selected implementation')

host.pluginRegistry.installedPlugins = {}
host._syncServices()
assertEqual(Object.keys(host._serviceProvenance).length, 0, 'removed services release their provenance records')
JS
