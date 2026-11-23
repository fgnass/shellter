# Changelog

## [0.2.0](https://github.com/fgnass/shellter/compare/v0.1.0...v0.2.0) (2026-11-23)


### Features

* a bell hint at the edge of the sidebar shows tabs that need input but are scrolled out of view; the selected tab scrolls into view; a line shows where a dragged project lands ([f4fcf6b](https://github.com/fgnass/shellter/commit/f4fcf6becedce4437be7690c31ac8c48a39f0b03))
* choose a project color by hand from the project header's context menu ([39d4d37](https://github.com/fgnass/shellter/commit/39d4d37480045d05761c45598da4ef776142274e))
* Compact Mode (⇧⌘K) shows the bottom rows of the selected tab in a small panel above all apps ([e280f87](https://github.com/fgnass/shellter/commit/e280f87bbbfeb4823887fa4696fedcfe0408ebb0))
* copy cleanup also handles Codex and Antigravity output ([59f3c7a](https://github.com/fgnass/shellter/commit/59f3c7a69fdb6146627e2818dfd8d71ba64fd47c))
* Copy in agent tabs removes markers, quote bars and the line breaks of the agent UI; Copy Raw Text and a context menu ([2c8a33e](https://github.com/fgnass/shellter/commit/2c8a33e6aa5b107290f12f24cf08325fba67136c))
* floating glass sidebar style for macOS 26; sidebar rows fade out under the title bar and the New Tab button ([dc1c529](https://github.com/fgnass/shellter/commit/dc1c52906e0b5512b1dfa28c42a3369b373847ba))
* list the windows of other apps as rows below the project's tabs, not as icons in the tab row ([f146188](https://github.com/fgnass/shellter/commit/f146188b0da90260748f91dab4d5e7ab4ca2261b))
* name branched sessions, so the fork is easy to tell from the original ([5c3b051](https://github.com/fgnass/shellter/commit/5c3b051ecb97e1a554bd31d8254968f037baa89b))
* show the windows of other apps that belong to a tab, a click brings them to the front ([fc7f6d6](https://github.com/fgnass/shellter/commit/fc7f6d696b001e25540737daae89e32964466f9b))
* start a fresh agent session next to a tab or in a project (⌥⌘T, context menus) ([fd81ac2](https://github.com/fgnass/shellter/commit/fd81ac2956062f77624d0fa1bf7ec35c2ccab3ef))
* support the Antigravity CLI (agy): icon, new sessions and resume by conversation ID ([eeaf4d4](https://github.com/fgnass/shellter/commit/eeaf4d42dc8ea2dbd91e025baf2e967aa0bbb592))
* the Dock icon shows the number of tabs that need input ([d0ff3e1](https://github.com/fgnass/shellter/commit/d0ff3e18e7d5dd26c05dad1f01a289a010a7c0a5))


### Bug Fixes

* create hidden terminals in their real size, so programs in background tabs do not draw narrow after a restart ([79778fc](https://github.com/fgnass/shellter/commit/79778fc748609d5d8af11d0fc4c91bd88106d3e5))
* in the lines layout, app icons of window rows are tinted in the project color ([9fdca9b](https://github.com/fgnass/shellter/commit/9fdca9bdc7a8b9b46dbf38bfc53aa301eaa38f71))
* in the lines layout, the project line ends at the last entry of a project ([856ed0b](https://github.com/fgnass/shellter/commit/856ed0bfb445589e53196295277e6ce90a5dea8e))
* lines use exactly the color of a letter icon or a chosen color, and the icon updates at once ([4d82afe](https://github.com/fgnass/shellter/commit/4d82afe192b46f6cc2cf88b2f32e81085b532552))
* project icons update when the icon file changes ([5dda956](https://github.com/fgnass/shellter/commit/5dda956e6dde32f2ae95c88ecb4cf231ec216a84))
* same terminal brightness in all sidebar styles; selected text keeps its color in editor themes ([49a5a4c](https://github.com/fgnass/shellter/commit/49a5a4ca26f8d87501fe4dad918104402c3eada8))
* the project color menu stays open while an agent works; the sidebar refreshes only for changes it shows ([6cf7079](https://github.com/fgnass/shellter/commit/6cf7079c98cbdb30aee2fa6fe57edebb7780f086))
* when several tabs of a project share an app window, its row opens the session of the tab that was active last ([615a381](https://github.com/fgnass/shellter/commit/615a381f00ed80c9a6f8da85d5a36db65e982172))
* window rows in the sidebar have one line, and in the lines layout the app icon sits on the project line like the agent icon of a tab ([f6b48c9](https://github.com/fgnass/shellter/commit/f6b48c9367e718860591638bf4e311e7ff075d6d))
