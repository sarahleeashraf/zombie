# Window history.
#
# Each window belongs to a history. Think of history as a timeline, with
# currently active window, and multiple previous and future windows. From that
# window you can navigate backwards and forwards between all other windows that
# belong to the same history.
#
# Each window also has a container: either a browser tab or an iframe. When
# navigating in history, a different window (from the same history), replaces
# the current window within its container.
#
# Containers have access to the currently active window, not the history
# itself, so navigation has to alert the container when there's a change in the
# currently active window.
#
# The history does so by calling a "focus" function. To create the first
# window, the container must first create a new history and supply a focus
# function. The result is another function it can use to create the new window.
#
# From there on, it can navigate in history and add new windows by chaing the
# current location (or using assign/replace).
#
# It can be used like this:
#
#   active = null
#   focus = (window)->
#     active = window
#   history = createHistory(browser, focus)
#   window = history(url: url, name: name)


createWindow  = require("./window")
HTML          = require("jsdom").dom.level3.html
URL           = require("url")


# Creates and returns a new history.
#
# browser - The browser object
# focus   - The focus method, called when a new window is in focus
#
# Returns a function for opening a new window, which accepts:
# name      - Window name (optional)
# opener    - Opening window (window.open call)
# parent    - Parent window (for frames)
# url       - Set document location to this URL upon opening
createHistory = (browser, focus)->
  history = new History(browser, focus)
  return history.open.bind(history)


# Entry has the following properties:
# window      - Window for this history entry (may be shared with other entries)
# url         - URL for this history entry
# pushState   - Push state state
# next        - Next entry in history
# prev        - Previous entry in history
class Entry
  constructor: (@window, url, @pushState)->
    @url = URL.format(url)
    @next = @prev = null

  # Called to dispose of this entry. Used when we dispose of the entire
  # history, closing all windows. But also used when we replace one entry with
  # another, and there are two cases to worry about:
  # - The current entry uses the same window as the previous entry, we get rid
  #   of the entry, but must keep the entry intact
  # - The current entry uses the same window as the new entry, also need to
  #   keep window intact
  dispose: (keep)->
    if @next
      @next.dispose()
    # Do not close window if replacing entry with same window
    if keep == @window
      return
    # Do not close window if used by previous entry in history
    if @prev && @prev.window == @window
      return
    @window._cleanup()

  append: (entry)->
    if @next
      @next.dispose()
    @next = entry
    entry.prev = this


class History
  constructor: (@browser, @focus)->
    @first = @current = null

  # Opens the first window and returns it.
  open: ({ name, opener, parent, url })->
    window = createWindow(browser: @browser, history: this, name: name, opener: opener, parent: parent, url: url)
    @current = @first = new Entry(window, url || window.location)
    return window

  # Dispose of all windows in history
  dispose: ->
    @first.dispose()
    @first = null

  # Add a new entry.  When a window opens it call this to add itself to history.
  addEntry: (window, url, pushState)->
    url ||= window.location
    entry = new Entry(window, url, pushState)
    @updateLocation(window, url)
    @current.append(entry)
    @current = entry
    @focus(window)
 
  # Replace current entry with a new one.
  replaceEntry: (window, url, pushState)->
    url ||= window.location
    entry = new Entry(window, url, pushState)
    @updateLocation(window, url)
    if @current == @first
      @current.dispose(window)
      @current = @first = entry
    else
      @current.prev.append(entry, window)
    @focus(window)

  # Update window location (navigating to new URL, same window, e.g pushState or hash change)
  updateLocation: (window, url)->
    history = this
    Object.defineProperty window, "location", 
      get: ->
        return createLocation(history, url)
      set: (url)->
        history.assign(url)
      enumerable: true

  # Returns current URL.
  @prototype.__defineGetter__ "url", ->
    return @current?.url

  # Form submission
  submit: ({ url, method, encoding, data })->
    window = @current.window
    url = HTML.resourceLoader.resolve(window.document, url || "/")
    params =
      browser:  @browser
      history:  this
      name:     window.name
      parent:   window.parent
      url:      url
      method:   method
      encoding: encoding
      data:     data
    newWindow = createWindow(params)
    @addEntry(newWindow, url)


  # -- Implementation of window.history --

  # This method is available from Location, used to navigate to a new page.
  assign: (url)->
    url = URL.format(url)
    if @current
      url = HTML.resourceLoader.resolve(@current.window.document, url)
      name = @current.window.name
    if @current && @current.url == url
      return # Not moving anywhere

    if hashChange(@current, url)
      window = @current.window
      @addEntry(window, url) # Reuse window with new URL
      event = window.document.createEvent("HTMLEvents")
      event.initEvent("hashchange", true, false)
      window._dispatchEvent(window, event)
    else
      if @current.window.parent != @current.window
        parent = @current.window.parent
      window = createWindow(browser: @browser, history: this, name: name, url: url, parent: parent)
      @addEntry(window, url)
    return

  # This method is available from Location, used to navigate to a new page.
  replace: (url)->
    url = URL.format(url)
    if @current
      url = HTML.resourceLoader.resolve(@current.window.document, url)
      name = @current.window.name
    if @current && @current.url == url
      return # Not moving anywhere

    if hashChange(@current, url)
      window = @current.window
      @replaceEntry(window, url) # Reuse window with new URL
      event = window.document.createEvent("HTMLEvents")
      event.initEvent("hashchange", true, false)
      window._dispatchEvent(window, event)
    else
      if @current.window.parent != @current.window
        parent = @current.window.parent
      window = createWindow(browser: @browser, history: this, name: name, url: url, parent: parent)
      @replaceEntry(window, url)
    return

  # This method is available from Location.
  go: (amount)->
    was = @current
    while amount > 0
      @current = @current.next if @current.next
      --amount
    while amount < 0
      @current = @current.prev if @current.prev
      ++amount

    # If moving from one page to another
    if @current && was && @current != was
      window = @current.window
      this.updateLocation(window, @current.url)
      @focus(window)
      if @current.pushState || was.pushState
        # Created with pushState/replaceState, send popstate event if navigating
        # within same host.
        oldHost = URL.parse(was.url).host
        newHost = URL.parse(@current.url).host
        if oldHost == newHost
          event = window.document.createEvent("HTMLEvents")
          event.initEvent("popstate", false, false)
          event.state = @current.pushState
          window._dispatchEvent(window, event)
      else if hashChange(was, @current.url)
        event = window.document.createEvent("HTMLEvents")
        event.initEvent("hashchange", true, false)
        window._dispatchEvent(window, event)
    return

  # This method is available from Location.
  @prototype.__defineGetter__ "length", ->
    entry = @first
    length = 0
    while entry
      ++length
      entry = entry.next
    return length

  # This method is available from Location.
  pushState: (state, title, url)->
    url = HTML.resourceLoader.resolve(@current.window.document, url)
    # TODO: check same origin
    @addEntry(@current.window, url, state || {})
    return

  # This method is available from Location.
  replaceState: (state, title, url)->
    url = HTML.resourceLoader.resolve(@current.window.document, url)
    # TODO: check same origin
    @replaceEntry(@current.window, url, state || {})
    return

  # This method is available from Location.
  @prototype.__defineGetter__ "state", ->
    if @current.pushState
      return @current.pushState



# Returns true if the hash portion of the URL changed between the history entry
# (entry) and the new URL we want to inspect (url).
hashChange = (entry, url)->
  return false unless entry
  return /^https?:/i.test(entry.url) && entry.url.split("#")[0] == url.split("#")[0]


# DOM Location object
createLocation = (history, url)->
  location = new Object()
  Object.defineProperties location,
    assign:
      value: (url)->
        history.assign(url)

    replace:
      value: (url)->
        history.replace(url)

    reload: (force)->
      value: 
        history.replace(@url)

    toString:
      value: ->
        return url
      enumerable: true

    hostname:
      get: ->
        return URL.parse(url).hostname
      set: (hostname)->
        newUrl = URL.parse(url)
        if newUrl.port
          newUrl.host = "#{hostname}:#{newUrl.port}"
        else
          newUrl.host = hostname
        history.assign(URL.format(newUrl))
      enumerable: true

    href:
      get: ->
        return url
      set: (href)->
        history.assign(URL.format(href))
      enumerable: true

  # Setting any of the properties creates a new URL and navigates there
  for prop in ["hash", "host", "pathname", "port", "protocol", "search"]
    do (prop)=>
      Object.defineProperty location, prop,
        get: ->
          return URL.parse(url)[prop] || ""
        set: (value)->
          newUrl = URL.parse(url)
          newUrl[prop] = value
          history.assign(URL.format(newUrl))
        enumerable: true

  return location


module.exports = createHistory

