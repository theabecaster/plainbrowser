import Foundation
import Network

/// A tiny HTTP server on localhost for the UI tests, so they never depend on the network.
/// The simulator shares the Mac's loopback, so the app reaches it at `localhost:<port>`.
///
/// Pages:
/// - `/a`: "Page A", with a link to `/b`.
/// - `/b`: "Page B".
/// - `/count`: "Load N", where N counts this page's loads (pull to refresh reloads it).
/// - `/fresh`: "Fresh N" and the request's cache headers ("Cache no-cache" for a reload from the
///   origin), N counting its loads (the pill's Reload and Reload Without Cache).
/// - `/long`: a long article, for scrolling and the toolbar collapse.
/// - `/footer`: a long page with a `position: fixed` footer, for the page's bottom inset.
/// - `/fixed-header`, `/sticky-header`, `/dark-header`: long pages with a fixed, a sticky, and a
///   dark page's fixed black header, for the top bar's inset on the Duo's inner screen.
/// - `/ua`: "Desktop UA" or "Mobile UA", from the request's user agent (Desktop Site).
/// - `/blocking`: "Ad blocked" or "Ad loaded", whether `/jquery.overlayad.js` (an EasyList rule
///   that matches any site) was blocked.
/// - `/article`: a readerable article (Reader), with a link to `/b`.
/// - `/location`: asks for the location (a permission prompt).
/// - `/motion`: a button that asks for motion sensors (a permission prompt after a tap).
/// - `/camera`: asks for the camera and microphone as it loads (a video call's first page).
/// - `/photo`: a picture (`/sunset.svg`) to long-press for Save Image.
/// - `/login`: a sign-in form with the `autocomplete` hints AutoFill reads.
/// - `/passkey`: "Sign In with a Passkey", which asks for a passkey; the heading says how it ended.
/// - `/french`: a page in French (`lang="fr"`) whose sentences the app's test translator knows.
/// - `/french-article`: a readerable article in French (Show Reader and Translate Page both apply).
/// - `/consent`: a shop page with a OneTrust cookie banner; the heading says how it was answered.
/// - `/paint-start`, `/paint-target`: the perf gate's link tap to first paint. The start page notes
///   when its link is tapped; the target shows "Paint <ms> fcp", from that tap to its own first
///   contentful paint (Paint Timing), both on the page's clock.
/// - `/video`, `/video-bare`, `/custom-player`, `/autoplay`: media pages (`mediaPage`) with
///   `/media-clip.mp4`: a video with controls and `playsinline`; one with neither (iPhone plays
///   it in the native player); a site's own player box that asks for fullscreen the way YouTube's
///   does; a muted video that autoplays inline. Their heading says what happened.
/// - `/big`: a large light-only page (3,000 paragraphs, 4,000 style rules, 300 background
///   pictures; the same as WebEngineTests' `DarkPagesTests.bigPage`), for the heavy scroll test.
final class TestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TestServer")
    private var loads = 0
    /// Requests for `/long?reload=slow` so far: the first answers at once, later ones slowly.
    private var slowReloads = 0
    private var freshLoads = 0
    private var freshPictureLoads = 0
    /// The last request's `Cache-Control` and `Pragma` values, for `/fresh`.
    private var cacheHeaders = ""
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// Starts listening and returns once the port is known.
    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != 0 else {
            throw URLError(.cannotConnectToHost)
        }
    }

    func stop() {
        listener.cancel()
    }

    /// The address as typed into the address bar.
    func address(_ path: String) -> String {
        "localhost:\(port)\(path)"
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            if path.hasPrefix("/media-clip.mp4") {
                self.serveClip(connection, request: request)
                return
            }
            let agent = request.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("user-agent:") }.map(String.init) ?? ""
            self.cacheHeaders = request.split(separator: "\r\n")
                .filter { $0.lowercased().hasPrefix("cache-control:") || $0.lowercased().hasPrefix("pragma:") }
                .compactMap { $0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
            let (status, body) = self.page(for: path, userAgent: agent)
            let isFile = path.hasPrefix("/file.txt")
            let type = path.hasSuffix(".js") ? "application/javascript"
                : path.hasSuffix(".svg") ? "image/svg+xml" : (isFile ? "text/plain" : "text/html; charset=utf-8")
            // A download: the browser saves it instead of showing it.
            let disposition = isFile ? "Content-Disposition: attachment; filename=\"plain-notes.txt\"\r\n" : ""
            let header = """
            HTTP/1.1 \(status)\r
            Content-Type: \(type)\r
            \(disposition)\
            Content-Length: \(body.utf8.count)\r
            Cache-Control: \(path == "/fresh.svg" ? "max-age=3600" : "no-store")\r
            Connection: close\r
            \r

            """
            // `/slow` answers after a few seconds: a page that stays loading (Stop, the progress bar).
            // `/long?reload=slow` loads at once and reloads slowly: a pull to refresh keeps spinning.
            var delay: Double = path.hasPrefix("/slow") ? 8 : 0
            if path.contains("reload=slow") {
                self.slowReloads += 1
                if self.slowReloads > 1 { delay = 3 }
            }
            self.queue.asyncAfter(deadline: .now() + delay) {
                connection.send(content: Data((header + body).utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    /// The test clip (`media-clip.mp4`: 60 s, 256x144 H.264 with a quiet AAC tone, so a playing
    /// page is audible as a real video is). WebKit's media loader asks for byte ranges and plays
    /// nothing from a server that ignores them, so this answers `Range` with 206.
    private static let clip: Data = {
        let url = Bundle(for: TestServer.self).url(forResource: "media-clip", withExtension: "mp4")
        return url.flatMap { try? Data(contentsOf: $0) } ?? Data()
    }()

    private func serveClip(_ connection: NWConnection, request: String) {
        let clip = Self.clip
        var range = 0..<clip.count
        var status = "200 OK"
        // One range: `a-b`, `a-` or the last N bytes (`-N`). Several ranges get the whole file (200).
        if let line = request.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("range: bytes=") }),
           !line.contains(",") {
            let spec = line.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            if spec.count == 2 {
                let last = clip.count - 1
                let (start, end): (Int?, Int?) = spec[0].isEmpty
                    ? (Int(spec[1]).map { max(0, clip.count - $0) }, last)
                    : (Int(spec[0]), spec[1].isEmpty ? last : Int(spec[1]).map { min($0, last) })
                if let start, let end, start <= end {
                    range = start..<(end + 1)
                    status = "206 Partial Content"
                }
            }
        }
        let contentRange = status.hasPrefix("206")
            ? "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(clip.count)\r\n" : ""
        let header = "HTTP/1.1 \(status)\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\n\(contentRange)"
            + "Content-Length: \(range.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + clip.subdata(in: range), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// The media pages' shared script. `log(text)` sets the `state` heading. It reports which
    /// fullscreen the page got ("Element fullscreen" from the Fullscreen API, "Native player"
    /// from the video's own presentation), picture in picture, and on leaving fullscreen whether
    /// the page's scroll position came back. `?exit=<s>` leaves native fullscreen after that many
    /// seconds, so a test needs no player buttons, whose labels are the system's.
    private static let mediaScript = """
        <script>
        const v = document.getElementById('v');
        const state = document.getElementById('state');
        const log = (t) => { state.textContent = t; };
        const exitAfter = Number(new URLSearchParams(location.search).get('exit') || 0);
        // `?slack=<pt>`: how far the page may move and still count as kept (a turn reflows it).
        const slack = Number(new URLSearchParams(location.search).get('slack') || 1);
        let scrollAtEntry = 0, hiddenAt = 0, timeAtHide = 0;
        document.getElementById('fe').textContent = 'Element fullscreen ' + (document.fullscreenEnabled ? 'on' : 'off');
        // The simulator has no picture in picture (Safari's own `document.pictureInPictureEnabled` is false there).
        document.getElementById('pp').textContent = 'Picture in picture ' + (document.pictureInPictureEnabled ? 'on' : 'off');
        const scrollNote = () => Math.abs(scrollY - scrollAtEntry) <= slack ? 'scroll kept' : 'scroll moved ' + Math.round(scrollAtEntry) + ' to ' + Math.round(scrollY);
        v.addEventListener('webkitbeginfullscreen', () => {
          log('Native player');
          if (exitAfter) setTimeout(() => v.webkitExitFullscreen(), exitAfter * 1000);
        });
        v.addEventListener('webkitendfullscreen', () => setTimeout(() => log('Left native player, ' + scrollNote()), 600));
        // The app turned while the player was up (the page under it turns with it).
        addEventListener('resize', () => {
          if (v.webkitDisplayingFullscreen && innerWidth > innerHeight) document.getElementById('fe').textContent += ', turned';
        });
        document.addEventListener('fullscreenchange', () => {
          if (document.fullscreenElement) {
            log('Element fullscreen');
            if (exitAfter) setTimeout(() => document.exitFullscreen(), exitAfter * 1000);
          } else setTimeout(() => log('Left element fullscreen, ' + scrollNote()), 600);
        });
        v.addEventListener('enterpictureinpicture', () => log('In picture in picture'));
        v.addEventListener('leavepictureinpicture', () => log('Left picture in picture'));
        v.addEventListener('playing', () => { if (!v.webkitDisplayingFullscreen && state.textContent === 'Video') log('Playing inline'); });
        document.addEventListener('visibilitychange', () => {
          if (document.hidden) { hiddenAt = Date.now(); timeAtHide = v.currentTime; return; }
          if (!hiddenAt || v.webkitPresentationMode !== 'picture-in-picture') return;
          const away = (Date.now() - hiddenAt) / 1000, played = v.currentTime - timeAtHide;
          log(played > away * 0.6 ? 'Kept playing in picture in picture' : 'Stalled in picture in picture ' + played.toFixed(1) + ' of ' + away.toFixed(1));
        });
        const fullscreen = () => {
          scrollAtEntry = scrollY;
          const player = document.getElementById('player');
          // What YouTube's and Vimeo's players do: the player's box when the page may go
          // fullscreen, the video's own fullscreen otherwise.
          if (player && document.fullscreenEnabled) player.requestFullscreen();
          else v.webkitEnterFullscreen();
          v.play();
        };
        const play = () => { scrollAtEntry = scrollY; v.play(); };
        const pip = () => { v.play(); v.webkitSetPresentationMode('picture-in-picture'); };
        </script>
        """

    private static let mediaButton = "font-size:20px;padding:10px 16px;margin:6px 6px 0 0"

    /// The media pages: a heading that reports what happened (`mediaScript`), a tall block above
    /// the player so fullscreen starts from a scrolled page, and the player.
    private func mediaPage(_ title: String, video: String, wrapped: Bool = false, autoplay: Bool = false) -> String {
        let player = wrapped
            ? "<div id=\"player\" style=\"position:relative;background:#000\">\(video)</div>" : video
        let script = autoplay ? "<script>document.getElementById('v').play().catch(() => {});</script>" : ""
        return html("Plain \(title)", """
            <h1 id="state">Video</h1><p id="fe"></p><p id="pp"></p>
            <div style="height:520px;background:linear-gradient(#8ab,#fda);border-radius:8px"></div>
            \(player)
            <p><button id="fs" style="\(Self.mediaButton)" onclick="fullscreen()">Go Fullscreen</button>\
            <button id="play" style="\(Self.mediaButton)" onclick="play()">Play Video</button>\
            <button id="pip" style="\(Self.mediaButton)" onclick="pip()">Start Picture in Picture</button></p>
            <div style="height:900px"></div>
            """ + Self.mediaScript + script)
    }

    private func page(for path: String, userAgent: String) -> (String, String) {
        // Query strings don't change the page (tests use long tracking addresses).
        let path = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        switch path {
        case "/a":
            return ("200 OK", html("Plain Test A", "<h1>Page A</h1><p><a href=\"/b\">Go to B</a></p>"))
        case "/opener":
            // A link that opens a new tab, and an ordinary one (the link menu's preview).
            let paragraphs = (1...30).map { "<p>Line \($0) of the page that opens a new tab.</p>" }
            return ("200 OK", html("Plain Opener", "<h1>Opener Page</h1>"
                + "<p><a id=\"newtab\" href=\"/b\" target=\"_blank\">Open B in a new tab</a></p>"
                + "<p><a id=\"plain\" href=\"/long\">Read the long page</a></p>" + paragraphs.joined()))
        case "/b":
            return ("200 OK", html("Plain Test B", "<h1>Page B</h1>"))
        case "/c":
            return ("200 OK", html("Plain Test C", "<h1>Page C</h1><p>A third page, for tab switching.</p>"))
        case "/launch":
            // A page in one strong color, so a screenshot tells it from Plain's paper at a glance
            // (the launch tests: the last tab's picture must be on the very first screen).
            return ("200 OK", html("Plain Launch", "<style>html,body{background:#2973FF;color:#fff;min-height:100%}</style>"
                + "<h1>Launch Page</h1><p>The last tab, back from the first frame.</p>"))
        case "/files":
            return ("200 OK", html("Plain Files", "<h1>Files</h1><p><a href=\"/file.txt\">Download notes</a></p>"))
        case "/file.txt":
            return ("200 OK", "Notes from the Plain test server.\n")
        case "/fresh":
            freshLoads += 1
            let cache = cacheHeaders.isEmpty ? "none" : cacheHeaders
            // The picture may be cached for an hour; its count says how often it was fetched before
            // this page (a reload from the origin fetches it again).
            return ("200 OK", html("Plain Fresh", "<h1>Fresh \(freshLoads)</h1><p>Cache \(cache)</p>"
                + "<p>Picture \(freshPictureLoads)</p><img src=\"/fresh.svg\" width=\"40\" height=\"40\" alt=\"\">"))
        case "/fresh.svg":
            freshPictureLoads += 1
            return ("200 OK", "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\"><rect width=\"40\" height=\"40\" fill=\"#2973FF\"/></svg>")
        case "/count":
            loads += 1
            return ("200 OK", html("Plain Counter", "<h1>Load \(loads)</h1>"))
        case "/long":
            let paragraphs = (1...80).map {
                "<p>Paragraph \($0). A browser shows pages, and Plain promises nothing extra: the page gets the screen, and the chrome steps aside while you read.</p>"
            }
            return ("200 OK", html("Plain Long Read", "<h1>Long Read</h1>" + paragraphs.joined()))
        case "/footer":
            // A long page with a fixed footer, like a cookie bar or an app's tab bar: the resting
            // toolbar must never cover it.
            let paragraphs = (1...60).map {
                "<p>Line \($0). Fixed page footers sit on the page's bottom edge, which the toolbar covers unless the page knows about it.</p>"
            }
            let footer = "<div style=\"position:fixed;left:0;right:0;bottom:0;padding:14px 20px;"
                + "background:#2973FF;color:#fff;font-weight:600\">Fixed Footer</div>"
            return ("200 OK", html("Plain Footer", "<h1>Footer Page</h1>" + paragraphs.joined() + "<p>End of page.</p>" + footer))
        case "/fixed-header", "/sticky-header", "/dark-header":
            // Long pages with a header like most news and shop sites have: `position: fixed`
            // (the body leaves room for it), `position: sticky`, and a dark page with a fixed
            // black header. On the Duo's inner screen WebKit fills an obscured top inset above
            // such a header with its color; the top bar's inset must leave no such band.
            let fixed = path != "/sticky-header"
            let dark = path == "/dark-header"
            let color = dark ? "#000" : fixed ? "#C0392B" : "#1F6F43"
            let name = dark ? "Dark Header Page" : fixed ? "Fixed Header Page" : "Sticky Header Page"
            let header = "<header style=\"position:\(fixed ? "fixed" : "sticky");top:0;left:0;right:0;height:56px;"
                + "background:\(color);color:#fff;font-weight:700;display:flex;align-items:center;padding:0 16px;"
                + "z-index:2\">\(fixed ? "Fixed" : "Sticky") Header</header>"
            let paragraphs = (1...60).map {
                "<p>Line \($0). A header that stays at the top is fine; a band of its color above it is not.</p>"
            }
            let css = "body{margin:0;background:\(dark ? "#121212" : "#fff");color:\(dark ? "#eee" : "#222")}"
                + "main{padding:\(fixed ? "56px" : "0") 16px 0}"
            return ("200 OK", styled("Plain \(name)", css, header + "<main><h1>\(name)</h1><p>First line of the page.</p>"
                + paragraphs.joined() + "<p>End of page.</p></main>"))
        case "/light-site", "/light-site-2":
            // A site designed only in light: white page, a colored header, a grey card, pictures,
            // an emoji. Dark pages darkens it while Plain is dark.
            let photo = "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='300' height='120'>"
                + "<defs><linearGradient id='g' x1='0' x2='1'><stop offset='0' stop-color='%23ff9a3c'/>"
                + "<stop offset='1' stop-color='%233c7dff'/></linearGradient></defs><rect width='300' height='120' fill='url(%23g)'/>"
                + "<circle cx='240' cy='40' r='22' fill='%23fff3b0'/></svg>"
            let paragraphs = (1...60).map {
                "<p>Paragraph \($0). This site was only ever designed in light colors, like most of the web.</p>"
            }
            let body = "<header style=\"background:#2973FF;color:#fff;padding:12px 16px;font-weight:700\">Light Site</header>"
                + "<main style=\"padding:0 16px\"><h1>Light Only</h1>"
                + "<img src=\"\(photo)\" alt=\"Sunset\" style=\"width:100%;border-radius:8px\">"
                + "<div style=\"background:#f2f2f2;border:1px solid #ddd;border-radius:8px;padding:12px;margin:12px 0\">"
                + "A grey card with a <a href=\"/a\">blue link</a> and an emoji 🌅.</div>"
                + paragraphs.joined() + "</main>"
                // The scroll proxy for the dark pages perf test: frames drawn while scrolling,
                // and how many took longer than 25 ms.
                + "<p id=\"stats\" style=\"padding:0 16px\">Frames: 0, long: 0, worst: 0</p><script>"
                + "let last = 0, frames = 0, long = 0, worst = 0, scrolled = 0, shown = '';"
                + "addEventListener('scroll', () => { scrolled = performance.now(); }, { passive: true });"
                + "const tick = (t) => { if (last && t - scrolled < 150) { const d = t - last; frames++;"
                + " if (d > 25) long++; worst = Math.max(worst, d); } last = t; requestAnimationFrame(tick); };"
                + "requestAnimationFrame(tick);"
                + "setInterval(() => { const text = `Frames: ${frames}, long: ${long}, worst: ${Math.round(worst)}`;"
                + " if (text !== shown) { shown = text; document.getElementById('stats').textContent = text; } }, 500);"
                + "</script>"
            return ("200 OK", styled("Plain Light Site", "body{background:#fff;color:#222;margin:0}", body))
        case "/dark-site":
            // A site with its own dark design: Plain leaves it alone.
            let paragraphs = (1...30).map { "<p>Paragraph \($0). This site has its own dark design.</p>" }
            let css = "body{background:#fff;color:#222;margin:0;padding:0 16px}"
                + "@media (prefers-color-scheme: dark){body{background:#1b1430;color:#e9e3ff}h1{color:#c8b6ff}}"
            return ("200 OK", styled("Plain Dark Site", css, "<h1>Own Dark Design</h1>" + paragraphs.joined(),
                                     head: "<meta name=\"color-scheme\" content=\"light dark\">"))
        case "/ua":
            let desktop = !userAgent.contains("Mobile")
            return ("200 OK", html("Plain UA", "<h1>\(desktop ? "Desktop" : "Mobile") UA</h1>"))
        case "/blocking":
            return ("200 OK", html("Plain Blocking", """
                <h1 id="state">Checking</h1>
                <script>function done(text) { document.getElementById('state').textContent = text; }</script>
                <script src="/jquery.overlayad.js" onload="done('Ad loaded')" onerror="done('Ad blocked')"></script>
                """))
        case "/jquery.overlayad.js":
            return ("200 OK", "window.plainAd = true;")
        case "/article":
            let paragraphs = (1...12).map {
                "<p>Paragraph \($0) of the article. Reading on a phone should feel calm: the text sets the pace, the "
                    + "margins give it room, and nothing moves unless you ask it to. A reader view keeps the words and "
                    + "drops everything around them, so a long piece reads like a page in a good book.</p>"
            }
            let body = "<header><nav><a href=\"/a\">Home</a> · <a href=\"/b\">Archive</a></nav></header>"
                + "<article><h1>The Quiet Page</h1><p class=\"byline\">By Plain Tester</p>"
                + paragraphs.joined() + "<p>Next, <a href=\"/b\">read page B</a>.</p></article>"
                + "<footer><p>Footer links and other chrome.</p></footer>"
            return ("200 OK", html("The Quiet Page", body))
        case "/french":
            let body = """
                <h1>Le marché du samedi</h1>
                <p>Chaque samedi matin, la place du village se remplit d'étals colorés.</p>
                <p>Les producteurs locaux vendent des fruits, des légumes et du fromage. <a href="/b">Lire la suite</a></p>
                <h2>Les horaires</h2>
                <p>Le marché ouvre à huit heures et ferme à midi.</p>
                <p>Venez tôt pour trouver le meilleur pain de la région.</p>
                """
            return ("200 OK", html("Le marché", body).replacingOccurrences(of: "<html>", with: "<html lang=\"fr\">"))
        case "/french-article":
            // Readerable and foreign at once: the page menu's tallest page state (Show Reader and
            // Translate Page both apply).
            let paragraphs = (1...12).map {
                "<p>Paragraphe \($0) de l'article. Lire sur un téléphone devrait être calme : le texte donne le "
                    + "rythme, les marges lui laissent de la place, et rien ne bouge sauf si vous le demandez. "
                    + "Une vue de lecture garde les mots et retire tout le reste autour d'eux.</p>"
            }
            let body = "<header><nav><a href=\"/a\">Accueil</a> · <a href=\"/b\">Archives</a></nav></header>"
                + "<article><h1>La page tranquille</h1><p class=\"byline\">Par Plain</p>"
                + paragraphs.joined() + "</article><footer><p>Liens de pied de page.</p></footer>"
            return ("200 OK", html("La page tranquille", body).replacingOccurrences(of: "<html>", with: "<html lang=\"fr\">"))
        case "/consent":
            let body = """
                <h1 id="state">Cookies not answered</h1><p>Fresh bread, every morning.</p>
                <div id="onetrust-consent-sdk"><div id="onetrust-banner-sdk" style="position:fixed;left:0;right:0;bottom:0;
                  padding:20px;background:#fff;border-top:1px solid #ccc;font-size:17px">
                  <p>We use cookies to improve your experience and for marketing.</p>
                  <button id="onetrust-accept-btn-handler">Accept All</button>
                  <button id="onetrust-reject-all-handler">Reject All</button>
                </div></div>
                <script>
                  const answer = (text) => { document.getElementById('state').textContent = 'Cookies ' + text;
                    document.getElementById('onetrust-banner-sdk').style.display = 'none'; };
                  document.getElementById('onetrust-reject-all-handler').onclick = () => answer('rejected');
                  document.getElementById('onetrust-accept-btn-handler').onclick = () => answer('accepted');
                </script>
                """
            return ("200 OK", html("Plain Bakery", body))
        case "/paint-start":
            // The tap: the link's touchend (the finger lifting), or its click when no touch came.
            // Its time rides in the link's address (and in sessionStorage, a second way), so the
            // next page has it whatever the browser does with a tab's storage.
            let script = "<script>sessionStorage.removeItem('plainTap'); let tapped = 0;"
                + "const go = document.getElementById('go');"
                + "const mark = () => { if (tapped) return; tapped = performance.timeOrigin + performance.now();"
                + " go.href = '/paint-target?tap=' + tapped; sessionStorage.setItem('plainTap', String(tapped)); };"
                + "go.addEventListener('touchend', mark, { passive: true }); go.addEventListener('click', mark);</script>"
            let link = "<a id=\"go\" href=\"/paint-target\" style=\"display:block;font-size:32px;padding:48px 0\">Open Paint Target</a>"
            return ("200 OK", html("Plain Paint Start", "<h1>Paint Start</h1>" + link + script))
        case "/paint-target":
            // First contentful paint, from the tap noted on the start page. Without Paint Timing,
            // the second animation frame after this script stands in ("raf"). The last word is
            // the tap's own time, so each report reads differently from the one before.
            let script = "<script>const tap = Number(new URLSearchParams(location.search).get('tap')"
                + " || sessionStorage.getItem('plainTap') || 0);"
                + "sessionStorage.removeItem('plainTap'); let done = false;"
                + "const show = (t, how) => { if (done) return; done = true; document.getElementById('paint').textContent ="
                + " tap ? `Paint ${(t - tap).toFixed(1)} ${how} ${Math.round(tap) % 1000000}` : 'Paint none'; };"
                + "let raf = 0; requestAnimationFrame(() => requestAnimationFrame(() => { raf = performance.timeOrigin + performance.now(); }));"
                + "try { new PerformanceObserver((list) => { for (const e of list.getEntries()) {"
                + " if (e.name === 'first-contentful-paint') show(performance.timeOrigin + e.startTime, 'fcp'); } })"
                + ".observe({ type: 'paint', buffered: true }); } catch (e) {}"
                + "setTimeout(() => { if (raf) show(raf, 'raf'); }, 1000);</script>"
            let body = "<h1>Paint Target</h1><p id=\"paint\">Paint pending</p>"
                + "<p><a id=\"back\" href=\"/paint-start\" style=\"display:block;font-size:32px;padding:48px 0\">Back to Paint Start</a></p>"
            return ("200 OK", html("Plain Paint Target", body + script))
        case "/video":
            return ("200 OK", mediaPage("Video", video: """
                <video id="v" src="/media-clip.mp4" controls playsinline preload="auto" style="width:100%;display:block"></video>
                """))
        case "/video-bare":
            return ("200 OK", mediaPage("Bare Video", video: """
                <video id="v" src="/media-clip.mp4" preload="auto" style="width:100%;display:block"></video>
                """))
        case "/custom-player":
            return ("200 OK", mediaPage("Custom Player", video: """
                <video id="v" src="/media-clip.mp4" playsinline preload="auto" style="width:100%;display:block"></video>
                """, wrapped: true))
        case "/autoplay":
            return ("200 OK", mediaPage("Autoplay", video: """
                <video id="v" src="/media-clip.mp4" muted autoplay loop playsinline style="width:100%;display:block"></video>
                """, autoplay: true))
        case "/big":
            return ("200 OK", Self.bigPage)
        case "/slow":
            return ("200 OK", html("Plain Slow", "<h1>Slow Page</h1>"))
        case "/motion":
            return ("200 OK", html("Plain Motion", """
                <h1 id="state">Motion</h1>
                <p><button id="ask" style="font-size:22px;padding:12px 20px" onclick="
                  DeviceMotionEvent.requestPermission()
                    .then(r => { document.getElementById('state').textContent = 'Motion ' + r; })
                    .catch(e => { document.getElementById('state').textContent = 'Motion error'; });
                ">Use Motion</button></p>
                """))
        case "/camera":
            return ("200 OK", html("Plain Camera", """
                <h1 id="state">Calling</h1>
                <script>
                const state = (text) => { document.getElementById('state').textContent = text; };
                try {
                  navigator.mediaDevices.getUserMedia({ video: true, audio: true })
                    .then(() => state('Camera allowed'), () => state('Camera denied'));
                } catch (e) { state('Camera denied'); }
                </script>
                """))
        case "/photo":
            return ("200 OK", html("Plain Photo", """
                <h1>Photo</h1>
                <a href="/a"><img src="/sunset.svg" alt="Sunset" style="width:100%;height:260px;border-radius:8px"></a>
                """))
        case "/sunset.svg":
            return ("200 OK", """
                <svg xmlns="http://www.w3.org/2000/svg" width="300" height="200"><rect width="300" height="200" fill="#ff9a3c"/>\
                <circle cx="220" cy="70" r="30" fill="#fff3b0"/></svg>
                """)
        case "/location":
            return ("200 OK", html("Plain Location", """
                <h1 id="state">Asking</h1>
                <script>
                navigator.geolocation.getCurrentPosition(
                  () => { document.getElementById('state').textContent = 'Location allowed'; },
                  () => { document.getElementById('state').textContent = 'Location denied'; });
                </script>
                """))
        case "/login":
            return ("200 OK", html("Plain Login", """
                <h1>Sign In</h1>
                <form method="post" action="/a">
                  <p><input id="user" name="username" type="email" autocomplete="username" placeholder="Email"
                    style="font-size:20px;width:90%"></p>
                  <p><input id="pass" name="password" type="password" autocomplete="current-password"
                    placeholder="Password" style="font-size:20px;width:90%"></p>
                  <p><button style="font-size:20px">Sign In</button></p>
                </form>
                """))
        case "/cookie":
            // A site login stand-in: `?set` signs in with a cookie; the heading says whether this
            // website data store has it (profiles keep theirs apart).
            return ("200 OK", html("Plain Cookie", """
                <h1 id="state">Checking</h1>
                <script>
                if (location.search.includes('set')) document.cookie = 'plain=1; max-age=3600; path=/';
                document.getElementById('state').textContent = document.cookie.includes('plain=1') ? 'Signed In' : 'Signed Out';
                </script>
                """))
        case "/passkey":
            return ("200 OK", html("Plain Passkey", """
                <h1 id="state">Passkey</h1>
                <p><button id="go" style="font-size:22px;padding:12px 20px" onclick="
                  navigator.credentials.get({ publicKey: { challenge: new Uint8Array(32), timeout: 5000 } })
                    .then(() => { document.getElementById('state').textContent = 'Signed in'; })
                    .catch(e => { document.getElementById('state').textContent = 'Passkey ' + e.name; });
                ">Sign In with a Passkey</button></p>
                """))
        default:
            return ("404 Not Found", html("Not Found", "<h1>Not Found</h1>"))
        }
    }

    /// `/big`: WebEngineTests' `DarkPagesTests.bigPage`, built once.
    private static let bigPage: String = {
        let picture = "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'>"
            + "<rect width='10' height='10' fill='%2300aa00'/></svg>"
        var rules = ""
        for i in 0..<4_000 { rules += ".c\(i){color:#\(String(format: "%03x", i % 4096));margin:\(i % 7)px}\n" }
        var body = "<h1>Big Page</h1>"
        for i in 0..<3_000 {
            body += "<p class=c\(i % 4_000)>Paragraph \(i) with <a href='#\(i)'>a link</a> and some text to wrap.</p>"
            if i % 10 == 0 { body += "<div class=hero style='height:20px'></div>" }
        }
        return """
            <!doctype html><html><head><meta charset="utf-8">\
            <meta name="viewport" content="width=device-width, initial-scale=1"><title>Plain Big Page</title>\
            <style>body{background:#fff;color:#222} .hero{background-image:url("\(picture)")}
            \(rules)</style></head><body>\(body)</body></html>
            """
    }()

    private func styled(_ title: String, _ css: String, _ body: String, head: String = "") -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width, initial-scale=1">\(head)\
        <title>\(title)</title><style>body{font:17px -apple-system;line-height:1.5}\(css)</style>\
        </head><body>\(body)</body></html>
        """
    }

    private func html(_ title: String, _ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width, initial-scale=1">\
        <title>\(title)</title>\
        <style>body{font:17px -apple-system;margin:20px;line-height:1.5}a{font-size:20px}</style>\
        </head><body>\(body)</body></html>
        """
    }
}
