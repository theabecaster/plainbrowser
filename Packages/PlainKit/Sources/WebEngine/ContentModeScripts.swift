import Foundation

/// The page scripts behind a desktop/mobile switch. They run only when a switch is due (a fold
/// or unfold that changed the wanted mode), in Plain's own content world, never on every page.
nonisolated enum ContentModeScripts {
    /// Asks the page whether a reload would lose anything, which mode its document was really
    /// loaded in (a page from the back-forward cache keeps its own), and where it is scrolled to.
    /// Takes `topInset`: the height in CSS pixels the browser's bar covers at the top of the page.
    ///
    /// - Typed input: a text field, text area, select, checkbox or radio whose value differs from
    ///   what the page served, in the document, its open shadow roots or a same-origin frame, or a
    ///   page in `designMode`. Edits this can't compare (an editable area left after typing, a
    ///   closed shadow root, a cross-origin frame) are caught by every frame reporting its first
    ///   `input` event (`UserScripts.subframePressSource`); a cross-origin frame with the focus
    ///   counts as editing.
    /// - The anchor: the element under the top edge of the visible page, by id when it or an
    ///   ancestor has one, else by its child-index path from `body`, with how far into it the
    ///   edge was; plus the scroll fraction as a fallback.
    static let probe = """
        const textTypes = ['', 'text', 'search', 'email', 'url', 'tel', 'password', 'number', 'date',
          'datetime-local', 'month', 'week', 'time'];
        const roots = (doc) => {
          const found = [doc];
          for (const el of doc.querySelectorAll('*')) if (el.shadowRoot) found.push(...roots(el.shadowRoot));
          return found;
        };
        const changedIn = (root) => {
          if (root.designMode === 'on') return true;
          for (const el of root.querySelectorAll('input, textarea, select')) {
            const type = (el.type || '').toLowerCase();
            if (el.tagName === 'SELECT') {
              // With no option marked selected, a single select shows its first one.
              const options = Array.from(el.options);
              const marked = options.some((option) => option.defaultSelected);
              if (el.multiple || marked) {
                if (options.some((option) => option.selected !== option.defaultSelected)) return true;
              } else if (el.selectedIndex > 0) {
                return true;
              }
            } else if (type === 'checkbox' || type === 'radio') {
              if (el.checked !== el.defaultChecked) return true;
            } else if (el.tagName === 'TEXTAREA' || textTypes.includes(type)) {
              if (el.value !== el.defaultValue) return true;
            } else if (type === 'file' && el.files && el.files.length) {
              return true;
            }
          }
          for (const frame of root.querySelectorAll('iframe')) {
            try { if (frame.contentDocument && changed(frame.contentDocument)) return true; } catch (e) {}
          }
          return false;
        };
        const changed = (doc) => roots(doc).some(changedIn);
        const editingIn = (doc) => {
          const el = doc.activeElement;
          if (!el) return false;
          // Focus inside a web component: follow it into an open shadow root; a closed one can't
          // be read, so a focused custom element counts as editing.
          if (el.shadowRoot && el.shadowRoot.activeElement) return editingIn(el.shadowRoot);
          if (el.tagName.includes('-') && !el.shadowRoot) return true;
          if (el.isContentEditable) return true;
          if (el.tagName === 'TEXTAREA') return true;
          if (el.tagName === 'INPUT') {
            return !['button', 'submit', 'reset', 'image', 'hidden', 'checkbox', 'radio', 'range', 'color', 'file']
              .includes((el.type || '').toLowerCase());
          }
          if (el.tagName === 'IFRAME') {
            try { return el.contentDocument ? editingIn(el.contentDocument) : true; } catch (e) { return true; }
          }
          return false;
        };
        \(placeSource)
        return {
          typed: changed(document),
          editing: editingIn(document),
          desktop: navigator.platform === 'MacIntel',
          anchor,
          fraction: range > 0 ? scrollY / range : 0,
          scrolled: scrollY > 0
        };
        """

    /// Where the reader is: the element under the top edge of the visible page (not a sticky or
    /// fixed header), by id when it or an ancestor has one, else by its child-index path from
    /// `body`, with how far into it the edge was; plus the scroll fraction as a fallback. Defines
    /// `anchor`, `scroller` and `range`; takes `topInset`.
    static let placeSource = """
        const edge = Math.max(0, topInset) + 1;
        // The first element under the edge that scrolls with the page: a sticky or fixed header
        // (or anything inside one) stays put, so it can't tell where the reader was.
        const pinned = (node) => {
          for (let n = node; n && n !== document.body && n !== document.documentElement; n = n.parentElement) {
            const position = getComputedStyle(n).position;
            if (position === 'fixed' || position === 'sticky') return true;
          }
          return false;
        };
        // The edge can fall in the gap between two blocks (a margin is the body's): look a little
        // lower for content, and remember how far above it the edge was.
        const content = (node) => node !== document.body && node !== document.documentElement && !pinned(node);
        let el = null;
        for (const dy of [0, 8, 16, 32, 48, 64, 96]) {
          const y = Math.min(edge + dy, innerHeight - 1);
          el = document.elementsFromPoint(innerWidth / 2, y).find(content) || null;
          if (el) break;
        }
        let anchor = null;
        if (el && el !== document.body && el !== document.documentElement) {
          const rect = el.getBoundingClientRect();
          // Negative when the edge is in the gap above the element.
          const into = rect.height > 0 ? Math.min(1, (edge - rect.top) / rect.height) : 0;
          let id = null, path = [], node = el;
          while (node && node !== document.body) {
            if (node.id) { id = node.id; break; }
            const parent = node.parentElement;
            if (!parent) break;
            path.unshift(Array.prototype.indexOf.call(parent.children, node));
            node = parent;
          }
          anchor = { id, path, into, text: (el.textContent || '').trim().slice(0, 40) };
        }
        const scroller = document.scrollingElement || document.documentElement;
        const range = scroller.scrollHeight - innerHeight;
        """

    /// Where the reader is, read when a pane starts to change size (before the fold reflows the
    /// page), so a switch afterwards puts back the place the reader saw, not the reflowed one.
    static let place = """
        \(placeSource)
        return { anchor, fraction: range > 0 ? scrollY / range : 0, scrolled: scrollY > 0,
          width: innerWidth, y: Math.round(scrollY) };
        """

    /// Puts the page back where `probe` found it: the anchor's element under the top edge when
    /// it is still there with the same text, else the same scroll fraction. Takes `topInset`,
    /// `anchor` and `fraction` as `probe` returned them. Waits two frames, so WebKit's own
    /// restore of the reloaded page has run and the result is painted before the picture over
    /// the page fades.
    static let restore = """
        const scroller = document.scrollingElement || document.documentElement;
        const edge = Math.max(0, topInset) + 1;
        let target = null;
        if (anchor) {
          let node = anchor.id ? document.getElementById(anchor.id) : document.body;
          for (const index of anchor.path) { node = node && node.children[index]; }
          if (node && (node.textContent || '').trim().slice(0, 40) === anchor.text) {
            const rect = node.getBoundingClientRect();
            target = scrollY + rect.top + rect.height * anchor.into - edge;
          }
        }
        if (target === null) target = fraction * Math.max(0, scroller.scrollHeight - innerHeight);
        scrollTo(0, Math.max(0, target));
        await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
        return scrollY;
        """
}
