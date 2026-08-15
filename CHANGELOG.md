# [2.5.0](https://github.com/vladdoster/hammerspoon-configuration/compare/v2.4.0...v2.5.0) (2026-08-15)


### Features

* **init:** enable FocusBorder at startup ([ff798d9](https://github.com/vladdoster/hammerspoon-configuration/commit/ff798d9be38e4e630627c166cc31087b8eb7867a))

# [2.4.0](https://github.com/vladdoster/hammerspoon-configuration/compare/v2.3.0...v2.4.0) (2026-08-15)


### Bug Fixes

* **battery:** avoid the IOBluetooth deadlock that aborts Hammerspoon ([20d00b5](https://github.com/vladdoster/hammerspoon-configuration/commit/20d00b56536494249b06d7b93cf6368bba6cab4e))
* **battery:** stop the menubar menu crashing on click ([e448e58](https://github.com/vladdoster/hammerspoon-configuration/commit/e448e5833888ac9cf8223c9b8a7898dbed8869b4)), closes [#1](https://github.com/vladdoster/hammerspoon-configuration/issues/1)


### Features

* **battery:** show charge percentage in the menubar title ([74354db](https://github.com/vladdoster/hammerspoon-configuration/commit/74354db7f76b38f8afd54fb7adafcbc26e67d9b1))
* **spoons:** add ClipboardHistory ([2b6be40](https://github.com/vladdoster/hammerspoon-configuration/commit/2b6be400f0fab524254e14f157b594d715a756ff))

# [2.3.0](https://github.com/vladdoster/hammerspoon-configuration/compare/v2.2.0...v2.3.0) (2026-08-15)


### Bug Fixes

* app-toggler logging & window commands ([0f53ddf](https://github.com/vladdoster/hammerspoon-configuration/commit/0f53ddfc0a7b05a190a8120913b905dacd950851))
* **build:** ext modules ([aa47d5c](https://github.com/vladdoster/hammerspoon-configuration/commit/aa47d5c1cba99d27efa0ceaf848d907a09dadb40))
* center window in app-toggle ext ([6be2311](https://github.com/vladdoster/hammerspoon-configuration/commit/6be23111723cfdace9ee1449b297872bf0fe02cb))
* compile hs modules make target ([369c2b5](https://github.com/vladdoster/hammerspoon-configuration/commit/369c2b5871c7d95a13e30fb09f43c9584f69a6bd))
* format lua files ([0a212fe](https://github.com/vladdoster/hammerspoon-configuration/commit/0a212fe08ef199594bba3546fcbd328a54a0c75b))
* install makefile target ([231101c](https://github.com/vladdoster/hammerspoon-configuration/commit/231101caf6a367d1aa01bfbf231d3f43873152c8))
* make targets in README.md ([d6a9a47](https://github.com/vladdoster/hammerspoon-configuration/commit/d6a9a47493311f3f32915e9562514e57b659fd21))
* migrate to hs.menubar module ([6e9341c](https://github.com/vladdoster/hammerspoon-configuration/commit/6e9341c48e7c8dadff148f782d28ebe08c5873bd))
* set volume increment from 3% to 2% ([da4fefb](https://github.com/vladdoster/hammerspoon-configuration/commit/da4fefb8eb75af76ae8c73d5ed2c8cdfd9dbe8b3))
* **spoons:** correct eight logic bugs ([064a5c7](https://github.com/vladdoster/hammerspoon-configuration/commit/064a5c78c176af6ec751edddb74664f5742358fc))
* **spoons:** update gitmodules ([f9c1a2f](https://github.com/vladdoster/hammerspoon-configuration/commit/f9c1a2f76a802881b45c79a4babadd2ec8a28bb2))
* stop make clean deleting hand-written Spoons ([265604a](https://github.com/vladdoster/hammerspoon-configuration/commit/265604a43bc7fae381cc7256fdeecc59bae9d6d3))
* use hs logger in battery ext ([f92c74e](https://github.com/vladdoster/hammerspoon-configuration/commit/f92c74e2320dc74b46f5e13858d7e052e378506f))


### Features

* modal app launcher via ctrl+opt+cmd+return ([be09512](https://github.com/vladdoster/hammerspoon-configuration/commit/be09512f73b4f680fd5f81d2d85b79b656ab2d89))
* Safari ignores escape to fix fullscreen ([86b4871](https://github.com/vladdoster/hammerspoon-configuration/commit/86b48717748341e8ea3fe6c32644358459d22a1d))
* track hand-written Spoons as source ([14c96b0](https://github.com/vladdoster/hammerspoon-configuration/commit/14c96b05132960f4b683b70e1b2d5b0937ff77e2))
* update asmHammerspoon submodule ([9e7f0ef](https://github.com/vladdoster/hammerspoon-configuration/commit/9e7f0ef2588b3cb4fffb268fd715af13eb7ba1b8))

# [2.2.0](https://github.com/vladdoster/hammerspoon-configuration/compare/v2.1.0...v2.2.0) (2023-04-08)


### Bug Fixes

* check if space did not change ([e925c8f](https://github.com/vladdoster/hammerspoon-configuration/commit/e925c8f406fd6672c0d1fbcee44926f06e9dc3aa))
* disable window manager ([a2f9bd6](https://github.com/vladdoster/hammerspoon-configuration/commit/a2f9bd61864115e1deb064430975408ace8a7dc1))
* handle focusing fullscreen apps ([6730bc3](https://github.com/vladdoster/hammerspoon-configuration/commit/6730bc372c35e2666b5493edcc141f76d912f440))
* remove duplicated code in app-toggle.lua ([a51c21b](https://github.com/vladdoster/hammerspoon-configuration/commit/a51c21b8122ae5d7ce9d1fd9db91cf6176acdba5))


### Features

* add smartLaunchOrFocus keybinds ([1c5a129](https://github.com/vladdoster/hammerspoon-configuration/commit/1c5a129db2600e6b9017e694b03af956f0dcfbf1))
* add vim modelines ([a614264](https://github.com/vladdoster/hammerspoon-configuration/commit/a61426467cbce1a1f8d9e4a1169d6aa4be2ad0de))

# [2.1.0](https://github.com/vladdoster/hammerspoon-configuration/compare/v2.0.1...v2.1.0) (2023-04-03)


### Bug Fixes

* hide clipboard history in menu bar ([a5931b5](https://github.com/vladdoster/hammerspoon-configuration/commit/a5931b56c22ebbc09cade5f75a4377dbdf930d85))
* remove local semantic release configuration  ([412a2cf](https://github.com/vladdoster/hammerspoon-configuration/commit/412a2cf66d29bffe7cc5d0ba626667081af53306))


### Features

* quickly toggle terminal and safari windows ([dbe37fb](https://github.com/vladdoster/hammerspoon-configuration/commit/dbe37fb82025e14e1a1477949469023c833f264a))

## [2.0.1](https://github.com/vladdoster/hammerspoon-configuration/compare/v2.0.0...v2.0.1) (2022-10-04)


### docs

* add Make targets & add release status badge ([32e5c4a](https://github.com/vladdoster/hammerspoon-configuration/commit/32e5c4a30d3e0ddb2c2085bea4c374ced0e4ee8c))

### fix

* clean Make target doesnt delete submodules ([985adde](https://github.com/vladdoster/hammerspoon-configuration/commit/985adde3ab64597a2b54e2b8d05a306041857851))

### maint

* refactor spoons extension ([6d003b4](https://github.com/vladdoster/hammerspoon-configuration/commit/6d003b44bf71f3e412da831ee3c2c86529c89a4c))

# [2.0.0](https://github.com/vladdoster/hammerspoon-configuration/compare/v1.6.0...v2.0.0) (2022-08-14)


### refactor

* Makefile targets & add clean target ([b3bb45c](https://github.com/vladdoster/hammerspoon-configuration/commit/b3bb45cbe5a4d9e4ebf631aba66469cd02b908c8))

# [1.6.0](https://github.com/vladdoster/hammerspoon-configuration/compare/v1.5.0...v1.6.0) (2022-08-07)


### feat

* add MouseFollowsFocus spoon ([742556c](https://github.com/vladdoster/hammerspoon-configuration/commit/742556c6d27581f2624aa60d07445bf1860a884e))

### fix

* command checks & Make foreach loop ([7262f58](https://github.com/vladdoster/hammerspoon-configuration/commit/7262f5898bbb6bf83181174c858ea58a72fcffcc))

### maint

* improve low battery notifications ([c1f0561](https://github.com/vladdoster/hammerspoon-configuration/commit/c1f0561ba1c7f1ffa0f7285e8ebae50e2f685972))

### style

* update format Make targets and format code ([775e1a5](https://github.com/vladdoster/hammerspoon-configuration/commit/775e1a5839db6e175178829881649f8fd0006ccc))

# [1.5.0](https://github.com/vladdoster/hammerspoon-configuration/compare/v1.4.0...v1.5.0) (2022-06-25)


### feat

* add less-laggy clipboard HS module ([df11d2a](https://github.com/vladdoster/hammerspoon-configuration/commit/df11d2a52d1db6925697f86a0a462016e36ac6c1))
* set brightness to 100 on pwr src change ([39b59d6](https://github.com/vladdoster/hammerspoon-configuration/commit/39b59d650e9aa1282fc99e7fc87b7a595052678c))

### fix

* Make targets silenced and more specific ([fc55a7e](https://github.com/vladdoster/hammerspoon-configuration/commit/fc55a7e6c2a3860b614f07ceef004e6ff0bbb50a))
* remove `v1.5.0` from CHANGELOG so CI passes ([145e3cb](https://github.com/vladdoster/hammerspoon-configuration/commit/145e3cb915c9c4ff21af8084986f4fbf43a3da4f))
* remove release version bump check in README.md ([fa9e2c1](https://github.com/vladdoster/hammerspoon-configuration/commit/fa9e2c19f232fada84d808373823da8afe2d8a79))
* revert version to appease CI ([e242931](https://github.com/vladdoster/hammerspoon-configuration/commit/e2429311f1b00df0362e5f9d9e7a87fbd72c9240))
* semantic release configuration ([384f230](https://github.com/vladdoster/hammerspoon-configuration/commit/384f230862a5130782442d47956f690fd6f0cccf))

### maint

* update git submodules ([451772e](https://github.com/vladdoster/hammerspoon-configuration/commit/451772e887af8029ce4d7d70e4a2d0269d796d3b))

### release

* v1.4.0 → v1.5.0 ([b5f19fd](https://github.com/vladdoster/hammerspoon-configuration/commit/b5f19fde31562759230766c5883777af46e968fa))

### style

* apply lua format styling to extensions ([d52ec09](https://github.com/vladdoster/hammerspoon-configuration/commit/d52ec09e9fb82d9fd38decac61854fe856321721))
* update lua format configuration ([d795280](https://github.com/vladdoster/hammerspoon-configuration/commit/d795280eb723d83d5d24229b67692ba8789e6554))

# [1.4.0](https://github.com/vladdoster/hammerspoon-configuration/compare/v1.3.0...v1.4.0) (2022-05-06)


### feat

* add volume module ([ad3fcd7](https://github.com/vladdoster/hammerspoon-configuration/commit/ad3fcd70593a5d98e3d09672d0f27afdd1b62c92))
* switch back to lua-format ([1f5b14e](https://github.com/vladdoster/hammerspoon-configuration/commit/1f5b14ea7413bb6f66f01628263a61afc9ad7f01))

### maint

* remove broken configuration modules until I can fix ([cf7b428](https://github.com/vladdoster/hammerspoon-configuration/commit/cf7b4283d350271a9777e112fba4213efeb001b4))
* run install target when installing git submodules ([e23f23c](https://github.com/vladdoster/hammerspoon-configuration/commit/e23f23cc2d9ca43056dd74a6a2601e42a2a2521f))

### style

* adjust stylua line length ([55998c7](https://github.com/vladdoster/hammerspoon-configuration/commit/55998c7cbf0ccd63a45bdbe75e5399a63d92c11a))

# [1.3.0](https://github.com/vladdoster/hammerspoon-configuration/compare/v1.2.0...v1.3.0) (2022-04-09)


### feat

* refactor out init.lua into individual modules so I DRM' block ([a1e38f7](https://github.com/vladdoster/hammerspoon-configuration/commit/a1e38f748f4d7e86479d06beb5651b9e8d620fcb))

### maint

* clean up init.lua and battery ext ([eea840e](https://github.com/vladdoster/hammerspoon-configuration/commit/eea840e2f8c3e0ca27c931636256d6b83e155089))
* update Makefile to compile asm Hammerspoon modules ([e03e39e](https://github.com/vladdoster/hammerspoon-configuration/commit/e03e39e2dc4dc5f64445a96049565cfb94f10e0e))

# [1.2.0](https://github.com/vladdoster/hammerspoon-configuration/compare/v1.1.0...v1.2.0) (2022-03-29)


### maint

* stylua fmt ([fbc56ab](https://github.com/vladdoster/hammerspoon-configuration/commit/fbc56ab0e743aa25edc9749bc95c824da7b21260))

# [1.1.0](https://github.com/vladdoster/hammerspoon-configuration/compare/v1.0.0...v1.1.0) (2022-03-25)


### feat

* add asm spaces module as git submodule ([830f366](https://github.com/vladdoster/hammerspoon-configuration/commit/830f366a6b071428801f1a88be06d34f8b7f5a47))
* update keybinding Method ([a110b53](https://github.com/vladdoster/hammerspoon-configuration/commit/a110b53ba71233f8cd3311c834df8aca073f0f3c))

### maint

* fmtting and cleanup init.lua cruft ([ea3a212](https://github.com/vladdoster/hammerspoon-configuration/commit/ea3a212afdfa47d93e6c2d7d4a3d5c47e2a6d0fc))

# 1.0.0 (2022-03-24)


### feat

* hammerspoon configuration ([4a060aa](https://github.com/vladdoster/hammerspoon-configuration/commit/4a060aaddb13b91d431b72ae9f64dc1b22eb4a01))

### fix

* remove `v` prefix from version in `VERSION` ([f295ee8](https://github.com/vladdoster/hammerspoon-configuration/commit/f295ee82c4e9b6f0aefb06253c31ebec3f365c83))

### maint

* add commit prefix `feat` to release rules ([9966815](https://github.com/vladdoster/hammerspoon-configuration/commit/99668156cbd68170354c8e8570ff09631b268518))
