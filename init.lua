hyper, shift_hyper = {'cmd', 'alt', 'ctrl'}, {'cmd', 'alt', 'ctrl', 'shift'}

require('ext.battery')
require('ext.dockTime').start()
require('ext.infoDisplay').start()
require('ext.navigation')
require('spoons')

hs.hotkey.bindSpec({hyper, 't'}, require('ext.sysStats').toggle)
hs.hotkey.bindSpec({hyper, 'y'}, hs.toggleConsole)
hs.hotkey.bindSpec({hyper, 'r'}, hs.reload)

hs.notify.show('Hammerspoon', 'Sucessfully loaded config', '')
