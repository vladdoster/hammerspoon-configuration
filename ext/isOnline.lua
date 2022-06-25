local obj = {}
obj.__index = obj

obj.menuItem = nil
obj.watcher = nil

function obj:start()
  self.menuItem = hs.menubar.new():setTitle('?')
  callback = function(self, flags)
    if (flags & hs.network.reachability.flags.reachable) > 0 then
      obj.menuItem:setTitle('☁️')
    else
      obj.menuItem:setTitle('🌪')
    end
  end
  self.watcher = hs.network.reachability.forAddress('8.8.8.8'):setCallback(callback):start()
  callback(self.watcher, self.watcher:status())
end
return obj