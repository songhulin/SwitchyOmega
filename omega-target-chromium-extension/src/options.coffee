OcontextMenu_inspectElementmegaTarget = require('omega-target')
OmegaPac = OmegaTarget.OmegaPac
Promise = OmegaTarget.Promise
xhr = Promise.promisify(require('xhr'))
Url = require('url')
querystring = require('querystring')
chromeApiPromisifyAll = require('./chrome_api')
proxySettings = chromeApiPromisifyAll(chrome.proxy.settings)
parseExternalProfile = require('./parse_external_profile')
ProxyAuth = require('./proxy_auth')
WebRequestMonitor = require('./web_request_monitor')
ChromePort = require('./chrome_port')

class ChromeOptions extends OmegaTarget.Options
  _inspect: null
  parseExternalProfile: (details) ->
    parseExternalProfile(details, @_options, @_fixedProfileConfig.bind(this))

  fetchUrl: (dest_url, opt_bypass_cache) ->
    if opt_bypass_cache
      parsed = Url.parse(dest_url, true)
      parsed.search = undefined
      parsed.query['_'] = Date.now()
      dest_url = Url.format(parsed)
    xhr(dest_url).get(1)

  updateProfile: (args...) ->
    super(args...).then (results) ->
      error = false
      for own profileName, result of results
        if result instanceof Error
          error = true
          break
      if error
        # TODO(catus): Find a better way to notify the user.
        ###
        @setBadge(
          text: '!'
          color: '#faa732'
          title: chrome.i18n.getMessage('browserAction_titleDownloadFail')
        )
        ###
      return results

  _proxyNotControllable: null
  proxyNotControllable: -> @_proxyNotControllable
  setProxyNotControllable: (reason, badge) ->
    @_proxyNotControllable = reason
    if reason
      @_state.set({'proxyNotControllable': reason})
      @setBadge(badge)
    else
      @_state.remove(['proxyNotControllable'])
      @clearBadge()

  _badgeTitle: null
  setBadge: (options) ->
    if not options
      options =
        if @_proxyNotControllable
          text: '='
          color: '#da4f49'
        else
          text: '?'
          color: '#49afcd'
    chrome.browserAction.setBadgeText(text: options.text)
    chrome.browserAction.setBadgeBackgroundColor(color: options.color)
    if options.title
      @_badgeTitle = options.title
      chrome.browserAction.setTitle(title: options.title)
    else
      @_badgeTitle = null
  clearBadge: ->
    return if @externalApi.disabled
    if @_badgeTitle
      @currentProfileChanged('clearBadge')
    if @_proxyNotControllable
      @setBadge()
    else
      chrome.browserAction.setBadgeText(text: '')
    return

  _fixedProfileConfig: (profile) ->
    config = {}
    config['mode'] = 'fixed_servers'
    rules = {}
    protocols = ['proxyForHttp', 'proxyForHttps', 'proxyForFtp']
    protocolProxySet = false
    for protocol in protocols when profile[protocol]?
      rules[protocol] = profile[protocol]
      protocolProxySet = true

    if profile.fallbackProxy
      if profile.fallbackProxy.scheme == 'http'
        # Chromium does not allow HTTP proxies in 'fallbackProxy'.
        if not protocolProxySet
          # Use 'singleProxy' if no proxy is configured for other protocols.
          rules['singleProxy'] = profile.fallbackProxy
        else
          # Try to set the proxies of all possible protocols.
          for protocol in protocols
            rules[protocol] ?= JSON.parse(JSON.stringify(profile.fallbackProxy))
      else
        rules['fallbackProxy'] = profile.fallbackProxy
    else if not protocolProxySet
      config['mode'] = 'direct'

    if config['mode'] != 'direct'
      rules['bypassList'] = bypassList = []
      for rule in profile.bypassList
        if rule.pattern == '<local>'
          for host in OmegaPac.Conditions.localHosts
            bypassList.push(host)
        else
          bypassList.push(rule.pattern)
      config['rules'] = rules
    return config

  _proxyChangeWatchers: null
  _proxyChangeListener: null
  watchProxyChange: (callback) ->
    @_proxyChangeWatchers = []
    if not @_proxyChangeListener?
      @_proxyChangeListener = (details) =>
        for watcher in @_proxyChangeWatchers
          watcher(details)
      chrome.proxy.settings.onChange.addListener @_proxyChangeListener
    @_proxyChangeWatchers.push(callback)
  applyProfileProxy: (profile, meta) ->
    meta ?= profile
    if profile.profileType == 'SystemProfile'
      # Clear proxy settings, returning proxy control to Chromium.
      return proxySettings.clearAsync({}).then =>
        chrome.proxy.settings.get {}, @_proxyChangeListener
        return
    config = {}
    if profile.profileType == 'DirectProfile'
      config['mode'] = 'direct'
    else if profile.profileType == 'PacProfile'
      config['mode'] = 'pac_script'
      
      config['pacScript'] =
        if !profile.pacScript || OmegaPac.Profiles.isFileUrl(profile.pacUrl)
          url: profile.pacUrl
          mandatory: true
        else
          data: OmegaPac.PacGenerator.ascii(profile.pacScript)
          mandatory: true
    else if profile.profileType == 'FixedProfile'
      config = @_fixedProfileConfig(profile)
    else
      config['mode'] = 'pac_script'
      config['pacScript'] =
        data: null
        mandatory: true
      setPacScript = @pacForProfile(profile).then (script) ->
        profileName = OmegaPac.PacGenerator.ascii(JSON.stringify(meta.name))
        profileName = profileName.replace(/\*/g, '\\u002a')
        profileName = profileName.replace(/\\/g, '\\u002f')
        prefix = "/*OmegaProfile*#{profileName}*#{meta.revision}*/"
        config['pacScript'].data = prefix + script
        return
    setPacScript ?= Promise.resolve()
    setPacScript.then(=>
      @_proxyAuth ?= new ProxyAuth(this)
      @_proxyAuth.listen()
      @_proxyAuth.setProxies(@_watchingProfiles)
      proxySettings.setAsync({value: config})
    ).then =>
      chrome.proxy.settings.get {}, @_proxyChangeListener
      return

  _quickSwitchInit: false
  _quickSwitchContextMenuCreated: false
  _quickSwitchCanEnable: false
  setQuickSwitch: (quickSwitch, canEnable) ->
    @_quickSwitchCanEnable = canEnable
    if not @_quickSwitchContextMenuCreated
      @_quickSwitchContextMenuCreated = true
      if quickSwitch
        chrome.contextMenus.update('enableQuickSwitch', {checked: true})
      window.OmegaContextMenuQuickSwitchHandler = (info) =>
        changes = {}
        changes['-enableQuickSwitch'] = info.checked
        setOptions = @_setOptions(changes)
        if info.checked and not @_quickSwitchCanEnable
          setOptions.then ->
            chrome.tabs.create(
              url: chrome.extension.getURL('options.html#/ui')
            )

    if quickSwitch
      chrome.browserAction.setPopup({popup: ''})
      if not @_quickSwitchInit
        @_quickSwitchInit = true
        chrome.browserAction.onClicked.addListener (tab) =>
          @clearBadge()
          profiles = @_options['-quickSwitchProfiles']
          index = profiles.indexOf(@_currentProfileName)
          index = (index + 1) % profiles.length
          @applyProfile(profiles[index]).then =>
            if @_options['-refreshOnProfileChange']
              if tab.url and tab.url.indexOf('chrome') != 0
                chrome.tabs.reload(tab.id)
    else
      chrome.browserAction.setPopup({popup: 'popup.html'})
    Promise.resolve()

  setInspect: (settings) ->
    if @_inspect
      if settings.showMenu
        @_inspect.enable()
      else
        @_inspect.disable()
    return Promise.resolve()

  _requestMonitor: null
  _monitorWebRequests: false
  _tabRequestInfoPorts: null
  setMonitorWebRequests: (enabled) ->
    @_monitorWebRequests = enabled
    if enabled and not @_requestMonitor?
      @_tabRequestInfoPorts = {}
      wildcardForReq = (req) -> OmegaPac.wildcardForUrl(req.url)
      @_requestMonitor = new WebRequestMonitor(wildcardForReq)
      @_requestMonitor.watchTabs (tabId, info) =>
        return unless @_monitorWebRequests
        if info.errorCount > 0
          info.badgeSet = true
          badge = {text: info.errorCount.toString(), color: '#f0ad4e'}
          chrome.browserAction.setBadgeText(text: badge.text, tabId: tabId)
          chrome.browserAction.setBadgeBackgroundColor(
            color: badge.color
            tabId: tabId
          )
        else if info.badgeSet
          info.badgeSet = false
          chrome.browserAction.setBadgeText(text: '', tabId: tabId)
        @_tabRequestInfoPorts[tabId]?.postMessage({
          errorCount: info.errorCount
          summary: info.summary
        })

      chrome.runtime.onConnect.addListener (rawPort) =>
        return unless rawPort.name == 'tabRequestInfo'
        return unless @_monitorWebRequests
        tabId = null
        port = new ChromePort(rawPort)
        port.onMessage.addListener (msg) =>
          tabId = msg.tabId
          @_tabRequestInfoPorts[tabId] = port
          info = @_requestMonitor.tabInfo[tabId]
          if info
            port.postMessage({
              errorCount: info.errorCount
              summary: info.summary
            })
        port.onDisconnect.addListener =>
          delete @_tabRequestInfoPorts[tabId] if tabId?

  _alarms: null
  schedule: (name, periodInMinutes, callback) ->
    name = 'omega.' + name
    if not _alarms?
      @_alarms = {}
      chrome.alarms.onAlarm.addListener (alarm) =>
        @_alarms[alarm.name]?()
    if periodInMinutes < 0
      delete @_alarms[name]
      chrome.alarms.clear(name)
    else
      @_alarms[name] = callback
      chrome.alarms.create(name, {
        periodInMinutes: periodInMinutes
      })
    Promise.resolve()

  printFixedProfile: (profile) ->
    return unless profile.profileType == 'FixedProfile'
    result = ''
    for scheme in OmegaPac.Profiles.schemes when profile[scheme.prop]
      pacResult = OmegaPac.Profiles.pacResult(profile[scheme.prop])
      if scheme.scheme
        result += "#{scheme.scheme}: #{pacResult}\n"
      else
        result += "#{pacResult}\n"
    result ||= chrome.i18n.getMessage(
      'browserAction_profileDetails_DirectProfile')
    return result

  printProfile: (profile) ->
    type = profile.profileType
    if type.indexOf('RuleListProfile') >= 0
      type = 'RuleListProfile'

    if type == 'FixedProfile'
      @printFixedProfile(profile)
    else if type == 'PacProfile' and profile.pacUrl
      profile.pacUrl
    else
      chrome.i18n.getMessage('browserAction_profileDetails_' + type) || null

  upgrade: (options, changes) ->
    super(options).catch (err) =>
      return Promise.reject err if options?['schemaVersion']
      getOldOptions = if @switchySharp
        @switchySharp.getOptions().timeout(1000)
      else
        Promise.reject()

      getOldOptions = getOldOptions.catch ->
        if options?['config']
          Promise.resolve options
        else if localStorage['config']
          Promise.resolve localStorage
        else
          Promise.reject new OmegaTarget.Options.NoOptionsError()

      getOldOptions.then (oldOptions) =>
        i18n = {
          upgrade_profile_auto: chrome.i18n.getMessage('upgrade_profile_auto')
        }
        try
          # Upgrade from SwitchySharp.
          upgraded = require('./upgrade')(oldOptions, i18n)
        catch ex
          @log.error(ex)
          return Promise.reject ex
        if localStorage['config']
          Object.getPrototypeOf(localStorage).clear.call(localStorage)
        @_state.set({'firstRun': 'upgrade'})
        return this && super(upgraded, upgraded)

  onFirstRun: (reason) ->
    chrome.tabs.create url: chrome.extension.getURL('options.html')

  getPageInfo: ({tabId, url}) ->
    getBadge = new Promise (resolve, reject) ->
      chrome.browserAction.getBadgeText {tabId: tabId}, (result) ->
        resolve(result)

    getInspectUrl = @_state.get({inspectUrl: ''})
    Promise.join getBadge, getInspectUrl, (badge, {inspectUrl}) =>
      if badge == '#' and inspectUrl
        url = inspectUrl
      else
        @clearBadge()
      return null if not url
      if url.substr(0, 6) == 'chrome'
        errorPagePrefix = 'chrome://errorpage/'
        if url.substr(0, errorPagePrefix.length) == errorPagePrefix
          url = querystring.parse(url.substr(url.indexOf('?') + 1)).lasturl
          return null if not url
        else
          return null
      domain = OmegaPac.getBaseDomain(Url.parse(url).hostname)
      return {
        url: url
        domain: domain
        tempRuleProfileName: @queryTempRule(domain)
      }

module.exports = ChromeOptions

