_            = require("underscore")
hbs          = require("hbs")
url          = require("url")
http         = require("http")
cookie       = require("cookie")
express      = require("express")
Promise      = require("bluebird")
httpProxy    = require("http-proxy")
httpsProxy   = require("@cypress/core-https-proxy")
parseDomain  = require("parse-domain")
allowDestroy = require("server-destroy")
appData      = require("./util/app_data")
cwd          = require("./cwd")
errors       = require("./errors")
logger       = require("./logger")
Socket       = require("./socket")

localHostOrIpAddressRe = /localhost|\.local|^[\d\.]+$/

## currently not making use of event emitter
## but may do so soon
class Server
  constructor: ->
    if not (@ instanceof Server)
      return new Server

    @_server     = null
    @_socket     = null
    @_wsProxy    = null
    @_httpsProxy = null
    @_remoteOrigin = "<root>"
    @_remoteHostAndPort = null

  createExpressApp: (port, morgan) ->
    app = express()

    ## set the cypress config from the cypress.json file
    app.set "port",        port
    app.set "view engine", "html"
    app.engine "html",     hbs.__express

    app.use require("cookie-parser")()
    app.use require("compression")()
    app.use require("morgan")("dev") if morgan

    ## serve static file from public when route is /__cypress/static
    ## this is to namespace the static cypress files away from
    ## the real application by separating the root from the files
    app.use "/__cypress/static", express.static(cwd("lib", "public"))

    ## errorhandler
    app.use require("errorhandler")()

    ## remove the express powered-by header
    app.disable("x-powered-by")

    return app

  createRoutes: (app, config) ->
    require("./routes")(app, config)

  getHttpServer: -> @_server

  portInUseErr: (port) ->
    e = errors.get("PORT_IN_USE_SHORT", port)
    e.port = port
    e.portInUse = true
    e

  open: (config = {}) ->
    Promise.try =>
      app = @createExpressApp(config.port, config.morgan)

      app.getRemoteOrigin = =>
        @_remoteOrigin

      logger.setSettings(config)

      @createRoutes(app, config)

      @createServer(config.port, config.socketIoRoute, app)
      .return(@)

  createServer: (port, socketIoRoute, app) ->
    new Promise (resolve, reject) =>
      @_server  = http.createServer(app)
      @_wsProxy = httpProxy.createProxyServer()

      allowDestroy(@_server)

      onError = (err) =>
        ## if the server bombs before starting
        ## and the err no is EADDRINUSE
        ## then we know to display the custom err message
        if err.code is "EADDRINUSE"
          reject @portInUseErr(port)

      onUpgrade = (req, socket, head) =>
        @proxyWebsockets(@_wsProxy, socketIoRoute, req, socket, head)

      callListeners = (req, res) =>
        listeners = @_server.listeners("request").slice(0)

        @_callRequestListeners(@_server, listeners, req, res)

      onSniUpgrade = (req, socket, head) =>
        upgrades = @_server.listeners("upgrade").slice(0)
        for upgrade in upgrades
          upgrade.call(@_server, req, socket, head)

      @_server.on "connect", (req, socket, head) =>
        @_httpsProxy.connect(req, socket, head, {
          onDirectConnection: (req) =>
            ## make a direct connection only if
            ## our req url does not match the remote host + port
            not @_urlMatchesRemoteHostAndPort(req.url)
        })

      @_server.on "upgrade", onUpgrade

      @_server.once "error", onError

      Promise.join(
        @_listen(port, onError),
        httpsProxy.create(appData.path("proxy"), port, {
          onRequest: callListeners
          onUpgrade: onSniUpgrade
        })
      )
      .spread (srv, httpsProxy) =>
        @_httpsProxy = httpsProxy

        resolve(srv)

  _listen: (port, onError) ->
    new Promise (resolve) =>
      @_server.listen port, =>
        @isListening = true
        logger.info("Server listening", {port: port})

        @_server.removeListener "error", onError

        resolve(@_server)

  _parseUrl: (str) ->
    [host, port] = str.split(":")

    ## if we couldn't get a parsed domain
    if not parsed = parseDomain(host, {
      customTlds: localHostOrIpAddressRe
    })

      ## then just fall back to a dumb check
      ## based on assumptions that the tld
      ## is the last segment after the final
      ## '.' and that the domain is the segment
      ## before that
      segments = host.split(".")

      parsed = {
        tld:    segments[segments.length - 1]
        domain: segments[segments.length - 2]
      }

    obj = {}
    obj.port   = port
    obj.tld    = parsed.tld
    obj.domain = parsed.domain

    return obj

  _urlMatchesRemoteHostAndPort: (url) ->
    parsedUrl  = @_parseUrl(url)

    ## does the parsedUrl match the parsedHost?
    _.isEqual(parsedUrl, @_remoteHostAndPort)

  _onDomainChange: (fullyQualifiedUrl) =>
      parsed = url.parse(fullyQualifiedUrl)

      port = parsed.port ? if parsed.protocol is "https:" then 443 else 80

      parsed.hash     = null
      parsed.search   = null
      parsed.query    = null
      parsed.path     = null
      parsed.pathname = null

      @_remoteOrigin = url.format(parsed)

      ## set an object with port, tld, and domain properties
      ## as the remoteHostAndPort
      @_remoteHostAndPort = @_parseUrl([parsed.hostname, port].join(":"))

  _callRequestListeners: (server, listeners, req, res) ->
    for listener in listeners
      listener.call(server, req, res)

  _normalizeReqUrl: (server) ->
    ## because socket.io removes all of our request
    ## events, it forces the socket.io traffic to be
    ## handled first.
    ## however we need to basically do the same thing
    ## it does and after we call into socket.io go
    ## through and remove all request listeners
    ## and change the req.url by slicing out the host
    ## because the browser is in proxy mode
    listeners = server.listeners("request").slice(0)
    server.removeAllListeners("request")
    server.on "request", (req, res) =>
      ## backup the original proxied url
      ## and slice out the host/origin
      ## and only leave the path which is
      ## how browsers would normally send
      ## use their url
      req.proxiedUrl = req.url

      req.url = url.parse(req.url).path

      @_callRequestListeners(server, listeners, req, res)

  proxyWebsockets: (proxy, socketIoRoute, req, socket, head) ->
    ## bail if this is our own namespaced socket.io request
    return if req.url.startsWith(socketIoRoute)

    ## parse the cookies to find our remoteHost
    cookies = cookie.parse(req.headers.cookie ? "")

    if remoteHost = cookies["__cypress.remoteHost"]
      ## get the hostname + port from the remoteHost
      {hostname, port} = url.parse(remoteHost)

      proxy.ws(req, socket, head, {
        target: {
          host: hostname
          port: port
        }
      })
    else
      ## we can't do anything with this socket
      ## since we don't know how to proxy it!
      socket.end() if socket.writable

  _close: ->
    new Promise (resolve) =>
      logger.unsetSettings()

      ## bail early we dont have a server or we're not
      ## currently listening
      return resolve() if not @_server or not @isListening

      logger.info("Server closing")

      @_server.destroy =>
        @isListening = false
        resolve()

  close: ->
    Promise.join(
      @_close()
      @_socket?.close()
      ## todo close @_httpsProxy
    )

  end: ->
    @_socket and @_socket.end()

  startWebsockets: (watchers, config, options = {}) ->
    options.onDomainChange = =>
      @_onDomainChange.apply(@, arguments)

    @_socket = Socket()
    @_socket.startListening(@_server, watchers, config, options = {})
    @_normalizeReqUrl(@_server)
    # handleListeners(@_server)

module.exports = Server