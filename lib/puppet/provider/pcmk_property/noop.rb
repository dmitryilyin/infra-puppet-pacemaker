require File.join File.dirname(__FILE__), '../../pacemaker/noop'

Puppet::Type.type(:pcmk_property).provide(:noop, :parent => Puppet::Provider::Noop) do
  # disable this provider
  confine({ :true => false })
end
