const parseViewport = str => str
    ?.split(/[,;\s]/) // NOTE: technically, only the comma is valid
    ?.filter(x => x)
    ?.map(x => x.split('=').map(x => x.trim()))

const getViewport = (doc, viewport) => {
    // use `viewBox` for SVG
    if (doc.documentElement.localName === 'svg') {
        const [, , width, height] = doc.documentElement
            .getAttribute('viewBox')?.split(/\s/) ?? []
        return { width, height }
    }

    // get `viewport` `meta` element
    const meta = parseViewport(doc.querySelector('meta[name="viewport"]')
        ?.getAttribute('content'))
    if (meta) return Object.fromEntries(meta)

    // fallback to book's viewport
    if (typeof viewport === 'string') return parseViewport(viewport)
    if (viewport) return viewport

    // if no viewport (possibly with image directly in spine), get image size
    const img = doc.querySelector('img')
    if (img) return { width: img.naturalWidth, height: img.naturalHeight }

    // just show *something*, i guess...
    console.warn(new Error('Missing viewport properties'))
    return { width: 1000, height: 2000 }
}

const easeOutSine = x => Math.sin((x * Math.PI) / 2)
// Finishes on time even if no animation frames come (a hidden or throttled
// view), so a turn never hangs half done.
const animate = (from, to, duration, ease, render) => new Promise(resolve => {
    let start
    let done = false
    const finish = () => {
        if (done) return
        done = true
        render(to)
        resolve()
    }
    const step = now => {
        if (done) return
        start ??= now
        const fraction = Math.min(1, (now - start) / duration)
        if (fraction >= 1) return finish()
        render(from + (to - from) * ease(fraction))
        requestAnimationFrame(step)
    }
    requestAnimationFrame(step)
    setTimeout(finish, duration + 120)
})

export class FixedLayout extends HTMLElement {
    #root = this.attachShadow({ mode: 'closed' })
    #observer = new ResizeObserver(() => this.#render())
    #spreads
    #index = -1
    defaultViewport
    spread
    #portrait = false
    #left
    #right
    #center
    #side
    // Horizontal offset of the shown spread while it slides with a finger or a
    // turn, applied to every frame as it is laid out.
    #offset = 0
    #drag = null
    #sliding = false
    // Scrolled mode: pages stacked top to bottom in one scrolling column.
    #scroller = null
    #pages = []
    #scrollFrame = 0
    #leftScrolledAt = 0
    static observedAttributes = ['flow']
    constructor() {
        super()

        const sheet = new CSSStyleSheet()
        this.#root.adoptedStyleSheets = [sheet]
        sheet.replaceSync(`:host {
            width: 100%;
            height: 100%;
            display: flex;
            justify-content: center;
            align-items: center;
        }`)

        this.#observer.observe(this)
        this.#listenForTouch(this)
    }
    async #createFrame(position, { index, src }, parent = this.#root) {
        const element = document.createElement('div')
        const iframe = document.createElement('iframe')
        element.append(iframe)
        Object.assign(iframe.style, {
            border: '0',
            display: 'none',
            overflow: 'hidden',
        })
        // `allow-scripts` is needed for events because of WebKit bug
        // https://bugs.webkit.org/show_bug.cgi?id=218086
        iframe.setAttribute('sandbox', 'allow-same-origin allow-scripts')
        iframe.setAttribute('scrolling', 'no')
        iframe.setAttribute('part', 'filter')
        parent.append(element)
        if (!src) return { blank: true, element, iframe }
        return new Promise(resolve => {
            const onload = () => {
                iframe.removeEventListener('load', onload)
                const doc = iframe.contentDocument
                doc.position = position
                this.#listenForTouch(doc)
                iframe.__index = index
                this.dispatchEvent(new CustomEvent('load', { detail: { doc, index } }))
                // The overlayer lives inside the page document: annotations are
                // drawn in the page's own coordinates, and the frame's scale
                // transform then applies to them as it does to the text.
                this.dispatchEvent(new CustomEvent('create-overlayer', {
                    detail: {
                        doc, index,
                        attach: overlayer => {
                            iframe.__overlayer = overlayer
                            ;(doc.body ?? doc.documentElement).append(overlayer.element)
                        },
                    },
                }))
                const { width, height } = getViewport(doc, this.defaultViewport)
                resolve({
                    element, iframe,
                    width: parseFloat(width),
                    height: parseFloat(height),
                })
            }
            iframe.addEventListener('load', onload)
            iframe.src = src
        })
    }
    #render(side = this.#side) {
        if (this.#scroller) return this.#relayoutScrolled()
        if (!side) return
        const left = this.#left ?? {}
        const right = this.#center ?? this.#right
        const target = side === 'left' ? left : right
        const { width, height } = this.getBoundingClientRect()
        const portrait = this.spread !== 'both' && this.spread !== 'portrait'
            && height > width
        this.#portrait = portrait
        const blankWidth = left.width ?? right.width
        const blankHeight = left.height ?? right.height

        const scale = portrait || this.#center
            ? Math.min(
                width / (target.width ?? blankWidth),
                height / (target.height ?? blankHeight))
            : Math.min(
                width / ((left.width ?? blankWidth) + (right.width ?? blankWidth)),
                height / Math.max(
                    left.height ?? blankHeight,
                    right.height ?? blankHeight))

        const transform = frame => {
            const { element, iframe, width, height, blank } = frame
            iframe.contentDocument.scale = scale
            Object.assign(iframe.style, {
                width: `${width}px`,
                height: `${height}px`,
                transform: `scale(${scale})`,
                transformOrigin: 'top left',
                display: blank ? 'none' : 'block',
            })
            // Annotations restored while the frame was still hidden had no layout
            // to measure; now that it is shown, measure them again.
            if (!blank) iframe.__overlayer?.redraw()
            Object.assign(element.style, {
                width: `${(width ?? blankWidth) * scale}px`,
                height: `${(height ?? blankHeight) * scale}px`,
                overflow: 'hidden',
                display: 'block',
            })
            element.style.transform = this.#offset ? `translateX(${this.#offset}px)` : ''
            if (portrait && frame !== target) {
                element.style.display = 'none'
            }
        }
        if (this.#center) {
            transform(this.#center)
        } else {
            transform(left)
            transform(right)
        }
    }
    async #showSpread({ left, right, center, side }) {
        this.#root.replaceChildren()
        this.#left = null
        this.#right = null
        this.#center = null
        if (center) {
            this.#center = await this.#createFrame('center', center)
            this.#side = 'center'
            this.#render()
        } else {
            this.#left = await this.#createFrame('left', left)
            this.#right = await this.#createFrame('right', right)
            this.#side = this.#left.blank ? 'right'
                : this.#right.blank ? 'left' : side
            this.#render()
        }
    }
    #goLeft() {
        if (this.#center || this.#left?.blank) return
        if (this.#portrait && this.#left?.element?.style?.display === 'none') {
            this.#right.element.style.display = 'none'
            this.#left.element.style.display = 'block'
            this.#side = 'left'
            this.#left.iframe.__overlayer?.redraw()
            return true
        }
    }
    #goRight() {
        if (this.#center || this.#right?.blank) return
        if (this.#portrait && this.#right?.element?.style?.display === 'none') {
            this.#left.element.style.display = 'none'
            this.#right.element.style.display = 'block'
            this.#side = 'right'
            this.#right.iframe.__overlayer?.redraw()
            return true
        }
    }
    open(book) {
        this.book = book
        const { rendition } = book
        this.spread = rendition?.spread
        this.defaultViewport = rendition?.viewport

        const rtl = book.dir === 'rtl'
        const ltr = !rtl
        this.rtl = rtl

        if (rendition?.spread === 'none')
            this.#spreads = book.sections.map(section => ({ center: section }))
        else this.#spreads = book.sections.reduce((arr, section) => {
            const last = arr[arr.length - 1]
            const { linear, pageSpread } = section
            if (linear === 'no') return arr
            const newSpread = () => {
                const spread = {}
                arr.push(spread)
                return spread
            }
            if (pageSpread === 'center') {
                const spread = last.left || last.right ? newSpread() : last
                spread.center = section
            }
            else if (pageSpread === 'left') {
                const spread = last.center || last.left || ltr ? newSpread() : last
                spread.left = section
            }
            else if (pageSpread === 'right') {
                const spread = last.center || last.right || rtl ? newSpread() : last
                spread.right = section
            }
            else if (ltr) {
                if (last.center || last.right) newSpread().left = section
                else if (last.left) last.right = section
                else last.left = section
            }
            else {
                if (last.center || last.left) newSpread().right = section
                else if (last.right) last.left = section
                else last .right = section
            }
            return arr
        }, [{}])
    }
    get index() {
        if (this.#scroller) return this.#index
        const spread = this.#spreads[this.#index]
        // Between leaving scrolled mode and showing a spread again.
        if (!spread) return this.#leftScrolledAt
        const section = spread?.center ?? (this.#side === 'left'
            ? spread.left ?? spread.right : spread.right ?? spread.left)
        return this.book.sections.indexOf(section)
    }
    #reportLocation(reason) {
        this.dispatchEvent(new CustomEvent('relocate', { detail:
            { reason, range: null, index: this.index, fraction: 0, size: 1 } }))
    }
    getSpreadOf(section) {
        const spreads = this.#spreads
        for (let index = 0; index < spreads.length; index++) {
            const { left, right, center } = spreads[index]
            if (left === section) return { index, side: 'left' }
            if (right === section) return { index, side: 'right' }
            if (center === section) return { index, side: 'center' }
        }
    }
    async goToSpread(index, side, reason) {
        if (index < 0 || index > this.#spreads.length - 1) return
        if (index === this.#index) {
            this.#render(side)
            return
        }
        this.#index = index
        const spread = this.#spreads[index]
        if (spread.center) {
            const index = this.book.sections.indexOf(spread.center)
            const src = await spread.center?.load?.()
            await this.#showSpread({ center: { index, src } })
        } else {
            const indexL = this.book.sections.indexOf(spread.left)
            const indexR = this.book.sections.indexOf(spread.right)
            const srcL = await spread.left?.load?.()
            const srcR = await spread.right?.load?.()
            const left = { index: indexL, src: srcL }
            const right = { index: indexR, src: srcR }
            await this.#showSpread({ left, right, side })
        }
        this.#reportLocation(reason)
    }
    async select(target) {
        await this.goTo(target)
        // TODO
    }
    async goTo(target) {
        const { book } = this
        const resolved = await target
        const section = book.sections[resolved.index]
        if (!section) return
        if (this.#isScrolled) {
            if (!this.#scroller) return this.#enterScrolled(resolved.index)
            return this.#scrollToIndex(resolved.index)
        }
        const { index, side } = this.getSpreadOf(section)
        await this.goToSpread(index, side)
    }
    attributeChangedCallback(name, old, value) {
        if (name === 'flow' && old !== value) this.#setScrolled(value === 'scrolled')
    }
    get #isScrolled() {
        return this.getAttribute('flow') === 'scrolled'
    }
    async next() {
        if (this.#isScrolled) return this.#scrollByScreen(1)
        return this.#sliding ? this.#step(true) : this.#turn(true)
    }
    async prev() {
        if (this.#isScrolled) return this.#scrollByScreen(-1)
        return this.#sliding ? this.#step(false) : this.#turn(false)
    }
    async #step(forward) {
        if (forward) {
            const s = this.rtl ? this.#goLeft() : this.#goRight()
            if (s) this.#reportLocation('page')
            else return this.goToSpread(this.#index + 1, this.rtl ? 'right' : 'left', 'page')
        } else {
            const s = this.rtl ? this.#goRight() : this.#goLeft()
            if (s) this.#reportLocation('page')
            else return this.goToSpread(this.#index - 1, this.rtl ? 'left' : 'right', 'page')
        }
    }
    #setOffset(x) {
        this.#offset = x
        for (const element of this.#root.children)
            element.style.transform = x ? `translateX(${x}px)` : ''
    }
    #animateOffset(to, duration) {
        return animate(this.#offset, to, duration, easeOutSine, x => this.#setOffset(x))
    }
    // Turns a page; with the slide style the page moves out and the next one
    // comes in from the other side. The curl is drawn by Flutter, so it turns
    // instantly here.
    async #turn(forward) {
        // Nothing on screen yet (opening the book): just show the page.
        const slide = this.hasAttribute('animated') && !this.hasAttribute('curl')
            && this.#index >= 0
        if (!slide) {
            this.#setOffset(0)
            return this.#step(forward)
        }
        this.#sliding = true
        try {
            const { width } = this.getBoundingClientRect()
            const sign = forward !== !!this.rtl ? -1 : 1
            const before = [this.#index, this.#side]
            await this.#animateOffset(sign * width, 170)
            this.#offset = -sign * width
            await this.#step(forward)
            const moved = this.#index !== before[0] || this.#side !== before[1]
            // Nothing to turn to: the page comes back from where it went.
            this.#setOffset(moved ? -sign * width : sign * width)
            await this.#animateOffset(0, 200)
        } finally {
            this.#sliding = false
        }
    }
    #listenForTouch(target) {
        const options = { passive: false }
        target.addEventListener('touchstart', e => this.#onTouchStart(e), options)
        target.addEventListener('touchmove', e => this.#onTouchMove(e), options)
        target.addEventListener('touchend', e => this.#onTouchEnd(e), options)
        target.addEventListener('touchcancel', e => this.#onTouchEnd(e), options)
    }
    #zoomed() {
        return (globalThis.visualViewport?.scale ?? 1) > 1.05
    }
    // Touches are reported with the same events and state as the paginator's,
    // so the reader's gestures (the curl, the bookmark pull) work on these pages.
    #emitTouch(type, touch, state) {
        this.dispatchEvent(new CustomEvent(type, {
            detail: { touch, touchState: state },
            bubbles: true,
            composed: true,
        }))
    }
    #onTouchStart(e) {
        // A frame's touches reach both its document and this element; the
        // document's listener handles them.
        if (e.__fxlSeen) return
        e.__fxlSeen = true
        if (this.#isScrolled || this.#zoomed() || this.#sliding || e.touches.length > 1) {
            this.#drag = null
            return
        }
        const touch = e.changedTouches[0]
        this.#drag = {
            startTouch: { x: touch.screenX, y: touch.screenY },
            x: touch.screenX, t: e.timeStamp, vx: 0, vy: 0,
            delta: { x: 0, y: 0 }, direction: 'none', pinched: false,
        }
        this.#emitTouch('doctouchstart', touch, this.#drag)
    }
    #onTouchMove(e) {
        if (e.__fxlSeen) return
        e.__fxlSeen = true
        const state = this.#drag
        if (!state) return
        if (e.touches.length > 1 || this.#zoomed()) {
            state.pinched = true
            return
        }
        const touch = e.changedTouches[0]
        state.delta.x = touch.screenX - state.startTouch.x
        state.delta.y = touch.screenY - state.startTouch.y
        const dt = e.timeStamp - state.t || 16.7
        // As in the paginator: positive while moving left.
        state.vx = (state.x - touch.screenX) / dt
        state.x = touch.screenX
        state.t = e.timeStamp
        if (state.direction === 'none' && Math.hypot(state.delta.x, state.delta.y) > 8)
            state.direction = Math.abs(state.delta.x) > Math.abs(state.delta.y)
                ? 'horizontal' : 'vertical'
        this.#emitTouch('doctouchmove', touch, state)
        if (state.direction !== 'horizontal') return
        e.preventDefault()
        if (this.hasAttribute('animated') && !this.hasAttribute('curl'))
            this.#setOffset(state.delta.x)
    }
    async #onTouchEnd(e) {
        if (e.__fxlSeen) return
        e.__fxlSeen = true
        const state = this.#drag
        this.#drag = null
        if (!state) return
        this.#emitTouch('doctouchend', e.changedTouches[0], state)
        if (state.pinched || state.direction !== 'horizontal' || this.hasAttribute('curl')) {
            if (this.#offset) await this.#animateOffset(0, 160)
            return
        }
        const dx = state.delta.x
        const velocity = -state.vx
        const { width } = this.getBoundingClientRect()
        const flicked = Math.abs(velocity) > 0.3 && Math.sign(velocity) === Math.sign(dx)
        if (Math.abs(dx) < 20 || (Math.abs(dx) < width * 0.25 && !flicked)) {
            if (this.#offset) await this.#animateOffset(0, 160)
            return
        }
        const forward = this.rtl ? dx > 0 : dx < 0
        if (!this.hasAttribute('animated')) return this.#step(forward)
        this.#sliding = true
        try {
            // Carry on from where the finger left the page.
            const sign = forward !== !!this.rtl ? -1 : 1
            const before = [this.#index, this.#side]
            await this.#animateOffset(sign * width, 140)
            this.#offset = -sign * width
            await this.#step(forward)
            const moved = this.#index !== before[0] || this.#side !== before[1]
            this.#setOffset(moved ? -sign * width : sign * width)
            await this.#animateOffset(0, 200)
        } finally {
            this.#sliding = false
        }
    }

    // Scrolled mode.
    #setScrolled(scrolled) {
        if (!this.book) return
        if (scrolled && !this.#scroller) {
            // Nothing shown yet: goTo will open in this mode.
            if (this.#index < 0) return
            this.#enterScrolled(this.index)
        } else if (!scrolled && this.#scroller) {
            const index = this.#index
            this.#leftScrolledAt = Math.max(0, index)
            this.#scroller = null
            this.#pages = []
            this.#root.replaceChildren()
            this.#index = -1
            this.#setOffset(0)
            if (this.book.sections[index]) this.goTo({ index })
        }
    }
    #enterScrolled(index) {
        const scroller = document.createElement('div')
        Object.assign(scroller.style, {
            width: '100%', height: '100%',
            overflowX: 'hidden', overflowY: 'auto',
            webkitOverflowScrolling: 'touch',
        })
        this.#root.replaceChildren(scroller)
        this.#left = this.#right = this.#center = null
        this.#offset = 0
        this.#index = Math.max(0, index)
        this.#scroller = scroller
        this.#pages = this.book.sections.map((section, i) => {
            const element = document.createElement('div')
            Object.assign(element.style, {
                position: 'relative', overflow: 'hidden', margin: '0 auto 6px',
            })
            if (section.linear === 'no') element.style.display = 'none'
            scroller.append(element)
            return { section, index: i, element, frame: null, loading: null, width: 0, height: 0 }
        })
        this.#layoutScrolled()
        scroller.addEventListener('scroll', () => {
            if (this.#scrollFrame) return
            this.#scrollFrame = requestAnimationFrame(() => {
                this.#scrollFrame = 0
                this.#loadNearby()
                this.#reportScrolled('scroll')
            })
        }, { passive: true })
        return this.#scrollToIndex(this.#index)
    }
    #layoutScrolled() {
        const { width } = this.getBoundingClientRect()
        const known = this.#pages.find(page => page.width)
        const ratio = known ? known.height / known.width : Math.SQRT2
        for (const page of this.#pages) {
            const scale = page.width ? width / page.width : 0
            page.element.style.width = `${width}px`
            page.element.style.height = `${page.width ? page.height * scale : width * ratio}px`
            if (page.frame) Object.assign(page.frame.iframe.style, {
                width: `${page.width}px`, height: `${page.height}px`,
                transform: `scale(${scale})`, transformOrigin: 'top left',
                display: 'block',
            })
        }
    }
    // Lays pages out again without moving what is on screen.
    #relayoutScrolled() {
        const at = this.#visiblePage()
        const anchor = at ? this.#pages[at.index].element : null
        const before = anchor?.offsetTop
        this.#layoutScrolled()
        if (anchor && anchor.offsetTop !== before)
            this.#scroller.scrollTop += anchor.offsetTop - before
    }
    #visiblePage() {
        const scroller = this.#scroller
        if (!scroller) return null
        const line = scroller.scrollTop + scroller.clientHeight * 0.3
        for (const page of this.#pages) {
            const { element } = page
            if (element.style.display === 'none') continue
            if (element.offsetTop + element.offsetHeight > line) {
                const fraction = (line - element.offsetTop) / Math.max(1, element.offsetHeight)
                return { index: page.index, fraction: Math.min(1, Math.max(0, fraction)) }
            }
        }
        return null
    }
    #reportScrolled(reason) {
        const at = this.#visiblePage()
        if (!at) return
        this.#index = at.index
        const { element } = this.#pages[at.index]
        const height = Math.max(1, element.offsetHeight)
        // Progress is measured like the paginator's: where the top of the screen
        // is within the page, and how much of the page one screen shows, at most
        // all of it. The page itself is picked by a line a third of the way down.
        const top = (this.#scroller.scrollTop - element.offsetTop) / height
        this.dispatchEvent(new CustomEvent('relocate', { detail: {
            reason, range: null, index: at.index,
            fraction: Math.min(1, Math.max(0, top)),
            size: Math.min(1, this.#scroller.clientHeight / height),
        } }))
    }
    #loadNearby() {
        const scroller = this.#scroller
        if (!scroller) return
        const top = scroller.scrollTop - scroller.clientHeight
        const bottom = scroller.scrollTop + 2 * scroller.clientHeight
        const keep = 4 * scroller.clientHeight
        for (const page of this.#pages) {
            const { element } = page
            if (element.style.display === 'none') continue
            const pageTop = element.offsetTop
            const pageBottom = pageTop + element.offsetHeight
            if (pageBottom >= top && pageTop <= bottom) this.#loadPage(page)
            else if (page.frame && (pageBottom < scroller.scrollTop - keep
                || pageTop > scroller.scrollTop + scroller.clientHeight + keep)) {
                page.frame.element.remove()
                page.frame = null
            }
        }
    }
    #loadPage(page) {
        if (page.frame) return Promise.resolve()
        page.loading ??= (async () => {
            const src = await page.section.load?.()
            if (!src || this.#scroller === null || !page.element.isConnected) return
            const frame = await this.#createFrame('center', { index: page.index, src }, page.element)
            if (!page.element.isConnected) return
            page.frame = frame
            page.width = frame.width
            page.height = frame.height
            this.#relayoutScrolled()
            frame.iframe.__overlayer?.redraw()
        })().finally(() => { page.loading = null })
        return page.loading
    }
    async #scrollToIndex(index) {
        const page = this.#pages[index]
        if (!page || !this.#scroller) return
        await this.#loadPage(page)
        this.#scroller.scrollTop = page.element.offsetTop
        this.#loadNearby()
        this.#reportScrolled('page')
    }
    #scrollByScreen(direction) {
        const scroller = this.#scroller
        // The reader opens a book without a saved position by asking for the
        // next page; in scrolled mode that means showing the first one.
        if (!scroller) return this.book ? this.#enterScrolled(0) : undefined
        scroller.scrollBy({
            top: direction * scroller.clientHeight * 0.9,
            behavior: this.hasAttribute('animated') ? 'smooth' : 'auto',
        })
    }
    // Changing the turn style re-lays the book out by moving a section away and
    // back; the reader expects these, as the paginator provides them.
    #adjacent(step) {
        const count = this.book?.sections?.length ?? 0
        return Math.min(Math.max(0, this.index + step), Math.max(0, count - 1))
    }
    prevSection() {
        return Promise.resolve(this.goTo({ index: this.#adjacent(-1) }))
    }
    nextSection() {
        return Promise.resolve(this.goTo({ index: this.#adjacent(1) }))
    }
    getContents() {
        return Array.from(this.#root.querySelectorAll('iframe'), frame => ({
            doc: frame.contentDocument,
            index: frame.__index,
            overlayer: frame.__overlayer,
        }))
    }
    destroy() {
        this.#observer.unobserve(this)
        if (this.#scrollFrame) cancelAnimationFrame(this.#scrollFrame)
    }
}

customElements.define('foliate-fxl', FixedLayout)
